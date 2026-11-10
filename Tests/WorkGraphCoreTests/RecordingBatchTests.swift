import XCTest
import GRDB
@testable import WorkGraphCore

/// 받아쓴 녹음이 정리 행이 되고, 업무에 붙고, 업무가 합쳐지거나 다시 판정될 때 따라간다
final class RecordingBatchTests: XCTestCase {
    private func lecture(id: Int64? = 7, start: Double = 1_100, end: Double = 1_500) -> Recording {
        Recording(id: id, startedAt: start, endedAt: end, duration: end - start, audioPath: "/r/7.m4a", title: "자료구조 3주차 강의",
                  summary: "연결 리스트 강의.", transcript: "오늘은 연결 리스트를 봅니다.\n노드는 값과 포인터를 가집니다.", status: .ready, readyAt: end + 10)
    }

    func testARecordingBecomesAZeroDwellRowWithItsSummaryAndTranscript() {
        let window = [ActivityRow(row: 1, start: 1_000, end: 1_600, dwell: 600, app: "Chrome", appBundle: "com.google.Chrome", title: "자료구조 강의자료",
                                  uri: "https://lms.example/ds", type: "WebPage", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [1])]
        let rows = EventCompressor.merge(window, chats: [], recordings: [lecture()], home: "/Users/me", fileExists: { _ in false }, snippetChars: 300)
        XCTAssertEqual(rows.map(\.row), [1, 2])
        let row = rows[1]
        XCTAssertEqual(row.app, "녹음")
        XCTAssertEqual(row.appBundle, "sillog.recording")
        XCTAssertEqual(row.type, "Recording")
        XCTAssertEqual(row.uri, "recording:7")
        XCTAssertEqual(row.title, "자료구조 3주차 강의")
        XCTAssertEqual(row.dwell, 0, "창 기록과 겹치므로 작업 시간에 더하지 않는다")
        XCTAssertEqual(row.recordingIds, [7])
        XCTAssertTrue(row.isChat, "창 기록이 아닌 행: 앱 노드·화면 카드 없음")
        XCTAssertEqual(row.snippet, "요약: 연결 리스트 강의. 「오늘은 연결 리스트를 봅니다. 노드는 값과 포인터를 가집니다.」")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.dwell }, 600)
    }

    func testARecordingWithoutTranscriptMakesNoRow() {
        var silent = lecture()
        silent.transcript = ""
        let window = [ActivityRow(row: 1, start: 1_000, end: 1_600, dwell: 600, app: "Chrome", appBundle: "com.google.Chrome", title: "t",
                                  uri: nil, type: nil, projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [1])]
        XCTAssertEqual(EventCompressor.merge(window, chats: [], recordings: [silent], home: "/Users/me", fileExists: { _ in false }, snippetChars: 300).count, 1)
    }

    func testAReadyRecordingJoinsTheNextBatchOnceAndGetsItsTask() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        for (i, ts) in [100.0, 160, 400, 460].enumerated() {
            try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: "b\(i % 2)", appName: "App\(i % 2)", windowTitle: "w\(i % 2)"))
        }
        let recordings = RecordingStore(db)
        let ready = try recordings.insert(lecture(id: nil, start: 120, end: 380))
        let silent = try recordings.insert(Recording(startedAt: 130, endedAt: 131, duration: 0.5, audioPath: "/r/2.m4a", status: .ready, readyAt: 140))
        let llm = StubLLM([.success("""
        {"tasks":[{"ref":"A","match":"new","title":"자료구조 공부","task_type":"강의수강"}],"rows":[{"rows":"1-5","task":"A"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """), .success("""
        {"tasks":[{"ref":"A","match":"new","title":"다른 작업","task_type":"기타"}],"rows":[{"rows":"1-2","task":"A"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 2_000 })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("첫 배치가 성공해야 한다") }
        XCTAssertTrue(llm.lastUser.contains("| 0s | 녹음 | Recording | 자료구조 3주차 강의 | recording:\(ready.id!)"), llm.lastUser)
        XCTAssertTrue(llm.lastUser.contains("text: 요약: 연결 리스트 강의. 「오늘은 연결 리스트를 봅니다."))
        XCTAssertFalse(llm.lastUser.contains("recording:\(silent.id!)"), "받아쓴 글이 없는 녹음은 넣지 않는다")

        let used = try XCTUnwrap(recordings.find(id: ready.id!))
        XCTAssertNotNil(used.batchId)
        let taskId = try await db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM nodes WHERE label = 'Task' AND title = '자료구조 공부'") }
        XCTAssertEqual(used.taskId, taskId)
        let resource = try await db.writer.read { try GraphTx($0).node(label: NodeLabel.resource, key: "recording:\(ready.id!)") }
        XCTAssertEqual(resource?.subtype, "Recording")
        let appNode = try await db.writer.read { try GraphTx($0).node(label: NodeLabel.app, key: "sillog.recording") }
        XCTAssertNil(appNode, "녹음은 앱 노드로 만들지 않는다")
        XCTAssertTrue(try recordings.unprocessed(upTo: 10_000, notOlderThan: 0).isEmpty)

        // 두 번째 배치에는 다시 들어가지 않는다
        try store.insert(Observation(ts: 900, trigger: "app_activate", appBundle: "b9", appName: "App9"))
        try store.insert(Observation(ts: 960, trigger: "app_activate", appBundle: "b8", appName: "App8"))
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("둘째 배치가 성공해야 한다") }
        XCTAssertFalse(llm.lastUser.contains("Recording"))
    }

    func testMergingAndRetiringTasksMoveTheRecordingsTask() throws {
        let db = try WGDatabase.inMemory()
        let (keep, victim, game) = try db.writer.write { conn -> (Int64, Int64, Int64) in
            let tx = GraphTx(conn)
            return (try tx.upsertNode(label: NodeLabel.task, key: "t_keep", subtype: nil, title: "남는 업무", props: ["status": "active"], at: 0),
                    try tx.upsertNode(label: NodeLabel.task, key: "t_victim", subtype: nil, title: "사라지는 업무", props: ["status": "active"], at: 0),
                    try tx.upsertNode(label: NodeLabel.task, key: "t_game", subtype: nil, title: "게임 리그", props: ["status": "active"], at: 0))
        }
        let recordings = RecordingStore(db)
        let merged = try recordings.insert(Recording(startedAt: 1, audioPath: "/a", transcript: "가", status: .ready, taskId: victim))
        let retired = try recordings.insert(Recording(startedAt: 2, audioPath: "/b", transcript: "나", status: .ready, taskId: game))
        try db.writer.write { conn in
            _ = try TaskMerger.merge(TaskMerger.Group(keep: "t_keep", merge: ["t_victim"]), conn: conn, now: 10)
            _ = try TaskMerger.retire("t_game", conn: conn, now: 10)
        }
        XCTAssertEqual(try recordings.find(id: merged.id!)?.taskId, keep)
        XCTAssertNil(try recordings.find(id: retired.id!)?.taskId)
    }

    func testReopeningABatchSendsItsRecordingsBackToTheQueue() throws {
        let db = try WGDatabase.inMemory()
        let recordings = RecordingStore(db)
        let recording = try recordings.insert(Recording(startedAt: 100, endedAt: 200, duration: 100, audioPath: "/a", transcript: "가나다",
                                                         status: .ready, readyAt: 210, batchId: 5, taskId: 9))
        _ = try EventStore(db).reopenBatches([5])
        let reopened = try XCTUnwrap(recordings.find(id: recording.id!))
        XCTAssertNil(reopened.batchId)
        XCTAssertNil(reopened.taskId)
    }

    func testRebuildingTheGraphFromAssignmentsKeepsTheRecording() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        for (i, ts) in [100.0, 160, 400, 460].enumerated() {
            try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: "b\(i % 2)", appName: "App\(i % 2)", windowTitle: "w\(i % 2)"))
        }
        let recording = try RecordingStore(db).insert(lecture(id: nil, start: 120, end: 380))
        let llm = StubLLM([.success("""
        {"tasks":[{"ref":"A","match":"new","title":"자료구조 공부","task_type":"강의수강"}],"rows":[{"rows":"1-5","task":"A"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 2_000 })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("배치가 성공해야 한다") }
        _ = try GraphRebuilder(db: db, store: store, config: .singleCall, home: "/Users/me", fileExists: { _ in false }).rebuildFromAssignments(now: 3_000)
        let key = "recording:\(recording.id!)"
        let resource = try await db.writer.read { try GraphTx($0).node(label: NodeLabel.resource, key: key) }
        let node = try XCTUnwrap(resource, "다시 만든 그래프에도 녹음 자료가 남아야 한다")
        let touched = try await db.writer.read { try GraphTx($0).edges(to: node.id, type: "TOUCHED") }
        XCTAssertEqual(touched.count, 1)
    }

    func testBothJudgmentPromptsExplainRecordingRows() {
        let line = #"Rows whose app is "녹음" (type Recording, dwell 0)"#
        XCTAssertTrue(StagePrompt.classifySystem.contains(line))
        XCTAssertTrue(OntologyPrompt.system.contains(line))
    }

    func testARecordingIsAReferenceResourceByDefault() {
        XCTAssertTrue(TBox.resourceTypes.contains { $0.name == "Recording" && $0.parent == "참고자료" })
        let row = ActivityRow(row: 1, start: 0, end: 0, dwell: 0, app: "녹음", appBundle: "sillog.recording", title: "회의", uri: "recording:1",
                              type: "Recording", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [])
        XCTAssertTrue(AssignmentApplier.defaultResource(row))
    }
}
