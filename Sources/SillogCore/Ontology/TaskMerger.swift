import Foundation
import GRDB

/// 제목만 다른 같은 목표를 합치고, 목표가 아닌 업무(목적 불명·분류 이름뿐·오락)는 업무 외로 돌린다.
/// 판단은 LLM ("이 업무들이 같은 목표인가", "이게 목표인가"), 반영은 기계적으로:
/// 행 판단(task_id)·세션·주제·나중에 할 일·시간을 남길 업무로 옮기고 나머지 노드를 지운다.
/// 시간이나 제목 유사도로 자동 병합하지 않는다.
public struct TaskMerger: Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var keep: String
        public var merge: [String]
        public var title: String?
        public var goal: String?
        public init(keep: String, merge: [String], title: String? = nil, goal: String? = nil) {
            self.keep = keep; self.merge = merge; self.title = title; self.goal = goal
        }
    }

    public struct Result: Equatable, Sendable {
        public var groups: [Group] = []
        public var merged = 0
        /// 목표가 아니라서 업무 외로 돌린 업무 id
        public var notGoals: [String] = []
        public var retired = 0
        public var raw = ""
        public init() {}
    }

    struct Answer: Decodable {
        var groups: [Group]?
        var notGoals: [String]?
        enum CodingKeys: String, CodingKey { case groups, notGoals = "not_goals" }
    }

    static let system = """
    You review the user's open tasks for a personal work graph: find tasks that are the SAME GOAL recorded twice under different titles, tasks whose title or goal is too vague, and tasks that are not goals at all.
    A task is a goal the user is pursuing: a project or deliverable, a course being studied, an errand with an outcome (an application, a payment, an interview), or a recurring routine that serves the user's work or study (a project team's channel, a class). Two tasks are the same goal when their titles, topics, recent work and resources describe the same project/deliverable, the same course, the same errand or the same routine. Sub-steps of one goal (reading docs for it, checking a tool's usage for it, managing a tool's account, subscription or billing for it, installing a tool for it, looking at examples for it) are that goal, not separate goals.
    Do NOT merge different goals that merely share an app, a website or a topic word; do not merge a course with a project.
    - groups: tasks to merge. keep = the id whose title best names the goal (prefer the specific, established one); merge = the ids to fold into it; title and goal = a better Korean title and goal sentence when the kept one is vague. A single task whose title or goal is vague but whose recent work shows one real goal gets a group with an empty merge list and the better title and goal.
    - not_goals: ids of tasks that are not goals: no goal can be named from their title, goal and recent work (the purpose is unknown, or it is a bare category or catch-all), or they are entertainment, a hobby (including regular participation in a game, a league, a sport or a fan community, alone or with a team) or idle browsing. Their rows will count as time outside tasks. When unsure, leave the task alone.
    Leave everything else alone. Always answer by calling merge_tasks.
    """

    static var tool: ToolSpec {
        ToolSpec(name: "merge_tasks", description: "Groups of task ids that are the same goal, and tasks that are not goals.", parameters: .object([
            "type": "object",
            "properties": .object([
                "groups": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "keep": .object(["type": "string", "description": "남길 업무 id"]),
                        "merge": .object(["type": "array", "items": .object(["type": "string"]), "description": "keep 에 합칠 업무 id 들 (이름만 고칠 때는 빈 목록)"]),
                        "title": .object(["type": "string", "description": "남길 업무의 제목이 모호할 때만, 더 나은 한국어 제목"]),
                        "goal": .object(["type": "string", "description": "남길 업무의 목표 문장이 모호할 때만, 더 나은 한국어 한 문장"]),
                    ]),
                    "required": .array(["keep", "merge"]),
                ])]),
                "not_goals": .object(["type": "array", "items": .object(["type": "string"]), "description": "목표가 아닌 업무 id 들 (목적 불명·분류 이름뿐, 오락·취미·목적 없는 탐색)"]),
            ]),
            "required": .array(["groups", "not_goals"]),
        ]))
    }

    static func prompt(_ tasks: [TaskDigest]) -> String {
        var lines = ["TASKS:"]
        for task in tasks {
            var line = "- id=\(task.id) | \(task.title) | \(task.taskType ?? "기타")"
            if let goal = task.goal { line += " | goal: \(OntologyPrompt.clip(goal, 140))" }
            if !task.topics.isEmpty { line += " | topics: \(task.topics.joined(separator: ", "))" }
            if !task.recentSummaries.isEmpty { line += " | recent work: \(task.recentSummaries.map { OntologyPrompt.clip($0, 120) }.joined(separator: " / "))" }
            if !task.recentResources.isEmpty { line += " | resources: \(task.recentResources.prefix(4).map { OntologyPrompt.clip($0, 50) }.joined(separator: "; "))" }
            if !task.folders.isEmpty { line += " | folders: \(task.folders.prefix(3).joined(separator: ", "))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// LLM 에 묻고 (dry 가 아니면) 반영한다. 돌려주는 값에 그룹과 합친 수
    /// extraRules: 규칙에 덧붙일 글 (정리 제안이 쓴다)
    public static func run(db: SillogDatabase, llm: any LLMClient, since: Double, now: Double, dry: Bool = false, extraRules: String = "") async throws -> Result {
        let tasks = try await db.writer.read { try GraphTx($0).openTasks(limit: 60, since: since) }
        var result = Result()
        guard tasks.count >= 2 else { return result }
        let answer = try await llm.callFunction(system: system + extraRules, user: prompt(tasks), tool: tool)
        result.raw = answer.raw
        guard let parsed = try? JSONDecoder().decode(Answer.self, from: answer.arguments) else { return result }
        let known = Set(tasks.map(\.id))
        func filled(_ text: String?) -> Bool { !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        result.groups = (parsed.groups ?? []).compactMap { group in
            let targets = group.merge.filter { known.contains($0) && $0 != group.keep }
            guard known.contains(group.keep), !targets.isEmpty || filled(group.title) || filled(group.goal) else { return nil }
            return Group(keep: group.keep, merge: targets, title: group.title, goal: group.goal)
        }
        // 합치거나 이름을 고치는 업무는 목표로 본 것이라 업무 외로 돌리지 않는다
        let grouped = Set(result.groups.flatMap { [$0.keep] + $0.merge })
        result.notGoals = Array(Set(parsed.notGoals ?? []).filter { known.contains($0) && !grouped.contains($0) }).sorted()
        guard !dry else { return result }
        let accepted = result.groups, notGoals = result.notGoals
        (result.merged, result.retired) = try await db.writer.write { conn in
            var merged = 0, retired = 0
            for group in accepted { merged += try merge(group, conn: conn, now: now) }
            for key in notGoals { if try retire(key, conn: conn, now: now) { retired += 1 } }
            return (merged, retired)
        }
        return result
    }

    /// 한 그룹 반영. 합친 업무 수를 돌려준다
    static func merge(_ group: Group, conn: Database, now: Double) throws -> Int {
        let tx = GraphTx(conn)
        guard let keep = try tx.node(label: NodeLabel.task, key: group.keep) else { return 0 }
        let pending = Set(try ProjectStore.proposals(conn).flatMap { $0.items.map(\.id) })
        guard !pending.contains("task:\(keep.id)") else { return 0 }
        var accumulated = keep.props
        var merged = 0
        var mergedKeys: [String] = []
        for key in group.merge {
            guard let victim = try tx.node(label: NodeLabel.task, key: key), victim.id != keep.id else { continue }
            guard !pending.contains("task:\(victim.id)") else { continue }
            let keepProject = try String.fetchOne(conn, sql: "SELECT project_id FROM project_tasks WHERE task_id = ?", arguments: [keep.id])
            let victimProject = try String.fetchOne(conn, sql: "SELECT project_id FROM project_tasks WHERE task_id = ?", arguments: [victim.id])
            if let keepProject, let victimProject, keepProject != victimProject { continue }
            if keepProject != victimProject,
               try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM project_reviewed WHERE item_id IN (?, ?) AND decision = 'manual')",
                                 arguments: ["task:\(keep.id)", "task:\(victim.id)"]) == true { continue }
            if keepProject == nil, let victimProject {
                try conn.execute(sql: "INSERT INTO project_tasks VALUES (?, ?)", arguments: [keep.id, victimProject])
            }
            // 행 판단
            try conn.execute(sql: "UPDATE observations SET task_id = ? WHERE task_id = ?", arguments: [keep.id, victim.id])
            try conn.execute(sql: "UPDATE chat_messages SET task_id = ? WHERE task_id = ?", arguments: [keep.id, victim.id])
            try conn.execute(sql: "UPDATE recordings SET task_id = ? WHERE task_id = ?", arguments: [keep.id, victim.id])
            // 세션, 나중에 할 일 → 남길 업무로. 주제는 겹치지 않는 것만
            // 같은 세션·할 일이 이미 남길 업무에도 걸려 있으면 그대로 둔다 (남은 연결은 아래에서 사라지는 업무와 함께 지운다)
            try conn.execute(sql: "UPDATE OR IGNORE edges SET dst = ? WHERE dst = ? AND type IN ('PART_OF', 'FOR')", arguments: [keep.id, victim.id])
            for edge in try tx.edges(from: victim.id, type: EdgeType.about) {
                try tx.upsertEdge(src: keep.id, dst: edge.dst, type: EdgeType.about, props: [:], addWeight: 0, at: edge.lastAt)
            }
            // 시간
            var props: [String: JSONValue] = [
                "active_seconds": .number((accumulated["active_seconds"]?.doubleValue ?? 0) + (victim.props["active_seconds"]?.doubleValue ?? 0)),
                "last_active": .number(max(accumulated["last_active"]?.doubleValue ?? 0, victim.props["last_active"]?.doubleValue ?? 0)),
            ]
            var tally = accumulated["project_seconds"]?.objectValue ?? [:]
            for (project, seconds) in victim.props["project_seconds"]?.objectValue ?? [:] {
                tally[project] = .number((tally[project]?.doubleValue ?? 0) + (seconds.doubleValue ?? 0))
            }
            if !tally.isEmpty { props["project_seconds"] = .object(tally) }
            try tx.setProps(nodeId: keep.id, props, at: now)
            accumulated.merge(props) { _, new in new }
            // 분야: 남는 업무에 없으면 사라지는 업무의 것을 받는다
            if try ThemeGraph.theme(ofTask: keep.id, tx) == nil, let theme = try ThemeGraph.theme(ofTask: victim.id, tx) {
                try ThemeGraph.attach(taskId: keep.id, to: theme.title, tx, now: now)
            }
            try ProjectStore.mergeTask(victim.id, into: keep.id, conn)
            try ConsolidationStore.mergeTask(from: victim.key, into: keep.key, now: now, conn)
            try conn.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [victim.id, victim.id])
            try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [victim.id])
            merged += 1
            mergedKeys.append(victim.key)
        }
        if let title = group.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != keep.title {
            try tx.upsertNode(label: NodeLabel.task, key: keep.key, subtype: nil, title: title, props: [:], at: now)
        }
        if let goal = group.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            try tx.setProps(nodeId: keep.id, ["goal": .string(goal)], at: now)
        }
        if merged > 0 {
            try ChatStore.moveFocus(from: mergedKeys, to: keep.key, title: try tx.node(label: NodeLabel.task, key: keep.key)?.title ?? keep.title, conn)
            try tx.rebindProjects(at: now)
            try ThemeGraph.pruneEmpty(tx)
        }
        return merged
    }

    /// 목표가 아닌 업무를 없앤다: 그 행들은 업무 외(판단 이유는 남김), 세션·나중에 할 일과 이제 아무 데도 안 걸린 주제·문제는 지운다
    public static func retire(_ key: String, conn: Database, now: Double) throws -> Bool {
        let tx = GraphTx(conn)
        guard let task = try tx.node(label: NodeLabel.task, key: key) else { return false }
        try conn.execute(sql: "UPDATE observations SET task_id = NULL, off_task = 1, resource_relevant = 0 WHERE task_id = ?", arguments: [task.id])
        try conn.execute(sql: "UPDATE chat_messages SET task_id = NULL WHERE task_id = ?", arguments: [task.id])
        try conn.execute(sql: "UPDATE recordings SET task_id = NULL WHERE task_id = ?", arguments: [task.id])
        let sessions = try Int64.fetchAll(conn, sql: "SELECT src FROM edges WHERE dst = ? AND type = ?", arguments: [task.id, EdgeType.partOf])
        let laterItems = try Int64.fetchAll(conn, sql: "SELECT src FROM edges WHERE dst = ? AND type = ?", arguments: [task.id, EdgeType.forTask])
        var leftovers = try Int64.fetchAll(conn, sql: "SELECT dst FROM edges WHERE src = ? AND type = ?", arguments: [task.id, EdgeType.about])
        for session in sessions {
            leftovers += try Int64.fetchAll(conn, sql: "SELECT dst FROM edges WHERE src = ? AND type = ?", arguments: [session, EdgeType.hit])
        }
        // 프로젝트 연결·제안·분류 기록에서도 뺀다
        try conn.execute(sql: "DELETE FROM project_tasks WHERE task_id = ?", arguments: [task.id])
        try conn.execute(sql: "DELETE FROM project_reviewed WHERE item_id = ?", arguments: ["task:\(task.id)"])
        try ProjectStore.removeFromProposals("task:\(task.id)", conn)
        try ConsolidationStore.retireTask(task.key, conn)
        let doomed = (sessions + laterItems + [task.id]).map(String.init).joined(separator: ",")
        try conn.execute(sql: "DELETE FROM edges WHERE src IN (\(doomed)) OR dst IN (\(doomed))")
        try conn.execute(sql: "DELETE FROM nodes WHERE id IN (\(doomed))")
        for id in Set(leftovers) {
            let links = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges WHERE src = ? OR dst = ?", arguments: [id, id]) ?? 0
            if links == 0 { try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id]) }
        }
        try ThemeGraph.pruneEmpty(tx)
        _ = try tx.pruneOrphanResources()
        try tx.rebindProjects(at: now)
        return true
    }
}
