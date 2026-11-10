import Foundation
import GRDB

/// 파일 정리 제안 한 건. status: pending → moved | rejected | ignored | undone
public struct FileSuggestion: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "file_suggestions"
    public var id: Int64?
    public var ts: Double
    public var path: String
    public var fileName: String
    public var originUrl: String?
    public var suggestedFolder: String
    public var confidence: Double
    public var reason: String?
    /// rule(학습된 규칙) | llm
    public var source: String
    public var status: String
    public var movedTo: String?
    public var decidedAt: Double?
    public var context: String?

    public init(id: Int64? = nil, ts: Double, path: String, fileName: String, originUrl: String?, suggestedFolder: String, confidence: Double,
                reason: String?, source: String, status: String = "pending", movedTo: String? = nil, decidedAt: Double? = nil, context: String? = nil) {
        self.id = id; self.ts = ts; self.path = path; self.fileName = fileName; self.originUrl = originUrl; self.suggestedFolder = suggestedFolder
        self.confidence = confidence; self.reason = reason; self.source = source; self.status = status; self.movedTo = movedTo
        self.decidedAt = decidedAt; self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, path
        case fileName = "file_name", originUrl = "origin_url", suggestedFolder = "suggested_folder"
        case confidence, reason, source, status
        case movedTo = "moved_to", decidedAt = "decided_at", context
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct FileSuggestionStore: Sendable {
    let db: WGDatabase
    public init(_ db: WGDatabase) { self.db = db }

    @discardableResult
    public func insert(_ suggestion: FileSuggestion) throws -> FileSuggestion {
        try db.writer.write { conn in var copy = suggestion; try copy.insert(conn); return copy }
    }

    public func suggestion(id: Int64) throws -> FileSuggestion? {
        try db.writer.read { try FileSuggestion.fetchOne($0, key: id) }
    }

    public func pending() throws -> [FileSuggestion] {
        try db.writer.read { try FileSuggestion.fetchAll($0, sql: "SELECT * FROM file_suggestions WHERE status = 'pending' ORDER BY ts DESC") }
    }

    public func recent(limit: Int) throws -> [FileSuggestion] {
        try db.writer.read { try FileSuggestion.fetchAll($0, sql: "SELECT * FROM file_suggestions ORDER BY ts DESC LIMIT ?", arguments: [limit]) }
    }

    /// 결정한 제안(파일 > 지난 기록) 한 쪽: 최근 것부터
    public func decided(limit: Int, offset: Int) throws -> [FileSuggestion] {
        try db.writer.read {
            try FileSuggestion.fetchAll($0, sql: "SELECT * FROM file_suggestions WHERE status != 'pending' ORDER BY ts DESC, id DESC LIMIT ? OFFSET ?",
                                        arguments: [limit, offset])
        }
    }

    public func decidedCount() throws -> Int {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_suggestions WHERE status != 'pending'") ?? 0 }
    }

    public func update(_ suggestion: FileSuggestion) throws {
        try db.writer.write { try suggestion.update($0) }
    }

    /// 이미 제안한 파일인지 (같은 경로가 pending 이면 다시 제안하지 않는다)
    public func hasPending(path: String) throws -> Bool {
        try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_suggestions WHERE path = ? AND status = 'pending'", arguments: [path]) ?? 0 } > 0
    }

    /// 방금 되돌린 파일은 다시 제안하지 않는다 (되돌리기 → 다운로드 폴더에 다시 나타남 → 같은 제안, 을 막는다)
    public func recentlyUndone(path: String, since: Double) throws -> Bool {
        try db.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_suggestions WHERE path = ? AND status = 'undone' AND decided_at >= ?", arguments: [path, since]) ?? 0
        } > 0
    }

    /// 대기 중인데 파일이 이미 사라진 것(사용자가 직접 옮기거나 지움)은 'gone' 으로 닫는다. 닫은 id 를 돌려준다.
    public func closeGone(now: Double, fileExists: (String) -> Bool) throws -> [Int64] {
        var closed: [Int64] = []
        for suggestion in try pending() where !fileExists(suggestion.path) {
            var copy = suggestion
            copy.status = "gone"; copy.decidedAt = now
            try update(copy)
            if let id = copy.id { closed.append(id) }
        }
        return closed
    }

    // MARK: 학습

    public func learnedFolder(key: String) throws -> String? {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT folder FROM folder_prefs WHERE key = ?", arguments: [key]) }
    }

    public func learn(key: String, folder: String, now: Double) throws {
        try db.writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO folder_prefs(key, folder, count, updated_at) VALUES (?, ?, 1, ?)
                ON CONFLICT(key) DO UPDATE SET folder = excluded.folder,
                  count = CASE WHEN folder_prefs.folder = excluded.folder THEN folder_prefs.count + 1 ELSE 1 END,
                  updated_at = excluded.updated_at
                """, arguments: [key, folder, now])
        }
    }

    public func forget(key: String) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM folder_prefs WHERE key = ?", arguments: [key]) }
    }
}
