import AppKit
import Foundation
import WorkGraphCore

/// 녹음 중인 것: 메뉴 막대 빨간 점과 "녹음 중 12:31"
struct ActiveRecording: Equatable {
    let id: Int64
    let startedAt: Double
}

/// 메뉴 막대 녹음: 시작 → 끝 → 받아쓰기 → 제목·.md → 폴더 제안 → 알림.
/// 받아쓰는 동안에도 새로 녹음할 수 있고, 정리는 하나씩 차례로 한다 (기기 안 인식기를 하나만 쓴다)
extension AppState {
    static let crashedRecordingMessage = "녹음 중 앱이 꺼져 녹음 파일을 읽을 수 없어요"
    /// 녹음기가 (인코딩 오류·입력 장치 끊김·디스크 가득 참으로) 스스로 멈춰 currentTime 이 0 이고, 파일에서도 길이를 잴 수 없을 때
    static let stoppedRecordingMessage = "녹음이 중간에 멈춰 녹음된 소리를 찾지 못했어요"

    /// 녹음기가 돌려준 길이(stopped)와 파일에서 다시 잰 길이(file) 중 더 믿을 만한 값.
    /// AVAudioRecorder 가 스스로 멈추면(인코딩 오류 등) currentTime 이 0 인데, 파일에는 소리가 남아 있을 수 있다
    static func recordedDuration(stopped: Double, file: Double?) -> Double { max(stopped, file ?? 0) }

    func refreshRecordings() {
        guard let db else { return }
        let fresh = (try? RecordingStore(db).all()) ?? []
        if fresh != recordings { recordings = fresh }
    }

    /// 메뉴 막대 [● 녹음 시작]. 권한이 없으면 녹음하지 않고 안내만 남긴다
    func startRecording() async {
        guard activeRecording == nil, let db else { return }
        if let problem = await recordingPermissions.check() {
            recordingProblem = problem
            AppLog.write("녹음 시작 안 함: \(problem.text)")
            return
        }
        guard activeRecording == nil else { return }                    // 권한 창을 기다리는 동안 한 번 더 눌린 경우
        recordingProblem = nil
        let store = RecordingStore(db)
        let now = Date().timeIntervalSince1970
        do {
            var recording = try store.insert(Recording(startedAt: now, audioPath: ""))
            guard let id = recording.id else { return }
            let url = db.recordingsDirectory.appendingPathComponent("\(id).m4a")
            recording.audioPath = url.path
            try store.update(recording)
            var samples: (@Sendable ([Float]) -> Void)?
            if let session = liveTranscriptions?.begin(audio: url) { samples = { session.append($0) } }
            do {
                try recorder.start(to: url, samples: samples)
            } catch {
                liveTranscriptions?.discard(url)
                try? store.delete(id: id)
                throw error
            }
            activeRecording = ActiveRecording(id: id, startedAt: now)
            AppLog.write("녹음 시작: \(url.lastPathComponent)")
        } catch {
            recordingProblem = .failed("녹음을 시작하지 못했어요. \(error.localizedDescription)")
            AppLog.write("녹음 시작 실패: \(error)")
        }
        refreshRecordings()
    }

    /// [■ 끝내기]: 파일을 닫고 받아쓰기부터 차례로 이어 간다. 이 녹음의 정리가 끝나면 돌아온다
    func stopRecording() async {
        guard let id = closeActiveRecording() else { return }
        await enqueueRecording(id)
    }

    /// 앱을 끝낼 때 녹음 중이면 파일을 닫아 둔다. 다음 실행 때 받아쓰기부터 이어 간다
    func finishRecordingOnQuit() {
        if let id = closeActiveRecording() { AppLog.write("앱 종료: 녹음 \(id) 을 닫고 다음 실행 때 받아씀") }
    }

    /// 보관함 [다시 받아쓰기] (받아쓰기에 실패한 녹음). recording 은 화면이 들고 있던 값이라 다시 읽어 확인한다 (두 번 눌렸거나 그사이 바뀌었을 수 있다)
    func retranscribe(_ recording: Recording) async {
        guard let id = recording.id, let db, let pipeline = recordingPipeline else { return }
        guard let current = try? RecordingStore(db).find(id: id), current.status == .failed else { return }
        let audioURL = URL(fileURLWithPath: current.audioPath)
        let duration = AudioFileInfo.duration(of: audioURL)
        if duration == nil, current.duration < RecordingPipeline.minDuration {
            // 녹음 중 앱이 꺼져 파일이 끝까지 쓰이지 않았고 길이도 모른다: 다시 받아써도 내용이 없다고 잘못 끝나지 않게 실패로 둔다
            recordingProblem = .failed(Self.crashedRecordingMessage)
            AppLog.write("녹음 \(id): \(Self.crashedRecordingMessage)")
            return
        }
        do {
            try pipeline.prepareRetry(id: id, duration: duration)
        } catch {
            recordingProblem = .failed("다시 받아쓰지 못했어요. \(error.localizedDescription)")
            return
        }
        recordingProblem = nil
        refreshRecordings()
        await enqueueRecording(id)
    }

    /// 앱을 켤 때: 꺼지기 전에 끝나지 않은 녹음을 이어서 정리한다. 녹음 중 꺼진 파일은 읽히면 받아쓰고, 안 읽히면 실패로 둔다
    func resumeRecordings() async {
        guard let db else { return }
        let store = RecordingStore(db)
        for var recording in (try? store.unfinished()) ?? [] {
            guard let id = recording.id, id != activeRecording?.id else { continue }
            if recording.status == .recording {
                guard let seconds = AudioFileInfo.duration(of: URL(fileURLWithPath: recording.audioPath)) else {
                    recording.status = .failed
                    recording.error = Self.crashedRecordingMessage
                    try? store.update(recording)
                    AppLog.write("녹음 \(id): \(Self.crashedRecordingMessage)")
                    continue
                }
                recording.duration = seconds
                recording.endedAt = recording.startedAt + seconds
                recording.status = .transcribing
                try? store.update(recording)
            }
            await enqueueRecording(id)
        }
        refreshRecordings()
    }

    /// 받아쓰기가 끝나고 7일 지난 녹음 파일을 지운다 (받아쓴 글은 남는다)
    func deleteExpiredRecordingAudio() {
        guard let db else { return }
        guard let count = try? RecordingStore(db).deleteExpiredAudio(now: Date().timeIntervalSince1970), count > 0 else { return }
        AppLog.write("녹음 파일 \(count)개를 지움 (받아쓰기 끝나고 7일)")
        refreshRecordings()
    }

    /// 정리를 차례로: 앞의 정리가 끝난 뒤에 시작하고, 이 녹음의 정리가 끝나면 돌아온다
    func enqueueRecording(_ id: Int64) async {
        guard queuedRecordingIds.insert(id).inserted else { return }                 // 이미 차례를 기다리는 녹음
        let previous = recordingQueue
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.processRecording(id)
            self?.queuedRecordingIds.remove(id)
        }
        recordingQueue = task
        await task.value
    }

    /// 정리 단계 알림. 끝난 정리가 늦게 보낸 알림(token 이 다름)은 버린다
    func applyRecordingStep(_ step: RecordingPipeline.Step, token: Int) {
        guard token == recordingStepToken else { return }
        if case .transcribing = step, case .naming? = recordingWork { return }
        recordingWork = step
    }

    /// 파일 탭·알림에서 받아쓴 글을 옮기거나 되돌리면 녹음 기록의 경로도 따라간다
    func recordingTextMoved(from old: String?, to new: String) {
        guard let db, let old, old != new else { return }
        guard (try? RecordingStore(db).moveText(from: old, to: new)) == true else { return }
        AppLog.write("녹음 글 경로 바뀜: \(new)")
        refreshRecordings()
    }

    /// 보관함 [녹음 삭제]: 정리가 끝났거나(ready) 실패한(failed) 녹음만, 녹음 중인 것은 지우지 않는다.
    /// 받아쓴 글(.md)은 사용자 파일이라 남긴다. 그래프에서도 카드가 빠지게 graphVersion 을 올린다
    func deleteRecording(_ recording: Recording) {
        guard let id = recording.id, let db, id != activeRecording?.id else { return }
        guard let current = try? RecordingStore(db).find(id: id), current.status == .ready || current.status == .failed else { return }
        do {
            try RecordingStore(db).remove(id: id)
            AppLog.write("녹음 \(id) 지움")
            refreshRecordings()
            graphVersion += 1
        } catch {
            recordingProblem = .failed("녹음을 지우지 못했어요. \(error.localizedDescription)")
        }
    }

    /// 그래프 카드의 녹음 자료(recording:<id>) → 받아쓴 글 파일. 파일이 없으면 nil
    func recordingTextURL(key: String) -> URL? {
        guard key.hasPrefix("recording:"), let id = Int64(key.dropFirst("recording:".count)), let db,
              let recording = try? RecordingStore(db).find(id: id), let path = recording.textPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func openRecordingText(key: String) {
        guard let url = recordingTextURL(key: key) else { AppLog.write("녹음 글을 찾지 못함: \(key)"); return }
        if !NSWorkspace.shared.open(url) { AppLog.write("열기 실패: \(url.path)") }
    }

    // MARK: 안쪽

    /// 녹음기를 멈추고 기록을 '받아쓰는 중'으로 바꾼다. 녹음기가 스스로 멈춰 길이를 0으로 돌려줘도 파일에서 다시 재 보고,
    /// 그래도 0이면(소리를 못 찾으면) 받아쓰기로 넘기지 않고 바로 실패로 남겨 재시도할 수 있게 한다. 닫은 녹음 id
    private func closeActiveRecording() -> Int64? {
        guard let active = activeRecording, let db else { return nil }
        let seconds = recorder.stop()
        activeRecording = nil
        let store = RecordingStore(db)
        if var recording = try? store.find(id: active.id) {
            let duration = Self.recordedDuration(stopped: seconds, file: AudioFileInfo.duration(of: URL(fileURLWithPath: recording.audioPath)))
            recording.endedAt = Date().timeIntervalSince1970
            recording.duration = duration
            if duration == 0 {
                recording.status = .failed
                recording.error = Self.stoppedRecordingMessage
                liveTranscriptions?.discard(URL(fileURLWithPath: recording.audioPath))
            } else {
                recording.status = .transcribing
            }
            try? store.update(recording)
        }
        AppLog.write("녹음 끝: \(Int(seconds))초")
        refreshRecordings()
        return active.id
    }

    private func processRecording(_ id: Int64) async {
        guard let pipeline = recordingPipeline else { return }
        recordingStepToken += 1
        let token = recordingStepToken
        recordingWork = .transcribing(0)
        refreshRecordings()
        do {
            let outcome = try await pipeline.process(id: id, onStep: { [weak self] step in
                Task { @MainActor in self?.applyRecordingStep(step, token: token) }
            }, suggest: { [weak self] recording, excerpt in
                await self?.suggestFolder(for: recording, excerpt: excerpt)
            })
            switch outcome {
            case .ready(let recording):
                AppLog.write("녹음 정리 끝: \(recording.textPath ?? "")")
                notifyRecordingReady(recording)
            case .empty:
                AppLog.write("녹음 \(id): 받아쓴 글 없음 (짧거나 소리가 없음)")
            case .failed(_, let error):
                AppLog.write("녹음 \(id) 받아쓰기 실패: \(error.message)")
                recordingProblem = RecordingProblem(error)
            }
        } catch {
            AppLog.write("녹음 \(id) 정리 실패: \(error)")
            recordingProblem = .failed("녹음을 정리하지 못했어요. \(error.localizedDescription)")
        }
        recordingStepToken += 1                                             // 늦게 온 단계 알림은 버린다
        recordingWork = nil
        if let db, let path = try? RecordingStore(db).find(id: id)?.audioPath {
            liveTranscriptions?.discard(URL(fileURLWithPath: path))       // 받아쓰기를 건너뛴 녹음(1초 미만)의 미리 받아쓰기
        }
        refreshRecordings()
    }

    /// 받아쓴 글 .md 의 폴더 제안: 녹음하는 동안 본 창과 최근 업무, 내용 발췌로 판단한다
    private func suggestFolder(for recording: Recording, excerpt: String) async -> FileSuggestion? {
        guard settings.suggestFolders, let suggester, let db, let path = recording.textPath else { return nil }
        let now = Date().timeIntervalSince1970
        let index = await currentFolderIndex()
        let observations = (try? store?.recent(limit: 120)) ?? []
        let openTasks: [TaskDigest] = (try? await db.writer.read { try GraphTx($0).openTasks(limit: 6) }) ?? []
        let currentTask = openTasks.first.flatMap { $0.lastActive > now - 1_800 ? $0.id : nil }
        let context = FolderSuggester.Context(recentTitles: Self.recentContext(from: observations, since: recording.startedAt - 600),
                                              openTasks: openTasks, currentTaskKey: currentTask, now: now,
                                              contentExcerpt: excerpt, kind: .recording)
        do {
            let suggestion = try await suggester.suggest(filePath: path, originURL: nil, index: index, context: context)
            if let suggestion {
                AppLog.write("녹음 폴더 제안: \(suggestion.fileName) → \(suggestion.suggestedFolder)")
                refreshFileSuggestions()
            }
            return suggestion
        } catch {
            AppLog.write("녹음 폴더 제안 실패: \(String(describing: error).prefix(200))")
            await handleAuthLossIfNeeded()
            return nil
        }
    }

    /// 폴더 제안이 있으면 [옮기기][무시] 알림, 없으면 저장한 곳만 알린다
    private func notifyRecordingReady(_ recording: Recording) {
        guard let db, let path = recording.textPath else { return }
        let home = NSHomeDirectory()
        if let id = recording.suggestionId, let suggestion = try? FileSuggestionStore(db).suggestion(id: id), suggestion.status == "pending" {
            notifier.notify(suggestion, home: home, recording: true)
        } else {
            notifier.notifyTranscribed(fileName: (path as NSString).lastPathComponent, folder: (path as NSString).deletingLastPathComponent, home: home)
        }
    }
}
