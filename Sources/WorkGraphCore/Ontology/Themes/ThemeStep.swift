import Foundation

/// 테마 단계: 분야가 없는 업무에 분야를, 종류가 옛 판으로 붙은 업무에 종류를 붙인다 (정리 뒤·앱 시작)
public enum ThemeStep {
    /// 판정할 업무
    public struct Target: Equatable, Sendable {
        public var key: String
        public var title: String
        public var goal: String?
        public var taskType: String?
        public var recent: [String]
        public var needsTheme: Bool
        public var needsType: Bool

        public init(key: String, title: String, goal: String?, taskType: String?, recent: [String], needsTheme: Bool, needsType: Bool) {
            self.key = key; self.title = title; self.goal = goal; self.taskType = taskType; self.recent = recent
            self.needsTheme = needsTheme; self.needsType = needsType
        }
    }

    /// 분야 목록의 한 줄: 이름과 거기 속한 업무 제목
    public struct ThemeLine: Equatable, Sendable {
        public var name: String
        public var tasks: [String]
        public init(name: String, tasks: [String]) { self.name = name; self.tasks = tasks }
    }

    /// 업무 하나에 대한 답 (해석한 뒤: 이름은 공백 정리, 종류는 고를 수 있는 이름)
    public struct Answer: Equatable, Sendable {
        public var theme: String?
        public var taskType: String?
        public init(theme: String?, taskType: String?) { self.theme = theme; self.taskType = taskType }
    }

    public struct Outcome: Equatable, Sendable {
        public var themed = 0
        public var retyped = 0
        public var created: [String] = []
        /// 받아들이지 않은 답 (다음 기회에 다시 묻는다)
        public var skipped = 0
        public init() {}
    }

    public static var tool: ToolSpec {
        ToolSpec(name: "assign_themes", description: "Assign a theme, and a task type when asked, to every task.", parameters: .object([
            "type": "object",
            "properties": .object(["tasks": .object(["type": "array", "description": "받은 업무를 빠짐없이", "items": .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "TASKS 의 id"]),
                    "theme": .object(["type": "string", "description": "NEEDS_THEME 일 때: 분야 이름 (짧은 한국어 명사구)"]),
                    "new_theme": .object(["type": "boolean", "description": "THEMES·DEFAULT_THEMES 에 없는 새 분야면 true"]),
                    "task_type": .object(["type": "string", "enum": .array(TBox.leafTaskTypes.map { .string($0) }), "description": "NEEDS_TYPE 일 때"]),
                ]),
                "required": .array(["id"]),
            ])])]),
            "required": .array(["tasks"]),
        ]))
    }

    public static let system = """
    You place each of the user's tasks in a broad area of their life (a theme), for a personal work graph.

    You receive:
    - THEMES: the themes the user already has, each with titles of its tasks. DEFAULT_THEMES: starting themes not used yet. SLOTS: how many more themes may be created.
    - TASKS: each task's id, what it needs (NEEDS_THEME, NEEDS_TYPE), title, what it is for (`goal:`), current type and what was done recently.
    - TASK_TYPES: the allowed task types, only when a task needs a type.

    Themes (NEEDS_THEME):
    - A theme is a broad area that holds many different goals over time. Choose the theme that the task's goal belongs to, judged from its goal and recent work, not from the app or site used.
    - Reuse a theme from THEMES whenever the task fits it. Otherwise choose a fitting theme from DEFAULT_THEMES.
    - Create a new theme only when nothing in THEMES or DEFAULT_THEMES fits, and only for a broad area that can hold several different goals; set new_theme to true. A single goal, a single company, a single course or a single project is never a theme.
    - Choosing an unused default theme or creating a new one each takes a slot. When SLOTS is 0, choose the closest theme in THEMES.
    - A theme name is a short Korean noun phrase.

    Task types (NEEDS_TYPE): choose from TASK_TYPES the kind of activity the task mostly is.

    Answer every task exactly once, by its id. Give theme only to NEEDS_THEME tasks and task_type only to NEEDS_TYPE tasks.
    Always answer by calling assign_themes. Do not write prose.
    """

    public static func user(targets: [Target], themes: [ThemeLine]) -> String {
        var lines = ["THEMES:"]
        if themes.isEmpty { lines.append("(none)") }
        for theme in themes {
            let tasks = theme.tasks.prefix(5).map { OntologyPrompt.clip($0, 60) }.joined(separator: "; ")
            lines.append(tasks.isEmpty ? "- \(theme.name)" : "- \(theme.name) | tasks: \(tasks)")
        }
        let used = Set(themes.map { ThemeCatalog.matchKey($0.name) })
        let unused = ThemeCatalog.defaults.filter { !used.contains(ThemeCatalog.matchKey($0)) }
        lines.append("DEFAULT_THEMES (not used yet): " + (unused.isEmpty ? "(none)" : unused.joined(separator: ", ")))
        lines.append("SLOTS: \(max(0, ThemeCatalog.limit - themes.count))")
        if targets.contains(where: \.needsType) { lines.append("TASK_TYPES: " + TBox.leafTaskTypes.joined(separator: ", ")) }
        lines.append("TASKS:")
        for target in targets {
            var needs: [String] = []
            if target.needsTheme { needs.append("NEEDS_THEME") }
            if target.needsType { needs.append("NEEDS_TYPE") }
            var line = "- id=\(target.key) | \(needs.joined(separator: ", ")) | \(OntologyPrompt.clip(target.title, 90))"
            if let goal = target.goal, !goal.isEmpty { line += " | goal: \(OntologyPrompt.clip(goal, 140))" }
            if let type = target.taskType { line += " | type: \(type)" }
            if !target.recent.isEmpty { line += " | recent: " + target.recent.prefix(3).map { OntologyPrompt.clip($0, 100) }.joined(separator: "; ") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 답 해석. 중첩 JSON 문자열을 풀고, 이름은 공백 정리, 종류는 고를 수 있는 이름으로 맞춘다 (못 맞추면 nil)
    public static func decode(_ data: Data) -> [String: Answer] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = AssignmentPatch.unwrapStrings(parsed) as? [String: Any] else { return [:] }
        var answers: [String: Answer] = [:]
        for entry in root["tasks"] as? [[String: Any]] ?? [] {
            guard let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { continue }
            let theme = (entry["theme"] as? String).map(ThemeCatalog.normalize).flatMap { $0.isEmpty ? nil : $0 }
            let type = (entry["task_type"] as? String).flatMap(TBox.leafType)
            answers[id] = Answer(theme: theme, taskType: type)
        }
        return answers
    }

    /// 대상 업무와 분야 목록. retypeAll 이면 판과 상관없이 모든 활성 업무의 종류를 다시 묻는다
    public static func load(_ tx: GraphTx, retypeAll: Bool = false) throws -> (targets: [Target], themes: [ThemeLine]) {
        var targets: [Target] = [], members: [Int64: [String]] = [:]
        for digest in try tx.openTasks(limit: 10_000) {
            guard let node = try tx.node(label: NodeLabel.task, key: digest.id) else { continue }
            let theme = try ThemeGraph.theme(ofTask: node.id, tx)
            if let theme { members[theme.id, default: []].append(digest.title) }
            let version = Int(node.props["type_version"]?.doubleValue ?? 0)
            let needsType = retypeAll || version < TBox.version
            guard theme == nil || needsType else { continue }
            targets.append(Target(key: digest.id, title: digest.title, goal: digest.goal, taskType: digest.taskType,
                                  recent: digest.recentSummaries, needsTheme: theme == nil, needsType: needsType))
        }
        let themes = try tx.nodes(label: NodeLabel.theme).map { ThemeLine(name: $0.title, tasks: members[$0.id] ?? []) }
        return (targets, themes)
    }

    /// LLM 호출 한 번 (기록하지 않음)
    public static func judge(targets: [Target], themes: [ThemeLine], llm: any LLMClient) async throws -> [String: Answer] {
        let result = try await llm.callFunction(system: system, user: user(targets: targets, themes: themes), tool: tool)
        return decode(result.arguments)
    }

    /// 답을 반영한다. 받아들이지 않는 답(대상에 없는 id, 빈·긴 이름, 자리 초과, 모르는 종류, 분야가 이미 있는 업무의 분야)은 건너뛴다
    public static func apply(_ answers: [String: Answer], targets: [Target], _ tx: GraphTx, now: Double) throws -> Outcome {
        var outcome = Outcome()
        for target in targets {
            guard let node = try tx.node(label: NodeLabel.task, key: target.key) else { continue }
            let answer = answers[target.key]
            // 새 연결은 업무의 마지막 활동 시각으로 남긴다 (옛 업무를 최근 활동처럼 보이게 하지 않는다)
            let stamp = node.props["last_active"]?.doubleValue ?? node.updatedAt
            if target.needsTheme {
                if let name = answer?.theme, let attached = try ThemeGraph.attach(taskId: node.id, to: name, tx, now: now, linkedAt: stamp) {
                    outcome.themed += 1
                    if attached.created { outcome.created.append(attached.node.title) }
                } else {
                    outcome.skipped += 1
                }
            }
            if target.needsType {
                if let type = answer?.taskType, let typeNode = try tx.node(label: NodeLabel.taskType, key: type) {
                    let edges = try tx.edges(from: node.id, type: EdgeType.instanceOf)
                    let previous = try edges.compactMap { try tx.node(id: $0.dst)?.title }.first
                    for edge in edges { try tx.deleteEdge(id: edge.id) }
                    try tx.upsertEdge(src: node.id, dst: typeNode.id, type: EdgeType.instanceOf, props: [:], addWeight: 0, at: stamp, countHit: false)
                    // 판과 이전 종류(되돌릴 때 쓴다)만 남기고 업무의 갱신 시각은 그대로 둔다 (그래프 뷰·대화 검색이 최근 활동으로 보지 않게)
                    var patch: [String: JSONValue] = ["type_version": .number(Double(TBox.version))]
                    if let previous { patch["previous_type"] = .string(previous) }
                    try tx.db.execute(sql: "UPDATE nodes SET props = json_patch(props, ?) WHERE id = ?", arguments: [JSONValue.encodeObject(patch), node.id])
                    outcome.retyped += 1
                } else {
                    outcome.skipped += 1
                }
            }
        }
        try ThemeGraph.pruneEmpty(tx)
        return outcome
    }

    /// 한 번 돈다. 대상이 없으면 호출하지 않고 nil
    public static func run(db: WGDatabase, llm: any LLMClient, now: Double, retypeAll: Bool = false) async throws -> Outcome? {
        let loaded = try await db.writer.write { conn -> (targets: [Target], themes: [ThemeLine]) in
            let tx = GraphTx(conn)
            // 다른 경로로 업무가 지워져 빈 분야가 남았을 수 있다
            try ThemeGraph.pruneEmpty(tx)
            return try load(tx, retypeAll: retypeAll)
        }
        guard !loaded.targets.isEmpty else { return nil }
        let answers = try await judge(targets: loaded.targets, themes: loaded.themes, llm: llm)
        return try await db.writer.write { conn in try apply(answers, targets: loaded.targets, GraphTx(conn), now: now) }
    }
}
