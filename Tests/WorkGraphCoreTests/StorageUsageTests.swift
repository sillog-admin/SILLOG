import XCTest
import GRDB
@testable import WorkGraphCore

private typealias F = ConsolidationFixtures

final class StorageUsageTests: XCTestCase {
    func testCategoriesAddUpToTheUsedPages() async throws {
        let db = try F.makeFileDB()
        try await F.work(db, task: "보고서", day: "2026-09-28", hour: 10, minutes: 30, text: String(repeating: "화면 글자 ", count: 3000))
        let usage = try StorageUsage.measure(db: db, capturesDir: nil, now: F.at("2026-09-30", 0))
        let used = try await db.writer.read { conn -> Int64 in
            let pages = try Int64.fetchOne(conn, sql: "PRAGMA page_count") ?? 0, free = try Int64.fetchOne(conn, sql: "PRAGMA freelist_count") ?? 0
            return (pages - free) * (try Int64.fetchOne(conn, sql: "PRAGMA page_size") ?? 4096)
        }
        let inDatabase = usage.bytes.filter { $0.key != .screenshots }.values.reduce(0, +)
        XCTAssertEqual(Double(inDatabase), Double(used), accuracy: Double(used) * 0.05, "범주 합계는 쓰는 페이지와 오차 5% 안")
        XCTAssertGreaterThan(usage.bytes[.screenText] ?? 0, usage.bytes[.observations] ?? 0)
        XCTAssertGreaterThan(usage.totalDailyGrowth, 0)
        XCTAssertGreaterThan(usage.databaseFileBytes, 0)
    }

    func testCategoryNamesCoverIndexesAndSearchTables() {
        XCTAssertEqual(StorageUsage.category(of: "text_snapshots_chat_fts_data"), .screenText)
        XCTAssertEqual(StorageUsage.category(of: "idx_observations_ts"), .observations)
        XCTAssertEqual(StorageUsage.category(of: "digests_fts_idx"), .digests)
        XCTAssertEqual(StorageUsage.category(of: "app_messages_fts_content"), .chatLibrary)
        XCTAssertEqual(StorageUsage.category(of: "sqlite_autoindex_nodes_1"), .graph)
        XCTAssertEqual(StorageUsage.category(of: "file_suggestions"), .other)
    }

    func testScreenshotPathsAreClearedWithTheirFolder() throws {
        let db = try WGDatabase.inMemory(), store = EventStore(db)
        let old = try store.insert(Observation(ts: 1, trigger: "periodic", appBundle: "a", appName: "A", screenshotPath: "/caps/2026-09-28/1.jpg"))
        let kept = try store.insert(Observation(ts: 2, trigger: "periodic", appBundle: "a", appName: "A", screenshotPath: "/caps/2026-09-29/2.jpg"))
        let similar = try store.insert(Observation(ts: 3, trigger: "periodic", appBundle: "a", appName: "A", screenshotPath: "/caps/2026-09-28-other/3.jpg"))
        try db.writer.write { conn in
            _ = try ScreenCardStore.insert(conn, ScreenCard(tsStart: 1, tsEnd: 2, screenHash: 0, screenshotPath: "/caps/2026-09-28/1.jpg", appBundle: "a", appName: "A",
                                                            windowTitle: nil, uri: nil, activity: "읽기", content: "내용", kind: "document", entities: "{}", createdAt: 1))
        }
        XCTAssertEqual(try store.clearScreenshotPaths(under: "/caps/2026-09-28"), 2)
        func path(_ id: Int64) throws -> String? { try db.writer.read { try String.fetchOne($0, sql: "SELECT screenshot_path FROM observations WHERE id = ?", arguments: [id]) } }
        XCTAssertNil(try path(old))
        XCTAssertNotNil(try path(kept))
        XCTAssertNotNil(try path(similar), "이름이 비슷한 다른 폴더는 그대로")
        XCTAssertNil(try db.writer.read { try String.fetchOne($0, sql: "SELECT screenshot_path FROM screen_cards") })

        XCTAssertEqual(try store.clearMissingScreenshotFolders(fileExists: { $0 == "/caps/2026-09-29" }), 1)
        XCTAssertNotNil(try path(kept))
        XCTAssertNil(try path(similar), "이미 지워진 폴더를 가리키던 경로도 비운다")
    }

    func testSystemPromptsAreStoredOnceAndReadBack() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try WGDatabase.migrator.migrate(queue, upTo: "v14-complete-chat-search")
        try queue.write { conn in
            for prompt in ["프롬프트 A", "프롬프트 A", "프롬프트 A", "프롬프트 B"] {
                try conn.execute(sql: "INSERT INTO batches(started_at, status, system_prompt) VALUES (0, 'ok', ?)", arguments: [prompt])
            }
        }
        try WGDatabase.migrator.migrate(queue)
        try queue.read { conn in
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM prompt_blobs"), 2)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM batches WHERE system_prompt IS NOT NULL"), 0)
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(DISTINCT system_prompt_hash) FROM batches"), 2)
            XCTAssertEqual(try String.fetchAll(conn, sql: "SELECT system_prompt FROM v_batches ORDER BY id"), ["프롬프트 A", "프롬프트 A", "프롬프트 A", "프롬프트 B"])
        }
    }

    func testBatcherStoresPromptByHash() async throws {
        let db = try F.makeDB()
        try await F.work(db, task: "보고서", day: "2026-09-28", hour: 10, minutes: 10)
        try await F.work(db, task: "보고서", day: "2026-09-28", hour: 11, minutes: 10)
        let (stored, blobs) = try await db.writer.read { conn in
            (try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM batches WHERE system_prompt IS NOT NULL") ?? -1,
             try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM prompt_blobs") ?? -1)
        }
        XCTAssertEqual(stored, 0)
        XCTAssertEqual(blobs, 1)
        let batch = try XCTUnwrap(try EventStore(db).recentBatches(limit: 1).first)
        XCTAssertEqual(batch.systemPrompt, OntologyPrompt.system, "읽을 때는 원문을 채운다")
    }

    func testRecordingsAreTheirOwnCategoryWithTheAudioFolder() throws {
        XCTAssertEqual(StorageUsage.category(of: "recordings"), .recordings)
        XCTAssertEqual(StorageUsage.category(of: "recordings_fts_data"), .recordings)
        XCTAssertEqual(StorageUsage.Category.recordings.title, "녹음")
        let db = try WGDatabase.inMemory()
        try FileManager.default.createDirectory(at: db.recordingsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: db.recordingsDirectory) }
        try Data(repeating: 1, count: 10_000).write(to: db.recordingsDirectory.appendingPathComponent("1.m4a"))
        let usage = try StorageUsage.measure(db: db, capturesDir: nil)
        XCTAssertGreaterThanOrEqual(usage.bytes[.recordings] ?? 0, 10_000)
    }
}
