import Foundation

/// 녹음 파일 하나를 받아쓴다 (App 의 SpeechTranscriber, 테스트에서는 가짜)
public protocol Transcribing: Sendable {
    /// Args: audio 는 녹음 파일, duration 은 녹음 길이(초), progress 는 0~1 진행률을 받는다.
    /// Returns: 발화별 문장. 말소리가 없으면 빈 배열.
    /// Raises: TranscriptionError.
    func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String]
}

public enum TranscriptionError: Error, Equatable, Sendable {
    /// 시스템 설정 → 키보드 → 받아쓰기가 꺼져 있음 (기기 안 인식이 kLSRErrorDomain 201 로 실패)
    case dictationDisabled
    /// 음성 인식 권한이 없음
    case speechDenied
    /// 이 Mac 에서 인식기를 쓸 수 없음 (언어 지원 등)
    case unavailable(String)
    case failed(String)

    public var message: String {
        switch self {
        case .dictationDisabled: "받아쓰기가 꺼져 있어요. 시스템 설정 → 키보드 → 받아쓰기를 켠 뒤 다시 받아쓰세요."
        case .speechDenied: "음성 인식 권한이 꺼져 있어요. 시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 Sillog을 켜 주세요."
        case .unavailable(let reason): reason
        case .failed(let reason): "받아쓰지 못했어요: \(reason)"
        }
    }

    /// 저장해 둔 실패 이유(message)로 되살린다: 받아쓰기 꺼짐·권한 없음은 그 경우로, 그 밖은 문구 그대로 (.unavailable 은 message 가 이유 그대로다)
    public static func restored(from message: String?) -> TranscriptionError {
        if message == TranscriptionError.dictationDisabled.message { return .dictationDisabled }
        if message == TranscriptionError.speechDenied.message { return .speechDenied }
        return .unavailable(message ?? "받아쓰지 못했어요.")
    }
}

/// 녹음 정리: 받아쓰기 → 제목·요약 → 받아쓴 글 .md → 폴더 추천 → ready.
/// 단계마다 DB 에 남기므로 앱이 꺼졌다 켜져도 끝난 단계는 건너뛴다 (받아쓴 글이 있으면 받아쓰기, .md 가 있으면 제목, 제안이 있으면 추천)
public struct RecordingPipeline: Sendable {
    /// 메뉴 막대에 보이는 단계
    public enum Step: Equatable, Sendable { case transcribing(Double), naming }

    public enum Outcome: Equatable, Sendable {
        /// 받아쓴 글 .md 까지 만들었다 (폴더 제안이 있으면 recording.suggestionId)
        case ready(Recording)
        /// 1초 미만이거나 받아쓴 글이 비었다: 이름·폴더 추천 없음
        case empty(Recording)
        /// 받아쓰기 실패: 녹음 파일은 남겨 둔다
        case failed(Recording, TranscriptionError)
    }

    /// 이보다 짧은 녹음은 받아쓰지 않는다 (초)
    public static let minDuration: Double = 1

    let store: RecordingStore
    let transcriber: any Transcribing
    let titler: RecordingTitler
    let textFolder: URL
    let timeZone: TimeZone
    let clock: @Sendable () -> Double

    public init(db: WGDatabase, transcriber: any Transcribing, llm: any LLMClient, textFolder: URL, timeZone: TimeZone = .current,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = RecordingStore(db); self.transcriber = transcriber; self.titler = RecordingTitler(llm: llm)
        self.textFolder = textFolder; self.timeZone = timeZone; self.clock = clock
    }

    /// 받아쓴 글을 두는 기본 폴더: ~/Documents/SILLOG 녹음
    public static func defaultTextFolder(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Documents", isDirectory: true).appendingPathComponent("SILLOG 녹음", isDirectory: true)
    }

    /// 실패한 녹음을 다시 받아쓰게 되돌린다. duration: 다시 잰 녹음 길이 (앱이 꺼져 길이를 몰랐던 녹음)
    public func prepareRetry(id: Int64, duration: Double? = nil) throws {
        guard var recording = try store.find(id: id) else { throw CocoaError(.fileNoSuchFile) }
        recording.status = .transcribing
        recording.error = nil
        if let duration, recording.duration < Self.minDuration { recording.duration = duration }
        try store.update(recording)
    }

    /// Args: id 는 끝난 녹음(status transcribing). onStep 은 메뉴 막대 단계,
    ///   suggest 는 받아쓴 글 .md 의 폴더 제안을 만든다 (녹음 기록, 내용 발췌).
    /// Returns: 결과와 저장된 녹음 기록.
    /// Raises: DB·파일 쓰기 오류. 받아쓰기 실패는 Outcome.failed 로 돌려준다.
    public func process(id: Int64, onStep: @escaping @Sendable (Step) -> Void = { _ in },
                        suggest: @escaping @Sendable (Recording, String) async -> FileSuggestion? = { _, _ in nil }) async throws -> Outcome {
        guard var recording = try store.find(id: id) else { throw CocoaError(.fileNoSuchFile) }
        switch recording.status {
        case .transcribing: break
        case .ready: return recording.hasTranscript ? .ready(recording) : .empty(recording)
        case .failed: return .failed(recording, .restored(from: recording.error))
        case .recording: throw CocoaError(.fileReadUnknown)               // 아직 녹음 중
        }

        // 1. 받아쓰기 (이미 받아쓴 글이나 .md 가 있으면 건너뛴다)
        if !recording.hasTranscript, recording.textPath == nil, recording.duration >= Self.minDuration {
            onStep(.transcribing(0))
            let gate = PercentGate()
            do {
                let audio = URL(fileURLWithPath: recording.audioPath)
                let utterances = try await transcriber.transcribe(audio: audio, duration: recording.duration) { progress in
                    if gate.advance(to: progress) { onStep(.transcribing(progress)) }
                }
                let lines = TranscriptCleanup.clean(utterances)
                recording.transcript = lines.joined(separator: "\n")
                recording.error = nil
                try store.update(recording)
            } catch {
                let failure = (error as? TranscriptionError) ?? .failed(error.localizedDescription)
                recording.status = .failed
                recording.error = failure.message
                try store.update(recording)
                return .failed(recording, failure)
            }
        }

        // 2. 짧거나 소리가 없는 녹음: 이름·폴더 추천 없이 끝낸다
        guard recording.hasTranscript else {
            if recording.title == nil { recording.title = RecordingTitler.fallbackTitle(startedAt: recording.startedAt, timeZone: timeZone) }
            recording.status = .ready
            recording.readyAt = clock()
            try store.update(recording)
            return .empty(recording)
        }

        // 3. 제목·요약과 받아쓴 글 .md
        var announced = false
        if recording.textPath == nil {
            onStep(.naming)
            announced = true
            let naming = await titler.name(transcript: recording.transcript, startedAt: recording.startedAt, duration: recording.duration, timeZone: timeZone)
            recording.title = naming.title
            recording.summary = naming.summary
            recording.textPath = try RecordingTitler.write(recording, into: textFolder, timeZone: timeZone).path
            try store.update(recording)
        }

        // 4. 폴더 추천 (제안이 이미 있으면 건너뛴다)
        if recording.suggestionId == nil {
            if !announced { onStep(.naming) }
            let excerpt = RecordingTitler.excerpt(summary: recording.summary, transcript: recording.transcript)
            if let suggestion = await suggest(recording, excerpt) { recording.suggestionId = suggestion.id }
        }

        recording.status = .ready
        recording.readyAt = clock()
        try store.update(recording)
        return .ready(recording)
    }
}

/// 진행률을 1% 단위로만 넘긴다 (인식기는 중간 결과마다 부른다)
private final class PercentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0

    func advance(to progress: Double) -> Bool {
        let percent = Int(progress * 100)
        return lock.withLock {
            guard percent > last else { return false }
            last = percent
            return true
        }
    }
}
