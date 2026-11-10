import XCTest
@testable import WorkGraphCore

final class ExporterTests: XCTestCase {
    private func sample() -> Subgraph {
        let task = GraphNode(id: 1, label: "Task", key: "t_1", subtype: nil, title: "O'Reilly \"책\" 읽기", props: ["active_seconds": 120, "status": "active"], createdAt: 1, updatedAt: 2)
        let res = GraphNode(id: 2, label: "Resource", key: "https://a.dev/x", subtype: "Documentation", title: "A docs", props: [:], createdAt: 1, updatedAt: 2)
        let edge = GraphEdge(id: 1, src: 1, dst: 2, type: "ABOUT", props: ["kind": "drift"], weight: 30, hits: 2, firstAt: 1, lastAt: 2)
        return Subgraph(nodes: [task, res], edges: [edge])
    }

    func testGraphJSONHasDegreeAndLinkEndpoints() throws {
        let data = try GraphJSONExporter.export(sample(), now: 10)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nodes = try XCTUnwrap(root["nodes"] as? [[String: Any]])
        let links = try XCTUnwrap(root["links"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0]["degree"] as? Int, 1)
        XCTAssertEqual(nodes[1]["subtype"] as? String, "Documentation")
        XCTAssertEqual(links[0]["source"] as? Int, 1)
        XCTAssertEqual(links[0]["target"] as? Int, 2)
        XCTAssertEqual(links[0]["type"] as? String, "ABOUT")
    }

    func testCypherUsesMergeAndEscapesQuotes() {
        let script = CypherExporter.export(sample())
        XCTAssertTrue(script.contains(#"MERGE (n:`Task` {key: 't_1'}) SET n.title = 'O\'Reilly "책" 읽기'"#))
        XCTAssertTrue(script.contains("n:`Documentation`"))
        XCTAssertTrue(script.contains("MERGE (a)-[r:`ABOUT`]->(b) SET r.weight = 30, r.hits = 2, r.`kind` = 'drift'"))
    }

    func testDemoSeedLooksLikeRealCollectorOutput() throws {
        let store = EventStore(try WGDatabase.inMemory())
        let count = try DemoScenarios.seed(into: store, dayStart: 1_000_000, home: "/Users/me")
        XCTAssertGreaterThan(count, 200)
        let all = try store.unprocessed(limit: 5000)
        XCTAssertEqual(all.count, count)
        // 생존 신호: 연속 행 간격이 60초를 넘지 않는 구간이 대부분이어야 한다.
        let gaps = zip(all, all.dropFirst()).map { $1.ts - $0.ts }
        XCTAssertGreaterThan(Double(gaps.filter { $0 <= 60 }.count) / Double(gaps.count), 0.95)
        XCTAssertTrue(all.contains { $0.url == "https://ui.shadcn.com/docs/components/card#usage" })
    }
}
