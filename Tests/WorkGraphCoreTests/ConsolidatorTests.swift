import XCTest
import GRDB
@testable import WorkGraphCore

private typealias F = ConsolidationFixtures

final class ConsolidatorTests: XCTestCase {
    /// 2026-W40 = 9/28(월) ~ 10/4(일). 주의 끝은 10/5 0시 (KST)
    private let weekEnd = F.at("2026-10-05", 0)

    private func digests(_ db: WGDatabase) throws -> [Digest] {
        try db.writer.read { try DigestStore.recent($0) }
    }

    func testWeekClosesOnlyFortyEightHoursAfterItEnds() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        let clock = TestClock(weekEnd + 47 * 3600)
        let consolidator = F.consolidator(db, clock: clock)
        _ = await consolidator.run(prune: false, narrate: false)
        XCTAssertTrue(try digests(db).isEmpty, "닫히기 전에는 만들지 않는다")

        clock.now = weekEnd + 49 * 3600
        let report = await consolidator.run(prune: false, narrate: false)
        XCTAssertEqual(report.weekly, 1)
        let digest = try XCTUnwrap(try digests(db).first)
        XCTAssertEqual(digest.period, "2026-W40")
        XCTAssertEqual(digest.status, .verified)
        XCTAssertEqual(digest.metrics.activeSeconds, 30 * 60, accuracy: 120)
        XCTAssertTrue(digest.body.contains("약 30분") || digest.body.contains("약 31분"), digest.body)
    }

    func testPendingObservationsKeepTheWeekOpen() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        try EventStore(db).insert(Observation(ts: F.at("2026-10-02", 9), trigger: "periodic", appBundle: "com.test.Cursor", appName: "Cursor", windowTitle: "미처리"))
        let report = await F.consolidator(db, clock: TestClock(weekEnd + 72 * 3600)).run(prune: false, narrate: false)
        XCTAssertEqual(report.weekly, 0)
        XCTAssertTrue(try digests(db).isEmpty, "정리 배치에 안 들어간 관측이 있으면 기간을 닫지 않는다")
    }

    func testValidNarrationIsVerifiedAndUnchangedInputIsNotRebuilt() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        let key = try F.taskKey(db, title: "보고서 작성")
        let llm = AllRowsLLM(title: nil) { _ in .success(F.groundedDigestJSON(taskKey: key)) }
        let clock = TestClock(weekEnd + 72 * 3600)
        _ = await F.consolidator(db, llm: llm, clock: clock).run(prune: false)
        let digest = try XCTUnwrap(try digests(db).first)
        XCTAssertEqual(digest.status, .verified)
        XCTAssertEqual(digest.model, "all-rows")
        XCTAssertTrue(digest.body.contains("보고서 초안을 작성했다"))
        let calls = llm.digestCalls
        _ = await F.consolidator(db, llm: llm, clock: clock).run(prune: false)
        XCTAssertEqual(llm.digestCalls, calls, "입력이 같으면 다시 만들지 않는다")
    }

    func testRejectedNarrationStaysDraftAndStopsAfterThirdAttempt() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        let key = try F.taskKey(db, title: "보고서 작성")
        let llm = AllRowsLLM(title: nil) { _ in
            .success("""
            {"summary":"보고서 777쪽을 끝냈다.","progress":[{"text":"끝냈다.","status":"in_progress","anchors":["\(key)"]}],"problems":[],"open_items":[]}
            """)
        }
        let clock = TestClock(weekEnd + 72 * 3600)
        for attempt in 1...3 {
            _ = await F.consolidator(db, llm: llm, clock: clock).run(prune: false)
            let digest = try XCTUnwrap(try digests(db).first)
            XCTAssertEqual(digest.attempts, attempt)
            XCTAssertEqual(digest.status, .draft, "검증 실패 \(attempt)번째")
            XCTAssertFalse(digest.body.contains("777"), "검증에 실패한 서술은 저장하지 않는다")
            clock.now += 86_400
        }
        let calls = llm.digestCalls
        let report = await F.consolidator(db, llm: llm, clock: clock).run(prune: false)
        XCTAssertEqual(llm.digestCalls, calls, "같은 입력으로 세 번 실패하면 다시 부르지 않는다")
        XCTAssertEqual(report.weeklyDrafts, 0, "다시 만들지 않은 초안은 처리 한도를 쓰지 않는다")
        XCTAssertEqual(try XCTUnwrap(try digests(db).first).status, .draft, "실패한 요약을 확정하지 않는다")
    }

    func testLLMOutageKeepsDraftWithoutCountingAttempts() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        let llm = AllRowsLLM(title: nil) { _ in .failure(.transport("오프라인")) }
        let report = await F.consolidator(db, llm: llm, clock: TestClock(weekEnd + 72 * 3600)).run(prune: false)
        let digest = try XCTUnwrap(try digests(db).first)
        XCTAssertEqual(digest.status, .draft)
        XCTAssertEqual(digest.attempts, 0)
        XCTAssertTrue(report.notes.contains { $0.contains("연결") })
    }

    func testShortTasksGetDeterministicOneLiner() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "메일 확인", day: "2026-09-28", hour: 10, minutes: 5)
        let llm = AllRowsLLM(title: nil) { _ in .failure(.transport("부르면 안 됨")) }
        _ = await F.consolidator(db, llm: llm, clock: TestClock(weekEnd + 72 * 3600)).run(prune: false)
        let digest = try XCTUnwrap(try digests(db).first)
        XCTAssertEqual(digest.status, .verified, "10분 미만 업무는 LLM 없이 확정")
        XCTAssertEqual(llm.digestCalls, 0)
    }

    func testDigestOfProjectOnlyTaskIsHiddenOutsideTheProject() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "비공개 과제", day: "2026-09-28", hour: 10, minutes: 30)
        try await F.work(db, task: "공개 과제", day: "2026-09-29", hour: 10, minutes: 30)
        _ = await F.consolidator(db, clock: TestClock(weekEnd + 72 * 3600)).run(prune: false, narrate: false)
        let tasks = try await db.writer.read { try GraphTx($0).nodes(label: NodeLabel.task) }
        let privateTask = try XCTUnwrap(tasks.first { $0.title == "비공개 과제" })
        let store = ProjectStore(db)
        var project = ChatProject(title: "비공개", goal: "목표"); project.memoryMode = .projectOnly
        try store.save(project)
        try store.move("task:\(privateTask.id)", to: project.id)

        let outside = try ContextSearch(db).search(query: "과제", from: 0, to: weekEnd + 86_400).filter { $0.id.hasPrefix("digest:") }
        XCTAssertEqual(outside.map(\.title).filter { $0.contains("비공개 과제") }, [])
        XCTAssertEqual(outside.filter { $0.title.contains("주간 요약 · 공개 과제") }.count, 1)
        XCTAssertEqual(outside.filter { $0.title.contains("월간 요약 · 공개 과제 · 2026-09") }.count, 1, "9월도 닫혀 월간 요약이 있다")
        let privateDigest = try XCTUnwrap(try digests(db).first { $0.taskKey == privateTask.key })
        XCTAssertTrue(try ContextSearch(db).read("digest:\(privateDigest.id!)").isEmpty, "밖에서 직접 읽기도 막는다")
        let inside = try ContextSearch(db, projectID: project.id).search(query: "과제", from: 0, to: weekEnd + 86_400).filter { $0.id.hasPrefix("digest:") }
        XCTAssertEqual(inside.map(\.title).filter { $0.contains("공개 과제") && !$0.contains("비공개") }, [], "전용 모드에서는 프로젝트 밖 요약을 보지 않는다")
        XCTAssertEqual(inside.filter { $0.title.contains("주간 요약 · 비공개 과제") }.count, 1)
        let summary = try XCTUnwrap(try ContextSearch(db).summarize(from: F.at("2026-09-28", 0), to: weekEnd, task: nil, calendar: F.calendar).first)
        XCTAssertFalse(summary.excerpt.contains("비공개 과제"), summary.excerpt)
        XCTAssertTrue(summary.excerpt.contains("공개 과제"))
    }

    func testMergingTasksMovesLedgerAndDigests() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서 작성", day: "2026-09-28", hour: 10, minutes: 30)
        try await F.work(db, task: "보고서 정리", day: "2026-10-06", hour: 10, minutes: 30)
        _ = await F.consolidator(db, clock: TestClock(F.at("2026-10-20", 0))).run(prune: false, narrate: false)
        let keep = try F.taskKey(db, title: "보고서 작성"), victim = try F.taskKey(db, title: "보고서 정리")
        let merged = try await db.writer.write { try TaskMerger.merge(.init(keep: keep, merge: [victim], title: nil, goal: nil), conn: $0, now: F.at("2026-10-20", 1)) }
        XCTAssertEqual(merged, 1)
        let all = try digests(db)
        XCTAssertEqual(Set(all.map(\.taskKey)), [keep], "병합하면 요약의 업무 key 를 옮긴다")
        XCTAssertTrue(all.allSatisfy { $0.title.contains("보고서 작성") })
        let ledgerKeys = try await db.writer.read { try String.fetchAll($0, sql: "SELECT DISTINCT task_key FROM usage_ledger WHERE task_key <> ''") }
        XCTAssertEqual(ledgerKeys, [keep])
    }
}
