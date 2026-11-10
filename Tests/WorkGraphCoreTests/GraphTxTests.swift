import XCTest
import GRDB
@testable import WorkGraphCore

final class GraphTxTests: XCTestCase {
    func testUpsertNodeMergesInsteadOfDuplicating() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: "Resource", key: "https://a.dev", subtype: "WebPage", title: "Old", props: ["x": 1], at: 10)
            let b = try tx.upsertNode(label: "Resource", key: "https://a.dev", subtype: nil, title: "New", props: ["y": "z"], at: 20)
            XCTAssertEqual(a, b)
            let node = try XCTUnwrap(tx.node(label: "Resource", key: "https://a.dev"))
            XCTAssertEqual(node.title, "New")
            XCTAssertEqual(node.subtype, "WebPage")
            XCTAssertEqual(node.props, ["x": 1, "y": "z"])
            XCTAssertEqual(node.createdAt, 10)
            XCTAssertEqual(node.updatedAt, 20)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM nodes"), 1)
            // 빈 제목으로 다시 upsert 해도 기존 제목은 유지된다.
            try tx.upsertNode(label: "Resource", key: "https://a.dev", subtype: nil, title: nil, props: [:], at: 30)
            XCTAssertEqual(try tx.node(id: a)?.title, "New")
        }
    }

    func testUpsertEdgeAccumulatesWeight() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let s = try tx.upsertNode(label: "Session", key: "s1", subtype: nil, title: "s", props: [:], at: 1)
            let r = try tx.upsertNode(label: "Resource", key: "r1", subtype: "QnA", title: "r", props: [:], at: 1)
            let e1 = try tx.upsertEdge(src: s, dst: r, type: "TOUCHED", props: ["mode": "read"], addWeight: 60, at: 5)
            let e2 = try tx.upsertEdge(src: s, dst: r, type: "TOUCHED", props: [:], addWeight: 40, at: 9)
            XCTAssertEqual(e1, e2)
            let edge = try XCTUnwrap(tx.edges(from: s, type: "TOUCHED").first)
            XCTAssertEqual(edge.weight, 100)
            XCTAssertEqual(edge.hits, 2)
            XCTAssertEqual(edge.firstAt, 5)
            XCTAssertEqual(edge.lastAt, 9)
            XCTAssertEqual(edge.props, ["mode": "read"])
        }
    }

    func testNeighborsRespectsHopLimit() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: "Task", key: "a", subtype: nil, title: "a", props: [:], at: 1)
            let b = try tx.upsertNode(label: "Session", key: "b", subtype: nil, title: "b", props: [:], at: 1)
            let c = try tx.upsertNode(label: "Resource", key: "c", subtype: nil, title: "c", props: [:], at: 1)
            let d = try tx.upsertNode(label: "Topic", key: "d", subtype: nil, title: "d", props: [:], at: 1)
            try tx.upsertEdge(src: b, dst: a, type: "PART_OF", props: [:], addWeight: 0, at: 1)
            try tx.upsertEdge(src: b, dst: c, type: "TOUCHED", props: [:], addWeight: 0, at: 1)
            try tx.upsertEdge(src: c, dst: d, type: "ABOUT", props: [:], addWeight: 0, at: 1)

            let two = try tx.neighbors(of: a, hops: 2)
            XCTAssertEqual(Set(two.nodes.map(\.key)), ["a", "b", "c"])
            XCTAssertEqual(two.edges.count, 2)
            let three = try tx.neighbors(of: a, hops: 3)
            XCTAssertEqual(Set(three.nodes.map(\.key)), ["a", "b", "c", "d"])
        }
    }

    func testTBoxSeedIsIdempotentAndHiddenByDefault() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 1)
            let first = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM nodes")
            let firstEdges = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges")
            try TBox.seed(tx, at: 2)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM nodes"), first)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges"), firstEdges)
            XCTAssertEqual(first, TBox.taskTypes.count + TBox.resourceTypes.count)

            let code = try XCTUnwrap(tx.node(label: "TaskType", key: "코드작성"))
            let parent = try XCTUnwrap(tx.edges(from: code.id, type: "SUBCLASS_OF").first)
            XCTAssertEqual(try tx.node(id: parent.dst)?.key, "산출물작성")

            try tx.upsertNode(label: "Topic", key: "react", subtype: nil, title: "React", props: [:], at: 3)
            XCTAssertEqual(try tx.subgraph(since: nil, includeTBox: false).nodes.map(\.key), ["react"])
            XCTAssertEqual(try tx.subgraph(since: nil, includeTBox: true).nodes.count, first! + 1)
        }
        XCTAssertTrue(TBox.leafTaskTypes.contains("코드작성"))
        XCTAssertTrue(TBox.leafTaskTypes.contains("기타"))
        XCTAssertFalse(TBox.leafTaskTypes.contains("산출물작성"))
    }

    func testSubgraphSinceFiltersOldNodes() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let old = try tx.upsertNode(label: "Topic", key: "old", subtype: nil, title: "old", props: [:], at: 10)
            let new = try tx.upsertNode(label: "Topic", key: "new", subtype: nil, title: "new", props: [:], at: 100)
            let hub = try tx.upsertNode(label: "Task", key: "hub", subtype: nil, title: "hub", props: [:], at: 10)
            try tx.upsertEdge(src: hub, dst: new, type: "ABOUT", props: [:], addWeight: 0, at: 100)
            try tx.upsertEdge(src: hub, dst: old, type: "ABOUT", props: [:], addWeight: 0, at: 10)
            let sub = try tx.subgraph(since: 50, includeTBox: false)
            XCTAssertEqual(Set(sub.nodes.map(\.key)), ["new", "hub"])   // hub는 최근 엣지의 끝점이라 포함
            XCTAssertEqual(sub.edges.count, 1)
        }
    }

    func testOpenTasksDigest() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 1)
            let task = try tx.upsertNode(label: "Task", key: "t_1", subtype: nil, title: "대시보드 카드 UI 구현",
                                         props: ["status": "active", "last_active": 500], at: 1)
            let type = try XCTUnwrap(tx.node(label: "TaskType", key: "코드작성"))
            try tx.upsertEdge(src: task, dst: type.id, type: "INSTANCE_OF", props: [:], addWeight: 0, at: 1)
            let topic = try tx.upsertNode(label: "Topic", key: "react", subtype: nil, title: "React", props: [:], at: 1)
            try tx.upsertEdge(src: task, dst: topic, type: "ABOUT", props: [:], addWeight: 0, at: 1)
            let session = try tx.upsertNode(label: "Session", key: "s_1", subtype: nil, title: "s", props: ["end": 500, "summary": "카드 컴포넌트를 만들었다"], at: 1)
            try tx.upsertEdge(src: session, dst: task, type: "PART_OF", props: [:], addWeight: 0, at: 1)
            let res = try tx.upsertNode(label: "Resource", key: "https://ui.shadcn.com/docs", subtype: "Documentation", title: "shadcn docs", props: [:], at: 1)
            try tx.upsertEdge(src: session, dst: res, type: "TOUCHED", props: [:], addWeight: 30, at: 400)
            try tx.upsertNode(label: "Task", key: "t_done", subtype: nil, title: "끝난 업무", props: ["status": "done", "last_active": 900], at: 1)

            let digests = try tx.openTasks(limit: 5)
            XCTAssertEqual(digests.count, 1, "끝난 업무는 후보가 아니다")
            XCTAssertEqual(digests.first, TaskDigest(id: "t_1", title: "대시보드 카드 UI 구현", taskType: "코드작성",
                                                     topics: ["React"], recentResources: ["shadcn docs"], lastActive: 500,
                                                     resourceKeys: ["https://ui.shadcn.com/docs"], apps: [], recentSummaries: ["카드 컴포넌트를 만들었다"]))
            XCTAssertEqual(try tx.latestSession(ofTask: task)?.key, "s_1")
        }
    }
}
