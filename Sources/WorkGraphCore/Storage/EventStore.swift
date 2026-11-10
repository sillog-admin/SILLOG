import Foundation
import GRDB
import CryptoKit

/// L0 원시층 읽기/쓰기. append-only 로 쌓고, 배치가 끝난 행에는 batch_id 만 찍는다.
public struct EventStore: Sendable {
    let db: WGDatabase

    public init(_ db: WGDatabase) { self.db = db }

    // MARK: 쓰기

    @discardableResult
    public func insert(_ observation: Observation) throws -> Int64 {
        try db.writer.write { conn in
            var copy = observation
            try copy.insert(conn)
            return copy.id ?? conn.lastInsertedRowID
        }
    }

    /// 같은 텍스트는 해시로 한 번만 저장한다.
    @discardableResult
    public func upsertText(_ text: String, source: String, at: Double) throws -> Int64 {
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return try db.writer.write { conn in
            if let id = try Int64.fetchOne(conn, sql: "SELECT id FROM text_snapshots WHERE hash = ?", arguments: [hash]) { return id }
            try conn.execute(sql: "INSERT INTO text_snapshots(hash, source, text, created_at) VALUES (?, ?, ?, ?)",
                             arguments: [hash, source, text, at])
            return conn.lastInsertedRowID
        }
    }

    public func attach(observationId: Int64, textId: Int64?, screenshotPath: String?) throws {
        try db.writer.write { conn in
            try conn.execute(sql: """
                UPDATE observations SET text_id = COALESCE(?, text_id), screenshot_path = COALESCE(?, screenshot_path) WHERE id = ?
                """, arguments: [textId, screenshotPath, observationId])
        }
    }

    /// 스크린샷과 그 차이 해시를 행에 붙인다 (화면 기억 카드의 재료). path 가 nil 이면 해시만
    public func attachScreen(observationId: Int64, path: String?, hash: UInt64) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "UPDATE observations SET screenshot_path = COALESCE(?, screenshot_path), screen_hash = ? WHERE id = ?",
                             arguments: [path, Int64(bitPattern: hash), observationId])
        }
    }

    public func insertFileEvent(_ event: FileEvent) throws {
        try db.writer.write { conn in
            var copy = event
            try copy.insert(conn)
        }
    }

    public func openIdle(at: Double) throws {
        try db.writer.write { conn in
            let open = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM idle_spans WHERE end_ts IS NULL") ?? 0
            if open == 0 { try conn.execute(sql: "INSERT INTO idle_spans(start_ts) VALUES (?)", arguments: [at]) }
        }
    }

    public func closeIdle(at: Double) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "UPDATE idle_spans SET end_ts = ? WHERE end_ts IS NULL", arguments: [at])
        }
    }

    public static func mark(_ conn: Database, observationIds: [Int64], batchId: Int64) throws {
        guard !observationIds.isEmpty else { return }
        let list = observationIds.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE observations SET batch_id = ? WHERE id IN (\(list))", arguments: [batchId])
    }

    /// 행의 업무 판단을 기록한다 (LLM 판단의 원본). 세션·그래프는 여기서 다시 만들 수 있다
    public static func assign(_ conn: Database, observationIds: [Int64], taskId: Int64?, relevant: Bool, offTask: Bool = false, reason: String? = nil) throws {
        guard !observationIds.isEmpty else { return }
        let list = observationIds.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE observations SET task_id = ?, resource_relevant = ?, off_task = ?, task_reason = ? WHERE id IN (\(list))",
                         arguments: [taskId, relevant, offTask, reason])
    }

    /// 집중 이탈 시간: 기간 안의 이탈 행을 앱별로 합친다 (초). 행의 체류는 다음 관측까지의 간격, 최대 maxGap.
    /// 내용 없는 행(빈 탭·로그인·시스템 화면)은 LLM 이 이탈이라 했어도 시간에 넣지 않는다 — 딴짓이 아니라 아무것도 아닌 시간이다
    public func offTaskSeconds(from: Double, to: Double, maxGap: Double = 90) throws -> [(app: String, seconds: Double)] {
        let spans: [(app: String, bundle: String, title: String?, url: String?, dwell: Double)] = try db.writer.read { conn in
            try Row.fetchAll(conn, sql: """
                WITH spans AS (
                  SELECT app_name, app_bundle, window_title, url, off_task, MIN(COALESCE(LEAD(ts) OVER (ORDER BY ts, id), ts) - ts, ?) AS dwell
                  FROM observations WHERE ts >= ? AND ts < ?
                )
                SELECT app_name, app_bundle, window_title, url, dwell FROM spans WHERE off_task = 1
                """, arguments: [maxGap, from, to]).map { ($0["app_name"] as String, $0["app_bundle"] as String, $0["window_title"] as String?, $0["url"] as String?, $0["dwell"] as Double? ?? 0) }
        }
        var seconds: [String: Double] = [:]
        for span in spans {
            guard !Self.contentlessBundles.contains(span.bundle), !TransientPages.isTransient(url: span.url, title: span.title) else { continue }
            let hasContent = !(span.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty || !(span.url ?? "").isEmpty
            guard hasContent else { continue }
            seconds[span.app, default: 0] += span.dwell
        }
        return seconds.sorted { $0.value > $1.value }.map { (app: $0.key, seconds: $0.value) }
    }

    public static let contentlessBundles: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.finder", "com.sillog.app", "excluded"]

    public static func assignChats(_ conn: Database, ids: [Int64], taskId: Int64?) throws {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE chat_messages SET task_id = ? WHERE id IN (\(list))", arguments: [taskId])
    }

    /// 판단이 기록된 행 전부 (시간순). 그래프를 LLM 없이 다시 만들 때 쓴다
    public func assignedObservations() throws -> [Observation] {
        try db.writer.read { conn in
            try Observation.fetchAll(conn, sql: "SELECT * FROM observations WHERE batch_id IS NOT NULL ORDER BY ts, id")
        }
    }

    public func assignedChatMessages() throws -> [ChatMessage] {
        try db.writer.read { conn in
            try ChatMessage.fetchAll(conn, sql: "SELECT * FROM chat_messages WHERE batch_id IS NOT NULL ORDER BY ts, id")
        }
    }

    // MARK: AI 대화 기록

    /// 같은 (도구, 세션, 시각) 메시지는 한 번만 저장한다. 새로 들어간 개수를 돌려준다.
    /// 읽기 위치도 전달되면 메시지와 같은 트랜잭션에서 갱신한다.
    @discardableResult
    public func insertChatMessages(_ messages: [ChatMessage], cursors: [String: Int64] = [:]) throws -> Int {
        guard !messages.isEmpty || !cursors.isEmpty else { return 0 }
        return try db.writer.write { conn in
            var inserted = 0
            for message in messages {
                try conn.execute(sql: """
                    INSERT OR IGNORE INTO chat_messages(ts, tool, session_id, cwd, text, ingested_at) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [message.ts, message.tool, message.sessionId, message.cwd, message.text, message.ingestedAt])
                inserted += conn.changesCount
            }
            for (path, offset) in cursors {
                try conn.execute(sql: "INSERT INTO chat_cursors(path, offset) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET offset = excluded.offset",
                                 arguments: [path, offset])
            }
            return inserted
        }
    }

    public func chatMessages(from: Double, to: Double) throws -> [ChatMessage] {
        try db.writer.read { conn in
            try ChatMessage.fetchAll(conn, sql: "SELECT * FROM chat_messages WHERE ts >= ? AND ts <= ? ORDER BY ts", arguments: [from, to])
        }
    }

    /// 아직 어느 배치에도 쓰이지 않은 메시지 중 `upTo` 이전 것. 창보다 오래된 메시지도 포함해서 빠지는 게 없게 한다.
    public func unprocessedChatMessages(upTo: Double, notOlderThan: Double) throws -> [ChatMessage] {
        try db.writer.read { conn in
            try ChatMessage.fetchAll(conn, sql: "SELECT * FROM chat_messages WHERE batch_id IS NULL AND ts <= ? AND ts >= ? ORDER BY ts",
                                     arguments: [upTo, notOlderThan])
        }
    }

    public static func markChats(_ conn: Database, ids: [Int64], batchId: Int64) throws {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE chat_messages SET batch_id = ? WHERE id IN (\(list))", arguments: [batchId])
    }

    public func chatMessage(id: Int64) throws -> ChatMessage? {
        try db.writer.read { conn in try ChatMessage.fetchOne(conn, key: id) }
    }

    public func chatCursor(path: String) throws -> Int64? {
        try db.writer.read { conn in try Int64.fetchOne(conn, sql: "SELECT offset FROM chat_cursors WHERE path = ?", arguments: [path]) }
    }

    public func setChatCursor(path: String, offset: Int64) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO chat_cursors(path, offset) VALUES (?, ?) ON CONFLICT(path) DO UPDATE SET offset = excluded.offset",
                             arguments: [path, offset])
        }
    }

    // MARK: 읽기

    public func unprocessed(limit: Int) throws -> [Observation] {
        try db.writer.read { conn in
            try Observation.fetchAll(conn, sql: "SELECT * FROM observations WHERE batch_id IS NULL ORDER BY ts ASC, id ASC LIMIT ?", arguments: [limit])
        }
    }

    public func oldestUnprocessedTs() throws -> Double? {
        try db.writer.read { conn in try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations WHERE batch_id IS NULL") }
    }

    /// 이 관측 바로 다음 관측의 시각 (처리 여부와 무관)
    public func nextObservationTs(after observation: Observation) throws -> Double? {
        try db.writer.read { conn in
            try Double.fetchOne(conn, sql: "SELECT ts FROM observations WHERE ts > ? OR (ts = ? AND id > ?) ORDER BY ts, id LIMIT 1",
                                arguments: [observation.ts, observation.ts, observation.id ?? 0])
        }
    }

    /// 다시 판정하기: 배치들의 행을 미처리로 되돌리고 배치 기록은 replaced 로 둔다. 화면 카드 연결은 남긴다
    public func reopenBatches(_ ids: [Int64]) throws -> (rows: Int, lastTs: Double?) {
        guard !ids.isEmpty else { return (0, nil) }
        return try db.writer.write { conn in
            let list = ids.map(String.init).joined(separator: ",")
            let lastTs = try Double.fetchOne(conn, sql: "SELECT MAX(ts) FROM observations WHERE batch_id IN (\(list))")
            try conn.execute(sql: "UPDATE observations SET batch_id = NULL, task_id = NULL, resource_relevant = 1, off_task = 0, task_reason = NULL WHERE batch_id IN (\(list))")
            let rows = conn.changesCount
            try conn.execute(sql: "UPDATE chat_messages SET batch_id = NULL, task_id = NULL WHERE batch_id IN (\(list))")
            try conn.execute(sql: "UPDATE recordings SET batch_id = NULL, task_id = NULL WHERE batch_id IN (\(list))")
            try conn.execute(sql: "UPDATE batches SET status = 'replaced' WHERE id IN (\(list))")
            return (rows, lastTs)
        }
    }

    public func texts(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let list = Set(ids).map(String.init).joined(separator: ",")
        return try db.writer.read { conn in
            var result: [Int64: String] = [:]
            for row in try Row.fetchAll(conn, sql: "SELECT id, text FROM text_snapshots WHERE id IN (\(list))") {
                result[row["id"]] = row["text"]
            }
            return result
        }
    }

    /// [from, to] 구간과 겹치는 유휴 구간.
    public func idleSpans(from: Double, to: Double) throws -> [IdleSpan] {
        try db.writer.read { conn in try Self.idleSpans(conn, from: from, to: to) }
    }

    /// 이미 열린 연결 안에서 (트랜잭션 중에) 쓰는 판
    public static func idleSpans(_ conn: Database, from: Double, to: Double) throws -> [IdleSpan] {
        try IdleSpan.fetchAll(conn, sql: """
            SELECT * FROM idle_spans WHERE start_ts <= ? AND COALESCE(end_ts, ?) >= ? ORDER BY start_ts
            """, arguments: [to, to, from])
    }

    public func recent(limit: Int) throws -> [Observation] {
        try db.writer.read { conn in
            try Observation.fetchAll(conn, sql: "SELECT * FROM observations ORDER BY ts DESC, id DESC LIMIT ?", arguments: [limit])
        }
    }

    /// 배치 열 전부. 시스템 프롬프트는 해시로 가리키는 원문을 채운다
    static let batchSelect = """
        SELECT b.id, b.started_at, b.finished_at, b.from_obs, b.to_obs, b.row_count, b.status, b.model, b.prompt_tokens, b.completion_tokens,
               b.error, b.raw_response, b.stats, COALESCE(b.system_prompt, p.text) AS system_prompt, b.user_prompt, b.llm_patch,
               b.applied_patch, b.system_prompt_hash
        FROM batches b LEFT JOIN prompt_blobs p ON p.hash = b.system_prompt_hash
        """

    public func recentBatches(limit: Int) throws -> [BatchRecord] {
        try db.writer.read { conn in
            try BatchRecord.fetchAll(conn, sql: "\(Self.batchSelect) ORDER BY b.id DESC LIMIT ?", arguments: [limit])
        }
    }

    /// 이미 지워진 날짜 폴더를 가리키는 경로를 비운다 (예전 정리에서 남은 끊긴 경로). 비운 폴더 수를 돌려준다
    @discardableResult
    public func clearMissingScreenshotFolders(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) throws -> Int {
        let paths: [String] = try db.writer.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT DISTINCT screenshot_path FROM observations WHERE screenshot_path IS NOT NULL
                UNION SELECT DISTINCT screenshot_path FROM screen_cards WHERE screenshot_path IS NOT NULL
                """)
        }
        let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        var cleared = 0
        for folder in folders where !folder.isEmpty && !fileExists(folder) {
            try clearScreenshotPaths(under: folder)
            cleared += 1
        }
        return cleared
    }

    /// 스크린샷 폴더를 지운 뒤 그 폴더를 가리키던 경로를 비운다 (없는 파일을 가리키지 않게)
    @discardableResult
    public func clearScreenshotPaths(under folder: String) throws -> Int {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return try db.writer.write { conn in
            try conn.execute(sql: "UPDATE observations SET screenshot_path = NULL WHERE substr(screenshot_path, 1, ?) = ?", arguments: [prefix.count, prefix])
            var cleared = conn.changesCount
            try conn.execute(sql: "UPDATE screen_cards SET screenshot_path = NULL WHERE substr(screenshot_path, 1, ?) = ?", arguments: [prefix.count, prefix])
            cleared += conn.changesCount
            return cleared
        }
    }

    /// 목록 화면용: 프롬프트·응답 같은 큰 열은 빼고 읽는다 (배치당 수십 KB 라 주기적으로 읽으면 부담).
    public func recentBatchSummaries(limit: Int) throws -> [BatchRecord] {
        try db.writer.read { conn in
            try BatchRecord.fetchAll(conn, sql: """
                SELECT id, started_at, finished_at, from_obs, to_obs, row_count, status, model, prompt_tokens, completion_tokens, error,
                       NULL AS raw_response, stats, NULL AS system_prompt, NULL AS user_prompt, NULL AS llm_patch, NULL AS applied_patch
                FROM batches ORDER BY id DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    public func batch(id: Int64) throws -> BatchRecord? {
        try db.writer.read { conn in try BatchRecord.fetchOne(conn, sql: "\(Self.batchSelect) WHERE b.id = ?", arguments: [id]) }
    }

    public func counts(since: Double) throws -> (total: Int, unprocessed: Int) {
        try db.writer.read { conn in
            let total = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts >= ?", arguments: [since]) ?? 0
            let pending = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE batch_id IS NULL") ?? 0
            return (total, pending)
        }
    }
}
