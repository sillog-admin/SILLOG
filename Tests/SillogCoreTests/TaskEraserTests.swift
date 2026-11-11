import XCTest
import GRDB
@testable import SillogCore

/// 분야째 업무를 기록까지 지운다 (사용자가 지우라고 한 회사 업무 같은 것). 다른 분야의 업무와 함께 쓰던 주제·자료·앱은 남는다
final class TaskEraserTests: XCTestCase {
    private struct Fixture {
        var work: Int64 = 0, study: Int64 = 0, workTheme: Int64 = 0, studyTheme: Int64 = 0
        var workSession: Int64 = 0, studySession: Int64 = 0
        var workTopic: Int64 = 0, sharedTopic: Int64 = 0, workResource: Int64 = 0, sharedResource: Int64 = 0
        var windowsApp: Int64 = 0, chrome: Int64 = 0
    }

    private func seed(_ db: SillogDatabase) throws -> Fixture {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            func node(_ label: String, _ key: String, _ title: String) throws -> Int64 {
                try tx.upsertNode(label: label, key: key, subtype: nil, title: title, props: [:], at: 100)
            }
            func edge(_ src: Int64, _ dst: Int64, _ type: String) throws { _ = try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: 1, at: 100) }
            var f = Fixture()
            f.workTheme = try node(NodeLabel.theme, "직장 업무", "직장 업무")
            f.studyTheme = try node(NodeLabel.theme, "학업", "학업")
            f.work = try node(NodeLabel.task, "t_work", "SK 업무용 AVD에서 서비스 개발·운영")
            f.study = try node(NodeLabel.task, "t_study", "자료구조 과제")
            try edge(f.work, f.workTheme, EdgeType.partOf)
            try edge(f.study, f.studyTheme, EdgeType.partOf)
            f.workSession = try node(NodeLabel.session, "s_work", "AVD 작업")
            f.studySession = try node(NodeLabel.session, "s_study", "과제 풀이")
            try edge(f.workSession, f.work, EdgeType.partOf)
            try edge(f.studySession, f.study, EdgeType.partOf)
            try edge(f.workSession, f.studySession, EdgeType.switchedTo)
            f.workTopic = try node(NodeLabel.topic, "avd", "Azure Virtual Desktop")
            f.sharedTopic = try node(NodeLabel.topic, "linux", "Linux")
            try edge(f.work, f.workTopic, EdgeType.about)
            try edge(f.work, f.sharedTopic, EdgeType.about)
            try edge(f.study, f.sharedTopic, EdgeType.about)
            f.workResource = try node(NodeLabel.resource, "https://portal.azure.com", "Azure Portal")
            f.sharedResource = try node(NodeLabel.resource, "https://stackoverflow.com/q/1", "ssh 질문")
            try edge(f.workSession, f.workResource, EdgeType.touched)
            try edge(f.workSession, f.sharedResource, EdgeType.touched)
            try edge(f.studySession, f.sharedResource, EdgeType.touched)
            f.windowsApp = try node(NodeLabel.app, "com.microsoft.rdc.macos", "Windows App")
            f.chrome = try node(NodeLabel.app, "com.google.Chrome", "Google Chrome")
            try edge(f.workSession, f.windowsApp, EdgeType.used)
            try edge(f.workSession, f.chrome, EdgeType.used)
            try edge(f.studySession, f.chrome, EdgeType.used)

            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'w', 'ax', '회사 서버 설정 화면', 100), (2, 's', 'ax', '연결 리스트 예제', 100)")
            try conn.execute(sql: """
                INSERT INTO screen_cards(id, ts_start, ts_end, screen_hash, screenshot_path, app_bundle, app_name, activity, content, kind, created_at)
                VALUES (1, 100, 200, 'h1', '/tmp/captures/work.jpg', 'com.microsoft.rdc.macos', 'Windows App', '회사 원격 데스크톱', '배포 스크립트', 'code', 100),
                       (2, 300, 400, 'h2', NULL, 'com.google.Chrome', 'Google Chrome', '과제 페이지', '연결 리스트', 'web', 100)
                """)
            try conn.execute(sql: """
                INSERT INTO batches(id, started_at, status, raw_response, user_prompt, llm_patch, applied_patch, row_count)
                VALUES (1, 100, 'ok', '{"work":"AVD"}', 'ROWS: Windows App 회사 서버 / Chrome 자료구조', '{}', '{}', 3),
                       (2, 300, 'ok', '{"study":1}', 'ROWS: Chrome 자료구조', '{}', '{}', 1),
                       (3, 500, 'ok', '{"study":2}', 'OPEN_TASKS:\n- id=t_work | SK 업무용 AVD에서 서비스 개발·운영\n- id=t_study | 자료구조 과제\nROWS: Chrome 자료구조', '{}', '{}', 1)
                """)
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, window_title, text_id, batch_id, task_id, card_id)
                VALUES (1, 100, 'app_activate', 'com.microsoft.rdc.macos', 'Windows App', 'SK-AVD', 1, 1, ?, 1),
                       (2, 150, 'app_activate', 'com.microsoft.rdc.macos', 'Windows App', 'SK-AVD', 1, 1, ?, 1),
                       (3, 180, 'app_activate', 'com.google.Chrome', 'Google Chrome', '자료구조', 2, 1, ?, 2),
                       (4, 300, 'app_activate', 'com.google.Chrome', 'Google Chrome', '자료구조', 2, 2, ?, 2)
                """, arguments: [f.work, f.work, f.study, f.study])
            try conn.execute(sql: "INSERT INTO chat_messages(ts, tool, session_id, text, ingested_at, task_id) VALUES (100, 'claude', 'a', '회사 배포 스크립트 고쳐줘', 100, ?), (300, 'claude', 'b', '연결 리스트 설명해줘', 300, ?)",
                             arguments: [f.work, f.study])
            for key in ["t_work", "t_study"] {
                try conn.execute(sql: """
                    INSERT INTO digests(level, period, period_start, period_end, tz, task_key, title, body, structured, metrics, anchors, status, prompt_version, input_hash, created_at)
                    VALUES ('week', '2026-W44', 0, 1, 'Asia/Seoul', ?, ?, '요약', '{}', '{}', '[]', 'ok', 'v1', ?, 100)
                    """, arguments: [key, "\(key) 주간 요약", key])
                try conn.execute(sql: "INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at) VALUES ('2026-10-27', ?, 'task', ?, 600, 100, 700), ('2026-10-27', ?, 'app', 'Windows App', 300, 100, 400)",
                                 arguments: [key, key, key])
            }
            try conn.execute(sql: "INSERT INTO retention_pins(kind, key, created_at) VALUES ('task', 't_work', 100)")
            try conn.execute(sql: """
                INSERT INTO file_suggestions(ts, path, file_name, suggested_folder, confidence, source, status, context)
                VALUES (100, '/Users/me/Downloads/a.pdf', 'a.pdf', '/Users/me/Documents', 0.8, 'llm', 'moved', '하던 업무: SK 업무용 AVD에서 서비스 개발·운영'),
                       (300, '/Users/me/Downloads/b.pdf', 'b.pdf', '/Users/me/Documents', 0.8, 'llm', 'moved', '하던 업무: 자료구조 과제')
                """)
            return f
        }
    }

    private func count(_ db: SillogDatabase, _ sql: String) throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: sql) ?? 0 }
    }

    func testDryRunOnlyCounts() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let report = try db.writer.write { try TaskEraser.erase(theme: "직장 업무", conn: $0, now: 1_000, dry: true) }
        XCTAssertEqual(report.tasks, ["SK 업무용 AVD에서 서비스 개발·운영"])
        XCTAssertEqual(report.observations, 2)
        XCTAssertEqual(report.cards, 1)
        XCTAssertEqual(report.texts, 1)
        XCTAssertEqual(report.chats, 1)
        XCTAssertEqual(report.digests, 1)
        XCTAssertEqual(report.batches, 2, "그 행이 들어간 정리 기록과, 업무 목록으로 그 업무를 언급한 정리 기록")
        XCTAssertEqual(report.files, ["/tmp/captures/work.jpg"])
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM observations"), 4, "세기만 하고 지우지 않는다")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM nodes WHERE label = 'Task'"), 2)
    }

    func testErasesTheThemeWithItsTasksAndRecordsButKeepsSharedOnes() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        _ = try db.writer.write { try TaskEraser.erase(theme: "직장 업무", conn: $0, now: 1_000, dry: false) }

        let nodes = Set(try db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM nodes") })
        for (id, name) in [(f.work, "업무"), (f.workTheme, "분야"), (f.workSession, "세션"), (f.workTopic, "그 업무에만 걸린 주제"),
                           (f.workResource, "그 업무 세션만 만진 자료"), (f.windowsApp, "그 업무 세션만 쓴 앱")] {
            XCTAssertFalse(nodes.contains(id), "\(name)은 지운다")
        }
        for (id, name) in [(f.study, "다른 업무"), (f.studyTheme, "다른 분야"), (f.studySession, "다른 세션"), (f.sharedTopic, "같이 쓰던 주제"),
                           (f.sharedResource, "같이 쓰던 자료"), (f.chrome, "같이 쓰던 앱")] {
            XCTAssertTrue(nodes.contains(id), "\(name)은 남긴다")
        }
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM edges WHERE src = \(f.workSession) OR dst = \(f.workSession)"), 0)

        XCTAssertEqual(try db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM observations ORDER BY id") }, [3, 4], "그 업무의 원시 행만 지운다")
        XCTAssertEqual(try db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM text_snapshots") }, [2])
        XCTAssertEqual(try db.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM screen_cards") }, [2])
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM screen_cards_fts WHERE screen_cards_fts MATCH '스크립트'"), 0, "검색 색인에서도 빠진다 (색인은 세 글자 단위)")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM screen_cards_fts WHERE screen_cards_fts MATCH '리스트'"), 1, "남은 카드는 그대로 찾아진다")
        XCTAssertEqual(try db.writer.read { try String.fetchAll($0, sql: "SELECT text FROM chat_messages") }, ["연결 리스트 설명해줘"])
        XCTAssertEqual(try db.writer.read { try String.fetchAll($0, sql: "SELECT task_key FROM digests") }, ["t_study"])
        XCTAssertEqual(try db.writer.read { try String.fetchAll($0, sql: "SELECT DISTINCT task_key FROM usage_ledger") }, ["t_study"],
                       "시간 기록은 업무 외로 옮기지 않고 지운다")
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM retention_pins"), 0)
        XCTAssertEqual(try db.writer.read { try String.fetchAll($0, sql: "SELECT COALESCE(context, '-') FROM file_suggestions ORDER BY ts") },
                       ["-", "하던 업무: 자료구조 과제"], "파일 정리 제안에 적어 둔 그 업무 이름도 비운다")

        let scrubbed = try db.writer.read { try Row.fetchOne($0, sql: "SELECT user_prompt, raw_response, llm_patch, applied_patch, row_count FROM batches WHERE id = 1") }
        XCTAssertNil(scrubbed?["user_prompt"] as String?, "그 행이 들어간 정리 기록은 원문을 비운다")
        XCTAssertNil(scrubbed?["raw_response"] as String?)
        XCTAssertNil(scrubbed?["llm_patch"] as String?)
        XCTAssertNil(scrubbed?["applied_patch"] as String?)
        XCTAssertEqual(scrubbed?["row_count"] as Int?, 3, "통계는 남긴다")
        XCTAssertEqual(try db.writer.read { try String.fetchOne($0, sql: "SELECT user_prompt FROM batches WHERE id = 2") }, "ROWS: Chrome 자료구조")
        XCTAssertNil(try db.writer.read { try String.fetchOne($0, sql: "SELECT user_prompt FROM batches WHERE id = 3") },
                     "업무 목록으로 그 업무의 이름·목표를 보낸 정리 기록도 원문을 비운다")
    }

    /// 지운 내용이 파일에 남지 않게 검색 색인을 다시 쓰고 VACUUM 한다. 남은 기록은 그대로 읽힌다
    func testCompactAfterEraseKeepsTheRestReadable() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        _ = try db.writer.write { try TaskEraser.erase(theme: "직장 업무", conn: $0, now: 1_000, dry: false) }
        try TaskEraser.compact(db)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM observations"), 2)
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM screen_cards_fts WHERE screen_cards_fts MATCH '리스트'"), 1)
    }

    /// 지운 기록의 파일은 그 DB 의 데이터 폴더 안에 있는 것만 지운다 (DB 사본으로 시험할 때 진짜 스크린샷을 지우지 않게)
    func testRemovesOnlyFilesInsideTheDataFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data"), other = root.appendingPathComponent("other")
        for dir in [data, other] { try FileManager.default.createDirectory(at: dir.appendingPathComponent("captures"), withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = data.appendingPathComponent("captures/a.jpg").path, outside = other.appendingPathComponent("captures/b.jpg").path
        for path in [inside, outside] { FileManager.default.createFile(atPath: path, contents: Data([1])) }
        let link = data.appendingPathComponent("linked-captures")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other.appendingPathComponent("captures"))
        let throughLink = link.appendingPathComponent("b.jpg").path
        let result = TaskEraser.removeFiles([inside, outside, throughLink, data.appendingPathComponent("captures/없음.jpg").path], within: data.path)
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(result.skipped, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
    }

    func testUnknownThemeErasesNothing() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let report = try db.writer.write { try TaskEraser.erase(theme: "없는 분야", conn: $0, now: 1_000, dry: false) }
        XCTAssertEqual(report.tasks, [])
        XCTAssertEqual(try count(db, "SELECT COUNT(*) FROM observations"), 4)
    }
}
