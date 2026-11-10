import GRDB
import XCTest
@testable import WorkGraphCore

/// 업무 드로어의 자료 탭: 그래프 화면의 업무 팝업과 같은 기준.
/// 세션이 건드린 자료를 산출물(코드, 노트, 문서, 디자인)과 참고자료로 나누고, 쓴 앱, 주제(자주 본 8개), 부딪힌 문제, 나중에 할 일, 같은 자료·주제를 쓴 업무
final class TaskMaterialsTests: XCTestCase {
    private struct Graph {
        let db: WGDatabase
        let flask: Int64
        let report: Int64
        let misc: Int64
    }

    private func edge(_ tx: GraphTx, _ src: Int64, _ dst: Int64, _ type: String, times: Int = 1) throws {
        for _ in 0..<times { try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: 0, at: 1) }
    }

    private func graph() throws -> Graph {
        let db = try WGDatabase.inMemory()
        let ids = try db.writer.write { conn -> (Int64, Int64, Int64) in
            let tx = GraphTx(conn)
            let node = { (label: String, key: String, subtype: String?, title: String, props: [String: JSONValue]) in
                try tx.upsertNode(label: label, key: key, subtype: subtype, title: title, props: props, at: 1)
            }
            let flask = try node(NodeLabel.task, "task:flask", nil, "Flask 웹앱 개발", [:])
            let report = try node(NodeLabel.task, "task:report", nil, "분기 보고서", [:])
            let misc = try node(NodeLabel.task, "task:misc", nil, "웹 서핑", [:])
            let etc = try node(NodeLabel.theme, "theme:etc", nil, "기타", [:])
            try edge(tx, misc, etc, EdgeType.partOf)                                   // '기타' 분야 업무는 같은 맥락에서 뺀다

            let s1 = try node(NodeLabel.session, "s1", nil, "라우팅 작성", ["start": .number(200)])
            let s2 = try node(NodeLabel.session, "s2", nil, "문서 읽기", ["start": .number(100)])
            let s3 = try node(NodeLabel.session, "s3", nil, "보고서 쓰기", ["start": .number(300)])
            let s4 = try node(NodeLabel.session, "s4", nil, "둘러보기", ["start": .number(400)])
            try edge(tx, s1, flask, EdgeType.partOf); try edge(tx, s2, flask, EdgeType.partOf)
            try edge(tx, s3, report, EdgeType.partOf); try edge(tx, s4, misc, EdgeType.partOf)

            let code = try node(NodeLabel.resource, "file:///a/app.py", "CodeFile", "app.py", [:])
            let docs = try node(NodeLabel.resource, "https://flask.palletsprojects.com", "WebPage", "Flask 문서", [:])
            try edge(tx, s1, code, EdgeType.touched)
            try edge(tx, s2, docs, EdgeType.touched); try edge(tx, s1, docs, EdgeType.touched)   // 두 세션에서 봐도 한 번
            try edge(tx, s3, docs, EdgeType.touched)                                   // 보고서도 같은 문서 → 같은 맥락
            try edge(tx, s4, docs, EdgeType.touched)                                   // 기타 업무도 봤지만 같은 맥락이 아니다

            let vscode = try node(NodeLabel.app, "com.microsoft.VSCode", nil, "Code", [:])
            try edge(tx, s1, vscode, EdgeType.used)
            let routing = try node(NodeLabel.topic, "topic:routing", nil, "라우팅", [:])
            try edge(tx, flask, routing, EdgeType.about)
            let problem = try node(NodeLabel.problem, "problem:import", nil, "ImportError", [:])
            try edge(tx, s1, problem, EdgeType.hit)
            let later = try node(NodeLabel.laterItem, "later:deploy", nil, "배포 설정", [:])
            try edge(tx, later, flask, EdgeType.forTask)
            return (flask, report, misc)
        }
        return Graph(db: db, flask: ids.0, report: ids.1, misc: ids.2)
    }

    private func read(_ g: Graph, _ task: Int64) throws -> TaskMaterials {
        try g.db.writer.read { try TaskMaterials.read(GraphTx($0), taskId: task) }
    }

    func testItemsAreSplitByKindLikeTheGraphPopup() throws {
        let g = try graph()
        let m = try read(g, g.flask)
        XCTAssertEqual(m.outputs.map(\.name), ["app.py"])
        XCTAssertEqual(m.references.map(\.name), ["Flask 문서"])
        XCTAssertEqual(m.apps.map(\.name), ["Code"])
        XCTAssertEqual(m.topics.map(\.name), ["라우팅"])
        XCTAssertEqual(m.problems.map(\.name), ["ImportError"])
        XCTAssertEqual(m.later.map(\.name), ["배포 설정"])
        XCTAssertEqual(m.outputs.first?.key, "file:///a/app.py", "자료는 눌러서 열 수 있게 키를 함께 둔다")
    }

    func testTasksSharingAResourceAreInTheSameContext() throws {
        let g = try graph()
        let m = try read(g, g.flask)
        XCTAssertEqual(m.related.map(\.taskId), [g.report], "기타 분야 업무는 빼고 같은 문서를 본 보고서만")
        XCTAssertEqual(m.related.first?.title, "분기 보고서")
        XCTAssertEqual(m.related.first?.shared, ["Flask 문서"])
    }

    func testTopicsKeepTheEightMostSeen() throws {
        let g = try graph()
        try g.db.writer.write { conn in
            let tx = GraphTx(conn)
            for i in 1...10 {
                let topic = try tx.upsertNode(label: NodeLabel.topic, key: "topic:\(i)", subtype: nil, title: "주제\(i)", props: [:], at: 1)
                try edge(tx, g.report, topic, EdgeType.about, times: i)                // 많이 본 주제일수록 hits 가 크다
            }
        }
        let m = try read(g, g.report)
        XCTAssertEqual(m.topics.map(\.name), (3...10).reversed().map { "주제\($0)" })
    }

    func testATaskWithNothingRecordedIsEmpty() throws {
        let g = try graph()
        let lonely = try g.db.writer.write { try GraphTx($0).upsertNode(label: NodeLabel.task, key: "task:new", subtype: nil, title: "새 업무", props: [:], at: 1) }
        let m = try read(g, lonely)
        XCTAssertTrue(m.isEmpty)
    }
}
