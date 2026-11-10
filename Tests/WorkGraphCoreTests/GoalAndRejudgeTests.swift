import XCTest
import GRDB
@testable import WorkGraphCore

final class NotAGoalTests: XCTestCase {
    func testReservedOffRefAndUnusedNewTasksMakeNoTask() throws {
        let db = try WGDatabase.inMemory()
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"off","match":"new","title":"기타","task_type":"기타","goal":"기타"},
                  {"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성","goal":"대시보드의 카드 UI 를 만든다"},
                  {"ref":"B","match":"new","title":"쓰이지 않은 업무","task_type":"문서작성","goal":"아무 행도 가리키지 않는다"}],
         "rows":[{"rows":"1-3","task":"A"},{"rows":"4-6","task":"off"}],
         "work":[{"task":"A","summary":"카드 구현","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let (stats, assignments) = try AssignmentApplier().apply(patch, rows: Fixtures.frontendRows(), tx: tx, now: 2_000_000, requireComplete: true)
            XCTAssertEqual(try tx.nodes(label: NodeLabel.task).map(\.title), ["대시보드 카드 UI 구현"], "off 와 아무 행도 안 쓰는 업무는 만들지 않는다")
            XCTAssertEqual(stats.tasksCreated, 1)
            XCTAssertEqual(assignments.filter(\.offTask).map(\.row.row), [4, 5, 6])
        }
    }

    func testANewTaskNamedOnlyByACategoryIsNotAGoalSoItsRowsAreOffTask() throws {
        let db = try WGDatabase.inMemory()
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"기타","task_type":"기타","goal":"기타"}],
         "rows":[{"rows":"1-6","task":"A","reason":"팀 채널 확인"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let (stats, assignments) = try AssignmentApplier().apply(patch, rows: Fixtures.frontendRows(), tx: tx, now: 2_000_000, requireComplete: true)
            XCTAssertTrue(try tx.nodes(label: NodeLabel.task).isEmpty)
            XCTAssertEqual(stats.offTaskRows, 6)
            XCTAssertTrue(assignments.allSatisfy { $0.offTask && $0.taskId == nil && $0.reason == "팀 채널 확인" }, "판단 이유는 남긴다")
            XCTAssertTrue(try tx.nodes(label: NodeLabel.session).isEmpty)
        }
    }

    func testMergerTurnsNotGoalsIntoOffTaskAndRenamesAVagueTask() async throws {
        let db = try WGDatabase.inMemory()
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let store = EventStore(db)
        for row in Fixtures.frontendRows() {                                      // 관측 id 1~6 = 행 1~6
            _ = try store.insert(Observation(ts: row.start, trigger: "app_activate", appBundle: row.appBundle, appName: row.app, windowTitle: row.title))
        }
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"팀 일","task_type":"코드작성","goal":"팀"},
                  {"ref":"B","match":"new","title":"목적 미확인 웹 이용","task_type":"문헌조사","goal":"목적이 확인되지 않았다"}],
         "rows":[{"rows":"1-3","task":"A","reason":"카드 구현"},{"rows":"4-6","task":"B","reason":"무언가 봄"}],
         "work":[{"task":"A","summary":"카드를 구현했다","topics":["React"]},{"task":"B","summary":"웹을 봤다","topics":["기상 관측"]}]}
        """)
        let (vagueKey, noGoalKey): (String, String) = try await db.writer.write { conn in
            let tx = GraphTx(conn)
            let (_, assignments) = try AssignmentApplier().apply(patch, rows: Fixtures.frontendRows(), tx: tx, now: 2_000_000)
            for item in assignments {
                try EventStore.assign(conn, observationIds: item.row.observationIds, taskId: item.taskId, relevant: item.resource, offTask: item.offTask, reason: item.reason)
            }
            let tasks = try tx.nodes(label: NodeLabel.task)
            return (tasks.first { $0.title == "팀 일" }!.key, tasks.first { $0.title == "목적 미확인 웹 이용" }!.key)
        }
        let llm = StubLLM([.success(#"{"groups":[{"keep":"\#(vagueKey)","merge":[],"title":"대시보드 카드 UI 구현","goal":"대시보드의 카드 UI 를 만든다"}],"not_goals":["\#(noGoalKey)"]}"#)])
        let outcome = try await TaskMerger.run(db: db, llm: llm, since: 0, now: 2_000_500)
        XCTAssertEqual(outcome.notGoals, [noGoalKey])
        XCTAssertEqual(outcome.retired, 1)
        XCTAssertEqual(outcome.merged, 0)
        try await db.writer.read { conn in
            let tx = GraphTx(conn)
            let tasks = try tx.nodes(label: NodeLabel.task)
            XCTAssertEqual(tasks.map(\.title), ["대시보드 카드 UI 구현"], "모호한 업무는 이름을 고친다")
            XCTAssertEqual(tasks.first?.props["goal"]?.stringValue, "대시보드의 카드 UI 를 만든다")
            XCTAssertEqual(try tx.nodes(label: NodeLabel.session).count, 1, "업무 외로 돌린 업무의 세션은 지운다")
            let rows = try Row.fetchAll(conn, sql: "SELECT task_id, off_task, task_reason FROM observations WHERE id IN (4, 5, 6)")
            XCTAssertEqual(rows.count, 3)
            XCTAssertTrue(rows.allSatisfy { ($0["task_id"] as Int64?) == nil && ($0["off_task"] as Int) == 1 && ($0["task_reason"] as String?) == "무언가 봄" })
            XCTAssertNil(try tx.node(label: NodeLabel.topic, key: TopicFilter.normalize("기상 관측")), "그 업무에만 걸린 주제도 지운다")
            XCTAssertNotNil(try tx.node(label: NodeLabel.topic, key: TopicFilter.normalize("React")))
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges WHERE src NOT IN (SELECT id FROM nodes) OR dst NOT IN (SELECT id FROM nodes)"), 0, "끊긴 엣지 없음")
        }
    }
}

final class HobbyRuleTests: XCTestCase {
    func testHobbiesAndEntertainmentAreNeverGoalsInEitherPrompt() {
        XCTAssertTrue(OntologyPrompt.system.contains("Hobbies and entertainment are not goals"))
        XCTAssertTrue(TaskMerger.system.contains("a hobby"))
        XCTAssertFalse(OntologyPrompt.system.contains("a community they run"), "취미 공동체를 목표로 정의하던 문장")
        XCTAssertFalse(TaskMerger.system.contains("community they take part in"))
    }

    func testManagingAToolsAccountForAGoalIsThatGoalsWork() {
        XCTAssertTrue(OntologyPrompt.system.contains("managing the account, subscription or billing of a tool or service used for it"))
        XCTAssertTrue(TaskMerger.system.contains("managing a tool's account, subscription or billing for it"))
        XCTAssertFalse(OntologyPrompt.system.contains("loading or authentication page"), "로그인 화면을 무조건 '없음'으로 보던 문장")
    }

    func testOnlyTheRecorderWindowItselfIsContentless() {
        XCTAssertTrue(OntologyPrompt.system.contains("rows whose app is Sillog"), "실록 프로젝트 문서까지 '없음'으로 보던 문장")
        XCTAssertFalse(OntologyPrompt.system.contains("the Sillog app itself"))
    }
}

final class CardReadingTests: XCTestCase {
    private func card(_ kind: String, lines count: Int) -> ScreenCard {
        ScreenCard(tsStart: 0, tsEnd: 10, screenHash: 0, screenshotPath: nil, appBundle: "b", appName: "App", windowTitle: "w", uri: nil,
                   activity: "읽고 있다", content: (1...count).map { "줄 \($0)" }.joined(separator: "\n"), kind: kind, createdAt: 0)
    }

    func testConversationCardsKeepTheLatestMessagesAndOtherCardsTheFirstLines() {
        XCTAssertEqual(OntologyPrompt.cardLines(card("message", lines: 10)).count, 10, "대화는 12줄까지 전부")
        let long = OntologyPrompt.cardLines(card("ai_chat", lines: 15))
        XCTAssertEqual(long.first, "(3 earlier lines omitted)")
        XCTAssertEqual(Array(long.dropFirst()), (4...15).map { "줄 \($0)" }, "최근 12줄")
        XCTAssertEqual(OntologyPrompt.cardLines(card("document", lines: 10)), (1...6).map { "줄 \($0)" })
    }

    func testPromptsTreatTheCardSummaryAsAReadingAndForbidReinterpretingWords() {
        XCTAssertTrue(CardMaker.system.contains("Do not interpret words"))
        XCTAssertTrue(CardMaker.system.contains("name only the partner and the app"))
        XCTAssertTrue(OntologyPrompt.system.contains("the first line is only a reading and can be wrong"))
        XCTAssertTrue(OntologyPrompt.system.contains("do not list \"off\" in tasks"))
    }
}

final class RejudgeTests: XCTestCase {
    func testRejudgedRowsUseTheNextObservationAndRebuildInTimeOrder() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let clock = TestClock(450)
        for (ts, bundle, app, title) in [(100.0, "com.todesktop.230313mzl4w4u92", "Cursor", "TaskCard.tsx — dashboard"),
                                         (160.0, "com.google.Chrome", "Google Chrome", "Card - shadcn/ui - Google Chrome"),
                                         (400.0, "com.apple.Terminal", "Terminal", "npm run dev")] {
            _ = try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: bundle, appName: app, windowTitle: title))
        }
        let cardWork = #"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성","goal":"대시보드 카드 UI 를 만든다"}],"rows":[{"rows":"1-3","task":"A"}],"work":[{"task":"A","summary":"카드 구현","topics":[]}]}"#
        let meeting = #"{"tasks":[{"ref":"B","match":"new","title":"디자인 리뷰 회의 준비","task_type":"회의","goal":"디자인팀 리뷰 회의를 준비한다"}],"rows":[{"rows":"1","task":"B"}],"work":[{"task":"B","summary":"회의 안건 확인","topics":[]}]}"#
        let noChange = #"{"groups":[],"not_goals":[]}"#                          // 둘째 배치 뒤 업무 합치기
        let llm = StubLLM([.success(cardWork), .success(meeting), .success(noChange), .success(cardWork)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { clock.now })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("첫 배치") }
        _ = try store.insert(Observation(ts: 470, trigger: "app_activate", appBundle: "com.tinyspeck.slackmacgap", appName: "Slack", windowTitle: "디자인팀"))
        clock.now = 600
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("둘째 배치") }

        let first = try XCTUnwrap(store.recentBatches(limit: 10).filter { $0.status == "ok" }.min { $0.startedAt < $1.startedAt }?.id)
        let (reopened, lastTs) = try store.reopenBatches([first])
        XCTAssertEqual(reopened, 3)
        XCTAssertEqual(lastTs, 400)
        XCTAssertEqual(try store.batch(id: first)?.status, "replaced")

        clock.now = 700
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("다시 판정") }
        XCTAssertTrue(llm.lastUser.contains("| 70s | Terminal"), "마지막 행의 체류는 이미 처리된 다음 관측(470초)까지:\n\(llm.lastUser)")
        XCTAssertTrue(try store.unprocessed(limit: 10).isEmpty)

        _ = try GraphRebuilder(db: db, store: store, home: "/Users/me", fileExists: { _ in false }).rebuildFromAssignments(now: 800)
        try await db.writer.read { conn in
            let tx = GraphTx(conn)
            let sessions = try tx.nodes(label: NodeLabel.session).sorted { ($0.props["start"]?.doubleValue ?? 0) < ($1.props["start"]?.doubleValue ?? 0) }
            XCTAssertEqual(sessions.count, 2)
            XCTAssertEqual(try tx.edges(from: sessions[0].id, type: EdgeType.switchedTo).map(\.dst), [sessions[1].id], "흐름은 행의 시각 순서: 카드 작업 → 회의 준비")
        }
    }
}
