import XCTest
import GRDB
@testable import SillogCore

/// 시드 → 배치(가짜 LLM) → 그래프까지 한 번에 도는지 확인하는 통합 테스트.
final class DemoPipelineTests: XCTestCase {
    func testWholeDayBecomesOneSharedGraph() async throws {
        let db = try SillogDatabase.inMemory()
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let dayStart = 1_790_000_000.0
        let seeded = try DemoScenarios.seed(into: EventStore(db), dayStart: dayStart, home: "/Users/me")
        let batcher = OntologyBatcher(db: db, llm: DemoLLM(), config: .singleCall, home: "/Users/me", fileExists: { _ in false },
                                      clock: { dayStart + 20 * 3600 })
        var rounds = 0
        while rounds < 40, case .ok = await batcher.runIfDue(force: true) { rounds += 1 }
        XCTAssertGreaterThan(rounds, 3)
        XCTAssertTrue(try EventStore(db).unprocessed(limit: 10).isEmpty, "\(seeded)개 행이 모두 처리되어야 함")

        try await db.writer.read { conn in
            let tx = GraphTx(conn)
            XCTAssertEqual(Set(try tx.nodes(label: "Task").map(\.title)),
                           ["AI기초수학 3주차 복습", "프로젝트 중간보고서 작성", "대시보드 카드 UI 구현", "대시보드 필터 UI 구현", "유튜브 시청"])

            // 같은 문서를 두 업무가 봤어도 노드는 하나 — 업무끼리 노드를 공유할 때 그래프의 값이 생긴다.
            let card = try XCTUnwrap(tx.node(label: "Resource", key: "https://ui.shadcn.com/docs/components/card"))
            let tasks = try Set(tx.edges(to: card.id, type: "TOUCHED").compactMap { try tx.edges(from: $0.src, type: "PART_OF").first?.dst })
            XCTAssertEqual(tasks.count, 2)
            let react = try XCTUnwrap(tx.node(label: "Topic", key: "react"))
            XCTAssertEqual(try tx.edges(to: react.id, type: "ABOUT").count, 2)

            // localhost 는 쿼리가 달라도 한 노드
            XCTAssertNotNil(try tx.node(label: "Resource", key: "local:3000/dashboard"))
            XCTAssertEqual(try tx.nodes(label: "Resource").filter { $0.key.hasPrefix("local:") }.count, 1)

            // 업무 5개에 세션 5개: 카드 UI 업무가 유튜브로 잠깐 끊겨도 30분 안에 돌아오면 같은 세션이다. 배치 경계도 세션을 쪼개지 않는다.
            XCTAssertEqual(try tx.nodes(label: "Session").count, 5)

            let problems = try tx.nodes(label: "Problem")
            XCTAssertEqual(problems.count, 2)
            for problem in problems { XCTAssertEqual(try tx.edges(from: problem.id, type: "RESOLVED_BY").count, 1, problem.title) }
            XCTAssertEqual(try tx.nodes(label: "LaterItem").count, 2)

            // 흐름(세션 → 다음 세션)은 시간순 행에서 나온다: 카드 UI → 유튜브 → 카드 UI
            let switches = try Row.fetchAll(conn, sql: "SELECT src, dst FROM edges WHERE type = 'SWITCHED_TO'").map { ($0["src"] as Int64, $0["dst"] as Int64) }
            let tube = try XCTUnwrap(tx.nodes(label: "Session").first { try tx.edges(from: $0.id, type: "PART_OF").first.flatMap { try tx.node(id: $0.dst) }?.title == "유튜브 시청" })
            XCTAssertTrue(switches.contains { $0.1 == tube.id } && switches.contains { $0.0 == tube.id }, "유튜브 세션으로 갔다가 돌아온 흐름")

            // 작업 시간 합은 시나리오 길이 합(70+51+86+32 = 239분)과 같아야 한다 — 시간이 새거나 두 번 세이지 않는다.
            // 시나리오마다 마지막 행은 다음 행이 없어 간격 상한(90초)까지 잡히므로 최대 30초 × 4 가 더해진다.
            let total = try tx.nodes(label: "Task").reduce(0.0) { $0 + ($1.props["active_seconds"]?.doubleValue ?? 0) }
            XCTAssertEqual(total / 60, 239, accuracy: 2.5)
        }
    }
}

final class GraphRebuilderTests: XCTestCase {
    /// 행 판단(observations.task_id)만으로 세션·앱·자료·흐름·프로젝트를 LLM 없이 똑같이 다시 만든다
    func testRebuildFromAssignmentsReproducesTheGraph() async throws {
        let db = try SillogDatabase.inMemory()
        let store = EventStore(db)
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let dayStart = 1_790_000_000.0
        _ = try DemoScenarios.seed(into: store, dayStart: dayStart, home: "/Users/me")
        let batcher = OntologyBatcher(db: db, llm: DemoLLM(), config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { dayStart + 20 * 3600 })
        var rounds = 0
        while rounds < 40, case .ok = await batcher.runIfDue(force: true) { rounds += 1 }

        func snapshot() async throws -> (sessions: [String], edges: [String], tasks: [String]) {
            try await db.writer.read { conn in
                let tx = GraphTx(conn)
                let sessions = try tx.nodes(label: "Session").map { "\($0.key) \($0.props["start"]?.doubleValue ?? 0)-\($0.props["end"]?.doubleValue ?? 0) \($0.props["active_seconds"]?.doubleValue ?? 0) \($0.title)" }.sorted()
                let edges = try Row.fetchAll(conn, sql: "SELECT type, s.key AS a, d.key AS b, weight FROM edges e JOIN nodes s ON s.id = e.src JOIN nodes d ON d.id = e.dst WHERE type IN ('PART_OF','USED','TOUCHED','SWITCHED_TO','ON','BELONGS_TO','HIT') ORDER BY 1, 2, 3")
                    .map { "\($0["type"] as String) \($0["a"] as String) → \($0["b"] as String) \($0["weight"] as Double)" }
                let tasks = try tx.nodes(label: "Task").map { "\($0.key) \($0.props["active_seconds"]?.doubleValue ?? 0)" }.sorted()
                return (sessions, edges, tasks)
            }
        }
        let before = try await snapshot()
        XCTAssertFalse(before.sessions.isEmpty)
        XCTAssertTrue(try store.assignedObservations().allSatisfy { $0.batchId != nil })

        let stats = try GraphRebuilder(db: db, store: store, home: "/Users/me", fileExists: { _ in false }).rebuildFromAssignments(now: dayStart + 20 * 3600)
        XCTAssertEqual(stats.sessions, before.sessions.count)
        let after = try await snapshot()
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.tasks, before.tasks)
        XCTAssertEqual(after.edges, before.edges)
    }
}
