import Foundation
import GRDB

public struct ChatLibraryItem: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var filename: String
    public var kind: String
    public var createdAt = Date().timeIntervalSince1970
    public var updatedAt: Double?
    public var extractionNote = ""
    public var originID: String?
    public init(title: String, filename: String, kind: String) {
        self.title = title; self.filename = filename; self.kind = kind
    }
}

/// 파일은 DB 옆의 보관함에 복사한다. 프로젝트·대화 연결을 지워도 보관함 원본은 유지한다.
public struct LibraryStore: Sendable {
    let db: SillogDatabase
    public let directory: URL
    public init(_ db: SillogDatabase, directory: URL? = nil) {
        self.db = db
        self.directory = directory ?? db.libraryDirectory
    }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13-project-library") { conn in
            try conn.execute(sql: """
                CREATE TABLE app_library (id TEXT PRIMARY KEY, created_at REAL NOT NULL, origin_id TEXT UNIQUE, payload TEXT NOT NULL, text TEXT NOT NULL);
                CREATE TABLE library_deleted_origins (origin_id TEXT PRIMARY KEY);
                CREATE TABLE library_project_sources (
                  project_id TEXT NOT NULL REFERENCES app_projects(id) ON DELETE CASCADE,
                  item_id TEXT NOT NULL REFERENCES app_library(id) ON DELETE CASCADE,
                  PRIMARY KEY (project_id, item_id)
                );
                CREATE TABLE library_conversation_sources (
                  conversation_id TEXT NOT NULL REFERENCES app_conversations(id) ON DELETE CASCADE,
                  item_id TEXT NOT NULL REFERENCES app_library(id) ON DELETE CASCADE,
                  PRIMARY KEY (conversation_id, item_id)
                );
                """)
        }
    }

    /// Args: 없음.
    /// Returns: 최신순 보관 자료 목록.
    /// Raises: DB·디코딩 오류.
    public func items() throws -> [ChatLibraryItem] {
        try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT payload FROM app_library ORDER BY created_at DESC, rowid DESC")
                .map { try JSONDecoder().decode(ChatLibraryItem.self, from: Data($0.utf8)) }
        }
    }

    /// Args: item은 보관 자료 메타데이터이다.
    /// Returns: 앱이 관리하는 파일 복사본의 위치.
    /// Raises: 없음.
    public func url(for item: ChatLibraryItem) -> URL {
        directory.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent(item.filename)
    }

    /// Args: id is the library item.
    /// Returns: its indexed text, or "" if it is gone.
    /// Raises: DB errors.
    public func text(for id: String) throws -> String {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT text FROM app_library WHERE id = ?", arguments: [id]) } ?? ""
    }

    public func modifiedAt(for item: ChatLibraryItem) -> Double {
        let fileDate = (try? url(for: item).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
        if let updatedAt = item.updatedAt { return max(updatedAt, fileDate ?? updatedAt) }
        return fileDate ?? item.createdAt
    }

    public func rename(_ id: String, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try db.writer.write { conn in
            guard let payload = try String.fetchOne(conn, sql: "SELECT payload FROM app_library WHERE id = ?", arguments: [id]) else { return }
            var item = try JSONDecoder().decode(ChatLibraryItem.self, from: Data(payload.utf8))
            guard item.title != name else { return }
            item.title = name
            item.updatedAt = Date().timeIntervalSince1970
            let json = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
            try conn.execute(sql: "UPDATE app_library SET payload = ? WHERE id = ?", arguments: [json, id])
        }
    }

    /// Args: source는 사용자가 선택한 원본 파일이다.
    /// Returns: 복사본과 검색용 본문이 저장된 자료.
    /// Raises: 크기·인증 경로·파일 복사·DB 오류. 추출 실패는 원본과 안내를 보관한다.
    @discardableResult public func importFile(_ source: URL) throws -> ChatLibraryItem {
        let source = source.resolvingSymlinksInPath()
        guard !source.pathComponents.contains(where: ChatTools.isPrivate) else { throw ChatToolError.unavailable("인증 정보가 포함된 파일은 보관함에 추가할 수 없습니다.") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 50_000_000 else {
            throw ChatToolError.unavailable("50MB 이하의 파일을 선택하세요. 폴더는 원본 연결로 추가할 수 있습니다.")
        }
        let item = ChatLibraryItem(title: source.lastPathComponent, filename: source.lastPathComponent, kind: "upload")
        return try write(item, data: Data(contentsOf: source), modifiedAt: values.contentModificationDate) { url in
            do { return try FileTextExtractor.read(url) }
            catch { return ("", "원본은 보관했습니다. 본문 추출 실패: \(error.localizedDescription)") }
        }
    }

    /// Args: artifact is a result created in chat.
    /// Returns: the library item, reused if this artifact was saved before.
    /// Raises: file, DB, or Office packaging errors.
    @discardableResult public func saveArtifact(_ artifact: ChatArtifact) throws -> ChatLibraryItem {
        if let existing = try find(originID: artifact.id) { return existing }
        let ext = artifact.fileExtension
        let name = artifact.title.components(separatedBy: CharacterSet(charactersIn: "/:\n\\")).joined(separator: "-")
        var item = ChatLibraryItem(title: artifact.title, filename: "\(name.isEmpty ? "result" : String(name.prefix(120))).\(ext)", kind: "generated")
        item.originID = artifact.id
        return try write(item, data: try artifact.fileData()) { _ in (artifact.content, "") }
    }

    /// Args: message는 완료된 답변, title은 사용자가 지정한 자료 이름이다.
    /// Returns: 재사용할 답변의 보관 자료.
    /// Raises: 미완료 답변·파일·DB 오류.
    @discardableResult public func saveResponse(_ message: ConversationMessage, title: String) throws -> ChatLibraryItem {
        guard message.status == "complete", message.role == "assistant", !message.text.isEmpty else {
            throw ChatToolError.unavailable("완료된 답변만 자료로 저장할 수 있습니다.")
        }
        let origin = "message:\(message.id)"
        if let existing = try find(originID: origin) { return existing }
        var item = ChatLibraryItem(title: title, filename: "note.md", kind: "note"); item.originID = origin
        return try write(item, data: Data(message.text.utf8)) { _ in (message.text, "") }
    }

    private func find(originID: String) throws -> ChatLibraryItem? {
        try db.writer.read { conn in
            try String.fetchOne(conn, sql: "SELECT payload FROM app_library WHERE origin_id = ?", arguments: [originID])
                .map { try JSONDecoder().decode(ChatLibraryItem.self, from: Data($0.utf8)) }
        }
    }

    private func write(_ value: ChatLibraryItem, data: Data, modifiedAt: Date? = nil, extract: (URL) throws -> (String, String)) throws -> ChatLibraryItem {
        var item = value
        let file = url(for: item), folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try data.write(to: file, options: .atomic)
            if let modifiedAt { try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path) }
            let (text, note) = try extract(file); item.extractionNote = note
            let payload = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
            try db.writer.write { conn in
                try conn.execute(sql: "INSERT INTO app_library VALUES (?, ?, ?, ?, ?)", arguments: [item.id, item.createdAt, item.originID, payload, text])
                if let origin = item.originID { try conn.execute(sql: "DELETE FROM library_deleted_origins WHERE origin_id = ?", arguments: [origin]) }
            }
            return item
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    /// Args: itemID는 보관 자료, projectID는 사용자가 공유할 프로젝트이다.
    /// Returns: 없음. 프로젝트의 모든 대화에서 자료를 사용할 수 있게 한다.
    /// Raises: 존재하지 않는 ID·DB 오류.
    public func attach(_ itemID: String, projectID: String) throws {
        try db.writer.write { try $0.execute(sql: "INSERT OR IGNORE INTO library_project_sources VALUES (?, ?)", arguments: [projectID, itemID]) }
    }
    /// Args: itemID는 보관 자료, conversationID는 사용할 대화이다.
    /// Returns: 없음. 해당 대화에서만 자료를 연결한다.
    /// Raises: 존재하지 않는 ID·DB 오류.
    public func attach(_ itemID: String, conversationID: String) throws {
        try db.writer.write { try $0.execute(sql: "INSERT OR IGNORE INTO library_conversation_sources VALUES (?, ?)", arguments: [conversationID, itemID]) }
    }
    /// Args: itemID·projectID는 해제할 연결이다.
    /// Returns: 없음. 보관함 원본은 유지한다.
    /// Raises: DB 오류.
    public func detach(_ itemID: String, projectID: String) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM library_project_sources WHERE project_id = ? AND item_id = ?", arguments: [projectID, itemID]) }
    }
    /// Args: itemID·conversationID는 해제할 연결이다.
    /// Returns: 없음. 보관함 원본은 유지한다.
    /// Raises: DB 오류.
    public func detach(_ itemID: String, conversationID: String) throws {
        try db.writer.write { try $0.execute(sql: "DELETE FROM library_conversation_sources WHERE conversation_id = ? AND item_id = ?", arguments: [conversationID, itemID]) }
    }
    /// Args: 없음.
    /// Returns: 대화에 연결된 자료 ID -> 그 대화 범위의 초점 목록(처음 초점이 있는 대화 것). 초점이 없으면 키가 없다. 쿼리 한 번.
    /// Raises: DB 오류.
    public func itemFocuses() throws -> [String: [ChatFocus]] {
        struct Payload: Decodable { struct Scope: Decodable { var focuses: [ChatFocus]? }; var scope: Scope? }
        return try db.writer.read { conn in
            var found: [String: [ChatFocus]] = [:]
            for row in try Row.fetchAll(conn, sql: """
                SELECT s.item_id, c.payload FROM library_conversation_sources s
                JOIN app_conversations c ON c.id = s.conversation_id ORDER BY c.updated_at DESC
                """) {
                let payload: String = row["payload"], item: String = row["item_id"]
                guard found[item] == nil, let focuses = (try? JSONDecoder().decode(Payload.self, from: Data(payload.utf8)))?.scope?.focuses,
                      !focuses.isEmpty else { continue }
                found[item] = focuses
            }
            return found
        }
    }
    /// Args: itemID는 보관 자료이다.
    /// Returns: 자료가 공유된 프로젝트 ID.
    /// Raises: DB 오류.
    public func projectIDs(for itemID: String) throws -> [String] {
        try db.writer.read { try String.fetchAll($0, sql: "SELECT project_id FROM library_project_sources WHERE item_id = ?", arguments: [itemID]) }
    }
    /// Args: conversationID·projectID는 현재 대화와 프로젝트이다.
    /// Returns: 명시적으로 연결한 자료 ID, 중복 없이 반환한다.
    /// Raises: DB 오류.
    public func sourceIDs(conversationID: String? = nil, projectID: String? = nil) throws -> [String] {
        try db.writer.read { try Self.sourceIDs(conversationID: conversationID, projectID: projectID, $0) }
    }
    static func sourceIDs(conversationID: String?, projectID: String?, _ conn: Database) throws -> [String] {
        try String.fetchAll(conn, sql: """
            SELECT item_id FROM library_conversation_sources WHERE conversation_id = ?
            UNION SELECT item_id FROM library_project_sources WHERE project_id = ?
            """, arguments: [conversationID, projectID])
    }

    /// Args: item은 사용자가 삭제를 확인한 보관 자료이다.
    /// Returns: 없음. 모든 연결도 해제하고 자동 결과물 재수집을 막는다.
    /// Raises: 파일 삭제·DB 오류. 업로드 원본은 수정하지 않는다.
    public func delete(_ item: ChatLibraryItem) throws {
        // 파일 삭제에 실패하면 DB와 연결을 남겨 재시도할 수 있다.
        let folder = url(for: item).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try db.writer.write { conn in
            if let origin = item.originID { try conn.execute(sql: "INSERT OR IGNORE INTO library_deleted_origins VALUES (?)", arguments: [origin]) }
            try conn.execute(sql: "DELETE FROM app_library WHERE id = ?", arguments: [item.id])
        }
    }

    /// 기존·새 결과물을 중복 없이 보관하고, 원래 대화에서 사용할 수 있도록 연결한다.
    public func collectArtifacts(_ messages: [ConversationMessage]) throws {
        for message in messages where message.role == "assistant" && message.status == "complete" {
            for artifact in message.artifacts {
                let deleted = try db.writer.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM library_deleted_origins WHERE origin_id = ?)", arguments: [artifact.id]) == true }
                if deleted { continue }
                let item = try saveArtifact(artifact)
                try attach(item.id, conversationID: message.conversationID)
            }
        }
    }

    /// Args: query는 검색어, ids는 허용된 자료 ID, notesOnly는 저장 답변만 검색하는 옵션이다.
    /// Returns: 일치 구간을 포함하는 최대 8개의 출처.
    /// Raises: DB·디코딩 오류.
    public func search(_ query: String, ids: [String], notesOnly: Bool = false) throws -> [ChatSource] {
        guard !ids.isEmpty else { return [] }
        return try db.writer.read { conn in
            let terms = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).prefix(24)
            let clauses = terms.map { _ in "instr(lower(text || ' ' || json_extract(payload, '$.title')), lower(?)) > 0" }
            let match = clauses.isEmpty ? "1" : clauses.joined(separator: " OR ")
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let arguments = StatementArguments(ids + Array(terms))
            return try Row.fetchAll(conn, sql: "SELECT id, payload, text FROM app_library WHERE id IN (\(placeholders)) AND (\(match)) \(notesOnly ? "AND json_extract(payload, '$.kind') = 'note'" : "") ORDER BY created_at DESC LIMIT 8", arguments: arguments).map { row in
                let item = try JSONDecoder().decode(ChatLibraryItem.self, from: Data((row["payload"] as String).utf8))
                let text: String = row["text"]
                let range = terms.compactMap { text.range(of: $0, options: .caseInsensitive) }.first
                let start = range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
                return .init(id: "library:\(item.id)", title: item.title, location: url(for: item).path,
                             excerpt: String(text.dropFirst(max(0, start - 200)).prefix(1600)))
            }
        }
    }

    /// Args: itemID는 자료 ID, ids는 허용 범위, start는 1부터 시작하는 문자 위치이다.
    /// Returns: 최대 18,000자 원문과 다음 시작 위치.
    /// Raises: 연결 범위·삭제된 자료·DB 오류.
    public func read(_ itemID: String, ids: [String], start: Int = 1) throws -> ChatSource {
        let pieces = itemID.split(separator: ":", omittingEmptySubsequences: false)
        let id = itemID.hasPrefix("library:") && pieces.count >= 2 ? String(pieces[1]) : itemID
        guard ids.contains(id) else { throw ChatToolError.unavailable("이 대화에 연결되지 않은 자료입니다.") }
        return try db.writer.read { conn in
            guard let row = try Row.fetchOne(conn, sql: "SELECT payload, text FROM app_library WHERE id = ?", arguments: [id]) else { throw ChatToolError.unavailable("자료가 삭제되었습니다.") }
            let item = try JSONDecoder().decode(ChatLibraryItem.self, from: Data((row["payload"] as String).utf8))
            let text: String = row["text"], offset = max(1, start)
            let page = String(text.dropFirst(offset - 1).prefix(18000))
            return .init(id: "library:\(id):\(offset)", title: item.title, location: url(for: item).path,
                         excerpt: page + "\n\n[전체 \(text.count)자 · \(offset)부터 · 다음 시작 위치 \(offset + page.count)]\n\(item.extractionNote)")
        }
    }
}
