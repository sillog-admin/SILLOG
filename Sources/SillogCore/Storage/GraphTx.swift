import Foundation
import GRDB

/// SQLite를 프로퍼티 그래프로 쓰는 계층. 열려 있는 트랜잭션(Database 핸들) 위에서 동작한다.
/// upsert = Cypher의 MERGE와 같은 역할 (있으면 병합, 없으면 생성).
public struct GraphTx {
    let db: Database

    public init(_ db: Database) { self.db = db }

    // MARK: 쓰기

    @discardableResult
    public func upsertNode(label: String, key: String, subtype: String?, title: String?,
                           props: [String: JSONValue], at: Double) throws -> Int64 {
        let id = try Int64.fetchOne(db, sql: """
            INSERT INTO nodes(label, key, subtype, title, props, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(label, key) DO UPDATE SET
              subtype = COALESCE(excluded.subtype, nodes.subtype),
              title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE nodes.title END,
              props = json_patch(nodes.props, excluded.props),
              updated_at = MAX(nodes.updated_at, excluded.updated_at)
            RETURNING id
            """, arguments: [label, key, subtype, title ?? "", JSONValue.encodeObject(props), at, at])
        guard let id else { throw DatabaseError(message: "upsertNode가 id를 돌려주지 않음: \(label) \(key)") }
        return id
    }

    /// 같은 (src, dst, type) 엣지가 있으면 weight를 더하고 hits를 올린다.
    /// 관계 스키마(RelationSchema)에 없는 관계나 방향은 저장을 거부한다. 그래프가 정의된 어휘 밖으로 벗어나지 않게 하는 장치.
    @discardableResult
    public func upsertEdge(src: Int64, dst: Int64, type: String, props: [String: JSONValue],
                           addWeight: Double, at: Double, countHit: Bool = true) throws -> Int64 {
        guard RelationSchema.rule(for: type) != nil else { throw OntologyError.unknownRelation(type) }
        guard let fromLabel = try String.fetchOne(db, sql: "SELECT label FROM nodes WHERE id = ?", arguments: [src]) else { throw OntologyError.missingNode(src) }
        guard let toLabel = try String.fetchOne(db, sql: "SELECT label FROM nodes WHERE id = ?", arguments: [dst]) else { throw OntologyError.missingNode(dst) }
        guard RelationSchema.allows(type: type, from: fromLabel, to: toLabel) else {
            throw OntologyError.invalidRelation(type: type, from: fromLabel, to: toLabel)
        }
        let id = try Int64.fetchOne(db, sql: """
            INSERT INTO edges(src, dst, type, props, weight, hits, first_at, last_at)
            VALUES (?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(src, dst, type) DO UPDATE SET
              props = json_patch(edges.props, excluded.props),
              weight = edges.weight + excluded.weight,
              hits = edges.hits + ?,
              first_at = MIN(edges.first_at, excluded.first_at),
              last_at = MAX(edges.last_at, excluded.last_at)
            RETURNING id
            """, arguments: [src, dst, type, JSONValue.encodeObject(props), addWeight, at, at, countHit ? 1 : 0])
        guard let id else { throw DatabaseError(message: "upsertEdge가 id를 돌려주지 않음: \(type)") }
        return id
    }

    /// 어느 세션도 만지지 않고 문제 해결·파일 출처로도 안 쓰인 자료 노드를 지운다. 지운 수를 돌려준다
    @discardableResult
    public func pruneOrphanResources() throws -> Int {
        let orphans = try Int64.fetchAll(db, sql: """
            SELECT id FROM nodes WHERE label = 'Resource'
              AND id NOT IN (SELECT dst FROM edges WHERE type IN ('TOUCHED', 'RESOLVED_BY', 'DERIVED_FROM'))
            """)
        for id in orphans {
            try db.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [id, id])
            try db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id])
        }
        return orphans.count
    }

    public func deleteEdge(id: Int64) throws {
        try db.execute(sql: "DELETE FROM edges WHERE id = ?", arguments: [id])
    }

    /// 업무의 프로젝트별 작업 시간(초)에 더한다. 업무 노드의 props.project_seconds = {"file:~/...": 초}
    public func addProjectSeconds(taskId: Int64, projectKey: String, seconds: Double, at: Double) throws {
        guard seconds > 0, let task = try node(id: taskId) else { return }
        var tally = task.props["project_seconds"]?.objectValue ?? [:]
        tally[projectKey] = .number((tally[projectKey]?.doubleValue ?? 0) + seconds)
        try setProps(nodeId: taskId, ["project_seconds": .object(tally)], at: at)
    }

    /// 업무 ↔ 프로젝트를 1:1 로 맞춘다. 근거는 업무별 프로젝트 작업 시간(project_seconds).
    /// 시간이 긴 (업무, 프로젝트) 쌍부터 차례로 짝지어, 이미 짝이 있는 업무나 프로젝트는 건너뛴다.
    /// 한 프로젝트는 한 업무의 것이고, 한 업무는 한 프로젝트만 갖는다. 나머지 ON 엣지는 지운다.
    @discardableResult
    public func rebindProjects(at: Double) throws -> [(taskId: Int64, projectId: Int64, seconds: Double)] {
        var pairs: [(taskId: Int64, projectKey: String, seconds: Double)] = []
        for task in try nodes(label: NodeLabel.task) {
            for (key, value) in task.props["project_seconds"]?.objectValue ?? [:] {
                if let seconds = value.doubleValue, seconds > 0 { pairs.append((task.id, key, seconds)) }
            }
        }
        pairs.sort { ($0.seconds, -$0.taskId) > ($1.seconds, -$1.taskId) }
        var takenTasks = Set<Int64>(), takenProjects = Set<String>()
        var chosen: [(taskId: Int64, projectId: Int64, seconds: Double)] = []
        for pair in pairs where !takenTasks.contains(pair.taskId) && !takenProjects.contains(pair.projectKey) {
            guard let project = try node(label: NodeLabel.project, key: pair.projectKey) else { continue }
            takenTasks.insert(pair.taskId); takenProjects.insert(pair.projectKey)
            chosen.append((pair.taskId, project.id, pair.seconds))
        }
        let wanted = Set(chosen.map { "\($0.taskId)>\($0.projectId)" })
        for edge in try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE type = ?", arguments: [EdgeType.on]).map(Self.edge)
        where !wanted.contains("\(edge.src)>\(edge.dst)") {
            try deleteEdge(id: edge.id)
        }
        for item in chosen {
            let existing = try edges(from: item.taskId, type: EdgeType.on).first { $0.dst == item.projectId }
            try db.execute(sql: existing == nil
                ? "INSERT INTO edges(src, dst, type, props, weight, hits, first_at, last_at) VALUES (?, ?, 'ON', '{}', ?, 1, ?, ?)"
                : "UPDATE edges SET weight = ?, last_at = MAX(last_at, ?) WHERE src = ? AND dst = ? AND type = 'ON'",
                arguments: existing == nil ? [item.taskId, item.projectId, item.seconds, at, at] : [item.seconds, at, item.taskId, item.projectId])
        }
        return chosen
    }

    public func setProps(nodeId: Int64, _ props: [String: JSONValue], at: Double) throws {
        try db.execute(sql: "UPDATE nodes SET props = json_patch(props, ?), updated_at = MAX(updated_at, ?) WHERE id = ?",
                       arguments: [JSONValue.encodeObject(props), at, nodeId])
    }

    // MARK: 읽기

    public func node(label: String, key: String) throws -> GraphNode? {
        try Row.fetchOne(db, sql: "SELECT * FROM nodes WHERE label = ? AND key = ?", arguments: [label, key]).map(Self.node)
    }

    public func node(id: Int64) throws -> GraphNode? {
        try Row.fetchOne(db, sql: "SELECT * FROM nodes WHERE id = ?", arguments: [id]).map(Self.node)
    }

    public func nodes(label: String) throws -> [GraphNode] {
        try Row.fetchAll(db, sql: "SELECT * FROM nodes WHERE label = ? ORDER BY id", arguments: [label]).map(Self.node)
    }

    public func edges(from src: Int64, type: String? = nil) throws -> [GraphEdge] {
        if let type {
            return try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE src = ? AND type = ? ORDER BY id", arguments: [src, type]).map(Self.edge)
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE src = ? ORDER BY id", arguments: [src]).map(Self.edge)
    }

    public func edges(to dst: Int64, type: String? = nil) throws -> [GraphEdge] {
        if let type {
            return try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE dst = ? AND type = ? ORDER BY id", arguments: [dst, type]).map(Self.edge)
        }
        return try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE dst = ? ORDER BY id", arguments: [dst]).map(Self.edge)
    }

    /// Ends of every edge of these types, oldest first. For list screens that would otherwise query per node.
    public func edgeEnds(types: [String]) throws -> [(src: Int64, dst: Int64, type: String)] {
        let marks = types.map { _ in "?" }.joined(separator: ",")
        return try Row.fetchAll(db, sql: "SELECT src, dst, type FROM edges WHERE type IN (\(marks)) ORDER BY id", arguments: StatementArguments(types))
            .map { (src: $0["src"], dst: $0["dst"], type: $0["type"]) }
    }

    /// Label and title of every node that an edge of these types points to.
    public func targets(ofEdgeTypes types: [String]) throws -> [Int64: (label: String, title: String)] {
        let marks = types.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: "SELECT id, label, title FROM nodes WHERE id IN (SELECT dst FROM edges WHERE type IN (\(marks)))",
                                    arguments: StatementArguments(types))
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"], (label: $0["label"], title: $0["title"])) })
    }

    public func counts() throws -> (nodesByLabel: [String: Int], edgesByType: [String: Int]) {
        var nodes: [String: Int] = [:], edges: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT label, COUNT(*) AS n FROM nodes GROUP BY label") { nodes[row["label"]] = row["n"] }
        for row in try Row.fetchAll(db, sql: "SELECT type, COUNT(*) AS n FROM edges GROUP BY type") { edges[row["type"]] = row["n"] }
        return (nodes, edges)
    }

    /// 방향을 무시하고 hops 다리 안에 닿는 부분 그래프. Cypher의 `-[*1..n]-` 에 해당한다.
    public func neighbors(of id: Int64, hops: Int, includeTBox: Bool = false) throws -> Subgraph {
        let ids = try Int64.fetchAll(db, sql: """
            WITH RECURSIVE reach(id, depth) AS (
              SELECT ?, 0
              UNION
              SELECT CASE WHEN e.src = r.id THEN e.dst ELSE e.src END, r.depth + 1
              FROM reach r JOIN edges e ON e.src = r.id OR e.dst = r.id
              WHERE r.depth < ?
            )
            SELECT DISTINCT id FROM reach
            """, arguments: [id, max(0, hops)])
        return try subgraph(ids: ids, includeTBox: includeTBox)
    }

    /// since 이후 갱신된 노드 + 그 시각 이후 엣지의 양 끝점. 보이는 업무의 분야는 언제 이어졌든 함께 넣는다
    public func subgraph(since: Double?, includeTBox: Bool) throws -> Subgraph {
        var ids: [Int64]
        if let since {
            ids = try Int64.fetchAll(db, sql: """
                SELECT id FROM nodes WHERE updated_at >= ?
                UNION SELECT src FROM edges WHERE last_at >= ?
                UNION SELECT dst FROM edges WHERE last_at >= ?
                """, arguments: [since, since, since])
            if !ids.isEmpty {
                let list = ids.map(String.init).joined(separator: ",")   // 정수만 들어가므로 SQL 주입 위험 없음
                ids += try Int64.fetchAll(db, sql: """
                    SELECT e.dst FROM edges e JOIN nodes t ON t.id = e.dst AND t.label = 'Theme'
                    WHERE e.type = 'PART_OF' AND e.src IN (\(list))
                    """)
            }
        } else {
            ids = try Int64.fetchAll(db, sql: "SELECT id FROM nodes")
        }
        var result = try subgraph(ids: Array(Set(ids)), includeTBox: includeTBox)
        if let since {
            let themes = Set(result.nodes.filter { $0.label == NodeLabel.theme }.map(\.id))
            result.edges.removeAll { $0.lastAt < since && !($0.type == EdgeType.partOf && themes.contains($0.dst)) }
        }
        return result
    }

    func subgraph(ids: [Int64], includeTBox: Bool) throws -> Subgraph {
        guard !ids.isEmpty else { return Subgraph() }
        let list = ids.map(String.init).joined(separator: ",")   // 정수만 들어가므로 SQL 주입 위험 없음
        var nodes = try Row.fetchAll(db, sql: "SELECT * FROM nodes WHERE id IN (\(list)) ORDER BY id").map(Self.node)
        if !includeTBox { nodes.removeAll { NodeLabel.tbox.contains($0.label) } }
        let kept = Set(nodes.map(\.id))
        let edges = try Row.fetchAll(db, sql: "SELECT * FROM edges WHERE src IN (\(list)) AND dst IN (\(list)) ORDER BY id")
            .map(Self.edge)
            .filter { kept.contains($0.src) && kept.contains($0.dst) }
        return Subgraph(nodes: nodes, edges: edges)
    }

    /// LLM에 후보로 줄 "열려 있는 업무". 최근 활동 순.
    /// LLM 에 보여 줄 업무 (제목·주제·최근에 한 일 문장·자료). since 를 주면 그 뒤에 활동한 것만
    public func openTasks(limit: Int, since: Double? = nil) throws -> [TaskDigest] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM nodes
            WHERE label = 'Task' AND COALESCE(json_extract(props, '$.status'), 'active') <> 'done'
              AND COALESCE(json_extract(props, '$.last_active'), updated_at) >= ?
            ORDER BY COALESCE(json_extract(props, '$.last_active'), updated_at) DESC
            LIMIT ?
            """, arguments: [since ?? 0, limit])
        return try rows.map(Self.node).map { task in
            let taskType = try String.fetchOne(db, sql: """
                SELECT n.title FROM edges e JOIN nodes n ON n.id = e.dst
                WHERE e.src = ? AND e.type = 'INSTANCE_OF' LIMIT 1
                """, arguments: [task.id])
            let topics = try String.fetchAll(db, sql: """
                SELECT n.title FROM edges e JOIN nodes n ON n.id = e.dst
                WHERE e.src = ? AND e.type = 'ABOUT' ORDER BY e.last_at DESC LIMIT 6
                """, arguments: [task.id])
            let resources = try String.fetchAll(db, sql: """
                SELECT r.title FROM edges p
                JOIN edges t ON t.src = p.src AND t.type = 'TOUCHED'
                JOIN nodes r ON r.id = t.dst
                WHERE p.dst = ? AND p.type = 'PART_OF'
                GROUP BY r.id ORDER BY MAX(t.last_at) DESC LIMIT 5
                """, arguments: [task.id])
            let resourceKeys = try String.fetchAll(db, sql: """
                SELECT r.key FROM edges p
                JOIN edges t ON t.src = p.src AND t.type = 'TOUCHED'
                JOIN nodes r ON r.id = t.dst
                WHERE p.dst = ? AND p.type = 'PART_OF'
                GROUP BY r.id ORDER BY MAX(t.last_at) DESC LIMIT 40
                """, arguments: [task.id])
            let apps = try String.fetchAll(db, sql: """
                SELECT a.key FROM edges p
                JOIN edges u ON u.src = p.src AND u.type = 'USED'
                JOIN nodes a ON a.id = u.dst
                WHERE p.dst = ? AND p.type = 'PART_OF'
                GROUP BY a.id ORDER BY SUM(u.weight) DESC LIMIT 3
                """, arguments: [task.id])
            let summaries = try String.fetchAll(db, sql: """
                SELECT COALESCE(NULLIF(json_extract(s.props, '$.summary'), ''), s.title) FROM edges p JOIN nodes s ON s.id = p.src
                WHERE p.dst = ? AND p.type = 'PART_OF' ORDER BY json_extract(s.props, '$.start') DESC LIMIT 3
                """, arguments: [task.id])
            return TaskDigest(id: task.key, title: task.title, taskType: taskType, topics: topics,
                              recentResources: resources, lastActive: task.props["last_active"]?.doubleValue ?? task.updatedAt,
                              resourceKeys: resourceKeys, apps: apps, recentSummaries: summaries,
                              goal: task.props["goal"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                              folders: (task.props["project_seconds"]?.objectValue ?? [:]).sorted { ($0.value.doubleValue ?? 0) > ($1.value.doubleValue ?? 0) }
                                .map { ($0.key as NSString).lastPathComponent })
        }
    }

    public func latestSession(ofTask taskId: Int64) throws -> GraphNode? {
        try Row.fetchOne(db, sql: """
            SELECT s.* FROM edges e JOIN nodes s ON s.id = e.src
            WHERE e.dst = ? AND e.type = 'PART_OF' AND s.label = 'Session'
            ORDER BY COALESCE(json_extract(s.props, '$.end'), s.updated_at) DESC LIMIT 1
            """, arguments: [taskId]).map(Self.node)
    }

    /// ts 이전에 시작된 세션 중 가장 늦게 끝난 것 (업무 전환 엣지를 만들 때 "직전 세션"으로 쓴다).
    public func latestSession(startedBefore ts: Double, excluding id: Int64?) throws -> GraphNode? {
        try Row.fetchOne(db, sql: """
            SELECT * FROM nodes
            WHERE label = 'Session' AND id <> ? AND COALESCE(json_extract(props, '$.start'), created_at) < ?
            ORDER BY COALESCE(json_extract(props, '$.end'), updated_at) DESC LIMIT 1
            """, arguments: [id ?? -1, ts]).map(Self.node)
    }

    // MARK: Row 변환

    static func node(_ row: Row) -> GraphNode {
        GraphNode(id: row["id"], label: row["label"], key: row["key"], subtype: row["subtype"], title: row["title"],
                  props: JSONValue.decodeObject(row["props"] as String?), createdAt: row["created_at"], updatedAt: row["updated_at"])
    }

    public static func edge(_ row: Row) -> GraphEdge {
        GraphEdge(id: row["id"], src: row["src"], dst: row["dst"], type: row["type"],
                  props: JSONValue.decodeObject(row["props"] as String?), weight: row["weight"], hits: row["hits"],
                  firstAt: row["first_at"], lastAt: row["last_at"])
    }
}
