import AppKit
import SwiftUI
import XCTest
import GRDB
@testable import SillogApp
@testable import SillogCore

/// 그래프의 업무 말고 다른 노드: 누르면 드로어에 그 노드 상세, 우클릭 메뉴로 지우기
@MainActor
final class NodeDetailUITests: XCTestCase {
    private let card = NodeRef(label: NodeLabel.resource, key: "https://ui.shadcn.com/docs/components/card")
    private let chrome = NodeRef(label: NodeLabel.app, key: "com.google.Chrome")

    private func database() throws -> SillogDatabase {
        let db = try SillogDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_dash", subtype: nil, title: "대시보드 카드 구현", props: ["active_seconds": .number(600)], at: 100)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s1", subtype: nil, title: "10/7 14:00 대시보드",
                                            props: ["start": .number(100), "end": .number(700), "active_seconds": .number(600)], at: 100)
            _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 1, at: 100)
            let card = try tx.upsertNode(label: NodeLabel.resource, key: self.card.key, subtype: "Documentation", title: "shadcn/ui Card", props: [:], at: 100)
            _ = try tx.upsertEdge(src: session, dst: card, type: EdgeType.touched, props: [:], addWeight: 2520, at: 100)
            let chrome = try tx.upsertNode(label: NodeLabel.app, key: self.chrome.key, subtype: nil, title: "Google Chrome", props: [:], at: 100)
            _ = try tx.upsertEdge(src: session, dst: chrome, type: EdgeType.used, props: [:], addWeight: 600, at: 100)
            try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, window_title, url, task_id) VALUES (120, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'Card - shadcn/ui', ?, ?)",
                             arguments: [self.card.key, task])
        }
        return db
    }

    private nonisolated func writeSync(_ db: SillogDatabase, _ work: (GRDB.Database) throws -> Void) throws {
        try db.writer.write { try work($0) }
    }

    /// 동기 읽기 (async 테스트 안에서 async 읽기를 고르지 않게)
    private nonisolated func count(_ db: SillogDatabase, _ sql: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    func testOpeningNodesKeepsATrailBackAndATaskOpensTheTaskDetail() throws {
        let state = AppState(preview: { $0.phase = .ready }, database: try database())
        state.openNodeDetail(card)
        XCTAssertEqual(state.openNode, card)
        XCTAssertTrue(state.taskDetailOpen)
        state.openNodeDetail(chrome, fromDetail: true)
        XCTAssertEqual(state.nodeTrail, [card], "상세 안에서 넘어가면 뒤로에 쌓는다")
        state.backNode()
        XCTAssertEqual(state.openNode, card)
        XCTAssertEqual(state.nodeTrail, [])
        state.openNodeDetail(chrome, fromDetail: true)
        state.openNodeDetail(card)
        XCTAssertEqual(state.nodeTrail, [], "그래프에서 누르면 새로 시작")
        state.openNodeDetail(NodeRef(label: NodeLabel.task, key: "t_dash"))
        XCTAssertNil(state.openNode, "업무는 지금의 업무 상세로")
        XCTAssertNotNil(state.selectedTaskId)
        state.openNodeDetail(card)
        state.taskDetailOpen = false
        XCTAssertNil(state.openNode, "드로어를 닫으면 노드 상세도 닫는다")
    }

    func testTheDrawerShowsTheNodeDetail() throws {
        let db = try database()
        let state = AppState(preview: { s in s.phase = .ready; s.taskList = [] }, database: db)
        state.openNodeDetail(card)
        let host = NSHostingView(rootView: AnyView(TasksPanel().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        for word in ["shadcn/uiCard", "본시간", "42분", "쓴업무", "대시보드카드구현", "이노드지우기"] { XCTAssertTrue(text.contains(word), "\(word): \(text)") }
    }

    func testAskingToEraseCountsAndErasingClosesTheDrawer() async throws {
        let db = try database()
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.openNodeDetail(card)
        state.askErase(card)
        XCTAssertEqual(state.eraseAsk?.report.observations, 1)
        XCTAssertEqual(state.eraseAsk?.report.title, "shadcn/ui Card")
        await state.erase(card)
        XCTAssertNil(state.openNode)
        XCTAssertFalse(state.taskDetailOpen)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM nodes WHERE label = 'Resource'"), 0)
    }

    /// 지우기가 실패하면(아무것도 안 지워짐) 로그에만 남기지 않고 화면에 알린다. 드로어는 그대로 둔다
    func testAFailedEraseIsShownAndNothingChanges() async throws {
        let db = try database()
        try writeSync(db) { conn in       // 지우려는 행을 가리키는 표 (외래 키가 삭제를 막는다)
            try conn.execute(sql: "CREATE TABLE probe_refs(observation_id INTEGER REFERENCES observations(id))")
            try conn.execute(sql: "INSERT INTO probe_refs SELECT id FROM observations")
        }
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.openNodeDetail(card)
        await state.erase(card)
        XCTAssertNotNil(state.eraseError)
        XCTAssertEqual(state.openNode, card, "실패하면 상세를 그대로 둔다")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM nodes WHERE label = 'Resource'"), 1, "아무것도 안 지운다")
    }

    func testErasingAnAppCanAlsoStopRecordingIt() async throws {
        let state = AppState(preview: { $0.phase = .ready }, database: try database())
        await state.erase(chrome, excludeApp: true)
        XCTAssertTrue(state.settings.excludedBundles.contains(chrome.key))
    }

    func testClassesCannotBeAskedToErase() throws {
        let db = try database()
        try db.writer.write { _ = try GraphTx($0).upsertNode(label: NodeLabel.taskType, key: "학습", subtype: nil, title: "학습", props: [:], at: 0) }
        let state = AppState(preview: { $0.phase = .ready }, database: db)
        state.askErase(NodeRef(label: NodeLabel.taskType, key: "학습"))
        XCTAssertNil(state.eraseAsk)
    }

    func testConfirmationTextByKind() {
        var report = TaskEraser.Report()
        report.observations = 12; report.cards = 3; report.nodes = 2
        XCTAssertEqual(EraseCopy.message(label: NodeLabel.resource, report), "원시 기록 12행, 화면 카드 3장과 이 노드에서만 이어진 노드 1개를 지워요. 되돌릴 수 없어요.")
        XCTAssertEqual(EraseCopy.message(label: NodeLabel.topic, TaskEraser.Report()), "이 노드와 그 연결을 지워요. 원시 기록은 따로 없어요. 되돌릴 수 없어요.")
    }

    func testGraphMessagesOpenAndAskAboutNodes() {
        XCTAssertEqual(GraphWebView.nodeRef(["type": "node", "label": "Resource", "key": "https://a.example"]), NodeRef(label: "Resource", key: "https://a.example"))
        XCTAssertNil(GraphWebView.nodeRef(["type": "node", "label": "Resource"]))
        XCTAssertNil(GraphWebView.nodeRef(["type": "node", "label": "", "key": "x"]))
    }
}
