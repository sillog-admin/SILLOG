import XCTest
@testable import SillogCore

/// 순서대로 결과를 돌려주는 가짜 받아쓰기. 부를 때마다 진행률 0.5 를 한 번 알린다
final class FakeTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[String], TranscriptionError>]
    private(set) var calls = 0
    init(_ results: [Result<[String], TranscriptionError>]) { self.results = results }

    func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        let next: Result<[String], TranscriptionError> = lock.withLock {
            calls += 1
            return results.isEmpty ? .failure(.failed("no stub")) : results.removeFirst()
        }
        progress(0.5)
        return try next.get()
    }
}

/// @Sendable 콜백이 남긴 값을 모은다
final class Collected<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Value] = []
    func append(_ value: Value) { lock.withLock { items.append(value) } }
    var values: [Value] { lock.withLock { items } }
}

/// 받아쓰기 → 제목·요약 → 받아쓴 글 .md → 폴더 추천 → ready, 그리고 실패·짧은 녹음·이어 하기
final class RecordingPipelineTests: XCTestCase {
    private var db: SillogDatabase!
    private var folder: URL!
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let naming = #"{"title":"자료구조 3주차 강의","summary":"연결 리스트를 설명한 강의."}"#

    /// 2026-10-10 15:32 (서울)
    private var start: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 32))!.timeIntervalSince1970
    }

    override func setUpWithError() throws {
        db = try SillogDatabase.inMemory()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private var textFolder: URL { folder.appendingPathComponent("SILLOG 녹음") }

    private func pipeline(_ transcriber: FakeTranscriber, _ llm: StubLLM) -> RecordingPipeline {
        RecordingPipeline(db: db, transcriber: transcriber, llm: llm, textFolder: textFolder, timeZone: seoul, clock: { 5_000 })
    }

    /// 끝난 녹음 (status transcribing). 녹음 파일도 만든다
    private func finished(duration: Double = 95) throws -> Recording {
        let audio = folder.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: audio)
        return try RecordingStore(db).insert(Recording(startedAt: start, endedAt: start + duration, duration: duration, audioPath: audio.path, status: .transcribing))
    }

    func testTranscribesNamesWritesTheTextFileSuggestsAFolderAndBecomesReady() async throws {
        let item = try finished()
        let llm = StubLLM([.success(naming)])
        let steps = Collected<RecordingPipeline.Step>()
        let excerpts = Collected<String>()
        let database = db!
        let outcome = try await pipeline(FakeTranscriber([.success(["오늘은 연결 리스트를 봅니다.", "노드는 값과 포인터를 가집니다."])]), llm)
            .process(id: item.id!, onStep: { steps.append($0) }, suggest: { recording, excerpt in
                excerpts.append(excerpt)
                return try? FileSuggestionStore(database).insert(FileSuggestion(ts: 5_000, path: recording.textPath!, fileName: "x.md", originUrl: nil,
                                                                                suggestedFolder: "/Users/me/학교/자료구조", confidence: 0.9, reason: "r", source: "llm"))
            })
        guard case .ready(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.readyAt, 5_000)
        XCTAssertEqual(saved.title, "자료구조 3주차 강의")
        XCTAssertEqual(saved.summary, "연결 리스트를 설명한 강의.")
        XCTAssertEqual(saved.transcript, "오늘은 연결 리스트를 봅니다.\n노드는 값과 포인터를 가집니다.")
        let path = try XCTUnwrap(saved.textPath)
        XCTAssertEqual((path as NSString).lastPathComponent, "2026-10-10 자료구조 3주차 강의.md")
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("# 자료구조 3주차 강의\n"))
        XCTAssertNotNil(saved.suggestionId)
        XCTAssertEqual(excerpts.values, ["연결 리스트를 설명한 강의.\n오늘은 연결 리스트를 봅니다. 노드는 값과 포인터를 가집니다."])
        XCTAssertEqual(steps.values, [.transcribing(0), .transcribing(0.5), .naming])
        XCTAssertEqual(try RecordingStore(db).find(id: item.id!), saved, "돌려준 값이 저장된 값")
    }

    func testDictationOffFailsKeepsTheAudioAndCanBeRetried() async throws {
        let item = try finished()
        let llm = StubLLM([.success(naming)])
        let runner = pipeline(FakeTranscriber([.failure(.dictationDisabled), .success(["다시 받아쓴 문장."])]), llm)
        let first = try await runner.process(id: item.id!)
        guard case .failed(let failed, .dictationDisabled) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.error, TranscriptionError.dictationDisabled.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.audioPath))
        XCTAssertEqual(llm.calls, 0)

        try runner.prepareRetry(id: item.id!)
        XCTAssertEqual(try RecordingStore(db).find(id: item.id!)?.status, .transcribing)
        let second = try await runner.process(id: item.id!)
        guard case .ready(let ready) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(ready.transcript, "다시 받아쓴 문장.")
        XCTAssertNil(ready.error)
    }

    func testAShortRecordingIsReadyWithoutTranscriptionNamingOrAFile() async throws {
        let item = try finished(duration: 0.6)
        let transcriber = FakeTranscriber([.success(["들리면 안 됨"])])
        let llm = StubLLM([])
        let outcome = try await pipeline(transcriber, llm).process(id: item.id!)
        guard case .empty(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(transcriber.calls, 0)
        XCTAssertEqual(llm.calls, 0)
        XCTAssertNil(saved.textPath)
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.title, "녹음 2026-10-10 15-32")
    }

    func testMadeUpRepeatsAreLeftOutOfTheSavedText() async throws {
        let item = try finished()
        let llm = StubLLM([.success(naming)])
        let loop = ["오늘은 연결 리스트를 봅니다.", "-"] + Array(repeating: "최선은", count: 12) + ["노드는 값과 포인터를 가집니다."]
        let outcome = try await pipeline(FakeTranscriber([.success(loop)]), llm).process(id: item.id!)
        guard case .ready(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(saved.transcript, "오늘은 연결 리스트를 봅니다.\n최선은\n노드는 값과 포인터를 가집니다.")
    }

    func testASilentRecordingMakesNoTextFile() async throws {
        let item = try finished()
        let llm = StubLLM([])
        let outcome = try await pipeline(FakeTranscriber([.success([])]), llm).process(id: item.id!)
        guard case .empty(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(llm.calls, 0)
        XCTAssertNil(saved.textPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: textFolder.path))
    }

    func testModelFailureFallsBackToTheDateTitle() async throws {
        let item = try finished()
        let outcome = try await pipeline(FakeTranscriber([.success(["회의 내용입니다."])]), StubLLM([.failure(.transport("offline"))])).process(id: item.id!)
        guard case .ready(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(saved.title, "녹음 2026-10-10 15-32")
        XCTAssertNil(saved.summary)
        XCTAssertEqual((saved.textPath! as NSString).lastPathComponent, "녹음 2026-10-10 15-32.md")
    }

    func testResumingSkipsTheStepsAlreadyDone() async throws {
        var item = try finished()
        let md = folder.appendingPathComponent("이미.md")
        try Data("# 이미".utf8).write(to: md)
        item.transcript = "이미 받아쓴 문장."
        item.title = "이미 지은 제목"
        item.textPath = md.path
        try RecordingStore(db).update(item)
        let transcriber = FakeTranscriber([])
        let llm = StubLLM([])
        let asked = Collected<String>()
        let outcome = try await pipeline(transcriber, llm).process(id: item.id!, suggest: { recording, _ in asked.append(recording.textPath ?? ""); return nil })
        guard case .ready(let saved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(transcriber.calls, 0)
        XCTAssertEqual(llm.calls, 0)
        XCTAssertEqual(asked.values, [md.path], "폴더 추천만 다시 한다")
        XCTAssertEqual(saved.textPath, md.path)
    }

    func testProcessingAReadyRecordingChangesNothing() async throws {
        let ready = try RecordingStore(db).insert(Recording(startedAt: start, endedAt: start + 60, duration: 60, audioPath: "/a.m4a",
                                                             transcript: "가", status: .ready, readyAt: 100))
        let outcome = try await pipeline(FakeTranscriber([]), StubLLM([])).process(id: ready.id!)
        XCTAssertEqual(outcome, .ready(ready))
        XCTAssertEqual(try RecordingStore(db).find(id: ready.id!)?.readyAt, 100)
    }

    func testProcessingAFailedRecordingReturnsItsStoredReasonUnchanged() async throws {
        let store = RecordingStore(db)
        let dictation = try store.insert(Recording(startedAt: start, endedAt: start + 60, duration: 60, audioPath: "/a.m4a",
                                                   status: .failed, error: TranscriptionError.dictationDisabled.message))
        let other = try store.insert(Recording(startedAt: start, endedAt: start + 60, duration: 60, audioPath: "/b.m4a",
                                               status: .failed, error: "인식기를 쓸 수 없어요"))
        let runner = pipeline(FakeTranscriber([]), StubLLM([]))
        let first = try await runner.process(id: dictation.id!)
        guard case .failed(_, .dictationDisabled) = first else { return XCTFail("\(first)") }
        let second = try await runner.process(id: other.id!)
        guard case .failed(_, let error) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(error.message, "인식기를 쓸 수 없어요", "저장된 이유를 다시 감싸지 않는다")
    }
}
