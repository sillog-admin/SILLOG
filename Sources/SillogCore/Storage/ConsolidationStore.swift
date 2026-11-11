import CryptoKit
import Foundation
import GRDB

/// 원시 기록을 보관 기간에 맞춰 정리할 때 쓰는 테이블: 사용 시간 기록, 다이제스트, 정리 진행 상태, 보존 핀, 중복 제거한 프롬프트
public enum ConsolidationStore {
    /// consolidation_state 의 키
    public enum Key {
        public static let ledgerUntil = "ledger_until"
        public static let weekUntil = "week_until"
        public static let monthUntil = "month_until"
        /// 이날까지 사용 시간 기록이 동결되고 세션이 재구성에서 보호된다 (YYYY-MM-DD)
        public static let sealedUntil = "sealed_until"
        public static let textPrunedUntil = "text_pruned_until"
        public static let batchesPrunedUntil = "batches_pruned_until"
        public static let observationsPrunedUntil = "observations_pruned_until"
        public static let cardsPrunedUntil = "cards_pruned_until"
        public static let aiRequestsPrunedUntil = "ai_requests_pruned_until"
        public static let filesPrunedUntil = "files_pruned_until"
        public static let firstPruneConsentedAt = "first_prune_consented_at"
        public static let policy = "retention_policy"
        public static let lastRunAt = "last_run_at"
        public static let lastReport = "last_report"
    }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15-consolidation") { db in
            try db.execute(sql: """
                CREATE TABLE usage_ledger (
                  day TEXT NOT NULL,
                  task_key TEXT NOT NULL DEFAULT '',
                  target_kind TEXT NOT NULL,
                  target_key TEXT NOT NULL,
                  seconds REAL NOT NULL,
                  first_at REAL NOT NULL,
                  last_at REAL NOT NULL,
                  hits INTEGER NOT NULL DEFAULT 0,
                  frozen INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (day, task_key, target_kind, target_key)
                );
                CREATE INDEX idx_usage_ledger_task ON usage_ledger(task_key, day);
                CREATE TABLE digests (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  level TEXT NOT NULL,
                  period TEXT NOT NULL,
                  period_start REAL NOT NULL,
                  period_end REAL NOT NULL,
                  tz TEXT NOT NULL,
                  task_key TEXT NOT NULL,
                  title TEXT NOT NULL,
                  body TEXT NOT NULL,
                  structured TEXT NOT NULL,
                  metrics TEXT NOT NULL,
                  anchors TEXT NOT NULL,
                  status TEXT NOT NULL,
                  model TEXT,
                  prompt_version INTEGER NOT NULL,
                  input_hash TEXT NOT NULL,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL,
                  verified_at REAL,
                  UNIQUE (level, period, task_key)
                );
                CREATE INDEX idx_digests_task ON digests(task_key, period_start);
                CREATE VIRTUAL TABLE digests_fts USING fts5(title, body, content='digests', content_rowid='id', tokenize='trigram');
                CREATE TRIGGER digests_ai AFTER INSERT ON digests BEGIN
                  INSERT INTO digests_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
                END;
                CREATE TRIGGER digests_ad AFTER DELETE ON digests BEGIN
                  INSERT INTO digests_fts(digests_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
                END;
                CREATE TRIGGER digests_au AFTER UPDATE ON digests BEGIN
                  INSERT INTO digests_fts(digests_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
                  INSERT INTO digests_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
                END;
                CREATE TABLE consolidation_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE retention_pins (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind TEXT NOT NULL,
                  key TEXT NOT NULL,
                  created_at REAL NOT NULL,
                  UNIQUE (kind, key)
                );
                CREATE TABLE prompt_blobs (hash TEXT PRIMARY KEY, text TEXT NOT NULL);
                ALTER TABLE batches ADD COLUMN system_prompt_hash TEXT;
                DROP VIEW v_batches;
                CREATE VIEW v_batches AS
                  SELECT b.id, datetime(b.started_at, 'unixepoch', 'localtime') AS time, b.status, b.model, b.row_count,
                         b.prompt_tokens, b.completion_tokens, b.error, b.user_prompt, b.llm_patch, b.applied_patch,
                         COALESCE(b.system_prompt, p.text) AS system_prompt, b.stats, b.from_obs, b.to_obs
                  FROM batches b LEFT JOIN prompt_blobs p ON p.hash = b.system_prompt_hash;
                CREATE VIEW v_ledger AS
                  SELECT l.day, COALESCE(t.title, NULLIF(l.task_key, ''), '(업무 외)') AS task, l.target_kind, l.target_key, l.seconds, l.hits, l.frozen
                  FROM usage_ledger l LEFT JOIN nodes t ON t.label = 'Task' AND t.key = l.task_key;
                CREATE VIEW v_digests AS
                  SELECT id, level, period, task_key, title, status, body, datetime(created_at, 'unixepoch', 'localtime') AS created FROM digests;
                """)
            // 배치마다 통째로 저장하던 시스템 프롬프트는 서로 다른 값이 몇 개뿐이다. 원문은 한 번만 두고 해시로 가리킨다
            for text in try String.fetchAll(db, sql: "SELECT DISTINCT system_prompt FROM batches WHERE system_prompt IS NOT NULL") {
                let hash = try storePrompt(text, db)
                try db.execute(sql: "UPDATE batches SET system_prompt_hash = ?, system_prompt = NULL WHERE system_prompt = ?", arguments: [hash, text])
            }
        }
    }

    // MARK: 진행 상태

    public static func value(_ key: String, _ conn: Database) throws -> String? {
        try String.fetchOne(conn, sql: "SELECT value FROM consolidation_state WHERE key = ?", arguments: [key])
    }

    public static func set(_ key: String, _ value: String?, _ conn: Database) throws {
        if let value {
            try conn.execute(sql: "INSERT INTO consolidation_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                             arguments: [key, value])
        } else {
            try conn.execute(sql: "DELETE FROM consolidation_state WHERE key = ?", arguments: [key])
        }
    }

    /// 날짜 상태값을 뒤로 가지 않게 올린다
    static func advance(_ key: String, to day: String, _ conn: Database) throws {
        if let current = try value(key, conn), current >= day { return }
        try set(key, day, conn)
    }

    // MARK: 프롬프트 원문

    static func promptHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 원문을 한 번만 저장하고 해시를 돌려준다
    @discardableResult
    public static func storePrompt(_ text: String, _ conn: Database) throws -> String {
        let hash = promptHash(text)
        try conn.execute(sql: "INSERT OR IGNORE INTO prompt_blobs(hash, text) VALUES (?, ?)", arguments: [hash, text])
        return hash
    }

    // MARK: 보존 핀

    public static func pins(_ conn: Database) throws -> [RetentionPin] {
        try Row.fetchAll(conn, sql: "SELECT * FROM retention_pins ORDER BY created_at").compactMap { row in
            guard let kind = RetentionPin.Kind(rawValue: row["kind"]) else { return nil }
            return RetentionPin(id: row["id"], kind: kind, key: row["key"], createdAt: row["created_at"])
        }
    }

    public static func pin(_ kind: RetentionPin.Kind, key: String, at: Double, _ conn: Database) throws {
        try conn.execute(sql: "INSERT OR IGNORE INTO retention_pins(kind, key, created_at) VALUES (?, ?, ?)", arguments: [kind.rawValue, key, at])
    }

    public static func unpin(_ kind: RetentionPin.Kind, key: String, _ conn: Database) throws {
        try conn.execute(sql: "DELETE FROM retention_pins WHERE kind = ? AND key = ?", arguments: [kind.rawValue, key])
    }

    // MARK: 업무 병합·업무 외로 돌리기

    /// 업무를 합치면 사용 시간 기록·다이제스트·핀의 업무 key 를 남는 업무로 옮긴다
    public static func mergeTask(from victim: String, into keep: String, now: Double, _ conn: Database) throws {
        guard victim != keep else { return }
        try conn.execute(sql: """
            INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at, hits, frozen)
            SELECT day, ?, target_kind, CASE WHEN target_kind = 'task' THEN ? ELSE target_key END, seconds, first_at, last_at, hits, frozen
            FROM usage_ledger WHERE task_key = ?
            ON CONFLICT(day, task_key, target_kind, target_key) DO UPDATE SET
              seconds = usage_ledger.seconds + excluded.seconds,
              first_at = MIN(usage_ledger.first_at, excluded.first_at),
              last_at = MAX(usage_ledger.last_at, excluded.last_at),
              hits = usage_ledger.hits + excluded.hits,
              frozen = MAX(usage_ledger.frozen, excluded.frozen)
            """, arguments: [keep, keep, victim])
        try conn.execute(sql: "DELETE FROM usage_ledger WHERE task_key = ?", arguments: [victim])
        try DigestStore.mergeTask(from: victim, into: keep, now: now, conn)
        if try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM retention_pins WHERE kind = 'task' AND key = ?)", arguments: [victim]) == true {
            try pin(.task, key: keep, at: now, conn)
            try unpin(.task, key: victim, conn)
        }
    }

    /// 목표가 아닌 업무를 지우면 그 시간은 업무 외('')로 남기고, 자료·프로젝트별 기록과 다이제스트는 지운다
    public static func retireTask(_ key: String, _ conn: Database) throws {
        guard !key.isEmpty else { return }
        try conn.execute(sql: """
            INSERT INTO usage_ledger(day, task_key, target_kind, target_key, seconds, first_at, last_at, hits, frozen)
            SELECT day, '', target_kind, CASE WHEN target_kind = 'task' THEN '' ELSE target_key END, seconds, first_at, last_at, hits, frozen
            FROM usage_ledger WHERE task_key = ? AND target_kind IN ('task', 'app')
            ON CONFLICT(day, task_key, target_kind, target_key) DO UPDATE SET
              seconds = usage_ledger.seconds + excluded.seconds,
              first_at = MIN(usage_ledger.first_at, excluded.first_at),
              last_at = MAX(usage_ledger.last_at, excluded.last_at),
              hits = usage_ledger.hits + excluded.hits,
              frozen = MAX(usage_ledger.frozen, excluded.frozen)
            """, arguments: [key])
        try conn.execute(sql: "DELETE FROM usage_ledger WHERE task_key = ?", arguments: [key])
        try conn.execute(sql: "DELETE FROM digests WHERE task_key = ?", arguments: [key])
        try unpin(.task, key: key, conn)
    }
}

/// 원문을 지우지 않고 남길 업무 또는 기간
public struct RetentionPin: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case task, period }
    public let id: Int64
    public let kind: Kind
    /// 업무 key 또는 "YYYY-MM-DD..YYYY-MM-DD"
    public let key: String
    public let createdAt: Double

    public init(id: Int64, kind: Kind, key: String, createdAt: Double) {
        self.id = id; self.kind = kind; self.key = key; self.createdAt = createdAt
    }

    public static func periodKey(from: String, to: String) -> String { "\(min(from, to))..\(max(from, to))" }

    /// 기간 핀이 이날을 덮는지
    public func covers(day: String) -> Bool {
        guard kind == .period else { return false }
        let parts = key.components(separatedBy: "..")
        guard parts.count == 2 else { return false }
        return parts[0] <= day && day <= parts[1]
    }
}
