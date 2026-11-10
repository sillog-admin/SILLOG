import XCTest
import GRDB
@testable import WorkGraphCore

final class EventStoreTests: XCTestCase {
    func testTextIsDeduplicatedByHash() throws {
        let store = EventStore(try WGDatabase.inMemory())
        let a = try store.upsertText("hello world", source: "ax", at: 1)
        let b = try store.upsertText("hello world", source: "ocr", at: 2)
        let c = try store.upsertText("something else", source: "ax", at: 3)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(try store.texts(ids: [a, c]), [a: "hello world", c: "something else"])
    }

    func testUnprocessedOrderingAndMark() throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let second = try store.insert(Observation(ts: 20, trigger: "window_change", appBundle: "b", appName: "B"))
        let first = try store.insert(Observation(ts: 10, trigger: "app_activate", appBundle: "a", appName: "A"))
        XCTAssertEqual(try store.unprocessed(limit: 10).map(\.id), [first, second])
        XCTAssertEqual(try store.oldestUnprocessedTs(), 10)

        try db.writer.write { conn in
            var batch = BatchRecord(startedAt: 30, status: "ok")
            try batch.insert(conn)
            try EventStore.mark(conn, observationIds: [first], batchId: batch.id!)
        }
        XCTAssertEqual(try store.unprocessed(limit: 10).map(\.id), [second])
        XCTAssertEqual(try store.counts(since: 0).unprocessed, 1)
        XCTAssertEqual(try store.counts(since: 0).total, 2)
    }

    func testAttachTextAndScreenshot() throws {
        let store = EventStore(try WGDatabase.inMemory())
        let id = try store.insert(Observation(ts: 1, trigger: "app_activate", appBundle: "a", appName: "A"))
        let textId = try store.upsertText("화면 텍스트", source: "ax", at: 1)
        try store.attach(observationId: id, textId: textId, screenshotPath: "/tmp/a.jpg")
        let loaded = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual(loaded.textId, textId)
        XCTAssertEqual(loaded.screenshotPath, "/tmp/a.jpg")
    }

    func testIdleSpansOpenAndClose() throws {
        let store = EventStore(try WGDatabase.inMemory())
        try store.openIdle(at: 100)
        try store.openIdle(at: 110)          // 이미 열려 있으면 무시
        try store.closeIdle(at: 160)
        try store.closeIdle(at: 170)         // 열린 게 없으면 무시
        let spans = try store.idleSpans(from: 0, to: 1000)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.startTs, 100)
        XCTAssertEqual(spans.first?.endTs, 160)
        XCTAssertTrue(try store.idleSpans(from: 200, to: 300).isEmpty)
    }
}
