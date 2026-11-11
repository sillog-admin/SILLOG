import Foundation
import GRDB

/// 정리 제안 하나 (하루 한 번 다시 보기). 사용자가 고른 것만 반영한다
public struct ReviewProposal: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case mergeTasks, retireTask, mergeTopics, laterDone, laterDrop, mergeProblems, joinSessions
    }

    /// 반영에 쓰는 값. 업무는 노드 키, 그 밖은 노드 키 (짧은 세션 붙이기는 [짧은 세션 키, 붙일 세션 키] 쌍). names: 키 → 보이는 이름 (줄 글을 다시 쓸 때)
    public struct Payload: Codable, Equatable, Sendable {
        public var keep: String?
        public var merge: [String] = []
        public var title: String?
        public var goal: String?
        public var key: String?
        public var moves: [[String]] = []
        public var names: [String: String]?
    }

    public var id: Int64?
    public var kind: Kind
    /// 시트 한 줄: "Sillog 앱 기능·UI 고도화 ← Sillog 파이프라인…, …"
    public var summary: String
    public var payload: Payload
    public var status = "pending"

    public static func make(_ kind: Kind, _ payload: Payload) -> ReviewProposal {
        ReviewProposal(kind: kind, summary: summary(kind, payload), payload: payload)
    }

    /// 줄 글: 합치기는 "남길 것 ← 합칠 것, …" (업무 이름을 바꾸면 "지금 이름 → 새 이름"), 할 일·업무 외는 그 이름
    public static func summary(_ kind: Kind, _ p: Payload) -> String {
        func name(_ key: String?) -> String { key.map { p.names?[$0] ?? $0 } ?? "" }
        switch kind {
        case .mergeTasks:
            let head = p.title.map { "\(name(p.keep)) → \($0)" } ?? name(p.keep)
            return p.merge.isEmpty ? head : "\(head) ← \(p.merge.map(name).joined(separator: ", "))"
        case .mergeTopics, .mergeProblems: return "\(name(p.keep)) ← \(p.merge.map(name).joined(separator: ", "))"
        case .retireTask, .laterDone, .laterDrop: return name(p.key)
        case .joinSessions: return "1분 미만 세션 \(p.moves.count)개를 같은 날 세션에 붙이기"
        }
    }

    /// 거절을 기억하는 단위: 합치기는 짝마다(순서 무관), 업무 이름 바꾸기, 할 일·업무 외는 키, 짧은 세션은 세션마다.
    /// 다음에 묶음이 달라져도 거절한 짝은 다시 묻지 않는다
    public var units: [String] {
        let p = payload
        switch kind {
        case .mergeTasks, .mergeTopics, .mergeProblems:
            guard let keep = p.keep else { return [] }
            var units = p.merge.map { Self.pair(kind, keep, $0) }
            if kind == .mergeTasks, let title = p.title { units.append("rename|\(keep)|\(title)") }
            return units
        case .retireTask, .laterDone, .laterDrop: return p.key.map { ["\(kind.rawValue)|\($0)"] } ?? []
        case .joinSessions: return p.moves.compactMap { $0.first.map { "\(kind.rawValue)|\($0)" } }
        }
    }

    static func pair(_ kind: Kind, _ a: String, _ b: String) -> String { "\(kind.rawValue)|\(min(a, b))|\(max(a, b))" }

    /// 거절한 단위를 뺀 제안 (남는 것이 없으면 nil). 바뀌었으면 줄 글을 다시 쓴다
    public func without(_ dismissed: Set<String>) -> ReviewProposal? {
        guard !dismissed.isEmpty else { return self }
        var p = payload
        switch kind {
        case .mergeTasks, .mergeTopics, .mergeProblems:
            guard let keep = p.keep else { return nil }
            p.merge = p.merge.filter { !dismissed.contains(Self.pair(kind, keep, $0)) }
            if let title = p.title, dismissed.contains("rename|\(keep)|\(title)") { p.title = nil }
            if p.merge.isEmpty && (kind != .mergeTasks || p.title == nil) { return nil }
        case .retireTask, .laterDone, .laterDrop:
            if units.contains(where: dismissed.contains) { return nil }
        case .joinSessions:
            p.moves = p.moves.filter { !dismissed.contains("\(kind.rawValue)|\($0.first ?? "")") }
            if p.moves.isEmpty { return nil }
        }
        guard p != payload else { return self }
        var copy = self
        copy.payload = p
        copy.summary = Self.summary(kind, p)
        return copy
    }
}

/// 정리 제안 저장 (review_proposals). 새 제안을 받으면 대기 중인 것을 갈아 끼우고, 예전에 거절한 단위(ReviewProposal.units)는 빼고 넣는다.
/// 반영한 것은 막지 않는다 (같은 제안이 또 나오면 같은 일이 다시 생긴 것). signature 칸에 단위를 줄마다 하나씩 둔다
public struct ReviewStore: Sendable {
    let db: SillogDatabase
    public init(_ db: SillogDatabase) { self.db = db }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18-review-proposals") { conn in
            try conn.execute(sql: """
                CREATE TABLE IF NOT EXISTS review_proposals (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  kind TEXT NOT NULL,
                  summary TEXT NOT NULL,
                  payload TEXT NOT NULL,
                  signature TEXT NOT NULL,
                  status TEXT NOT NULL DEFAULT 'pending',
                  created_at REAL NOT NULL,
                  decided_at REAL
                );
                CREATE INDEX IF NOT EXISTS idx_review_proposals_status ON review_proposals(status, signature);
                """)
        }
    }

    /// Returns: 새로 생긴 제안 수 (갈아 끼우기 전 대기 중이던 제안에 없던 단위가 있는 것. 알림은 이것이 있을 때만)
    @discardableResult
    public func replacePending(with proposals: [ReviewProposal], now: Double) throws -> Int {
        try db.writer.write { conn in
            let before = Set(try String.fetchAll(conn, sql: "SELECT signature FROM review_proposals WHERE status = 'pending'")
                .flatMap { $0.components(separatedBy: "\n") })
            try conn.execute(sql: "DELETE FROM review_proposals WHERE status = 'pending'")
            let dismissed = Set(try String.fetchAll(conn, sql: "SELECT signature FROM review_proposals WHERE status = 'dismissed'")
                .flatMap { $0.components(separatedBy: "\n") })
            var fresh = 0
            for proposal in proposals.compactMap({ $0.without(dismissed) }) {
                let payload = String(decoding: try JSONEncoder().encode(proposal.payload), as: UTF8.self)
                try conn.execute(sql: "INSERT INTO review_proposals(kind, summary, payload, signature, created_at) VALUES (?, ?, ?, ?, ?)",
                                 arguments: [proposal.kind.rawValue, proposal.summary, payload, proposal.units.joined(separator: "\n"), now])
                if !proposal.units.allSatisfy(before.contains) { fresh += 1 }
            }
            return fresh
        }
    }

    public func pending() throws -> [ReviewProposal] {
        try db.writer.read { conn in
            try Row.fetchAll(conn, sql: "SELECT * FROM review_proposals WHERE status = 'pending' ORDER BY id").compactMap { row in
                guard let kind = ReviewProposal.Kind(rawValue: row["kind"]),
                      let payload = try? JSONDecoder().decode(ReviewProposal.Payload.self, from: Data((row["payload"] as String).utf8)) else { return nil }
                return ReviewProposal(id: row["id"], kind: kind, summary: row["summary"], payload: payload, status: row["status"])
            }
        }
    }

    public func decide(applied: [Int64], dismissed: [Int64], now: Double) throws {
        try db.writer.write { conn in
            try Self.mark(conn, applied, "applied", now)
            try Self.mark(conn, dismissed, "dismissed", now)
        }
    }

    /// 고른 것을 반영하고 표시한다 (열린 트랜잭션 하나에서, 반영과 표시가 같이 남거나 같이 사라지게).
    /// 반영한 것은 applied, 대상이 이미 없어 못 한 것은 skipped (다음에 다시 물을 수 있다), 안 고른 것은 dismissed. Returns: 반영한 수
    public static func apply(_ conn: Database, chosen: [ReviewProposal], dismissed: [Int64], now: Double) throws -> Int {
        let results = try WeeklyReview.apply(chosen, conn: conn, now: now)
        let done = zip(chosen, results).filter(\.1).compactMap(\.0.id)
        try mark(conn, done, "applied", now)
        try mark(conn, zip(chosen, results).filter { !$0.1 }.compactMap(\.0.id), "skipped", now)
        try mark(conn, dismissed, "dismissed", now)
        return done.count
    }

    static func mark(_ conn: Database, _ ids: [Int64], _ status: String, _ now: Double) throws {
        guard !ids.isEmpty else { return }
        try conn.execute(sql: "UPDATE review_proposals SET status = ?, decided_at = ? WHERE id IN (\(ids.map(String.init).joined(separator: ",")))",
                         arguments: [status, now])
    }
}

/// 하루 한 번 다시 보기: 정리해 둔 그래프 전체를 다시 보고 제안을 만든다 (AI 호출 2번: 업무 합치기, 주제·나중에 할 일·문제 정리)
///   - 업무 합치기: TaskMerger 를 전체 기간(60일)으로, 한 제품의 다른 이름·부분 작업을 같은 목표로 보는 규칙을 더해서
///   - 주제: 같은 뜻을 다르게 쓴 것끼리 ("그래프 시각화" ← "3D 그래프 시각화")
///   - 나중에 할 일: 날짜가 지난 것은 끝, 사용자 할 일이 아닌 것(AI 에게 한 부탁, 앱 자체에 대한 메모)은 지움
///   - 문제: 같은 오류를 다르게 적은 것끼리
///   - 짧은 세션: 1분 미만 세션을 같은 날 같은 업무의 세션에 (AI 없이)
public enum WeeklyReview {
    /// 업무 합치기에 더하는 규칙 (자동 합치기에는 넣지 않는다: 이 규칙으로 합친 것은 사용자가 고를 때만 반영)
    public static let taskRules = """

    The user reviews every merge before it is applied, so propose a merge whenever two tasks are more likely than not the same goal; a missed merge leaves the user's work split across tasks.
    Also treat these as the same goal:
    - different names of one product or codebase: an app's name and its repository, folder or code name. Tasks whose work happened in the same project folder (`folders:`) are one product unless their goals name clearly different deliverables
    - a product and its parts: one of its features or screens, its design, its releases (commits, PRs, merges), its issue board or sprint, the tools and subscriptions bought for it. A task named after one feature of an app the user is building belongs to that app, even when its field differs.
    """

    static let tidySystem = """
    You tidy a personal work graph that an assistant filled over several weeks. Answer only with what should change; leaving things alone is normal.

    You receive:
    - NOW: the current date.
    - TOPICS: id | name | tasks that use it | times seen. Topics say what work is about.
    - LATER: id | to-do text | task | when it was noted.
    - PROBLEMS: id | what went wrong | kind | task | when.

    Do this:
    1. topic_groups: topics that are the same concept written differently: a narrower wording that means the same thing in this graph ("3D 그래프 시각화", "인터랙티브 그래프 시각화" → "그래프 시각화"), spelling or spacing variants, a Korean and an English name of one concept. keep = the clearest general name, usually the one used most. Do not group related but different concepts (React and Next.js, 선형대수 and 확률).
    2. later: to-dos to close. "done" when the date or deadline in the text is before NOW. "drop" when it is not the user's own to-do: a request the user made to an AI assistant, a remark about the assistant or this app's data, a general notice. Leave the rest out.
    3. problem_groups: problems that are the same error or blocker described differently. keep = the clearest description.
    Use only the given ids. Always answer by calling tidy_graph.
    """

    static var tidyTool: ToolSpec {
        let group: JSONValue = .object(["type": "array", "items": .object([
            "type": "object",
            "properties": .object(["keep": .object(["type": "string"]), "merge": .object(["type": "array", "items": .object(["type": "string"])])]),
            "required": .array(["keep", "merge"]),
        ])])
        return ToolSpec(name: "tidy_graph", description: "Topics and problems to merge, to-dos to close.", parameters: .object([
            "type": "object",
            "properties": .object([
                "topic_groups": group,
                "later": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["id": .object(["type": "string"]), "action": .object(["type": "string", "enum": .array(["done", "drop"])])]),
                    "required": .array(["id", "action"]),
                ])]),
                "problem_groups": group,
            ]),
            "required": .array(["topic_groups", "later", "problem_groups"]),
        ]))
    }

    struct TidyAnswer: Decodable {
        struct Group: Decodable { var keep: String; var merge: [String] }
        struct Later: Decodable { var id: String; var action: String }
        var topicGroups: [Group]?
        var later: [Later]?
        var problemGroups: [Group]?
        enum CodingKeys: String, CodingKey { case topicGroups = "topic_groups", later, problemGroups = "problem_groups" }
    }

    /// 짧은 세션(활동 이 초 미만)
    static let shortSession: Double = 60

    /// Returns: 제안 (업무 → 업무 외 → 주제 → 나중에 할 일 → 문제 → 짧은 세션 순). 주제·문제 정리 호출이 실패하면 그 부분만 빼고 돌려준다.
    /// Raises: 업무 합치기 호출·DB 오류
    public static func plan(db: SillogDatabase, llm: any LLMClient, now: Double, calendar: Calendar = .current) async throws -> [ReviewProposal] {
        var proposals: [ReviewProposal] = []
        let titles = try await db.writer.read { conn in
            Dictionary(try GraphTx(conn).nodes(label: NodeLabel.task).map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        let merged = try await TaskMerger.run(db: db, llm: llm, since: now - 60 * 86_400, now: now, dry: true, extraRules: taskRules)
        for group in merged.groups {
            let title = group.title == titles[group.keep] ? nil : group.title       // 제목을 그대로 돌려주면 바꾸지 않는다
            guard !group.merge.isEmpty || title != nil else { continue }
            let names = Dictionary(([group.keep] + group.merge).map { ($0, titles[$0] ?? $0) }, uniquingKeysWith: { first, _ in first })
            proposals.append(.make(.mergeTasks, .init(keep: group.keep, merge: group.merge, title: title, goal: group.goal, names: names)))
        }
        for key in merged.notGoals {
            proposals.append(.make(.retireTask, .init(key: key, names: [key: titles[key] ?? key])))
        }

        let (prompt, keys, names) = try await db.writer.read { try tidyPrompt($0, now: now, calendar: calendar) }
        if !keys.isEmpty {
            do {
                let answer = try await llm.callFunction(system: tidySystem, user: prompt, tool: tidyTool)
                if let tidy = try? JSONDecoder().decode(TidyAnswer.self, from: answer.arguments) {
                    func group(_ g: TidyAnswer.Group, _ prefix: String) -> ReviewProposal.Payload? {
                        guard g.keep.hasPrefix(prefix), let keep = keys[g.keep] else { return nil }
                        let merge = g.merge.filter { $0.hasPrefix(prefix) && $0 != g.keep }.compactMap { keys[$0] }
                        let shown = Dictionary(([keep] + merge).map { ($0, names[prefix + $0] ?? $0) }, uniquingKeysWith: { first, _ in first })
                        return merge.isEmpty ? nil : .init(keep: keep, merge: merge, names: shown)
                    }
                    for g in tidy.topicGroups ?? [] { if let p = group(g, "T") { proposals.append(.make(.mergeTopics, p)) } }
                    for item in tidy.later ?? [] {
                        guard item.id.hasPrefix("L"), let key = keys[item.id], let kind: ReviewProposal.Kind = item.action == "done" ? .laterDone : item.action == "drop" ? .laterDrop : nil else { continue }
                        proposals.append(.make(kind, .init(key: key, names: [key: names["L" + key] ?? key])))
                    }
                    for g in tidy.problemGroups ?? [] { if let p = group(g, "P") { proposals.append(.make(.mergeProblems, p)) } }
                }
            } catch {
                AppLog.write("정리 제안: 주제·할 일·문제 정리 실패, 업무 합치기만 제안 (\("\(error)"))")
            }
        }
        // 종류 순서대로 모은다 (시트에서 묶음으로 보이게. 같은 종류 안은 받은 순서)
        proposals = ReviewProposal.Kind.allCases.flatMap { kind in proposals.filter { $0.kind == kind } }

        let moves = try await db.writer.read { try sessionMoves($0, calendar: calendar) }
        if !moves.isEmpty {
            proposals.append(.make(.joinSessions, .init(moves: moves.map { [$0.short, $0.target] })))
        }
        return proposals
    }

    /// AI 에 보낼 목록. 짧은 id(T·L·P + 노드 id)를 쓰고, keys 는 id → 노드 키, names 는 접두어+키 → 이름
    /// 목록이 길면 주제는 많이 쓴 것, 할 일·문제는 최근 것부터 limits 개만 (프롬프트가 한없이 커지지 않게)
    static func tidyPrompt(_ conn: Database, now: Double, calendar: Calendar,
                           limits: (topics: Int, later: Int, problems: Int) = (800, 200, 200)) throws -> (String, [String: String], [String: String]) {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        func date(_ ts: Double?) -> String { ts.map { day.string(from: Date(timeIntervalSince1970: $0)) } ?? "-" }
        var keys: [String: String] = [:], names: [String: String] = [:]
        var lines = ["NOW: \(date(now))", "TOPICS (id | name | tasks | times seen):"]
        for row in try Row.fetchAll(conn, sql: """
            SELECT n.id, n.key, n.title, COUNT(e.id) AS tasks, COALESCE(SUM(e.hits), 0) AS seen FROM nodes n
            JOIN edges e ON e.dst = n.id AND e.type = 'ABOUT' WHERE n.label = 'Topic' GROUP BY n.id ORDER BY seen DESC, tasks DESC, n.id LIMIT ?
            """, arguments: [limits.topics]).sorted(by: { ($0["title"] as String) < ($1["title"] as String) }) {     // 비슷한 이름이 붙어 보이게
            let id = "T\(row["id"] as Int64)"
            keys[id] = row["key"]; names["T" + (row["key"] as String)] = row["title"]
            lines.append("\(id) | \(OntologyPrompt.clip(row["title"], 60)) | \(row["tasks"] as Int) | \(row["seen"] as Int)")
        }
        lines.append("LATER (id | to-do | task | noted):")
        for row in try Row.fetchAll(conn, sql: """
            SELECT n.id, n.key, n.title, n.props, n.created_at, t.title AS task FROM nodes n
            LEFT JOIN edges e ON e.src = n.id AND e.type = 'FOR' LEFT JOIN nodes t ON t.id = e.dst
            WHERE n.label = 'LaterItem' AND COALESCE(json_extract(n.props, '$.done'), 0) = 0
            ORDER BY COALESCE(json_extract(n.props, '$.at'), n.created_at) DESC, n.id DESC LIMIT ?
            """, arguments: [limits.later]).reversed() {
            let id = "L\(row["id"] as Int64)"
            keys[id] = row["key"]; names["L" + (row["key"] as String)] = row["title"]
            let props = (row["props"] as String?).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8)) } ?? [:]
            lines.append("\(id) | \(OntologyPrompt.clip(row["title"], 140)) | \(OntologyPrompt.clip((row["task"] as String?) ?? "-", 40)) | \(date(props["at"]?.doubleValue ?? row["created_at"]))")
        }
        lines.append("PROBLEMS (id | what went wrong | kind | task | when):")
        for row in try Row.fetchAll(conn, sql: """
            SELECT n.id, n.key, n.title, n.subtype, n.created_at, MIN(t.title) AS task FROM nodes n
            LEFT JOIN edges h ON h.dst = n.id AND h.type = 'HIT' LEFT JOIN edges p ON p.src = h.src AND p.type = 'PART_OF' LEFT JOIN nodes t ON t.id = p.dst
            WHERE n.label = 'Problem' GROUP BY n.id ORDER BY n.created_at DESC, n.id DESC LIMIT ?
            """, arguments: [limits.problems]).reversed() {
            let id = "P\(row["id"] as Int64)"
            keys[id] = row["key"]; names["P" + (row["key"] as String)] = row["title"]
            lines.append("\(id) | \(OntologyPrompt.clip(row["title"], 140)) | \((row["subtype"] as String?) ?? "-") | \(OntologyPrompt.clip((row["task"] as String?) ?? "-", 40)) | \(date(row["created_at"]))")
        }
        return (lines.joined(separator: "\n"), keys, names)
    }

    /// 짧은 세션 → 같은 날 같은 업무의 가장 가까운 (짧지 않은) 세션
    static func sessionMoves(_ conn: Database, calendar: Calendar) throws -> [(short: String, target: String)] {
        let rows = try Row.fetchAll(conn, sql: """
            SELECT s.key FROM nodes s JOIN edges e ON e.src = s.id AND e.type = 'PART_OF' WHERE s.label = 'Session' AND json_extract(s.props, '$.start') IS NOT NULL
            """)
        let tx = GraphTx(conn)
        let sessions = try rows.compactMap { try span(tx, key: $0["key"]) }
        let byTask = Dictionary(grouping: sessions, by: \.task)
        var moves: [(String, String)] = []
        for short in sessions where short.active < shortSession {
            let targets = (byTask[short.task] ?? []).filter { joinable(short, into: $0, calendar: calendar) }
            func distance(_ s: Span) -> Double { short.start < s.start ? s.start - short.start : short.start > s.end ? short.start - s.end : 0 }
            if let target = targets.min(by: { distance($0) < distance($1) }) { moves.append((short.key, target.key)) }
        }
        return moves.sorted { $0.0 < $1.0 }
    }

    struct Span { let key: String; let task: Int64; let start: Double; let end: Double; let active: Double }

    static func span(_ tx: GraphTx, key: String) throws -> Span? {
        guard let node = try tx.node(label: NodeLabel.session, key: key), let start = node.props["start"]?.doubleValue,
              let task = try tx.edges(from: node.id, type: EdgeType.partOf).first?.dst else { return nil }
        return Span(key: key, task: task, start: start, end: node.props["end"]?.doubleValue ?? start, active: node.props["active_seconds"]?.doubleValue ?? 0)
    }

    /// 짧은 세션을 붙여도 되는지: 아직 짧고, 같은 업무이고, 같은 날 시작한 짧지 않은 세션 (제안할 때와 반영할 때 같은 기준)
    static func joinable(_ short: Span, into target: Span, calendar: Calendar) -> Bool {
        short.key != target.key && short.active < shortSession && target.active >= shortSession && short.task == target.task
            && calendar.isDate(Date(timeIntervalSince1970: short.start), inSameDayAs: Date(timeIntervalSince1970: target.start))
    }

    /// 고른 제안을 반영한다 (열린 트랜잭션 안에서). 앞 제안에서 합쳐져 사라진 노드는 남은 노드로 따라간다.
    /// Returns: 제안마다 반영했는지 (대상이 이미 없거나 바뀌어 아무것도 안 했으면 false)
    @discardableResult
    public static func apply(_ proposals: [ReviewProposal], conn: Database, now: Double, calendar: Calendar = .current) throws -> [Bool] {
        let tx = GraphTx(conn)
        var gone: [String: String] = [:]                       // "종류|합쳐져 사라진 키" → 남은 키
        func follow(_ label: String, _ key: String) -> String {
            var key = key, seen: Set<String> = []
            while let next = gone["\(label)|\(key)"], seen.insert(key).inserted { key = next }
            return key
        }
        func folded(_ label: String, _ p: ReviewProposal.Payload) -> (keep: String, merge: [String])? {
            guard let raw = p.keep else { return nil }
            let keep = follow(label, raw)
            var merge: [String] = []
            for key in p.merge.map({ follow(label, $0) }) where key != keep && !merge.contains(key) { merge.append(key) }
            return (keep, merge)
        }
        func remember(_ label: String, _ keep: String, _ merge: [String]) { for key in merge { gone["\(label)|\(key)"] = keep } }

        return try proposals.map { proposal in
            let p = proposal.payload
            switch proposal.kind {
            case .mergeTasks:
                guard let (keep, merge) = folded(NodeLabel.task, p), let before = try tx.node(label: NodeLabel.task, key: keep) else { return false }
                let left = try merge.filter { try tx.node(label: NodeLabel.task, key: $0) != nil }
                let merged = try TaskMerger.merge(TaskMerger.Group(keep: keep, merge: merge, title: p.title, goal: p.goal), conn: conn, now: now)
                let gone = try left.filter { try tx.node(label: NodeLabel.task, key: $0) == nil }
                remember(NodeLabel.task, keep, gone)
                let after = try tx.node(label: NodeLabel.task, key: keep)?.title
                return merged > 0 || after != before.title
            case .retireTask:
                guard let key = p.key else { return false }
                return try TaskMerger.retire(follow(NodeLabel.task, key), conn: conn, now: now)
            case .mergeTopics, .mergeProblems:
                let label = proposal.kind == .mergeTopics ? NodeLabel.topic : NodeLabel.problem
                guard let (keep, merge) = folded(label, p), try fold(label: label, keep: keep, merge: merge, conn: conn) else { return false }
                remember(label, keep, merge)
                return true
            case .laterDone:
                guard let key = p.key, let item = try tx.node(label: NodeLabel.laterItem, key: key) else { return false }
                try tx.setProps(nodeId: item.id, ["done": .bool(true)], at: now)
                return true
            case .laterDrop:
                guard let key = p.key, let item = try tx.node(label: NodeLabel.laterItem, key: key) else { return false }
                try conn.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [item.id, item.id])
                try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [item.id])
                return true
            case .joinSessions:
                var joined = false
                for move in p.moves where move.count == 2 {
                    // 제안한 뒤에 바뀌었으면(길어졌거나, 다른 업무로 갔거나, 이미 붙었으면) 건너뛴다
                    guard let short = try span(tx, key: move[0]), let target = try span(tx, key: move[1]),
                          joinable(short, into: target, calendar: calendar) else { continue }
                    try join(short: move[0], into: move[1], tx: tx, now: now)
                    joined = true
                }
                return joined
            }
        }
    }

    /// 같은 종류 노드 합치기: 들어오고 나가는 연결을 남길 노드로 옮기고(무게·횟수는 더함) 합친 노드를 지운다
    static func fold(label: String, keep: String, merge: [String], conn: Database) throws -> Bool {
        let tx = GraphTx(conn)
        guard let target = try tx.node(label: label, key: keep) else { return false }
        var moved = false
        for key in merge {
            guard let victim = try tx.node(label: label, key: key), victim.id != target.id else { continue }
            try moveEdges(from: victim.id, to: target.id, conn: conn)
            try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [victim.id])
            moved = true
        }
        return moved
    }

    /// victim 의 연결을 target 으로 (같은 연결이 있으면 무게·횟수를 더하고, 자기 자신으로 가는 연결은 버린다)
    static func moveEdges(from victim: Int64, to target: Int64, conn: Database) throws {
        for (end, other) in [("dst", "src"), ("src", "dst")] {
            try conn.execute(sql: """
                INSERT INTO edges(src, dst, type, props, weight, hits, first_at, last_at)
                SELECT \(end == "dst" ? "src, ?" : "?, dst"), type, props, weight, hits, first_at, last_at FROM edges WHERE \(end) = ? AND \(other) <> ? AND \(other) <> ?
                ON CONFLICT(src, dst, type) DO UPDATE SET weight = edges.weight + excluded.weight, hits = edges.hits + excluded.hits,
                  first_at = MIN(edges.first_at, excluded.first_at), last_at = MAX(edges.last_at, excluded.last_at)
                """, arguments: [target, victim, target, victim])
        }
        try conn.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [victim, victim])
    }

    /// 짧은 세션을 붙인다: 시간 범위는 넓히고, 활동 시간·한 일은 더하고, 연결(자료·앱·문제·흐름)은 옮긴다
    static func join(short: String, into target: String, tx: GraphTx, now: Double) throws {
        guard let s = try tx.node(label: NodeLabel.session, key: short), let t = try tx.node(label: NodeLabel.session, key: target), s.id != t.id else { return }
        let start = min(t.props["start"]?.doubleValue ?? .infinity, s.props["start"]?.doubleValue ?? .infinity)
        let end = max(t.props["end"]?.doubleValue ?? 0, s.props["end"]?.doubleValue ?? 0)
        var summaries = t.props["summaries"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for line in s.props["summaries"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !summaries.contains(line) { summaries.append(line) }
        try tx.setProps(nodeId: t.id, ["start": .number(start), "end": .number(end),
                                       "active_seconds": .number((t.props["active_seconds"]?.doubleValue ?? 0) + (s.props["active_seconds"]?.doubleValue ?? 0)),
                                       "summaries": .array(summaries.suffix(40).map { .string($0) })], at: now)
        if let task = try tx.edges(from: t.id, type: EdgeType.partOf).first.flatMap({ try tx.node(id: $0.dst) }) {
            try tx.upsertNode(label: NodeLabel.session, key: t.key, subtype: nil, title: SessionBuilder.title(task: task.title, start: start, end: end), props: [:], at: now)
        }
        try tx.db.execute(sql: "DELETE FROM edges WHERE src = ? AND type = ?", arguments: [s.id, EdgeType.partOf])   // 업무 연결은 이미 있다
        try moveEdges(from: s.id, to: t.id, conn: tx.db)
        try tx.db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [s.id])
    }
}
