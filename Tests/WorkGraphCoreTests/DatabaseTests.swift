import XCTest
import GRDB
@testable import WorkGraphCore

final class DatabaseTests: XCTestCase {
    func testMigrationCreatesAllTables() throws {
        let db = try WGDatabase.inMemory()
        let names = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in ["observations", "text_snapshots", "file_events", "idle_spans", "batches", "nodes", "edges"] {
            XCTAssertTrue(names.contains(table), "\(table) 테이블이 없음")
        }
    }

    func testBatchPromptColumnsExistAfterMigration() throws {
        let db = try WGDatabase.inMemory()
        let columns = try db.writer.read { db in try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('batches')") }
        for column in ["system_prompt", "user_prompt", "llm_patch", "applied_patch"] { XCTAssertTrue(columns.contains(column), column) }
        var record = BatchRecord(startedAt: 1, status: "ok", userPrompt: "ROWS …", llmPatch: "{}")
        try db.writer.write { try record.insert($0) }
        let loaded = try db.writer.read { try BatchRecord.fetchOne($0, key: record.id!) }
        XCTAssertEqual(loaded?.userPrompt, "ROWS …")
        XCTAssertEqual(loaded?.llmPatch, "{}")
    }

    func testReadableViewsJoinTextAndTasks() throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let textId = try store.upsertText("화면의 글자", source: "ax", at: 1)
        try store.insert(Observation(ts: 1_700_000_000, trigger: "app_activate", appBundle: "b", appName: "Chrome", windowTitle: "t", textId: textId))
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: "Task", key: "t1", subtype: nil, title: "업무 A", props: [:], at: 1)
            let session = try tx.upsertNode(label: "Session", key: "s1", subtype: nil, title: "s", props: ["start": 1_700_000_000, "end": 1_700_000_600, "active_seconds": 600, "summary": "요약"], at: 1)
            try tx.upsertEdge(src: session, dst: task, type: "PART_OF", props: [:], addWeight: 0, at: 1)
        }
        let views = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name") }
        XCTAssertEqual(views, ["v_batches", "v_cards", "v_chats", "v_digests", "v_edges", "v_file_suggestions", "v_ledger", "v_nodes", "v_row_tasks", "v_rows", "v_sessions"])
        let row = try db.writer.read { try Row.fetchOne($0, sql: "SELECT time, app_name, text FROM v_rows") }
        XCTAssertEqual(row?["text"] as String?, "화면의 글자")
        XCTAssertEqual((row?["time"] as String?)?.count, 19)                      // "YYYY-MM-DD HH:MM:SS"
        let session = try db.writer.read { try Row.fetchOne($0, sql: "SELECT task, active_seconds, summary FROM v_sessions") }
        XCTAssertEqual(session?["task"] as String?, "업무 A")
        XCTAssertEqual(session?["active_seconds"] as Int?, 600)
        let edge = try db.writer.read { try Row.fetchOne($0, sql: "SELECT from_label, type, to_title FROM v_edges") }
        XCTAssertEqual(edge?["to_title"] as String?, "업무 A")
    }

    func testNodeLabelKeyIsUnique() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO nodes(label, key, created_at, updated_at) VALUES ('Topic', 'react', 1, 1)")
        }
        XCTAssertThrowsError(try db.writer.write { db in
            try db.execute(sql: "INSERT INTO nodes(label, key, created_at, updated_at) VALUES ('Topic', 'react', 2, 2)")
        })
    }

    func testEdgeSrcDstTypeIsUnique() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO nodes(label, key, created_at, updated_at) VALUES ('Task', 't1', 1, 1), ('Topic', 'react', 1, 1)")
            try db.execute(sql: "INSERT INTO edges(src, dst, type, first_at, last_at) VALUES (1, 2, 'ABOUT', 1, 1)")
        }
        XCTAssertThrowsError(try db.writer.write { db in
            try db.execute(sql: "INSERT INTO edges(src, dst, type, first_at, last_at) VALUES (1, 2, 'ABOUT', 2, 2)")
        })
    }

    func testObservationRoundTripsThroughSnakeCaseColumns() throws {
        let db = try WGDatabase.inMemory()
        var obs = Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Chrome",
                              windowTitle: "shadcn/ui", url: "https://ui.shadcn.com/docs")
        try db.writer.write { db in try obs.insert(db) }
        XCTAssertNotNil(obs.id)
        let loaded = try db.writer.read { db in try Observation.fetchOne(db, key: obs.id!) }
        XCTAssertEqual(loaded, obs)
    }

    func testJSONValueRoundTrip() throws {
        let props: [String: JSONValue] = ["dwell": 120, "mode": "edit", "done": true, "tags": .array(["a", "b"])]
        let text = JSONValue.encodeObject(props)
        XCTAssertEqual(JSONValue.decodeObject(text), props)
        XCTAssertEqual(JSONValue.decodeObject(nil), [:])
    }
}
