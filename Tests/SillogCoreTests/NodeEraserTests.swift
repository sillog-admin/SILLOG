import XCTest
import GRDB
@testable import SillogCore

/// 노드 하나를 지운다: 그 노드에서만 내려가는 하위 노드와, 그 노드가 찍힌 원시 기록까지. 다른 곳에도 걸린 노드는 연결만 끊고 남긴다
final class NodeEraserTests: XCTestCase {
    private let home = "/Users/me"
    private let shadcnURL = "https://ui.shadcn.com/docs/components/card"
    private let soURL = "https://stackoverflow.com/q/1"
    private var shadcn: String { URINormalizer.normalize(url: shadcnURL) }
    private var so: String { URINormalizer.normalize(url: soURL) }

    private struct Fixture {
        var study: Int64 = 0, work: Int64 = 0, s1: Int64 = 0, s2: Int64 = 0, s3: Int64 = 0
        var shadcn: Int64 = 0, so: Int64 = 0, chrome: Int64 = 0, vscode: Int64 = 0
        var linux: Int64 = 0, avd: Int64 = 0, problem: Int64 = 0, later: Int64 = 0, taskType: Int64 = 0
    }

    private func seed(_ db: SillogDatabase) throws -> Fixture {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            func node(_ label: String, _ key: String, _ title: String, _ props: [String: JSONValue] = [:]) throws -> Int64 {
                try tx.upsertNode(label: label, key: key, subtype: nil, title: title, props: props, at: 100)
            }
            func edge(_ src: Int64, _ dst: Int64, _ type: String, _ weight: Double = 1) throws {
                _ = try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: weight, at: 100)
            }
            var f = Fixture()
            let theme = try node(NodeLabel.theme, "학업", "학업")
            f.taskType = try node(NodeLabel.taskType, "학습", "학습")
            f.study = try node(NodeLabel.task, "t_study", "자료구조 과제", ["active_seconds": .number(900)])
            f.work = try node(NodeLabel.task, "t_work", "회사 대시보드", ["active_seconds": .number(300)])
            try edge(f.study, theme, EdgeType.partOf)
            try edge(f.study, f.taskType, EdgeType.instanceOf)
            f.s1 = try node(NodeLabel.session, "s1", "10/7 과제 1", ["start": .number(100), "end": .number(200), "active_seconds": .number(100)])
            f.s2 = try node(NodeLabel.session, "s2", "10/7 과제 2", ["start": .number(300), "end": .number(400), "active_seconds": .number(100)])
            f.s3 = try node(NodeLabel.session, "s3", "10/8 대시보드", ["start": .number(500), "end": .number(600), "active_seconds": .number(100)])
            for (session, task) in [(f.s1, f.study), (f.s2, f.study), (f.s3, f.work)] { try edge(session, task, EdgeType.partOf) }
            try edge(f.s1, f.s2, EdgeType.switchedTo)
            f.shadcn = try node(NodeLabel.resource, shadcn, "shadcn/ui Card")
            f.so = try node(NodeLabel.resource, so, "ssh 질문")
            try edge(f.s1, f.shadcn, EdgeType.touched, 40)
            try edge(f.s1, f.so, EdgeType.touched, 20)
            try edge(f.s3, f.so, EdgeType.touched, 30)
            f.chrome = try node(NodeLabel.app, "com.google.Chrome", "Google Chrome")
            f.vscode = try node(NodeLabel.app, "com.microsoft.VSCode", "Code")
            for session in [f.s1, f.s2, f.s3] { try edge(session, f.chrome, EdgeType.used, 60) }
            try edge(f.s2, f.vscode, EdgeType.used, 40)
            f.linux = try node(NodeLabel.topic, "linux", "Linux")
            f.avd = try node(NodeLabel.topic, "avd", "AVD")
            try edge(f.study, f.linux, EdgeType.about)
            try edge(f.work, f.linux, EdgeType.about)
            try edge(f.work, f.avd, EdgeType.about)
            f.problem = try node(NodeLabel.problem, "problem:build:1", "빌드 오류")
            try edge(f.s1, f.problem, EdgeType.hit)
            f.later = try node(NodeLabel.laterItem, "later:1", "보고서 고치기", ["done": .bool(false)])
            try edge(f.later, f.study, EdgeType.forTask)

            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'a', 'ax', 'Card 컴포넌트 문서', 100), (2, 'b', 'ax', 'ssh 질문', 100)")
            try conn.execute(sql: """
                INSERT INTO screen_cards(id, ts_start, ts_end, screen_hash, screenshot_path, app_bundle, app_name, uri, activity, content, kind, created_at)
                VALUES (1, 100, 120, 'h1', '/tmp/captures/shadcn.jpg', 'com.google.Chrome', 'Google Chrome', ?, 'Card 문서 읽기', 'Card props', 'web', 100),
                       (2, 300, 320, 'h2', NULL, 'com.microsoft.VSCode', 'Code', NULL, 'list.c 편집', 'insert 함수', 'code', 100)
                """, arguments: [shadcn])
            try conn.execute(sql: """
                INSERT INTO batches(id, started_at, status, user_prompt, raw_response, row_count) VALUES
                  (1, 100, 'ok', 'ROWS: shadcn / stackoverflow', '{}', 2), (2, 300, 'ok', 'ROWS: list.c', '{}', 1), (3, 500, 'ok', 'ROWS: stackoverflow / shadcn', '{}', 2)
                """)
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, window_title, url, text_id, batch_id, task_id, off_task, card_id) VALUES
                  (1, 110, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'Card - shadcn/ui', ?, 1, 1, ?, 0, 1),
                  (2, 150, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'ssh 질문', ?, 2, 1, ?, 0, NULL),
                  (3, 310, 'app_activate', 'com.microsoft.VSCode', 'Code', 'list.c — 과제', NULL, NULL, 2, ?, 0, 2),
                  (4, 510, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'ssh 질문', ?, 2, 3, ?, 0, NULL),
                  (5, 520, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'Card - shadcn/ui', ?, 1, 3, NULL, 1, NULL)
                """, arguments: [shadcnURL + "#props", f.study, soURL, f.study, f.study, soURL, f.work, shadcnURL])
            try conn.execute(sql: """
                INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at) VALUES
                  ('2026-10-07', 't_study', 'resource', ?, 40, 100, 140), ('2026-10-07', 't_study', 'app', 'com.microsoft.VSCode', 40, 300, 340),
                  ('2026-10-07', 't_study', 'app', 'com.google.Chrome', 120, 100, 400)
                """, arguments: [shadcn])
            return f
        }
    }

    private func erase(_ db: SillogDatabase, _ label: String, _ key: String, dry: Bool = false) throws -> TaskEraser.Report {
        try db.writer.write { try NodeEraser.erase(label: label, key: key, conn: $0, now: 1_000, home: self.home, dry: dry) }
    }

    private func ids(_ db: SillogDatabase, _ sql: String) throws -> [Int64] {
        try db.writer.read { try Int64.fetchAll($0, sql: sql) }
    }

    private func nodes(_ db: SillogDatabase) throws -> Set<Int64> { Set(try ids(db, "SELECT id FROM nodes")) }

    func testErasingAResourceRemovesItsRowsCardsAndTimeButKeepsSessions() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let report = try erase(db, NodeLabel.resource, shadcn)
        XCTAssertEqual(report.observations, 2, "주소가 같은 행이면 업무 밖 행도 (#뒤는 정규화로 같아진다)")
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [2, 3, 4])
        XCTAssertEqual(try ids(db, "SELECT id FROM screen_cards"), [2])
        XCTAssertEqual(try ids(db, "SELECT id FROM text_snapshots"), [2])
        XCTAssertEqual(try ids(db, "SELECT id FROM batches WHERE user_prompt IS NULL ORDER BY id"), [1, 3], "지운 행이 들어간 정리 기록은 원문을 비운다")
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage_ledger WHERE target_kind = 'resource'") }, 0)
        XCTAssertEqual(report.files, ["/tmp/captures/shadcn.jpg"])
        let left = try nodes(db)
        XCTAssertFalse(left.contains(f.shadcn))
        XCTAssertTrue(left.isSuperset(of: [f.s1, f.so, f.study, f.chrome]))
    }

    /// 내려받은 파일 기록이 지우는 원시 행을 가리키면 연결만 끊는다 (그 행을 가리키는 채로는 DB 가 삭제를 막는다, 11/06 실제 앱에서 실패)
    func testFileEventsPointingAtErasedRowsAreUnlinked() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        try db.writer.write { try $0.execute(sql: "INSERT INTO file_events(ts, path, kind, origin_url, observation_id) VALUES (115, '/Users/me/Downloads/card.pdf', 'created', ?, 1)", arguments: [self.shadcnURL]) }
        XCTAssertNoThrow(try erase(db, NodeLabel.resource, shadcn))
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [2, 3, 4])
        let link = try db.writer.read { try Row.fetchOne($0, sql: "SELECT path, observation_id FROM file_events") }
        XCTAssertEqual(link?["path"] as String?, "/Users/me/Downloads/card.pdf", "내려받은 파일 기록은 남긴다 (파일 정리 제안이 쓴다)")
        XCTAssertNil(link?["observation_id"] as Int64?)
    }

    func testErasingAnAppRemovesAllItsRows() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let report = try erase(db, NodeLabel.app, "com.microsoft.VSCode")
        XCTAssertEqual(report.observations, 1)
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [1, 2, 4, 5])
        XCTAssertEqual(try ids(db, "SELECT id FROM screen_cards"), [1], "그 앱의 화면 카드")
        XCTAssertEqual(try db.writer.read { try String.fetchAll($0, sql: "SELECT target_key FROM usage_ledger WHERE target_kind = 'app'") }, ["com.google.Chrome"])
        let left = try nodes(db)
        XCTAssertFalse(left.contains(f.vscode))
        XCTAssertTrue(left.contains(f.s2), "세션은 남는다")
    }

    func testErasingASessionRemovesItsWindowAndWhatOnlyItUsed() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let report = try erase(db, NodeLabel.session, "s1")
        XCTAssertEqual(report.observations, 2, "그 업무의 그 시간대 행")
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [3, 4, 5], "같은 주소라도 세션 밖 행은 남는다")
        let left = try nodes(db)
        for (id, name) in [(f.s1, "세션"), (f.shadcn, "그 세션만 만진 자료"), (f.problem, "그 세션만 겪은 문제")] { XCTAssertFalse(left.contains(id), name) }
        for (id, name) in [(f.so, "다른 세션도 만진 자료"), (f.chrome, "다른 세션도 쓴 앱"), (f.study, "업무"), (f.s2, "다음 세션")] { XCTAssertTrue(left.contains(id), name) }
        let seconds = try db.writer.read { try GraphTx($0).node(id: f.study)?.props["active_seconds"]?.doubleValue }
        XCTAssertEqual(seconds, 800, "업무 시간에서 그 세션 시간을 뺀다")
        XCTAssertEqual(report.nodes, 3)
    }

    func testErasingASessionKeepsRecordsThatOverlapAnotherSessionOfTheSameTask() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        try db.writer.write { conn in
            try GraphTx(conn).setProps(nodeId: f.s2, ["start": .number(140)], at: 500)
        }

        let report = try erase(db, NodeLabel.session, "s1")
        XCTAssertEqual(report.observations, 1)
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [2, 3, 4, 5])
        XCTAssertTrue(try nodes(db).contains(f.s2))
    }

    func testErasingATopicOrLaterItemRemovesOnlyTheNode() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        _ = try erase(db, NodeLabel.topic, "linux")
        _ = try erase(db, NodeLabel.laterItem, "later:1")
        let left = try nodes(db)
        XCTAssertFalse(left.contains(f.linux))
        XCTAssertFalse(left.contains(f.later))
        XCTAssertTrue(left.isSuperset(of: [f.study, f.work, f.avd]))
        XCTAssertEqual(try ids(db, "SELECT COUNT(*) FROM observations"), [5], "원시 기록은 그대로")
    }

    func testErasingAThemeErasesItsTasks() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let report = try erase(db, NodeLabel.theme, "학업")
        XCTAssertEqual(report.tasks, ["자료구조 과제"])
        XCTAssertEqual(report.title, "학업", "확인 창 제목은 분야 이름")
        let left = try nodes(db)
        XCTAssertFalse(left.contains(f.study))
        XCTAssertTrue(left.contains(f.work))
        XCTAssertEqual(try ids(db, "SELECT id FROM observations ORDER BY id"), [4, 5])
    }

    func testClassesAreNotErasable() throws {
        let db = try SillogDatabase.inMemory()
        let f = try seed(db)
        let report = try erase(db, NodeLabel.taskType, "학습")
        XCTAssertFalse(report.erasable)
        XCTAssertTrue(try nodes(db).contains(f.taskType))
        XCTAssertFalse(NodeEraser.canErase(label: NodeLabel.resourceType))
        XCTAssertTrue(NodeEraser.canErase(label: NodeLabel.resource))
    }

    func testDryRunCountsWithoutErasing() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let report = try erase(db, NodeLabel.session, "s1", dry: true)
        XCTAssertEqual(report.observations, 2)
        XCTAssertEqual(report.nodes, 3)
        XCTAssertEqual(report.title, "10/7 과제 1")
        XCTAssertEqual(try ids(db, "SELECT COUNT(*) FROM observations"), [5])
        XCTAssertEqual(try ids(db, "SELECT COUNT(*) FROM nodes WHERE label = 'Session'"), [3])
    }

    func testUnknownNodeErasesNothing() throws {
        let db = try SillogDatabase.inMemory()
        _ = try seed(db)
        let report = try erase(db, NodeLabel.resource, "https://nowhere.example")
        XCTAssertEqual(report.observations, 0)
        XCTAssertEqual(report.title, "")
        XCTAssertEqual(try ids(db, "SELECT COUNT(*) FROM observations"), [5])
    }
}
