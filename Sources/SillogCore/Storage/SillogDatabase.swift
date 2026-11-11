import Foundation
import GRDB

/// SQLite 파일 하나에 L0 원시 로그와 그래프를 함께 둔다.
/// 같은 파일이라 "배치 처리 표시"와 "그래프 반영"이 한 트랜잭션으로 묶인다.
public final class SillogDatabase: @unchecked Sendable {
    public let writer: any DatabaseWriter
    public let path: String?
    private let memoryLibraryID = UUID().uuidString
    public var libraryDirectory: URL {
        path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("library", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Sillog-library-\(memoryLibraryID)", isDirectory: true)
    }
    /// 녹음 파일 폴더 (받아쓰기가 끝나고 7일 뒤 지운다). 메모리 DB 는 임시 폴더
    public var recordingsDirectory: URL {
        path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Sillog-recordings-\(memoryLibraryID)", isDirectory: true)
    }

    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        self.writer = try DatabasePool(path: path, configuration: config)   // WAL
        self.path = path
        try Self.migrator.migrate(writer)
    }

    private init(queue: DatabaseQueue) throws {
        self.writer = queue
        self.path = nil
        try Self.migrator.migrate(writer)
    }

    public static func inMemory() throws -> SillogDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try SillogDatabase(queue: DatabaseQueue(configuration: config))
    }

    /// ~/Library/Application Support/Sillog
    public static func defaultDirectory() -> URL { resolvedDirectory }

    private static let resolvedDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return migrateLegacyDirectory(in: base)
    }()

    /// `SILLOG_DB` (or legacy `WORKGRAPH_DB`) overrides it so dev runs never touch real data.
    public static func defaultPath() -> String {
        if let override = SillogEnv.value("DB") { return override }
        return databaseFile(in: defaultDirectory()).path
    }

    static func databaseFile(in directory: URL) -> URL {
        let current = directory.appendingPathComponent(databaseName), legacy = directory.appendingPathComponent(legacyDatabaseName)
        return !FileManager.default.fileExists(atPath: current.path) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : current
    }

    static let databaseName = "sillog.sqlite"
    static let legacyDatabaseName = "workgraph.sqlite"

    /// Moves the pre-rename `WorkGraph` folder to `Sillog` and leaves a symlink behind,
    /// because screenshot and file paths stored in the DB are absolute.
    /// Args: base is the Application Support folder.
    /// Returns: the folder to use. The legacy folder whenever moving is unsafe or fails, so data is never left behind.
    /// Raises: nothing.
    static func migrateLegacyDirectory(in base: URL) -> URL {
        let fm = FileManager.default
        let current = base.appendingPathComponent("Sillog", isDirectory: true)
        let legacy = base.appendingPathComponent("WorkGraph", isDirectory: true)
        let legacyIsFolder = (try? legacy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map { $0.isDirectory == true && $0.isSymbolicLink != true } ?? false
        guard legacyIsFolder, !fm.fileExists(atPath: current.path) else { return current }
        let lock = InstanceLock(databasePath: legacy.appendingPathComponent(legacyDatabaseName).path)
        guard lock.acquire() else { return legacy }    // an older build is still running on this folder
        defer { lock.release() }
        do { try fm.moveItem(at: legacy, to: current) } catch { return legacy }
        do {
            try fm.createSymbolicLink(at: legacy, withDestinationURL: current)
        } catch {
            try? fm.moveItem(at: current, to: legacy)
            return fm.fileExists(atPath: legacy.path) ? legacy : current
        }
        renameDatabase(in: current)
        try? fm.removeItem(at: current.appendingPathComponent(legacyDatabaseName + ".instance.lock"))
        return current
    }

    /// Renames workgraph.sqlite with its WAL files, main file last; rolls back on failure so the pair never splits.
    static func renameDatabase(in directory: URL) {
        let fm = FileManager.default
        var moved: [(URL, URL)] = []
        for suffix in ["-wal", "-shm", ""] {
            let from = directory.appendingPathComponent(legacyDatabaseName + suffix), to = directory.appendingPathComponent(databaseName + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            } catch {
                for (from, to) in moved.reversed() { try? fm.moveItem(at: to, to: from) }
                return
            }
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE text_snapshots (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              hash TEXT NOT NULL UNIQUE,
              source TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE TABLE batches (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at REAL NOT NULL,
              finished_at REAL,
              from_obs INTEGER,
              to_obs INTEGER,
              row_count INTEGER NOT NULL DEFAULT 0,
              status TEXT NOT NULL,
              model TEXT,
              prompt_tokens INTEGER NOT NULL DEFAULT 0,
              completion_tokens INTEGER NOT NULL DEFAULT 0,
              error TEXT,
              raw_response TEXT,
              stats TEXT
            );
            CREATE TABLE observations (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL NOT NULL,
              trigger_kind TEXT NOT NULL,
              app_bundle TEXT NOT NULL,
              app_name TEXT NOT NULL,
              window_title TEXT,
              url TEXT,
              doc_path TEXT,
              text_id INTEGER REFERENCES text_snapshots(id),
              screenshot_path TEXT,
              batch_id INTEGER REFERENCES batches(id)
            );
            CREATE INDEX idx_observations_batch_ts ON observations(batch_id, ts);
            CREATE INDEX idx_observations_ts ON observations(ts);
            CREATE TABLE file_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL NOT NULL,
              path TEXT NOT NULL,
              kind TEXT NOT NULL,
              origin_url TEXT,
              observation_id INTEGER REFERENCES observations(id)
            );
            CREATE TABLE idle_spans (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              start_ts REAL NOT NULL,
              end_ts REAL
            );
            CREATE TABLE nodes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              label TEXT NOT NULL,
              key TEXT NOT NULL,
              subtype TEXT,
              title TEXT NOT NULL DEFAULT '',
              props TEXT NOT NULL DEFAULT '{}',
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              UNIQUE(label, key)
            );
            CREATE INDEX idx_nodes_label ON nodes(label);
            CREATE TABLE edges (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              src INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
              dst INTEGER NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
              type TEXT NOT NULL,
              props TEXT NOT NULL DEFAULT '{}',
              weight REAL NOT NULL DEFAULT 0,
              hits INTEGER NOT NULL DEFAULT 1,
              first_at REAL NOT NULL,
              last_at REAL NOT NULL,
              UNIQUE(src, dst, type)
            );
            CREATE INDEX idx_edges_src ON edges(src);
            CREATE INDEX idx_edges_dst ON edges(dst);
            """)
        }
        migrator.registerMigration("v2-batch-prompts") { db in
            // LLM 이 정확히 무엇을 받고 무엇을 돌려줬는지 배치마다 남긴다 (검수·디버그·발표용).
            try db.execute(sql: "ALTER TABLE batches ADD COLUMN system_prompt TEXT")
            try db.execute(sql: "ALTER TABLE batches ADD COLUMN user_prompt TEXT")
            try db.execute(sql: "ALTER TABLE batches ADD COLUMN llm_patch TEXT")
            try db.execute(sql: "ALTER TABLE batches ADD COLUMN applied_patch TEXT")
        }
        migrator.registerMigration("v3-readable-views") { db in
            // DBeaver 같은 DB 도구에서 바로 읽기 좋은 뷰. 시각은 현지 시간 문자열, 텍스트와 업무 이름은 조인해 둔다.
            try db.execute(sql: """
            CREATE VIEW v_rows AS
              SELECT o.id, datetime(o.ts, 'unixepoch', 'localtime') AS time, o.trigger_kind, o.app_name, o.app_bundle,
                     o.window_title, o.url, o.doc_path, t.source AS text_source, t.text, o.screenshot_path, o.batch_id
              FROM observations o LEFT JOIN text_snapshots t ON t.id = o.text_id;
            CREATE VIEW v_batches AS
              SELECT id, datetime(started_at, 'unixepoch', 'localtime') AS time, status, model, row_count,
                     prompt_tokens, completion_tokens, error, user_prompt, llm_patch, applied_patch, system_prompt, stats, from_obs, to_obs
              FROM batches;
            CREATE VIEW v_nodes AS
              SELECT id, label, subtype, title, key, props,
                     datetime(created_at, 'unixepoch', 'localtime') AS created, datetime(updated_at, 'unixepoch', 'localtime') AS updated
              FROM nodes;
            CREATE VIEW v_edges AS
              SELECT e.id, s.label AS from_label, s.title AS from_title, e.type, d.label AS to_label, d.title AS to_title,
                     e.weight, e.hits, e.props, datetime(e.last_at, 'unixepoch', 'localtime') AS last_at
              FROM edges e JOIN nodes s ON s.id = e.src JOIN nodes d ON d.id = e.dst;
            CREATE VIEW v_sessions AS
              SELECT s.id, t.title AS task, datetime(json_extract(s.props, '$.start'), 'unixepoch', 'localtime') AS start_time,
                     datetime(json_extract(s.props, '$.end'), 'unixepoch', 'localtime') AS end_time,
                     json_extract(s.props, '$.active_seconds') AS active_seconds, json_extract(s.props, '$.summary') AS summary
              FROM nodes s JOIN edges e ON e.src = s.id AND e.type = 'PART_OF' JOIN nodes t ON t.id = e.dst
              WHERE s.label = 'Session';
            """)
        }
        migrator.registerMigration("v4-chat-messages") { db in
            // AI 코딩 도구(Claude Code, Codex CLI)에 사용자가 입력한 메시지. 로컬 로그 파일에서 읽는다.
            try db.execute(sql: """
            CREATE TABLE chat_messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL NOT NULL,
              tool TEXT NOT NULL,
              session_id TEXT NOT NULL,
              cwd TEXT,
              text TEXT NOT NULL,
              ingested_at REAL NOT NULL,
              UNIQUE(tool, session_id, ts)
            );
            CREATE INDEX idx_chat_messages_ts ON chat_messages(ts);
            CREATE TABLE chat_cursors (
              path TEXT PRIMARY KEY,
              offset INTEGER NOT NULL
            );
            CREATE VIEW v_chats AS
              SELECT id, datetime(ts, 'unixepoch', 'localtime') AS time, tool, session_id, cwd, text FROM chat_messages;
            """)
        }
        migrator.registerMigration("v5-chat-batch") { db in
            // 대화 메시지도 어느 배치가 썼는지 기록한다. 늦게 읽힌 메시지가 빠지지 않고 다음 배치에 반드시 들어가게.
            try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN batch_id INTEGER REFERENCES batches(id)")
            try db.execute(sql: "CREATE INDEX idx_chat_messages_batch ON chat_messages(batch_id, ts)")
        }
        migrator.registerMigration("v6-file-suggestions") { db in
            // 내려받은 파일을 어디에 둘지 제안한 기록과, 사용자의 수락·거절에서 배운 규칙
            try db.execute(sql: """
            CREATE TABLE file_suggestions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts REAL NOT NULL,
              path TEXT NOT NULL,
              file_name TEXT NOT NULL,
              origin_url TEXT,
              suggested_folder TEXT NOT NULL,
              confidence REAL NOT NULL,
              reason TEXT,
              source TEXT NOT NULL,
              status TEXT NOT NULL,
              moved_to TEXT,
              decided_at REAL,
              context TEXT
            );
            CREATE INDEX idx_file_suggestions_status ON file_suggestions(status, ts);
            CREATE TABLE folder_prefs (
              key TEXT PRIMARY KEY,
              folder TEXT NOT NULL,
              count INTEGER NOT NULL DEFAULT 1,
              updated_at REAL NOT NULL
            );
            CREATE VIEW v_file_suggestions AS
              SELECT id, datetime(ts, 'unixepoch', 'localtime') AS time, file_name, origin_url, suggested_folder, confidence, reason, source, status, moved_to
              FROM file_suggestions;
            """)
        }
        migrator.registerMigration("v7-row-tasks") { db in
            // 행마다 어느 업무인지 (LLM 의 판단 원본). 세션·그래프는 여기서 다시 계산할 수 있다
            try db.execute(sql: """
            ALTER TABLE observations ADD COLUMN task_id INTEGER;
            ALTER TABLE observations ADD COLUMN resource_relevant INTEGER NOT NULL DEFAULT 1;
            ALTER TABLE chat_messages ADD COLUMN task_id INTEGER;
            CREATE INDEX idx_observations_task ON observations(task_id);
            CREATE VIEW v_row_tasks AS
              SELECT o.id, datetime(o.ts, 'unixepoch', 'localtime') AS time, o.app_name, o.window_title, o.url, o.doc_path,
                     t.title AS task, o.resource_relevant, o.batch_id
              FROM observations o LEFT JOIN nodes t ON t.id = o.task_id;
            """)
        }
        migrator.registerMigration("v8-off-task") { db in
            // 어떤 목표에도 기여하지 않는 행 (집중 이탈). 업무 없이 시간만 남긴다
            try db.execute(sql: "ALTER TABLE observations ADD COLUMN off_task INTEGER NOT NULL DEFAULT 0")
        }
        migrator.registerMigration("v9-task-reason") { db in
            // LLM 이 행마다 적은 판정 이유 ("왜 이 업무인가")
            try db.execute(sql: """
            ALTER TABLE observations ADD COLUMN task_reason TEXT;
            DROP VIEW v_row_tasks;
            CREATE VIEW v_row_tasks AS
              SELECT o.id, datetime(o.ts, 'unixepoch', 'localtime') AS time, o.app_name, o.window_title, o.url, o.doc_path,
                     CASE WHEN o.off_task = 1 THEN '(이탈)' ELSE t.title END AS task, o.task_reason AS reason, o.resource_relevant, o.batch_id
              FROM observations o LEFT JOIN nodes t ON t.id = o.task_id;
            """)
        }
        migrator.registerMigration("v10-screen-cards") { db in
            // 화면 기억 카드: 대표 화면을 멀티모달로 읽은 "무엇을 했나 + 화면 내용". 검색은 FTS5 trigram (한국어 부분 문자열)
            try db.execute(sql: """
            ALTER TABLE observations ADD COLUMN screen_hash INTEGER;
            ALTER TABLE observations ADD COLUMN card_id INTEGER;
            CREATE TABLE screen_cards (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              ts_start REAL NOT NULL,
              ts_end REAL NOT NULL,
              screen_hash INTEGER NOT NULL,
              screenshot_path TEXT,
              app_bundle TEXT NOT NULL,
              app_name TEXT NOT NULL,
              window_title TEXT,
              uri TEXT,
              activity TEXT NOT NULL,
              content TEXT NOT NULL,
              kind TEXT NOT NULL,
              entities TEXT NOT NULL DEFAULT '{}',
              batch_id INTEGER,
              created_at REAL NOT NULL
            );
            CREATE INDEX idx_screen_cards_ts ON screen_cards(ts_start);
            CREATE INDEX idx_observations_card ON observations(card_id);
            CREATE VIRTUAL TABLE screen_cards_fts USING fts5(activity, content, entities, window_title, uri, app_name, content='screen_cards', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER screen_cards_ai AFTER INSERT ON screen_cards BEGIN
              INSERT INTO screen_cards_fts(rowid, activity, content, entities, window_title, uri, app_name) VALUES (new.id, new.activity, new.content, new.entities, new.window_title, new.uri, new.app_name);
            END;
            CREATE TRIGGER screen_cards_ad AFTER DELETE ON screen_cards BEGIN
              INSERT INTO screen_cards_fts(screen_cards_fts, rowid, activity, content, entities, window_title, uri, app_name) VALUES ('delete', old.id, old.activity, old.content, old.entities, old.window_title, old.uri, old.app_name);
            END;
            CREATE TRIGGER screen_cards_au AFTER UPDATE ON screen_cards BEGIN
              INSERT INTO screen_cards_fts(screen_cards_fts, rowid, activity, content, entities, window_title, uri, app_name) VALUES ('delete', old.id, old.activity, old.content, old.entities, old.window_title, old.uri, old.app_name);
              INSERT INTO screen_cards_fts(rowid, activity, content, entities, window_title, uri, app_name) VALUES (new.id, new.activity, new.content, new.entities, new.window_title, new.uri, new.app_name);
            END;
            CREATE VIEW v_cards AS
              SELECT id, datetime(ts_start, 'unixepoch', 'localtime') AS start, datetime(ts_end, 'unixepoch', 'localtime') AS end,
                     app_name, window_title, activity, content, kind, entities, uri FROM screen_cards;
            """)
        }
        ChatStore.migrate(&migrator)
        ProjectStore.migrate(&migrator)
        LibraryStore.migrate(&migrator)
        ContextSearch.migrate(&migrator)
        ConsolidationStore.migrate(&migrator)
        RecordingStore.migrate(&migrator)
        ChatStore.migratePins(&migrator)
        EventSuggestionStore.migrate(&migrator)
        ReviewStore.migrate(&migrator)
        ChatStore.migrateSkills(&migrator)
        return migrator
    }
}
