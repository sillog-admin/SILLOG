import Foundation
import GRDB

/// 업무·대화·사용자가 연결한 자료를 같은 목표로 묶는 프로젝트.
public enum ProjectMemoryMode: String, Codable, CaseIterable, Sendable {
    case allRecords, projectOnly
    public var title: String { self == .allRecords ? "전체 기록 참고" : "프로젝트 전용" }
}

public struct ChatProject: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var goal: String
    public var paths: [String] = []
    public var instructions = ""
    public var memoryMode = ProjectMemoryMode.allRecords
    public var updatedAt = Date().timeIntervalSince1970
    public init(title: String, goal: String) { self.title = title; self.goal = goal }

    private enum CodingKeys: String, CodingKey { case id, title, goal, paths, instructions, memoryMode, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        goal = try values.decode(String.self, forKey: .goal)
        paths = try values.decodeIfPresent([String].self, forKey: .paths) ?? []
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        memoryMode = try values.decodeIfPresent(ProjectMemoryMode.self, forKey: .memoryMode) ?? .allRecords
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
    }
}

public struct ProjectItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var projectID: String?
    public var paths: [String] = []
    public var isTask: Bool { id.hasPrefix("task:") }
}

public struct ProjectProposal: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var projectID: String?
    public var title: String
    public var goal: String
    public var reason: String
    public var items: [ProjectItem]
}

/// LLM이 반환하는 제안. target은 기존 프로젝트·대기 중 제안의 ID이며 새 프로젝트면 빈 문자열이다.
public struct ProjectSuggestion: Codable, Sendable {
    public var target: String
    public var title: String
    public var goal: String
    public var reason: String
    public var items: [String]
    public init(target: String = "", title: String, goal: String, reason: String, items: [String]) {
        self.target = target; self.title = title; self.goal = goal; self.reason = reason; self.items = items
    }
}

public struct ProjectReview: Sendable {
    public struct Destination: Codable, Sendable {
        public var id: String
        public var title: String
        public var goal: String
    }
    public var items: [ProjectItem]
    public var newIDs: Set<String>
    public var destinations: [Destination]
}

/// 제안은 저장만 하고, 사용자가 수락할 때 한 트랜잭션으로 프로젝트와 소속을 반영한다.
public struct ProjectStore: Sendable {
    let db: WGDatabase
    public init(_ db: WGDatabase) { self.db = db }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12-chat-projects") { conn in
            try conn.execute(sql: """
                CREATE TABLE app_projects (id TEXT PRIMARY KEY, updated_at REAL NOT NULL, payload TEXT NOT NULL);
                ALTER TABLE app_conversations ADD COLUMN project_id TEXT REFERENCES app_projects(id) ON DELETE SET NULL;
                CREATE INDEX idx_app_conversations_project ON app_conversations(project_id);
                CREATE TABLE project_tasks (
                  task_id INTEGER PRIMARY KEY REFERENCES nodes(id) ON DELETE CASCADE,
                  project_id TEXT NOT NULL REFERENCES app_projects(id) ON DELETE CASCADE
                );
                CREATE INDEX idx_project_tasks_project ON project_tasks(project_id);
                CREATE TABLE project_proposals (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE project_reviewed (item_id TEXT PRIMARY KEY, decision TEXT NOT NULL);
                """)
        }
    }

    public func projects() throws -> [ChatProject] {
        try db.writer.read { try Self.projects($0) }
    }

    static func projects(_ conn: Database) throws -> [ChatProject] {
        try String.fetchAll(conn, sql: "SELECT payload FROM app_projects ORDER BY updated_at DESC")
            .map { try JSONDecoder().decode(ChatProject.self, from: Data($0.utf8)) }
    }

    public func proposals() throws -> [ProjectProposal] {
        try db.writer.read { try Self.proposalGroups($0).map(\.proposal) }
    }

    static func proposals(_ conn: Database) throws -> [ProjectProposal] {
        try String.fetchAll(conn, sql: "SELECT payload FROM project_proposals ORDER BY rowid")
            .map { try JSONDecoder().decode(ProjectProposal.self, from: Data($0.utf8)) }
    }

    /// 기존 프로젝트는 ID, 새 프로젝트 제안은 공백·대소문자를 제외한 제목으로 묶는다.
    /// 저장된 중복 행의 ID도 유지해 수락·무시할 때 전체를 함께 처리한다.
    private static func proposalGroups(_ conn: Database) throws -> [(proposal: ProjectProposal, ids: [String])] {
        var groups: [(proposal: ProjectProposal, ids: [String])] = []
        var positions: [String: Int] = [:]
        for proposal in try proposals(conn) {
            let title = proposal.title.split(whereSeparator: \.isWhitespace).joined().lowercased()
            let key = proposal.projectID.map { "project:\($0)" } ?? "title:\(title)"
            if let index = positions[key] {
                groups[index].ids.append(proposal.id)
                var seen = Set(groups[index].proposal.items.map(\.id))
                groups[index].proposal.items += proposal.items.filter { seen.insert($0.id).inserted }
                let reasons = groups[index].proposal.reason.components(separatedBy: "\n")
                if !reasons.contains(proposal.reason) { groups[index].proposal.reason += "\n" + proposal.reason }
            } else {
                positions[key] = groups.count
                groups.append((proposal, [proposal.id]))
            }
        }
        return groups
    }

    public func items() throws -> [ProjectItem] { try db.writer.read { try Self.items($0) } }

    static func items(_ conn: Database) throws -> [ProjectItem] {
        var items = try Row.fetchAll(conn, sql: """
            SELECT t.id, t.title, p.project_id,
              (SELECT group_concat(props, char(10)) FROM (
                SELECT s.props FROM nodes s JOIN edges e ON e.src = s.id AND e.type = 'PART_OF'
                WHERE e.dst = t.id AND s.label = 'Session' ORDER BY s.updated_at DESC LIMIT 3
              )) AS summary,
              (SELECT group_concat(r.title, ', ') FROM edges part JOIN edges used ON used.src = part.src AND used.type = 'TOUCHED'
                JOIN nodes r ON r.id = used.dst WHERE part.dst = t.id AND part.type = 'PART_OF' AND r.label = 'Resource') AS resources
            FROM nodes t LEFT JOIN project_tasks p ON p.task_id = t.id WHERE t.label = 'Task' ORDER BY t.updated_at DESC
            """).map { row -> ProjectItem in
                let summary = (row["summary"] as String? ?? "") + "\n자료: " + (row["resources"] as String? ?? "")
                return .init(id: "task:\(row["id"] as Int64)", title: row["title"], summary: String(summary.prefix(1600)), projectID: row["project_id"])
            }
        for row in try Row.fetchAll(conn, sql: "SELECT id, payload, project_id FROM app_conversations ORDER BY updated_at DESC") {
            let conversation = try JSONDecoder().decode(ChatConversation.self, from: Data((row["payload"] as String).utf8))
            let text = try String.fetchAll(conn, sql: """
                SELECT json_extract(payload, '$.text') FROM app_messages
                WHERE conversation_id = ? AND json_extract(payload, '$.status') = 'complete'
                ORDER BY created_at DESC, rowid DESC LIMIT 4
                """, arguments: [conversation.id]).reversed().joined(separator: "\n")
            // 아직 요청을 보내지 않은 빈 대화는 다음 검토까지 남겨 둔다.
            guard !text.isEmpty else { continue }
            items.append(.init(id: "conversation:\(conversation.id)", title: conversation.title,
                               summary: String(text.prefix(1600)), projectID: row["project_id"], paths: conversation.scope.paths))
        }
        return items
    }

    /// 처음에는 모든 기존 항목을 순서대로 검토하고, 이후에는 새 항목만 판단한다. 이전 미분류 항목은 연결 근거로 제공한다.
    public func review(limit: Int = 40) throws -> ProjectReview {
        try db.writer.read { conn in
            let proposals = try Self.proposalGroups(conn).map(\.proposal)
            let pending = Set(proposals.flatMap { $0.items.map(\.id) })
            let reviewed = Dictionary(uniqueKeysWithValues: try Row.fetchAll(conn, sql: "SELECT * FROM project_reviewed")
                .map { ($0["item_id"] as String, $0["decision"] as String) })
            let eligible = try Self.items(conn).filter {
                $0.projectID == nil && !pending.contains($0.id) && (reviewed[$0.id] == nil || reviewed[$0.id] == "seen")
            }
            let fresh = Array(eligible.filter { reviewed[$0.id] == nil }.prefix(limit))
            let context = Array(eligible.filter { reviewed[$0.id] == "seen" }.prefix(limit))
            let destinations = try Self.projects(conn).map { ProjectReview.Destination(id: "project:\($0.id)", title: $0.title, goal: $0.goal) }
                + proposals.map { .init(id: "proposal:\($0.id)", title: $0.title, goal: $0.goal) }
            return .init(items: fresh + context, newIDs: Set(fresh.map(\.id)), destinations: destinations)
        }
    }

    /// 응답 전체를 검증한 뒤 저장한다. 잘못된 ID·중복·사용자가 이미 옮긴 항목이면 검토 완료로 기록하지 않는다.
    public func record(_ suggestions: [ProjectSuggestion], review: ProjectReview) throws {
        try db.writer.write { conn in
            let known = Dictionary(uniqueKeysWithValues: review.items.map { ($0.id, $0) })
            let current = Dictionary(uniqueKeysWithValues: try Self.items(conn).map { ($0.id, $0) })
            let destinations = Set(review.destinations.map(\.id))
            var used: Set<String> = []
            for suggestion in suggestions {
                guard !suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suggestion.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suggestion.items.isEmpty, !suggestion.target.isEmpty || suggestion.items.count >= 2,
                      suggestion.items.contains(where: { review.newIDs.contains($0) }),
                      suggestion.target.isEmpty || destinations.contains(suggestion.target) else {
                    throw ChatToolError.unavailable("프로젝트 제안의 내용을 확인하지 못했습니다.")
                }
                for id in suggestion.items {
                    let decision = try String.fetchOne(conn, sql: "SELECT decision FROM project_reviewed WHERE item_id = ?", arguments: [id])
                    guard known[id] != nil, current[id]?.projectID == nil, current[id] != nil,
                          decision == nil || decision == "seen", used.insert(id).inserted else {
                        throw ChatToolError.unavailable("제안에 중복되거나 이미 옮겨진 항목이 있습니다. 다시 확인하세요.")
                    }
                }
            }
            for suggestion in suggestions {
                let members = suggestion.items.compactMap { current[$0] }
                if suggestion.target.hasPrefix("proposal:") {
                    let id = String(suggestion.target.dropFirst("proposal:".count))
                    guard var proposal = try Self.proposals(conn).first(where: { $0.id == id }) else { throw ChatToolError.unavailable("대기 중인 제안이 변경되었습니다. 다시 확인하세요.") }
                    proposal.items += members
                    try Self.save(proposal, conn)
                } else {
                    let projectID = suggestion.target.isEmpty ? nil : String(suggestion.target.dropFirst("project:".count))
                    let existing = try Self.projects(conn).first(where: { $0.id == projectID })
                    if projectID != nil, existing == nil {
                        throw ChatToolError.unavailable("대상 프로젝트가 삭제되었습니다. 다시 확인하세요.")
                    }
                    let proposal = ProjectProposal(projectID: projectID, title: existing?.title ?? String(suggestion.title.prefix(120)),
                                                   goal: existing?.goal ?? String(suggestion.goal.prefix(1000)), reason: String(suggestion.reason.prefix(1000)), items: members)
                    try Self.save(proposal, conn)
                }
            }
            for id in review.newIDs {
                if try String.fetchOne(conn, sql: "SELECT decision FROM project_reviewed WHERE item_id = ?", arguments: [id]) == nil {
                    try Self.mark(id, decision: "seen", conn)
                }
            }
            for group in try Self.proposalGroups(conn) where group.ids.count > 1 {
                try Self.save(group.proposal, conn)
                for id in group.ids.dropFirst() {
                    try conn.execute(sql: "DELETE FROM project_proposals WHERE id = ?", arguments: [id])
                }
            }
        }
    }

    /// 수락한 제안만 생성·분류한다. 다른 곳으로 옮겨진 항목을 덮어쓰지 않는다.
    @discardableResult public func accept(_ id: String, title: String) throws -> ChatProject {
        try db.writer.write { conn in
            guard let group = try Self.proposalGroups(conn).first(where: { $0.ids.contains(id) }) else { throw ChatToolError.unavailable("제안을 찾을 수 없습니다.") }
            let proposal = group.proposal
            let current = Dictionary(uniqueKeysWithValues: try Self.items(conn).map { ($0.id, $0) })
            guard proposal.items.allSatisfy({ current[$0.id] != nil && current[$0.id]?.projectID == nil }) else {
                throw ChatToolError.unavailable("제안의 항목이 변경되었습니다. 제안을 무시한 뒤 다시 확인하세요.")
            }
            var project: ChatProject
            if let projectID = proposal.projectID {
                guard let existing = try Self.projects(conn).first(where: { $0.id == projectID }) else { throw ChatToolError.unavailable("프로젝트를 찾을 수 없습니다.") }
                project = existing
            } else {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ChatToolError.unavailable("프로젝트 이름을 입력하세요.") }
                project = .init(title: String(name.prefix(120)), goal: proposal.goal)
            }
            project.updatedAt = Date().timeIntervalSince1970
            try Self.save(project, conn)
            for item in proposal.items { try Self.move(item.id, to: project.id, conn) }
            for id in group.ids { try conn.execute(sql: "DELETE FROM project_proposals WHERE id = ?", arguments: [id]) }
            return project
        }
    }

    public func dismiss(_ id: String) throws {
        try db.writer.write { conn in
            guard let group = try Self.proposalGroups(conn).first(where: { $0.ids.contains(id) }) else { return }
            for item in group.proposal.items { try Self.mark(item.id, decision: "dismissed", conn) }
            for id in group.ids { try conn.execute(sql: "DELETE FROM project_proposals WHERE id = ?", arguments: [id]) }
        }
    }

    public func move(_ itemID: String, to projectID: String?) throws {
        try move([itemID], to: projectID)
    }

    public func move(_ itemIDs: [String], to projectID: String?) throws {
        try db.writer.write { conn in
            for itemID in Set(itemIDs) {
                try Self.move(itemID, to: projectID, conn)
                try Self.mark(itemID, decision: "manual", conn)
                try Self.removeFromProposals(itemID, conn)
            }
        }
    }

    static func removeFromProposals(_ itemID: String, _ conn: Database) throws {
        for var proposal in try Self.proposals(conn) where proposal.items.contains(where: { $0.id == itemID }) {
            proposal.items.removeAll { $0.id == itemID }
            if proposal.items.isEmpty { try conn.execute(sql: "DELETE FROM project_proposals WHERE id = ?", arguments: [proposal.id]) }
            else { try Self.save(proposal, conn) }
        }
    }

    /// 업무 병합 뒤에도 사용자의 분류 선택을 남길 업무로 이어 준다.
    static func mergeTask(_ victim: Int64, into keep: Int64, _ conn: Database) throws {
        let oldID = "task:\(victim)", newID = "task:\(keep)"
        if let decision = try String.fetchOne(conn, sql: "SELECT decision FROM project_reviewed WHERE item_id = ?", arguments: [oldID]) {
            let existing = try String.fetchOne(conn, sql: "SELECT decision FROM project_reviewed WHERE item_id = ?", arguments: [newID])
            if existing == nil || (existing == "seen" && decision != "seen") { try Self.mark(newID, decision: decision, conn) }
        }
    }

    static func move(_ itemID: String, to projectID: String?, _ conn: Database) throws {
        if let projectID, !(try Self.projects(conn)).contains(where: { $0.id == projectID }) { throw ChatToolError.unavailable("프로젝트를 찾을 수 없습니다.") }
        if itemID.hasPrefix("task:"), let id = Int64(itemID.dropFirst(5)) {
            guard try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM nodes WHERE id = ? AND label = 'Task')", arguments: [id]) == true else { throw ChatToolError.unavailable("업무를 찾을 수 없습니다.") }
            try conn.execute(sql: "DELETE FROM project_tasks WHERE task_id = ?", arguments: [id])
            if let projectID { try conn.execute(sql: "INSERT INTO project_tasks VALUES (?, ?)", arguments: [id, projectID]) }
        } else if itemID.hasPrefix("conversation:") {
            let id = String(itemID.dropFirst("conversation:".count))
            guard try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM app_conversations WHERE id = ?)", arguments: [id]) == true else { throw ChatToolError.unavailable("대화를 찾을 수 없습니다.") }
            try conn.execute(sql: "UPDATE app_conversations SET project_id = ? WHERE id = ?", arguments: [projectID, id])
        } else { throw ChatToolError.unavailable("옮길 항목을 찾을 수 없습니다.") }
    }

    static func mark(_ id: String, decision: String, _ conn: Database) throws {
        try conn.execute(sql: "INSERT INTO project_reviewed VALUES (?, ?) ON CONFLICT(item_id) DO UPDATE SET decision = excluded.decision", arguments: [id, decision])
    }

    public func save(_ project: ChatProject) throws { try db.writer.write { try Self.save(project, $0) } }

    static func save(_ project: ChatProject, _ conn: Database) throws {
        let payload = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        try conn.execute(sql: "INSERT INTO app_projects VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at",
                         arguments: [project.id, project.updatedAt, payload])
    }

    static func save(_ proposal: ProjectProposal, _ conn: Database) throws {
        let payload = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        try conn.execute(sql: "INSERT INTO project_proposals VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", arguments: [proposal.id, payload])
    }

    public func delete(_ projectID: String) throws {
        try db.writer.write { conn in
            for item in try Self.items(conn) where item.projectID == projectID { try Self.mark(item.id, decision: "manual", conn) }
            for proposal in try Self.proposals(conn) where proposal.projectID == projectID {
                try conn.execute(sql: "DELETE FROM project_proposals WHERE id = ?", arguments: [proposal.id])
            }
            try conn.execute(sql: "UPDATE app_automations SET payload = json_remove(payload, '$.scope.projectID') WHERE json_extract(payload, '$.scope.projectID') = ?", arguments: [projectID])
            try conn.execute(sql: "DELETE FROM app_projects WHERE id = ?", arguments: [projectID])
        }
    }

    /// 대화 전용 자료와 프로젝트에 명시적으로 공유한 자료만 사용한다.
    public func scope(for conversation: ChatConversation) throws -> ChatScope {
        try db.writer.read { conn in
            var scope = conversation.scope
            scope.conversationID = conversation.id
            let row = try Row.fetchOne(conn, sql: "SELECT project_id FROM app_conversations WHERE id = ?", arguments: [conversation.id])
            let projectID: String? = row.map { $0["project_id"] as String? } ?? conversation.projectID
            scope.projectID = projectID
            scope.libraryIDs = try LibraryStore.sourceIDs(conversationID: conversation.id, projectID: projectID, conn)
            guard let projectID else { return scope }
            guard let project = try Self.projects(conn).first(where: { $0.id == projectID }) else { throw ChatToolError.unavailable("프로젝트가 삭제되었습니다.") }
            scope.paths = Array(Set(scope.paths + project.paths)).sorted()
            return scope
        }
    }
}
