import XCTest
import GRDB
@testable import SillogCore

final class FileKeysTests: XCTestCase {
    private let composed = "file:~/캡스톤/SILLOG".precomposedStringWithCanonicalMapping
    private var decomposed: String { composed.decomposedStringWithCanonicalMapping }
    private func bytes(_ s: String?) -> [UInt8] { Array((s ?? "").utf8) }

    func testDecomposedKeysAreComposedAndTwinsFolded() throws {
        let db = try SillogDatabase.inMemory()
        let lone = "file:~/실습환경/a.py".decomposedStringWithCanonicalMapping
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            _ = try tx.upsertNode(label: NodeLabel.task, key: "t1", subtype: nil, title: "업무",
                                  props: ["project_seconds": .object([self.decomposed: .number(5)])], at: 0)
            let kept = try tx.upsertNode(label: NodeLabel.project, key: self.composed, subtype: nil, title: "SILLOG", props: [:], at: 0)
            let twin = try tx.upsertNode(label: NodeLabel.project, key: self.decomposed, subtype: nil, title: "SILLOG", props: [:], at: 0)
            let file = try tx.upsertNode(label: NodeLabel.resource, key: lone, subtype: nil, title: "a.py", props: [:], at: 0)
            _ = try tx.upsertEdge(src: file, dst: twin, type: EdgeType.belongsTo, props: [:], addWeight: 0, at: 0)
            for (key, seconds) in [(self.decomposed, 5.0), (self.composed, 3.0)] {
                try conn.execute(sql: """
                    INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at, hits)
                    VALUES ('2026-11-18', 't1', 'project', ?, ?, 0, 0, 1)
                    """, arguments: [key, seconds])
            }
            XCTAssertNotEqual(kept, twin)
            try FileKeys.composeStored(conn)
        }
        try db.writer.read { conn in
            let tx = GraphTx(conn)
            let projects = try tx.nodes(label: NodeLabel.project)
            XCTAssertEqual(projects.map { self.bytes($0.key) }, [bytes(composed)])
            let file = try XCTUnwrap(tx.nodes(label: NodeLabel.resource).first)
            XCTAssertEqual(bytes(file.key), bytes(lone.precomposedStringWithCanonicalMapping))
            XCTAssertEqual(try tx.edges(from: file.id, type: EdgeType.belongsTo).map(\.dst), projects.map(\.id))
            let ledger = try Row.fetchAll(conn, sql: "SELECT target_key, seconds FROM usage_ledger")
            XCTAssertEqual(ledger.map { self.bytes($0["target_key"]) }, [bytes(composed)])
            XCTAssertEqual(ledger.first?["seconds"], 8.0)
            let tally = try Row.fetchAll(conn, sql: "SELECT key, value FROM json_each((SELECT props FROM nodes WHERE key = 't1'), '$.project_seconds')")
            XCTAssertEqual(tally.map { self.bytes($0["key"]) }, [bytes(composed)])
            XCTAssertEqual(tally.first?["value"], 5.0)
        }
    }

    func testDigestAnchorsAreComposed() throws {
        let db = try SillogDatabase.inMemory()
        let anchors = "[\"\(decomposed)\"]"
        try db.writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO digests(level, period, period_start, period_end, tz, task_key, title, body, structured, metrics, anchors,
                                    status, prompt_version, input_hash, created_at)
                VALUES ('week', '2026-W47', 0, 0, 'Asia/Seoul', 't1', '요약', '', '{}', '{}', ?, 'verified', 1, 'h', 0)
                """, arguments: [anchors])
            try FileKeys.composeStored(conn)
        }
        let stored = try db.writer.read { try String.fetchOne($0, sql: "SELECT anchors FROM digests") }
        XCTAssertEqual(bytes(stored), bytes(anchors.precomposedStringWithCanonicalMapping))
    }
}
