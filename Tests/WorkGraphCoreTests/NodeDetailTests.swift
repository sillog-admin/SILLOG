import XCTest
import GRDB
@testable import WorkGraphCore

/// 업무 말고 다른 노드의 상세 (드로어): 노드마다 보여 줄 사실과 연결된 노드 묶음
final class NodeDetailTests: XCTestCase {
    private struct Fixture { var study: Int64 = 0, work: Int64 = 0, s1: Int64 = 0, s2: Int64 = 0, s3: Int64 = 0 }

    private func seed(_ db: WGDatabase) throws -> Fixture {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            func node(_ label: String, _ key: String, _ title: String, _ props: [String: JSONValue] = [:], subtype: String? = nil) throws -> Int64 {
                try tx.upsertNode(label: label, key: key, subtype: subtype, title: title, props: props, at: 100)
            }
            func edge(_ src: Int64, _ dst: Int64, _ type: String, _ weight: Double = 1, at: Double = 100) throws {
                _ = try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: weight, at: at)
            }
            var f = Fixture()
            let theme = try node(NodeLabel.theme, "학업", "학업")
            f.study = try node(NodeLabel.task, "t_study", "자료구조 과제", ["active_seconds": .number(900), "last_active": .number(400)])
            f.work = try node(NodeLabel.task, "t_work", "대시보드", ["active_seconds": .number(300), "last_active": .number(600)])
            try edge(f.study, theme, EdgeType.partOf)
            try edge(f.work, theme, EdgeType.partOf)
            f.s1 = try node(NodeLabel.session, "s1", "10/7 과제 1", ["start": .number(100), "end": .number(200), "active_seconds": .number(90),
                                                                     "summaries": .array([.string("연결 리스트 삽입 함수를 작성했다.")])])
            f.s2 = try node(NodeLabel.session, "s2", "10/7 과제 2", ["start": .number(300), "end": .number(400), "active_seconds": .number(80)])
            f.s3 = try node(NodeLabel.session, "s3", "10/8 대시보드", ["start": .number(500), "end": .number(600), "active_seconds": .number(70)])
            for (session, task) in [(f.s1, f.study), (f.s2, f.study), (f.s3, f.work)] { try edge(session, task, EdgeType.partOf) }
            try edge(f.s1, f.s2, EdgeType.switchedTo)
            let card = try node(NodeLabel.resource, "https://ui.shadcn.com/docs/components/card", "shadcn/ui Card", ["last_seen": .number(560)], subtype: "Documentation")
            try edge(f.s1, card, EdgeType.touched, 40, at: 120)
            try edge(f.s3, card, EdgeType.touched, 30, at: 550)
            let chrome = try node(NodeLabel.app, "com.google.Chrome", "Google Chrome")
            try edge(f.s1, chrome, EdgeType.used, 60)
            try edge(f.s3, chrome, EdgeType.used, 50)
            let topic = try node(NodeLabel.topic, "linked-list", "연결 리스트")
            try edge(f.study, topic, EdgeType.about)
            let problem = try node(NodeLabel.problem, "problem:build:1", "빌드가 실패했다", ["kind": .string("build"), "at": .number(150)], subtype: "build")
            try edge(f.s1, problem, EdgeType.hit)
            try edge(problem, card, EdgeType.resolvedBy)
            let later = try node(NodeLabel.laterItem, "later:1", "보고서 고치기", ["done": .bool(false), "at": .number(180)])
            try edge(later, f.study, EdgeType.forTask)
            return f
        }
    }

    private func detail(_ db: WGDatabase, _ label: String, _ key: String) throws -> NodeDetail {
        try XCTUnwrap(try db.writer.read { try NodeDetailBuilder.build(label: label, key: key, conn: $0) })
    }

    private func section(_ detail: NodeDetail, _ title: String) -> [String] {
        detail.sections.first { $0.title == title }?.links.map(\.title) ?? []
    }

    func testThemeListsItsTasksMostRecentFirst() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let d = try detail(db, NodeLabel.theme, "학업")
        XCTAssertEqual(d.kindName, "분야")
        XCTAssertEqual(section(d, "업무"), ["대시보드", "자료구조 과제"])
        XCTAssertEqual(d.facts, [.init(name: "업무", value: .count(2)), .init(name: "작업 시간", value: .duration(1200))])
        XCTAssertTrue(d.erasable)
    }

    func testSessionShowsTimesWorkDoneAndWhatItUsed() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let d = try detail(db, NodeLabel.session, "s1")
        XCTAssertEqual(d.facts, [.init(name: "시작", value: .time(100)), .init(name: "끝", value: .time(200)), .init(name: "활동 시간", value: .duration(90))])
        XCTAssertEqual(d.notes, ["연결 리스트 삽입 함수를 작성했다."])
        XCTAssertEqual(section(d, "업무"), ["자료구조 과제"])
        XCTAssertEqual(section(d, "만진 자료"), ["shadcn/ui Card"])
        XCTAssertEqual(d.sections.first { $0.title == "만진 자료" }?.links.first?.seconds, 40)
        XCTAssertEqual(section(d, "쓴 앱"), ["Google Chrome"])
        XCTAssertEqual(section(d, "문제"), ["빌드가 실패했다"])
        XCTAssertEqual(section(d, "이어진 세션"), ["10/7 과제 2"])
        XCTAssertTrue(d.resumable)
    }

    func testResourceShowsTimeSeenAndTheTasksAndSessionsThatUsedIt() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let d = try detail(db, NodeLabel.resource, "https://ui.shadcn.com/docs/components/card")
        XCTAssertEqual(d.kindName, "자료 · Documentation")
        XCTAssertEqual(d.address, "https://ui.shadcn.com/docs/components/card")
        XCTAssertEqual(d.facts, [.init(name: "본 시간", value: .duration(70)), .init(name: "처음", value: .time(100)), .init(name: "마지막", value: .time(560))])
        XCTAssertEqual(section(d, "쓴 업무"), ["자료구조 과제", "대시보드"], "본 시간 많은 순")
        XCTAssertEqual(section(d, "세션"), ["10/8 대시보드", "10/7 과제 1"], "최근 세션부터")
        XCTAssertEqual(section(d, "해결한 문제"), ["빌드가 실패했다"])
        XCTAssertTrue(d.openable)
    }

    func testAppTopicProblemAndLaterItem() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let app = try detail(db, NodeLabel.app, "com.google.Chrome")
        XCTAssertEqual(app.facts.first, .init(name: "사용 시간", value: .duration(110)))
        XCTAssertEqual(section(app, "쓴 업무"), ["자료구조 과제", "대시보드"])
        XCTAssertTrue(app.openable)
        XCTAssertEqual(section(try detail(db, NodeLabel.topic, "linked-list"), "업무"), ["자료구조 과제"])
        let problem = try detail(db, NodeLabel.problem, "problem:build:1")
        XCTAssertEqual(section(problem, "세션"), ["10/7 과제 1"])
        XCTAssertEqual(section(problem, "업무"), ["자료구조 과제"])
        XCTAssertEqual(section(problem, "해결한 자료"), ["shadcn/ui Card"])
        let later = try detail(db, NodeLabel.laterItem, "later:1")
        XCTAssertEqual(later.facts.first, .init(name: "상태", value: .text("아직")))
        XCTAssertEqual(section(later, "업무"), ["자료구조 과제"])
    }

    func testClassesHaveDetailButCannotBeErased() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let type = try tx.upsertNode(label: NodeLabel.taskType, key: "학습", subtype: nil, title: "학습", props: [:], at: 0)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t", subtype: nil, title: "통계 수업", props: [:], at: 0)
            _ = try tx.upsertEdge(src: task, dst: type, type: EdgeType.instanceOf, props: [:], addWeight: 1, at: 0)
        }
        let d = try detail(db, NodeLabel.taskType, "학습")
        XCTAssertEqual(d.kindName, "업무 종류")
        XCTAssertEqual(section(d, "업무"), ["통계 수업"])
        XCTAssertFalse(d.erasable)
    }

    func testUnknownNodeHasNoDetail() throws {
        let db = try WGDatabase.inMemory()
        XCTAssertNil(try db.writer.read { try NodeDetailBuilder.build(label: NodeLabel.resource, key: "없음", conn: $0) })
    }
}
