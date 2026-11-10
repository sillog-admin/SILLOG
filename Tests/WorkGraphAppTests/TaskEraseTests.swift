import XCTest
import GRDB
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 업무 상세 드로어의 '이 업무 지우기': 확인 창에 보여 줄 수를 세고, 지우면 목록과 드로어를 닫는다
@MainActor
final class TaskEraseTests: XCTestCase {
    private func database() throws -> (WGDatabase, work: Int64) {
        let db = try WGDatabase.inMemory()
        let work = try db.writer.write { conn -> Int64 in
            let tx = GraphTx(conn)
            let theme = try tx.upsertNode(label: NodeLabel.theme, key: "직장 업무", subtype: nil, title: "직장 업무", props: [:], at: 100)
            let work = try tx.upsertNode(label: NodeLabel.task, key: "t_work", subtype: nil, title: "SK 업무용 AVD 운영", props: [:], at: 100)
            let other = try tx.upsertNode(label: NodeLabel.task, key: "t_vpn", subtype: nil, title: "회사 VPN 설정", props: [:], at: 100)
            let study = try tx.upsertNode(label: NodeLabel.task, key: "t_study", subtype: nil, title: "자료구조 과제", props: [:], at: 100)
            for task in [work, other] { _ = try tx.upsertEdge(src: task, dst: theme, type: EdgeType.partOf, props: [:], addWeight: 1, at: 100) }
            for (index, task) in [work, other, study].enumerated() {                // 업무 목록은 세션이 있는 업무만 보여 준다
                let session = try tx.upsertNode(label: NodeLabel.session, key: "s\(index)", subtype: nil, title: "세션", props: [:], at: 100)
                _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 1, at: 100)
            }
            try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, window_title, task_id) VALUES (100, 'app_activate', 'com.microsoft.rdc.macos', 'Windows App', 'SK-AVD', ?), (200, 'app_activate', 'com.google.Chrome', 'Google Chrome', '자료구조', ?)",
                             arguments: [work, study])
            return work
        }
        return (db, work)
    }

    /// 동기 읽기 (async 테스트 안에서 XCTAssert 의 자동 클로저가 async 읽기를 고르지 않게)
    private nonisolated func strings(_ db: WGDatabase, _ sql: String) throws -> [String] {
        try db.writer.read { try String.fetchAll($0, sql: sql) }
    }

    func testPreviewCountsWithoutErasing() throws {
        let (db, _) = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        XCTAssertEqual(state.erasePreview(NodeRef(label: NodeLabel.task, key: "t_work"))?.observations, 1)
        XCTAssertEqual(state.erasePreview(NodeRef(label: NodeLabel.theme, key: "직장 업무"))?.tasks.count, 2)
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM nodes WHERE label = 'Task'") }, 3, "세기만 한다")
    }

    func testErasingATaskRemovesItAndClosesTheDrawer() async throws {
        let (db, work) = try database()
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTaskId = work; s.taskDetailOpen = true }, database: db)
        await state.erase(NodeRef(label: NodeLabel.task, key: "t_work"))
        XCTAssertEqual(try strings(db, "SELECT key FROM nodes WHERE label = 'Task' ORDER BY key"), ["t_study", "t_vpn"])
        XCTAssertEqual(try strings(db, "SELECT window_title FROM observations"), ["자료구조"])
        XCTAssertNil(state.selectedTaskId)
        XCTAssertFalse(state.taskDetailOpen)
        XCTAssertEqual(Set(state.taskList.map(\.key)), ["t_study", "t_vpn"], "목록을 다시 읽는다")
    }

    func testConfirmationSaysWhatGoesAndThatItCannotBeUndone() {
        var report = TaskEraser.Report()
        report.observations = 103; report.cards = 18; report.digests = 1
        XCTAssertEqual(EraseCopy.message(label: NodeLabel.task, report), "원시 기록 103행, 화면 카드 18장, 요약 1개와 이 업무가 들어간 정리 기록의 원문을 지워요. 되돌릴 수 없어요.")
    }

    /// 업무를 지울 때 같은 분야에 업무가 더 있으면 분야째 지우기도 고를 수 있다
    func testAskingToEraseATaskOffersItsTheme() throws {
        let (db, _) = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.refreshTasks()
        state.askErase(NodeRef(label: NodeLabel.task, key: "t_work"))
        XCTAssertEqual(state.eraseAsk?.report.title, "SK 업무용 AVD 운영")
        XCTAssertEqual(state.eraseAsk?.theme?.title, "직장 업무")
        XCTAssertEqual(state.eraseAsk?.theme?.tasks, 2)
        state.askErase(NodeRef(label: NodeLabel.task, key: "t_study"))
        XCTAssertNil(state.eraseAsk?.theme, "분야 없는 업무")
    }

    func testErasingAThemeRemovesAllItsTasks() async throws {
        let (db, _) = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        await state.erase(NodeRef(label: NodeLabel.theme, key: "직장 업무"))
        XCTAssertEqual(try strings(db, "SELECT key FROM nodes WHERE label = 'Task'"), ["t_study"])
        XCTAssertEqual(try strings(db, "SELECT title FROM nodes WHERE label = 'Theme'"), [])
    }
}
