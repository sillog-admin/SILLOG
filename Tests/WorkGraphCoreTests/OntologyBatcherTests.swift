import XCTest
import GRDB
@testable import WorkGraphCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    var now: Double {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

extension BatchConfig {
    /// 한 번 호출 형식(assign_rows)으로 답하는 가짜 LLM 을 쓰는 테스트용. 테마 단계와 일정 찾기는 따로 테스트하므로 끈다
    static var singleCall: BatchConfig {
        var config = BatchConfig()
        config.pipeline = .single
        config.themes = false
        config.findEvents = false
        return config
    }
}

final class StubLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<String, LLMError>]
    private(set) var calls = 0
    private(set) var lastUser = ""
    private(set) var lastSystem = ""
    private(set) var users: [String] = []
    private(set) var systems: [String] = []
    let modelName = "stub-model"

    init(_ responses: [Result<String, LLMError>]) { self.responses = responses }

    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        let next: Result<String, LLMError> = lock.withLock {
            calls += 1
            lastUser = user
            lastSystem = system
            users.append(user)
            systems.append(system)
            return responses.isEmpty ? .failure(LLMError.transport("no stub")) : responses.removeFirst()
        }
        let json = try next.get()
        return LLMResult(arguments: Data(json.utf8), model: modelName, promptTokens: 100, completionTokens: 20, raw: json)
    }
}

final class OntologyBatcherTests: XCTestCase {
    private let patch = """
    {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],"rows":[{"rows":"1-2","task":"A"}],
     "work":[{"task":"A","summary":"카드 구현","topics":["React"]}]}
    """

    private func seed(_ db: WGDatabase) throws -> [Int64] {
        let store = EventStore(db)
        return [
            try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.todesktop.230313mzl4w4u92", appName: "Cursor", windowTitle: "TaskCard.tsx — dashboard")),
            try store.insert(Observation(ts: 160, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                         windowTitle: "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card")),
            try store.insert(Observation(ts: 400, trigger: "app_activate", appBundle: "com.apple.Terminal", appName: "Terminal", windowTitle: "npm run dev")),
        ]
    }

    private func makeBatcher(_ db: WGDatabase, _ llm: StubLLM, _ clock: TestClock) -> OntologyBatcher {
        OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { clock.now })
    }

    func testSeparateJudgmentFailureKeepsRecordsAndRetriesTheSameJudge() async throws {
        let db = try WGDatabase.inMemory()
        let ids = try seed(db)
        let clock = TestClock(500)
        let judge = StubLLM([
            .failure(.http(500, "judge unavailable")),
            .success(#"{"rows":[{"row":1,"choice":"new","reason":"작업 시작"}]}"#),
            .success(#"{"rows":[{"row":1,"choice":"off","reason":"업무 외"},{"row":2,"choice":"none","reason":"근거 부족"}]}"#),
        ])
        let organizer = StubLLM([
            .success(#"{"tasks":[{"rows":[1],"title":"대시보드 카드","goal":"대시보드 카드 구현"}]}"#),
            .success(#"{"resources":[],"work":[],"problems":[],"later_items":[]}"#),
        ])
        var config = BatchConfig()
        config.findEvents = false; config.screenCards = false
        let batcher = OntologyBatcher(db: db, llm: organizer, config: config, activityJudge: .gpt(judge), clock: { clock.now })
        let store = EventStore(db)

        guard case .failed = await batcher.runIfDue(force: true) else { return XCTFail("판단 실패가 기록되어야 합니다.") }
        XCTAssertEqual(try store.unprocessed(limit: 10).compactMap(\.id), ids)
        XCTAssertEqual(organizer.calls, 0)
        guard case .skipped = await batcher.runIfDue(force: false) else { return XCTFail("자동 재시도 간격을 지켜야 합니다.") }
        XCTAssertEqual(judge.calls, 1)

        clock.now += 61
        guard case .ok(let stats) = await batcher.runIfDue(force: false) else { return XCTFail("판단한 행을 정리해야 합니다.") }
        XCTAssertEqual(stats.deferredJudgmentRows, 2)
        XCTAssertEqual(try store.unprocessed(limit: 10).compactMap(\.id), Array(ids.dropFirst()))
        XCTAssertFalse(organizer.users.contains { $0.contains("npm run dev") })

        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("보류한 행을 같은 판단 모델로 재시도해야 합니다.") }
        XCTAssertTrue(try store.unprocessed(limit: 10).isEmpty)
        XCTAssertEqual(judge.calls, 3)
    }

    func testSkipsWhenNothingToDoOrTooYoung() async throws {
        let db = try WGDatabase.inMemory()
        let clock = TestClock(200)
        let llm = StubLLM([.success(patch)])
        let batcher = makeBatcher(db, llm, clock)
        guard case .skipped = await batcher.runIfDue(force: false) else { return XCTFail("미처리 없음이면 skipped") }

        _ = try seed(db)
        guard case .skipped = await batcher.runIfDue(force: false) else { return XCTFail("5분 미경과면 skipped") }
        XCTAssertEqual(llm.calls, 0)

        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("force 면 실행") }
        XCTAssertEqual(llm.calls, 1)
        XCTAssertTrue(try EventStore(db).unprocessed(limit: 10).isEmpty)   // force 는 진행 중인 마지막 행까지 처리
    }

    func testSuccessMarksRowsButLeavesFreshLastObservation() async throws {
        let db = try WGDatabase.inMemory()
        let ids = try seed(db)
        let clock = TestClock(450)
        let llm = StubLLM([.success(patch)])
        let outcome = await makeBatcher(db, llm, clock).runIfDue(force: false)
        guard case .ok(let stats) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(stats.tasksCreated, 1)
        XCTAssertEqual(stats.sessions, 1)

        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).map(\.id), [ids[2]])   // 방금 시작한 행은 다음 배치로
        XCTAssertTrue(llm.lastUser.contains("| 60s |"))                                  // Cursor 100→160
        XCTAssertTrue(llm.lastUser.contains("| 90s |"))                                  // Chrome 160→(400, 상한 90)
        XCTAssertFalse(llm.lastUser.contains("npm run dev"))

        let batch = try XCTUnwrap(EventStore(db).recentBatches(limit: 1).first)
        XCTAssertEqual(batch.status, "ok")
        XCTAssertEqual(batch.systemPrompt, OntologyPrompt.system)                       // LLM 이 받은 것이 그대로 남는다
        XCTAssertTrue(batch.userPrompt?.contains("ROWS (row | time | dwell") ?? false)
        XCTAssertTrue(batch.llmPatch?.contains("\"title\" : \"대시보드 카드 UI 구현\"") ?? false)   // 받은 것
        XCTAssertTrue(batch.appliedPatch?.contains("1 | 대시보드 카드 UI 구현") ?? false)              // 반영한 것 (행 | 업무)
        XCTAssertEqual(batch.model, "stub-model")
        XCTAssertEqual(batch.promptTokens, 100)
        XCTAssertEqual(batch.rowCount, 2)
        XCTAssertEqual(batch.fromObs, ids[0])
        XCTAssertEqual(batch.toObs, ids[1])
        let tasks = try await db.writer.read { try GraphTx($0).nodes(label: "Task") }
        XCTAssertEqual(tasks.map(\.title), ["대시보드 카드 UI 구현"])
    }

    func testFailureKeepsRowsAndBacksOff() async throws {
        let db = try WGDatabase.inMemory()
        _ = try seed(db)
        let clock = TestClock(450)
        let llm = StubLLM([.failure(.http(500, "token invalid")), .success(patch.replacingOccurrences(of: "1-2", with: "1-3"))])
        let batcher = makeBatcher(db, llm, clock)

        guard case .failed(let message) = await batcher.runIfDue(force: false) else { return XCTFail("실패여야 함") }
        XCTAssertTrue(message.contains("500"))
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 3)
        let failed = try XCTUnwrap(EventStore(db).recentBatches(limit: 1).first)
        XCTAssertEqual(failed.status, "failed")
        XCTAssertNotNil(failed.userPrompt, "실패해도 무엇을 보냈는지는 남긴다")
        XCTAssertNil(failed.llmPatch)

        clock.now = 470                                                       // 백오프(60초) 안
        guard case .skipped = await batcher.runIfDue(force: false) else { return XCTFail("백오프 중이면 skipped") }
        XCTAssertEqual(llm.calls, 1)

        clock.now = 520
        guard case .ok = await batcher.runIfDue(force: false) else { return XCTFail("백오프가 지나면 재시도") }
        XCTAssertEqual(llm.calls, 2)
    }

    func testRerunAfterSuccessDoesNotChangeGraph() async throws {
        let db = try WGDatabase.inMemory()
        _ = try seed(db)
        let clock = TestClock(450)
        let llm = StubLLM([.success(patch), .success(patch)])
        let batcher = makeBatcher(db, llm, clock)
        _ = await batcher.runIfDue(force: false)
        let before = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nodes") }
        guard case .skipped = await batcher.runIfDue(force: false) else { return XCTFail("남은 행은 아직 어림") }
        let after = try await db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nodes") }
        XCTAssertEqual(after, before)
        XCTAssertEqual(llm.calls, 1)
    }

    func testUnusableAnswersRemainPendingAfterRepeatedFailures() async throws {
        let db = try WGDatabase.inMemory()
        _ = try seed(db)
        let clock = TestClock(450)
        let llm = StubLLM(Array(repeating: .success(#"{"tasks":[],"rows":[],"work":[]}"#), count: 5))
        let batcher = makeBatcher(db, llm, clock)
        for _ in 0..<5 {
            guard case .failed = await batcher.runIfDue(force: false) else { return XCTFail("빈 배정은 실패") }
            clock.now += 4000
        }
        XCTAssertEqual(llm.calls, 5)
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 3)
    }

    func testIncompleteAssignmentsRollBackAndCanBeRetried() async throws {
        let invalid = [
            patch.replacingOccurrences(of: "1-2", with: "1"),
            patch.replacingOccurrences(of: "1-2", with: "1-4"),
            patch.replacingOccurrences(of: "\"task\":\"A\"", with: "\"task\":\"unknown\""),
            #"{"tasks":[],"rows":[{"rows":"1-2","task":null},{"rows":"2","task":null}],"work":[]}"#,
        ]
        for response in invalid {
            let db = try WGDatabase.inMemory()
            _ = try seed(db)
            let clock = TestClock(450)
            let batcher = makeBatcher(db, StubLLM([.success(response), .success(patch.replacingOccurrences(of: "1-2", with: "1-3"))]), clock)
            guard case .failed = await batcher.runIfDue(force: false) else { return XCTFail("불완전한 배정은 실패") }
            XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 3)
            let tasks = try await db.writer.read { try GraphTx($0).nodes(label: "Task") }
            XCTAssertTrue(tasks.isEmpty, "실패한 응답이 만든 업무도 롤백")
            clock.now = 510
            guard case .ok = await batcher.runIfDue(force: false) else { return XCTFail("정상 응답은 재시도 성공") }
            XCTAssertTrue(try EventStore(db).unprocessed(limit: 10).isEmpty)
        }
    }
}
