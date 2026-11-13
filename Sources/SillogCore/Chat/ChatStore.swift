import Foundation
import GRDB

/// A Google Drive file the user picked for one chat.
public struct ChatDriveFile: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var url: String

    public init(id: String, name: String, mimeType: String, url: String) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.url = url
    }
}

public struct ChatScope: Codable, Equatable, Sendable {
    public var projectID: String?
    public var conversationID: String?
    public var paths: [String] = []
    public var libraryIDs: [String] = []
    public var useActivity = true
    public var useWeb = false
    public var useGitHub = false
    public var connectors: [String] = []
    /// 활동 기록을 고른 업무·분야로 좁힌다 (여럿이면 합친 범위). 비어 있으면 모든 기록
    public var focus: [ChatFocus] = []
    public var driveFiles: [ChatDriveFile] = []
    // 기존 대화와 예약 작업의 자료 선택을 유지하기 위한 저장 키.
    private enum CodingKeys: String, CodingKey { case paths, libraryIDs, useActivity, useWeb, useGitHub, connectors = "plugins", projectID, focus = "focuses", driveFiles }
    /// 하나만 고르던 때 저장한 대화: "focus" 에 항목 하나
    private enum LegacyKeys: String, CodingKey { case focus }

    /// Args: 없음.
    /// Returns: 활동 기록만 사용하는 기본 범위.
    /// Raises: 없음.
    public init() {}

    /// Args: decoder는 저장된 대화의 자료 설정이다.
    /// Returns: 기존 웹·GitHub 통합 설정을 유지하는 자료 범위.
    /// Raises: 저장된 값의 디코딩 오류.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        paths = try values.decodeIfPresent([String].self, forKey: .paths) ?? []
        libraryIDs = try values.decodeIfPresent([String].self, forKey: .libraryIDs) ?? []
        useActivity = try values.decodeIfPresent(Bool.self, forKey: .useActivity) ?? true
        useWeb = try values.decodeIfPresent(Bool.self, forKey: .useWeb) ?? false
        useGitHub = try values.decodeIfPresent(Bool.self, forKey: .useGitHub) ?? useWeb
        connectors = try values.decodeIfPresent([String].self, forKey: .connectors) ?? []
        driveFiles = try values.decodeIfPresent([ChatDriveFile].self, forKey: .driveFiles) ?? []
        if let saved = try values.decodeIfPresent([ChatFocus].self, forKey: .focus) {
            focus = saved
        } else if let single = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(ChatFocus.self, forKey: .focus) {
            focus = [single]
        }
    }

    /// Args: files are Drive files just picked for this chat.
    /// Returns: nothing. Adds new files and turns the Drive connector on so the tools can read them.
    /// Raises: none.
    public mutating func addDriveFiles(_ files: [ChatDriveFile]) {
        for file in files where !driveFiles.contains(where: { $0.id == file.id }) { driveFiles.append(file) }
        if !driveFiles.isEmpty && !connectors.contains("drive") { connectors.append("drive") }
    }
}

public struct ChatSource: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var location: String
    public var excerpt: String
    public init(id: String, title: String, location: String, excerpt: String) {
        self.id = id; self.title = title; self.location = location; self.excerpt = excerpt
    }
    /// The task node's key when this source is a task; ContextSearch titles nodes "<label> · <title>" and puts the key in location.
    public var taskKey: String? {
        id.hasPrefix("node:") && title.hasPrefix("\(NodeLabel.task) · ") && !location.isEmpty ? location : nil
    }
}

public struct ChatArtifact: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var format: String
    public var content: String
    /// First version's id; a root instead of a parent so dropping a middle version keeps the series together.
    public var baseID: String?
    public var seriesID: String { baseID ?? id }
    public init(title: String, format: String, content: String) {
        self.title = title; self.format = format; self.content = content
    }

    /// Args: artifact is any version, messages the conversation in order.
    /// Returns: every version of the artifact's series, oldest first, including earlier answer versions.
    /// Raises: none.
    public static func versions(of artifact: ChatArtifact, in messages: [ConversationMessage]) -> [ChatArtifact] {
        messages.flatMap { $0.versions.flatMap(\.artifacts) }.filter { $0.seriesID == artifact.seriesID }
    }

    /// Args: artifacts are one answer's results in order.
    /// Returns: the last version of each series, in the order each series first appears.
    /// Raises: none.
    public static func latestPerSeries(_ artifacts: [ChatArtifact]) -> [ChatArtifact] {
        let last = Dictionary(artifacts.map { ($0.seriesID, $0) }, uniquingKeysWith: { $1 })
        var seen = Set<String>()
        return artifacts.compactMap { seen.insert($0.seriesID).inserted ? last[$0.seriesID] : nil }
    }

    /// Args: artifact is the version the user edited, content its new text, messages the conversation in order.
    /// Returns: the answer holding the series' latest version with the edit appended after it, and the edit. Nil when the series isn't in messages.
    /// Raises: none.
    public static func edit(_ artifact: ChatArtifact, content: String, in messages: [ConversationMessage]) -> (message: ConversationMessage, version: ChatArtifact)? {
        guard let last = versions(of: artifact, in: messages).last,
              var message = messages.first(where: { $0.versions.contains { $0.artifacts.contains { $0.id == last.id } } }) else { return nil }
        var version = ChatArtifact(title: artifact.title, format: artifact.format, content: content)
        version.baseID = artifact.seriesID
        // Appending to the answer version holding the latest keeps the edit last in the series order.
        if message.artifacts.contains(where: { $0.id == last.id }) { message.artifacts.append(version) }
        else if let index = message.previous?.firstIndex(where: { $0.artifacts.contains { $0.id == last.id } }) { message.previous?[index].artifacts.append(version) }
        return (message, version)
    }

    /// Args: text is a passage the user selected in a result.
    /// Returns: the passage as a Markdown quote followed by an empty line, ready for a question after it.
    /// Raises: none.
    public static func quote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n") + "\n\n"
    }
}

/// One tool call or agent step of an answer, shown in the answer's work log.
public struct ChatStep: Codable, Identifiable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed }
    public var id = UUID().uuidString
    public var title: String
    public var detail = ""
    public var result = ""
    public var status = Status.running
    public var startedAt = Date().timeIntervalSince1970
    public var endedAt: Double?
    public init(title: String, detail: String = "", status: Status = .running) {
        self.title = title; self.detail = detail; self.status = status
        if status != .running { endedAt = startedAt }
    }
}

public struct ChatAutomationProposal: Codable, Equatable, Sendable {
    public var title: String
    public var prompt: String
    public var intervalHours: Int
}

public struct ChatConversation: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    /// Stored untranslated so the auto-title check works in every language.
    public static let defaultTitle = "새 대화"
    public var title = defaultTitle
    /// 비면 스킬 지침을 적용하지 않는다. 예전 저장값 skillID 는 읽을 때 옮긴다.
    public var skillIDs: [String] = []
    public var scope = ChatScope()
    public var projectID: String?
    public var updatedAt = Date().timeIntervalSince1970
    /// nil이면 고정 안 됨. 원본은 app_conversations.pinned_at 칼럼이다.
    public var pinnedAt: Double?
    /// Summary of the messages that no longer fit in what is sent to the model.
    public var memory: ChatMemory?
    /// Args: 없음.
    /// Returns: 고유 ID를 가진 빈 대화.
    /// Raises: 없음.
    public init() {}

    private enum CodingKeys: String, CodingKey { case id, title, skillIDs, skillID, scope, projectID, updatedAt, pinnedAt, memory }

    /// Args: decoder는 저장된 대화이다. skillIDs 가 없으면 예전 skillID 를 옮기고 "general" 은 빈 배열로 둔다.
    public init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        id = try v.decodeIfPresent(String.self, forKey: .id) ?? id
        title = try v.decodeIfPresent(String.self, forKey: .title) ?? title
        if let ids = try v.decodeIfPresent([String].self, forKey: .skillIDs) { skillIDs = ids }
        else if let old = try v.decodeIfPresent(String.self, forKey: .skillID), old != "general" { skillIDs = [old] }
        scope = try v.decodeIfPresent(ChatScope.self, forKey: .scope) ?? scope
        projectID = try v.decodeIfPresent(String.self, forKey: .projectID)
        updatedAt = try v.decodeIfPresent(Double.self, forKey: .updatedAt) ?? updatedAt
        pinnedAt = try v.decodeIfPresent(Double.self, forKey: .pinnedAt)
        memory = try v.decodeIfPresent(ChatMemory.self, forKey: .memory)
    }

    public func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(id, forKey: .id); try v.encode(title, forKey: .title); try v.encode(skillIDs, forKey: .skillIDs)
        try v.encode(scope, forKey: .scope); try v.encodeIfPresent(projectID, forKey: .projectID)
        try v.encode(updatedAt, forKey: .updatedAt); try v.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try v.encodeIfPresent(memory, forKey: .memory)
    }

    /// Args: title is a stored conversation title.
    /// Returns: the title to show, with the untouched default translated.
    public static func display(_ title: String) -> String { title == defaultTitle ? L10n.tr(key: title) : title }
}

/// Running summary of a conversation's older messages; `through` is the last message it covers.
public struct ChatMemory: Codable, Equatable, Sendable {
    public var summary: String
    public var through: String
    public init(summary: String, through: String) { self.summary = summary; self.through = through }
}

public struct ChatSearchHit: Identifiable, Equatable, Sendable {
    public var conversationID: String
    public var title: String
    public var snippet: String
    public var updatedAt: Double
    /// The message the snippet came from; nil when only the title matched.
    public var messageID: String?
    public var id: String { conversationID }

    public init(conversationID: String, title: String, snippet: String, updatedAt: Double, messageID: String? = nil) {
        self.conversationID = conversationID; self.title = title; self.snippet = snippet; self.updatedAt = updatedAt; self.messageID = messageID
    }
}

public struct ConversationMessage: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var conversationID: String
    public var role: String
    public var text: String
    public var status = "complete"
    public var createdAt = Date().timeIntervalSince1970
    public var sources: [ChatSource] = []
    public var artifacts: [ChatArtifact] = []
    public var steps: [String] = []
    /// Tool steps with what they looked at and a preview of what came back. Nil in messages saved before it existed.
    public var trace: [ChatStep]?
    public var automation: ChatAutomationProposal?
    public var approvedAutomationID: String?
    /// The chat model that wrote this answer; nil in messages saved before it existed.
    public var model: String?
    /// The reasoning effort that answer used; nil for an API server and in messages saved before it existed.
    public var effort: String?
    /// When the run ended; nil while running and in messages saved before it existed.
    public var completedAt: Double?
    /// Earlier answers to the same question, oldest first, kept when the answer was regenerated.
    public var previous: [ConversationMessage]?
    /// A suggested next question shown as ghost text in the composer; nil until generated.
    public var followUp: String?
    /// The other paths from this question on, each starting with its own question; nil until the question is edited.
    public var branches: [[ConversationMessage]]?

    /// Args: conversationID는 소속 대화, role·text·status는 메시지 내용과 상태이다.
    /// Returns: 저장 가능한 채팅 메시지.
    /// Raises: 없음.
    public init(conversationID: String, role: String, text: String, status: String = "complete") {
        self.conversationID = conversationID; self.role = role; self.text = text; self.status = status
    }
}

extension ConversationMessage {
    /// Args: message is a question to edit or an answer to regenerate, messages the conversation in order.
    /// Returns: the messages to replace, from that turn's question to the end. Empty if message isn't there.
    /// Raises: 없음.
    public static func replaced(from message: ConversationMessage, in messages: [ConversationMessage]) -> [ConversationMessage] {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return [] }
        let start = message.role == "user" ? index : (messages[..<index].lastIndex(where: { $0.role == "user" }) ?? index)
        return Array(messages[start...])
    }

    /// Earlier answers then this one, oldest first, without nesting so a regenerate never stores copies of copies.
    public var versions: [ConversationMessage] {
        var latest = self; latest.previous = nil
        return (previous ?? []) + [latest]
    }

    /// Args: replaced is the question this new one replaces and every message after it.
    /// Returns: none. An edit keeps the replaced path as a branch, newest 9 kept; resending the same text keeps the branches and the asking time so the branch order holds.
    /// Raises: none.
    public mutating func branch(replacing replaced: [ConversationMessage]) {
        guard let old = replaced.first, old.role == "user" else { return }
        var paths = old.branches ?? []
        if old.text.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
            createdAt = old.createdAt
        } else {
            var path = replaced; path[0].branches = nil
            paths.append(path)
        }
        branches = paths.isEmpty ? nil : Array(paths.suffix(9))
    }

    /// Args: question is a question in messages, the conversation's active path.
    /// Returns: every path from that question on, oldest question first, and the index of the active one. Empty when it isn't a question there.
    /// Raises: none.
    public static func paths(at question: ConversationMessage, in messages: [ConversationMessage]) -> (paths: [[ConversationMessage]], active: Int) {
        guard question.role == "user", let start = messages.firstIndex(where: { $0.id == question.id }) else { return ([], 0) }
        var active = Array(messages[start...])
        let others = active[0].branches ?? []
        active[0].branches = nil
        let all = (others + [active]).filter { !$0.isEmpty }.sorted { $0[0].createdAt < $1[0].createdAt }
        return (all, all.firstIndex { $0[0].id == question.id } ?? 0)
    }

    /// Args: question is a question in messages, index a path of `paths(at:in:)`.
    /// Returns: the conversation with that path from the question on, carrying the others as its branches. Nil when index is out of range.
    /// Raises: none.
    public static func switching(_ question: ConversationMessage, to index: Int, in messages: [ConversationMessage]) -> [ConversationMessage]? {
        let all = paths(at: question, in: messages).paths
        guard all.indices.contains(index), let start = messages.firstIndex(where: { $0.id == question.id }) else { return nil }
        var path = all[index]
        path[0].branches = all.indices.filter { $0 != index }.map { all[$0] }
        return Array(messages[..<start]) + path
    }
}

public struct ChatAutomation: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var prompt: String
    /// 저장 형식 유지: 스킬 여럿은 쉼표로 이어 쓰고, 없으면 "general".
    public var skillID: String
    public var skillIDs: [String] { skillID == "general" ? [] : skillID.split(separator: ",").map(String.init) }
    public var scope: ChatScope
    public var intervalHours: Int
    public var nextRun: Double
    public var enabled = true
    public var lastStatus = "실행 대기"
    public var lastConversationID: String?

    /// Args: proposal은 승인된 예약안, conversation은 권한 범위, now는 등록 시각이다.
    /// Returns: 첫 실행 시각이 지정된 예약.
    /// Raises: 없음.
    public init(proposal: ChatAutomationProposal, conversation: ChatConversation, now: Double = Date().timeIntervalSince1970) {
        title = proposal.title; prompt = proposal.prompt; skillID = conversation.skillIDs.isEmpty ? "general" : conversation.skillIDs.joined(separator: ",")
        scope = conversation.scope; scope.projectID = conversation.projectID; intervalHours = proposal.intervalHours
        nextRun = now + Double(intervalHours) * 3600
    }
}

public struct ChatStore: Sendable {
    let db: SillogDatabase
    /// Args: db는 앱 데이터베이스이다.
    /// Returns: 채팅 전용 저장소.
    /// Raises: 없음.
    public init(_ db: SillogDatabase) { self.db = db }

    /// Args: migrator는 기존 DB 마이그레이션 목록이다.
    /// Returns: 없음. 채팅 테이블과 검색 색인 생성 단계를 등록한다.
    /// Raises: 등록 시 없음. 적용 시 DB 오류를 전달한다.
    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11-context-chat") { db in
            try db.execute(sql: """
                CREATE TABLE app_conversations (id TEXT PRIMARY KEY, updated_at REAL NOT NULL, payload TEXT NOT NULL);
                CREATE TABLE app_messages (
                  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES app_conversations(id) ON DELETE CASCADE,
                  created_at REAL NOT NULL, payload TEXT NOT NULL
                );
                CREATE INDEX idx_app_messages_conversation ON app_messages(conversation_id, created_at);
                CREATE TABLE app_automations (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                """)
            // 기존 원문에도 검색 색인을 추가한다. 원문은 기존 테이블에만 보관한다.
            for (table, columns) in [("nodes", ["title", "key", "props"]), ("text_snapshots", ["text"]), ("chat_messages", ["text", "cwd"])] {
                let fields = columns.joined(separator: ", ")
                let newFields = columns.map { "new.\($0)" }.joined(separator: ", ")
                let oldFields = columns.map { "old.\($0)" }.joined(separator: ", ")
                let index = "\(table)_chat_fts"
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE \(index) USING fts5(\(fields), content='\(table)', content_rowid='id', tokenize='trigram');
                    INSERT INTO \(index)(\(index)) VALUES ('rebuild');
                    CREATE TRIGGER \(index)_ai AFTER INSERT ON \(table) BEGIN
                      INSERT INTO \(index)(rowid, \(fields)) VALUES (new.id, \(newFields));
                    END;
                    CREATE TRIGGER \(index)_ad AFTER DELETE ON \(table) BEGIN
                      INSERT INTO \(index)(\(index), rowid, \(fields)) VALUES ('delete', old.id, \(oldFields));
                    END;
                    CREATE TRIGGER \(index)_au AFTER UPDATE ON \(table) BEGIN
                      INSERT INTO \(index)(\(index), rowid, \(fields)) VALUES ('delete', old.id, \(oldFields));
                      INSERT INTO \(index)(rowid, \(fields)) VALUES (new.id, \(newFields));
                    END;
                    """)
            }
        }
    }

    static func migrateSkills(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19-chat-skills") { conn in
            try conn.execute(sql: "CREATE TABLE app_chat_skills (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        }
        migrator.registerMigration("v20-chat-skill-deletions") { conn in
            try conn.execute(sql: "CREATE TABLE app_deleted_skills (id TEXT PRIMARY KEY)")
        }
        migrator.registerMigration("v21-chat-skill-pins") { conn in
            try conn.execute(sql: "CREATE TABLE app_chat_skill_pins (id TEXT PRIMARY KEY, position INTEGER NOT NULL)")
            for (position, skill) in try ChatSkill.load().prefix(6).enumerated() {
                try conn.execute(sql: "INSERT INTO app_chat_skill_pins VALUES (?, ?)", arguments: [skill.id, position])
            }
        }
    }

    public func pinnedSkillIDs() throws -> [String] {
        let available = Set(try skills().map(\.id))
        return try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT id FROM app_chat_skill_pins ORDER BY position")
                .filter { available.contains($0) }
        }
    }

    public func setPinnedSkills(_ ids: [String]) throws {
        let available = Set(try skills().map(\.id))
        guard ids.count <= 6, Set(ids).count == ids.count, ids.allSatisfy({ available.contains($0) }) else {
            throw ChatToolError.unavailable(tr("목록에 있는 스킬을 최대 6개까지 표시할 수 있어요."))
        }
        try db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM app_chat_skill_pins")
            for (position, id) in ids.enumerated() {
                try conn.execute(sql: "INSERT INTO app_chat_skill_pins VALUES (?, ?)", arguments: [id, position])
            }
        }
    }

    public func skills() throws -> [ChatSkill] {
        let defaults = try ChatSkill.load()
        let defaultIDs = Set(defaults.map(\.id))
        return try db.writer.read { conn in
            let deleted = try Set(String.fetchAll(conn, sql: "SELECT id FROM app_deleted_skills"))
            let saved = try String.fetchAll(conn, sql: "SELECT payload FROM app_chat_skills ORDER BY rowid")
                .map { try JSONDecoder().decode(ChatSkill.self, from: Data($0.utf8)) }
            let byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
            return defaults.filter { !deleted.contains($0.id) }.map { byID[$0.id] ?? $0 }
                + saved.filter { !defaultIDs.contains($0.id) }
        }
    }

    @discardableResult public func addSkill(title: String, instructions: String, summary: String = "") throws -> ChatSkill {
        let skill = ChatSkill(title: title, instructions: instructions, summary: summary)
        return try saveSkill(skill, title: title, instructions: instructions, summary: summary, updating: false)
    }

    @discardableResult public func updateSkill(_ skill: ChatSkill, title: String, instructions: String, summary: String) throws -> ChatSkill {
        try saveSkill(skill, title: title, instructions: instructions, summary: summary, updating: true)
    }

    public func deleteSkill(_ skill: ChatSkill) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM app_chat_skills WHERE id = ?", arguments: [skill.id])
            try conn.execute(sql: "DELETE FROM app_chat_skill_pins WHERE id = ?", arguments: [skill.id])
            if !skill.isCustom {
                try conn.execute(sql: "INSERT OR IGNORE INTO app_deleted_skills VALUES (?)", arguments: [skill.id])
            }
        }
    }

    private func saveSkill(_ skill: ChatSkill, title: String, instructions: String, summary: String, updating: Bool) throws -> ChatSkill {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !body.isEmpty, body.count <= 12_000, description.count <= 200 else {
            throw ChatToolError.unavailable(tr("스킬 이름은 80자, 설명은 200자, 지침은 12,000자까지 입력할 수 있어요."))
        }
        let saved = skill.edited(title: name, instructions: body, summary: description)
        let json = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        try db.writer.write { conn in
            if updating {
                let deleted = try String.fetchOne(conn, sql: "SELECT id FROM app_deleted_skills WHERE id = ?", arguments: [skill.id])
                let existing = try String.fetchOne(conn, sql: "SELECT id FROM app_chat_skills WHERE id = ?", arguments: [skill.id])
                guard deleted == nil, !skill.isCustom || existing != nil else {
                    throw ChatToolError.unavailable(tr("이 스킬이 이미 삭제됐어요."))
                }
            }
            try conn.execute(sql: """
                INSERT INTO app_chat_skills (id, payload) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [saved.id, json])
        }
        return saved
    }

    /// Args: migrator는 v16까지 등록된 마이그레이션 목록이다.
    /// Returns: 없음. 대화 고정 칼럼 단계를 등록한다. GRDB는 등록 순서대로 돌리므로 v16 뒤에 불러야 한다.
    /// Raises: 등록 시 없음. 적용 시 DB 오류를 전달한다.
    static func migratePins(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17-chat-pins") { db in
            try db.execute(sql: "ALTER TABLE app_conversations ADD COLUMN pinned_at REAL")
        }
    }

    /// Args: 없음.
    /// Returns: 최신순 대화 목록.
    /// Raises: DB·디코딩 오류.
    public func conversations() throws -> [ChatConversation] {
        try db.writer.read { conn in
            try Row.fetchAll(conn, sql: "SELECT payload, project_id, pinned_at FROM app_conversations ORDER BY updated_at DESC")
                .map { row in
                    var conversation = try JSONDecoder().decode(ChatConversation.self, from: Data((row["payload"] as String).utf8))
                    conversation.projectID = row["project_id"]
                    conversation.pinnedAt = row["pinned_at"]
                    return conversation
                }
        }
    }

    /// Args: 없음.
    /// Returns: 대화 목록에 표시할 마지막 메시지의 짧은 미리보기.
    /// Raises: DB 조회 오류.
    public func conversationPreviews() throws -> [String: String] {
        try db.writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT c.id, (
                    SELECT substr(json_extract(m.payload, '$.text'), 1, 240)
                    FROM app_messages m WHERE m.conversation_id = c.id
                      AND json_extract(m.payload, '$.text') != ''
                      AND json_extract(m.payload, '$.status') = 'complete'
                    ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1
                ) AS preview FROM app_conversations c
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["id"] as String, row["preview"] as String? ?? "")
            })
        }
    }

    /// Args: conversation은 저장할 대화 설정이다.
    /// Returns: 없음. 기존 ID가 있으면 갱신한다.
    /// Raises: 인코딩·DB 오류.
    public func save(_ conversation: ChatConversation) throws {
        let payload = String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self)
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO app_conversations (id, updated_at, payload, project_id) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, payload = excluded.payload",
                             arguments: [conversation.id, conversation.updatedAt, payload, conversation.projectID])
        }
    }

    /// Args: pinned는 고정 여부, time은 고정한 시각이다.
    /// Returns: 없음. pinned_at만 바꾸고 updated_at은 그대로 둔다.
    /// Raises: DB 쓰기 오류.
    public func setPinned(_ conversationID: String, pinned: Bool, at time: Double = Date().timeIntervalSince1970) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "UPDATE app_conversations SET pinned_at = ? WHERE id = ?", arguments: [pinned ? time : nil, conversationID])
        }
    }

    /// Args: query는 찾을 글(공백으로 나눈 낱말 모두), limit는 최대 대화 수이다.
    /// Returns: 낱말마다 제목이나 완료 메시지 본문에 든 대화(대화당 한 줄, 최신순). 빈 검색어는 [].
    /// Raises: DB 조회 오류, 또는 Task가 취소되면 GRDB가 중단한 조회 오류.
    public func searchConversations(_ query: String, limit: Int = 30) async throws -> [ChatSearchHit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = terms.first else { return [] }
        let likes = terms.map { "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
        let messageText = "json_extract(m.payload, '$.status') = 'complete' AND json_extract(m.payload, '$.text') LIKE ? ESCAPE '\\'"
        let conversationWhere = Array(repeating: "(json_extract(c.payload, '$.title') LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM app_messages m WHERE m.conversation_id = c.id AND \(messageText)))", count: terms.count).joined(separator: " AND ")
        let matchWhere = Array(repeating: "json_extract(m.payload, '$.text') LIKE ? ESCAPE '\\'", count: terms.count).joined(separator: " AND ")
        return try await db.writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT c.id, json_extract(c.payload, '$.title') AS title, c.updated_at FROM app_conversations c
                WHERE \(conversationWhere)
                ORDER BY c.updated_at DESC LIMIT ?
                """, arguments: StatementArguments(likes.flatMap { [$0, $0] } + [limit]))
            return try rows.map { row in
                let id: String = row["id"]
                let match = try Row.fetchOne(conn, sql: """
                    SELECT m.id, json_extract(m.payload, '$.text') AS text FROM app_messages m WHERE m.conversation_id = ?
                      AND json_extract(m.payload, '$.status') = 'complete' AND \(matchWhere)
                    ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1
                    """, arguments: StatementArguments([id] + likes))
                let hit: String? = match?["text"]
                var snippet: String
                if let hit {
                    let start = hit.range(of: first, options: .caseInsensitive)?.lowerBound ?? hit.startIndex
                    let from = hit.index(start, offsetBy: -20, limitedBy: hit.startIndex) ?? hit.startIndex
                    snippet = String(hit[from...].prefix(120))
                } else {
                    let last = try String.fetchOne(conn, sql: """
                        SELECT json_extract(payload, '$.text') FROM app_messages WHERE conversation_id = ?
                          AND json_extract(payload, '$.status') = 'complete' AND json_extract(payload, '$.text') != ''
                        ORDER BY created_at DESC, rowid DESC LIMIT 1
                        """, arguments: [id])
                    snippet = String((last ?? "").prefix(120))
                }
                snippet = snippet.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                return ChatSearchHit(conversationID: id, title: row["title"] ?? "", snippet: snippet, updatedAt: row["updated_at"],
                                     messageID: match?["id"])
            }
        }
    }

    /// Args: conversationID는 삭제할 대화 ID이다.
    /// Returns: 없음. 메시지·결과물을 함께 삭제하고 예약의 결과 링크만 해제한다.
    /// Raises: DB 쓰기 오류. 승인된 예약과 원본 활동 기록은 유지한다.
    public func deleteConversation(_ conversationID: String) throws {
        try deleteConversations([conversationID])
    }

    public func deleteConversations(_ conversationIDs: [String]) throws {
        try db.writer.write { conn in
            for conversationID in Set(conversationIDs) {
                try conn.execute(sql: "DELETE FROM app_conversations WHERE id = ?", arguments: [conversationID])
                try ProjectStore.removeFromProposals("conversation:\(conversationID)", conn)
                try conn.execute(sql: "UPDATE app_automations SET payload = json_remove(payload, '$.lastConversationID') WHERE json_extract(payload, '$.lastConversationID') = ?", arguments: [conversationID])
            }
        }
    }

    /// Args: conversationID는 대화 ID, title은 새 이름이다.
    /// Returns: 없음. 자료 범위나 대화 순서는 바꾸지 않고 이름만 저장한다.
    /// Raises: DB 쓰기 오류.
    public func renameConversation(_ conversationID: String, title: String) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "UPDATE app_conversations SET payload = json_set(payload, '$.title', ?) WHERE id = ?", arguments: [title, conversationID])
        }
    }

    /// Args: conversationID는 읽을 대화 ID이다.
    /// Returns: 작성 순서의 대화 메시지.
    /// Raises: DB·디코딩 오류.
    public func messages(_ conversationID: String) throws -> [ConversationMessage] {
        try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT payload FROM app_messages WHERE conversation_id = ? ORDER BY created_at, rowid", arguments: [conversationID])
                .map { try JSONDecoder().decode(ConversationMessage.self, from: Data($0.utf8)) }
        }
    }

    public func firstMessage(_ conversationID: String) throws -> ConversationMessage? {
        try db.writer.read { conn in
            try String.fetchOne(conn, sql: "SELECT payload FROM app_messages WHERE conversation_id = ? ORDER BY created_at, rowid LIMIT 1", arguments: [conversationID])
                .map { try JSONDecoder().decode(ConversationMessage.self, from: Data($0.utf8)) }
        }
    }

    /// Messages of every conversation that carry artifacts, so the library can collect them without decoding the rest.
    public func messagesWithArtifacts() throws -> [ConversationMessage] {
        try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT payload FROM app_messages WHERE json_array_length(payload, '$.artifacts') > 0 ORDER BY created_at, rowid")
                .map { try JSONDecoder().decode(ConversationMessage.self, from: Data($0.utf8)) }
        }
    }

    /// Args: message는 저장할 요청·응답·진행 기록이다.
    /// Returns: 없음. 기존 ID가 있으면 갱신한다.
    /// Raises: 인코딩·DB 오류.
    public func save(_ message: ConversationMessage) throws {
        let payload = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO app_messages VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                             arguments: [message.id, message.conversationID, message.createdAt, payload])
        }
    }

    /// Args: 없음.
    /// Returns: 등록된 예약 목록.
    /// Raises: DB·디코딩 오류.
    /// 업무를 합칠 때: 사라지는 업무를 범위에 둔 대화·예약을 남는 업무로 옮기고(겹치면 하나로), 남는 업무의 지금 이름으로 맞춘다
    static func moveFocus(from victims: [String], to keep: String, title: String, _ conn: Database) throws {
        let affected = Set(victims + [keep])
        for table in ["app_conversations", "app_automations"] {
            for row in try Row.fetchAll(conn, sql: "SELECT id, payload FROM \(table) WHERE json_type(payload, '$.scope.focuses') = 'array'") {
                let payload: String = row["payload"]
                guard var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                      var scope = object["scope"] as? [String: Any], let focuses = scope["focuses"] as? [[String: Any]] else { continue }
                var moved: [[String: Any]] = [], seen: Set<String> = [], changed = false
                for var item in focuses {
                    if item["kind"] as? String == "task", let key = item["key"] as? String, affected.contains(key) {
                        changed = changed || key != keep || item["title"] as? String != title
                        item["key"] = keep; item["title"] = title
                    }
                    let identity = "\(item["kind"] as? String ?? ""):\(item["key"] as? String ?? "")"
                    if seen.insert(identity).inserted { moved.append(item) } else { changed = true }
                }
                guard changed else { continue }
                scope["focuses"] = moved; object["scope"] = scope
                let updated = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                try conn.execute(sql: "UPDATE \(table) SET payload = ? WHERE id = ?", arguments: [updated, row["id"] as String])
            }
        }
    }

    public func automations() throws -> [ChatAutomation] {
        try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT payload FROM app_automations ORDER BY rowid DESC")
                .map { try JSONDecoder().decode(ChatAutomation.self, from: Data($0.utf8)) }
        }
    }

    /// Args: automation은 저장할 예약과 실행 상태이다.
    /// Returns: 없음. 기존 ID가 있으면 갱신한다.
    /// Raises: 인코딩·DB 오류.
    public func save(_ automation: ChatAutomation) throws {
        let payload = String(decoding: try JSONEncoder().encode(automation), as: UTF8.self)
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO app_automations VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [automation.id, payload])
        }
    }

    /// Args: id는 삭제할 예약 ID이다.
    /// Returns: 없음. 원래 대화와 실행 결과는 보존하고 승인 표시만 해제한다.
    /// Raises: DB 쓰기 오류.
    public func deleteAutomation(_ id: String) throws {
        try db.writer.write { conn in
            try conn.execute(sql: "DELETE FROM app_automations WHERE id = ?", arguments: [id])
            try conn.execute(sql: "UPDATE app_messages SET payload = json_remove(payload, '$.approvedAutomationID') WHERE json_extract(payload, '$.approvedAutomationID') = ?", arguments: [id])
        }
    }

    /// Args: 없음.
    /// Returns: 없음. 이전 실행이 종료된 작업을 중단 상태로 표시한다.
    /// Raises: DB 읽기·쓰기 오류.
    public func recoverInterruptedRuns() throws {
        try db.writer.write { conn in
            try conn.execute(sql: """
                UPDATE app_messages SET payload = json_set(payload, '$.status', 'interrupted')
                WHERE json_extract(payload, '$.status') = 'running'
                """)
        }
        // Rows saved before statuses were stored as keys hold the English text.
        for var job in try automations() where ["실행 중", L10n.english["실행 중"]].contains(job.lastStatus) {
            job.lastStatus = "앱 종료로 중단됨"; try save(job)
        }
    }

    /// Args: conversation은 대화, user·answer는 새 요청과 응답 자리이다.
    /// Returns: 없음. 한 요청을 이루는 세 레코드를 함께 저장한다.
    /// Raises: 인코딩·DB 오류. 실패하면 모두 반영하지 않는다.
    /// Args: replacing are messages an edit or regenerate drops in the same write, along with the conversation links of their artifacts.
    public func startTurn(conversation: ChatConversation, user: ConversationMessage, answer: ConversationMessage, replacing: [ConversationMessage] = []) throws {
        let encoder = JSONEncoder()
        let payload = String(decoding: try encoder.encode(conversation), as: UTF8.self)
        let records = try [user, answer].map { ($0, String(decoding: try encoder.encode($0), as: UTF8.self)) }
        try db.writer.write { conn in
            for old in replacing {
                try conn.execute(sql: "DELETE FROM app_messages WHERE id = ? AND conversation_id = ?", arguments: [old.id, conversation.id])
                for artifact in old.artifacts {
                    try conn.execute(sql: "DELETE FROM library_conversation_sources WHERE conversation_id = ? AND item_id IN (SELECT id FROM app_library WHERE origin_id = ?)",
                                     arguments: [conversation.id, artifact.id])
                }
            }
            try conn.execute(sql: "INSERT INTO app_conversations (id, updated_at, payload, project_id) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at, payload = excluded.payload", arguments: [conversation.id, conversation.updatedAt, payload, conversation.projectID])
            for (message, json) in records {
                try conn.execute(sql: "INSERT INTO app_messages VALUES (?, ?, ?, ?)", arguments: [message.id, message.conversationID, message.createdAt, json])
            }
        }
    }

    /// Args: removing are messages leaving the conversation's active path, inserting the ones taking their place.
    /// Returns: none. Swaps them in one write and unlinks the removed answers' artifacts like startTurn.
    /// Raises: encoding or DB errors; nothing changes then.
    public func replaceMessages(in conversationID: String, removing: [ConversationMessage], inserting: [ConversationMessage]) throws {
        let records = try inserting.map { ($0, String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) }
        try db.writer.write { conn in
            for old in removing {
                try conn.execute(sql: "DELETE FROM app_messages WHERE id = ? AND conversation_id = ?", arguments: [old.id, conversationID])
                for artifact in old.artifacts {
                    try conn.execute(sql: "DELETE FROM library_conversation_sources WHERE conversation_id = ? AND item_id IN (SELECT id FROM app_library WHERE origin_id = ?)",
                                     arguments: [conversationID, artifact.id])
                }
            }
            for (message, json) in records {
                try conn.execute(sql: "INSERT INTO app_messages VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                                 arguments: [message.id, conversationID, message.createdAt, json])
            }
        }
    }

    /// Args: automation은 승인한 예약, message는 승인 상태를 반영한 답변이다.
    /// Returns: 없음. 예약과 답변의 승인 상태를 함께 저장한다.
    /// Raises: 인코딩·DB 오류.
    public func approve(_ automation: ChatAutomation, message: ConversationMessage) throws {
        let job = String(decoding: try JSONEncoder().encode(automation), as: UTF8.self)
        let answer = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO app_automations VALUES (?, ?)", arguments: [automation.id, job])
            try conn.execute(sql: "UPDATE app_messages SET payload = ? WHERE id = ?", arguments: [answer, message.id])
        }
    }
}
