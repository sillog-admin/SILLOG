import XCTest
import GRDB
@testable import WorkGraphCore

/// 녹음 기록: 검색 색인, 남은 녹음, 정리 대기·표시·배정, 7일 지난 녹음 파일, 받아쓴 글 경로
final class RecordingStoreTests: XCTestCase {
    private var db: WGDatabase!
    private var store: RecordingStore!
    private var folder: URL!

    override func setUpWithError() throws {
        db = try WGDatabase.inMemory()
        store = RecordingStore(db)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func matches(_ word: String) throws -> [Int64] {
        try db.writer.read { try Int64.fetchAll($0, sql: "SELECT rowid FROM recordings_fts WHERE recordings_fts MATCH ?", arguments: ["\"\(word)\""]) }
    }

    private func file(_ name: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        return url.path
    }

    func testSearchIndexFollowsInsertUpdateAndDelete() throws {
        var recording = try store.insert(Recording(startedAt: 1, audioPath: "/a.m4a"))
        XCTAssertEqual(recording.status, .recording)
        XCTAssertTrue(try matches("연결리스트").isEmpty)
        recording.title = "자료구조 3주차"
        recording.transcript = "오늘은 연결리스트를 봅니다."
        try store.update(recording)
        XCTAssertEqual(try matches("연결리스트"), [recording.id!])
        XCTAssertEqual(try matches("자료구조"), [recording.id!])
        try store.delete(id: recording.id!)
        XCTAssertTrue(try matches("연결리스트").isEmpty)
        XCTAssertNil(try store.find(id: recording.id!))
    }

    func testUnfinishedIsRecordingOrTranscribingOldestFirstAndAllIsNewestFirst() throws {
        let a = try store.insert(Recording(startedAt: 10, audioPath: "/a", status: .transcribing))
        let b = try store.insert(Recording(startedAt: 20, audioPath: "/b", status: .recording))
        let c = try store.insert(Recording(startedAt: 30, audioPath: "/c", transcript: "가", status: .ready, readyAt: 31))
        let d = try store.insert(Recording(startedAt: 40, audioPath: "/d", status: .failed, error: "x"))
        XCTAssertEqual(try store.unfinished().map(\.id), [a.id, b.id])
        XCTAssertEqual(try store.all().map(\.id), [d.id, c.id, b.id, a.id])
    }

    func testUnprocessedIsReadyWithTextInsideTheWindowUntilMarked() throws {
        let ready = try store.insert(Recording(startedAt: 100, endedAt: 200, duration: 100, audioPath: "/a", transcript: "가나다", status: .ready, readyAt: 210))
        _ = try store.insert(Recording(startedAt: 100, endedAt: 200, duration: 100, audioPath: "/b", transcript: "  ", status: .ready, readyAt: 210))     // 받아쓴 글 없음
        _ = try store.insert(Recording(startedAt: 100, endedAt: 200, duration: 100, audioPath: "/f", transcript: " \n\t ", status: .ready, readyAt: 210)) // 빈칸·줄바꿈·탭만 있음 (받아쓴 글 없음)
        _ = try store.insert(Recording(startedAt: 100, endedAt: 200, duration: 100, audioPath: "/c", transcript: "가나다", status: .transcribing))        // 아직 정리 중
        _ = try store.insert(Recording(startedAt: 900, endedAt: 1_000, duration: 100, audioPath: "/d", transcript: "가나다", status: .ready, readyAt: 1_010)) // 창보다 뒤
        _ = try store.insert(Recording(startedAt: 0, endedAt: 10, duration: 10, audioPath: "/e", transcript: "가나다", status: .ready, readyAt: 20))       // 너무 오래됨
        XCTAssertEqual(try store.unprocessed(upTo: 500, notOlderThan: 50).map(\.id), [ready.id])

        try db.writer.write { conn in
            try RecordingStore.mark(conn, ids: [ready.id!], batchId: 3)
            try RecordingStore.assign(conn, ids: [ready.id!], taskId: 9)
        }
        XCTAssertTrue(try store.unprocessed(upTo: 500, notOlderThan: 50).isEmpty)
        let saved = try XCTUnwrap(store.find(id: ready.id!))
        XCTAssertEqual(saved.batchId, 3)
        XCTAssertEqual(saved.taskId, 9)
    }

    func testOldReadyAudioIsDeletedOnceButFailedAndRecentAreKept() throws {
        let now = 100 * 86_400.0
        let old = try store.insert(Recording(startedAt: 0, endedAt: 60, duration: 60, audioPath: try file("old.m4a"), transcript: "가", status: .ready, readyAt: now - 8 * 86_400))
        let recent = try store.insert(Recording(startedAt: 0, endedAt: 60, duration: 60, audioPath: try file("recent.m4a"), transcript: "가", status: .ready, readyAt: now - 2 * 86_400))
        let failed = try store.insert(Recording(startedAt: 0, endedAt: 60, duration: 60, audioPath: try file("failed.m4a"), status: .failed, error: "받아쓰기 꺼짐"))
        XCTAssertEqual(try store.expiredAudio(now: now).map(\.id), [old.id])

        XCTAssertEqual(try store.deleteExpiredAudio(now: now), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.audioPath))
        XCTAssertEqual(try store.find(id: old.id!)?.audioDeletedAt, now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.audioPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.audioPath), "받아쓰기에 실패한 녹음은 다시 받아쓸 수 있게 남긴다")
        XCTAssertEqual(try store.deleteExpiredAudio(now: now), 0, "한 번 지운 것은 다시 고르지 않는다")
    }

    func testTextPathFollowsTheMovedFile() throws {
        let recording = try store.insert(Recording(startedAt: 1, audioPath: "/a", textPath: "/Docs/SILLOG 녹음/회의.md", transcript: "가", status: .ready))
        XCTAssertTrue(try store.moveText(from: "/Docs/SILLOG 녹음/회의.md", to: "/Docs/학교/회의.md"))
        XCTAssertEqual(try store.find(textPath: "/Docs/학교/회의.md")?.id, recording.id)
        XCTAssertNil(try store.find(textPath: "/Docs/SILLOG 녹음/회의.md"))
        XCTAssertFalse(try store.moveText(from: "/없는/경로.md", to: "/x.md"))
    }

    /// [녹음 삭제]: 행·색인·그래프 자료 노드와 그 엣지·녹음 파일을 지운다. 받아쓴 글(.md)은 사용자 파일이라 손대지 않는다
    func testRemoveDeletesTheRowAudioAndGraphNodeButKeepsTheTextFile() throws {
        let audio = try file("7.m4a")
        let text = folder.appendingPathComponent("강의.md")
        try Data("# 강의".utf8).write(to: text)
        let recording = try store.insert(Recording(startedAt: 1, audioPath: audio, textPath: text.path, title: "자료구조 3주차",
                                                    transcript: "연결리스트를 봅니다.", status: .ready, readyAt: 2))
        let id = try XCTUnwrap(recording.id)
        let (nodeId, sessionId) = try db.writer.write { conn -> (Int64, Int64) in
            let tx = GraphTx(conn)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s1", subtype: nil, title: "세션", props: [:], at: 1)
            let node = try tx.upsertNode(label: NodeLabel.resource, key: "recording:\(id)", subtype: "Recording", title: "자료구조 3주차", props: [:], at: 1)
            try tx.upsertEdge(src: session, dst: node, type: EdgeType.touched, props: [:], addWeight: 0, at: 1)
            return (node, session)
        }
        XCTAssertEqual(try matches("연결리스트"), [id])

        try store.remove(id: id)

        XCTAssertNil(try store.find(id: id))
        XCTAssertTrue(try matches("연결리스트").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio), "녹음 파일은 지운다")
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path), "받아쓴 글(.md)은 사용자 파일이라 남는다")
        try db.writer.read { conn in
            let tx = GraphTx(conn)
            XCTAssertNil(try tx.node(id: nodeId))
            XCTAssertTrue(try tx.edges(to: nodeId).isEmpty)
            XCTAssertTrue(try tx.edges(from: sessionId).isEmpty, "세션 → 녹음 엣지도 함께 지워진다")
        }
    }
}
