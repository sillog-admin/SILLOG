import Foundation
import GRDB

/// 그래프 노드 하나를 지운다 (그래프에서 우클릭 → 지우기). 그 노드에서만 내려가는 하위 노드와, 그 노드가 찍힌 원시 기록까지 지우고,
/// 다른 곳에도 걸린 노드는 연결만 끊고 남긴다. 되돌릴 수 없다.
///   - 분야·업무: TaskEraser (업무 기록째)
///   - 세션: 그 업무의 그 시간대 원시 기록, 그 세션에서만 만진 자료·쓴 앱·겪은 문제. 업무 시간에서 세션 시간을 뺀다
///   - 자료: 그 주소·파일로 분류되는 원시 행(업무 밖 행도), 그 자료의 화면 카드, AI 대화·녹음 자료면 그 대화·녹음, 그 자료의 시간 기록
///   - 앱: 그 앱의 원시 행·화면 카드·시간 기록 전부
///   - 주제·문제·나중에 할 일·프로젝트: 노드와 연결만 (원시 기록이 따로 없다)
///   - 업무 종류 같은 클래스: 지우지 않는다 (report.erasable = false)
/// 실제 파일(문서, 받아쓴 .md)은 지우지 않는다. 지운 내용이 DB 파일에 남지 않게 하려면 커밋 뒤 TaskEraser.compact 를 부른다
public enum NodeEraser {
    public static func canErase(label: String) -> Bool { !NodeLabel.tbox.contains(label) }

    /// 지울 때 하위로 따라 내려가는 연결 (노드 → 하위 노드): 세션이 만진 자료·쓴 앱·겪은 문제
    static let childEdges: [String] = [EdgeType.touched, EdgeType.used, EdgeType.hit]
    /// 이 연결로 다른 노드에 걸려 있으면 하위 노드라도 남긴다
    static let parentEdges: [String] = [EdgeType.touched, EdgeType.used, EdgeType.hit, EdgeType.about, EdgeType.resolvedBy,
                                        EdgeType.derivedFrom, EdgeType.createdDuring, EdgeType.partOf, EdgeType.forTask, EdgeType.belongsTo]

    /// Returns: 지운 것(dry 면 지울 것)의 수. 없는 노드면 빈 보고(title 이 빈 글). Raises: DB 오류 (열린 트랜잭션 안에서 부른다)
    public static func erase(label: String, key: String, conn: Database, now: Double, home: String = NSHomeDirectory(), dry: Bool) throws -> TaskEraser.Report {
        let tx = GraphTx(conn)
        guard let node = try tx.node(label: label, key: key) else { return TaskEraser.Report() }
        guard canErase(label: label) else {
            var report = TaskEraser.Report()
            report.title = node.title
            report.erasable = false
            return report
        }
        switch label {
        case NodeLabel.theme:
            var report = try TaskEraser.erase(theme: node.title, conn: conn, now: now, dry: dry)
            report.title = node.title                                  // 확인 창 제목은 업무 이름들이 아니라 분야 이름
            return report
        case NodeLabel.task: return try TaskEraser.erase(taskKeys: [key], conn: conn, now: now, dry: dry)
        default: break
        }
        var report = TaskEraser.Report()
        report.title = node.title
        var rows = RecordEraser.Rows()
        switch label {
        case NodeLabel.session: rows = try sessionRows(node, conn: conn)
        case NodeLabel.resource: rows = try resourceRows(key, conn: conn, home: home)
        case NodeLabel.app:
            rows.observations = try Int64.fetchAll(conn, sql: "SELECT id FROM observations WHERE app_bundle = ?", arguments: [key])
            rows.cards = try Int64.fetchAll(conn, sql: "SELECT id FROM screen_cards WHERE app_bundle = ?", arguments: [key])
        default: break
        }
        let doomed = try subtree(node.id, conn: conn)
        report.nodes = doomed.count
        try RecordEraser.apply(rows, conn: conn, report: &report, dry: dry)
        guard !dry else { return report }

        switch label {
        case NodeLabel.resource: try conn.execute(sql: "DELETE FROM usage_ledger WHERE target_kind = 'resource' AND target_key = ?", arguments: [key])
        case NodeLabel.app: try conn.execute(sql: "DELETE FROM usage_ledger WHERE target_kind = 'app' AND target_key = ?", arguments: [key])
        case NodeLabel.session:
            // 업무 시간에서 그 세션 시간을 뺀다
            if let task = try tx.edges(from: node.id, type: EdgeType.partOf).first.flatMap({ try tx.node(id: $0.dst) }) {
                let left = max(0, (task.props["active_seconds"]?.doubleValue ?? 0) - (node.props["active_seconds"]?.doubleValue ?? 0))
                try tx.setProps(nodeId: task.id, ["active_seconds": .number(left)], at: now)
            }
        default: break
        }
        let list = doomed.map(String.init).joined(separator: ",")
        try conn.execute(sql: "DELETE FROM edges WHERE src IN (\(list)) OR dst IN (\(list))")
        try conn.execute(sql: "DELETE FROM nodes WHERE id IN (\(list))")
        _ = try ThemeGraph.pruneEmpty(tx)
        return report
    }

    /// 지울 노드와, 그 노드에서만 내려가는 하위 노드 (다른 노드에도 걸린 것은 뺀다)
    static func subtree(_ root: Int64, conn: Database) throws -> [Int64] {
        let children = childEdges.map { "'\($0)'" }.joined(separator: ",")
        let parents = parentEdges.map { "'\($0)'" }.joined(separator: ",")
        var doomed: Set<Int64> = [root], frontier = [root]
        while let id = frontier.popLast() {
            for child in try Int64.fetchAll(conn, sql: "SELECT DISTINCT dst FROM edges WHERE src = ? AND type IN (\(children))", arguments: [id]) where !doomed.contains(child) {
                let list = doomed.map(String.init).joined(separator: ",")
                let others = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges WHERE dst = ? AND type IN (\(parents)) AND src NOT IN (\(list))", arguments: [child]) ?? 0
                guard others == 0 else { continue }
                doomed.insert(child)
                frontier.append(child)
            }
        }
        return doomed.sorted()
    }

    /// 세션의 원시 기록: 같은 업무의 다른 세션과 겹치는 시간대는 어느 쪽 기록인지 구분할 수 없어 남긴다.
    static func sessionRows(_ session: GraphNode, conn: Database) throws -> RecordEraser.Rows {
        guard let start = session.props["start"]?.doubleValue,
              let task = try Int64.fetchOne(conn, sql: "SELECT dst FROM edges WHERE src = ? AND type = ?", arguments: [session.id, EdgeType.partOf]) else { return .init() }
        let end = session.props["end"]?.doubleValue ?? start
        func ids(in table: String, timestamp: String) throws -> [Int64] {
            try Int64.fetchAll(conn, sql: """
                SELECT r.id FROM \(table) r
                WHERE r.task_id = ? AND r.\(timestamp) BETWEEN ? AND ?
                  AND NOT EXISTS (
                    SELECT 1 FROM edges e JOIN nodes s ON s.id = e.src
                    WHERE e.dst = r.task_id AND e.src <> ? AND e.type = ? AND s.label = ?
                      AND r.\(timestamp) BETWEEN json_extract(s.props, '$.start')
                        AND COALESCE(json_extract(s.props, '$.end'), json_extract(s.props, '$.start'))
                  )
                """, arguments: [task, start, end, session.id, EdgeType.partOf, NodeLabel.session])
        }
        return try RecordEraser.Rows(observations: ids(in: "observations", timestamp: "ts"),
                                     chats: ids(in: "chat_messages", timestamp: "ts"),
                                     recordings: ids(in: "recordings", timestamp: "started_at"))
    }

    /// 자료의 원시 기록: AI 대화(chat:도구:세션), 녹음(recording:번호), 그 밖에는 정리할 때와 같은 규칙(RuleClassifier)으로 그 키가 되는 행과 그 주소의 화면 카드
    static func resourceRows(_ key: String, conn: Database, home: String) throws -> RecordEraser.Rows {
        var rows = RecordEraser.Rows()
        if key.hasPrefix("chat:") {
            let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                rows.chats = try Int64.fetchAll(conn, sql: "SELECT id FROM chat_messages WHERE tool = ? AND session_id = ?", arguments: [parts[1], parts[2]])
            }
            return rows
        }
        if key.hasPrefix("recording:"), let id = Int64(key.dropFirst("recording:".count)) {
            rows.recordings = try Int64.fetchAll(conn, sql: "SELECT id FROM recordings WHERE id = ?", arguments: [id])
            return rows
        }
        let candidates = try Row.fetchAll(conn, sql: """
            SELECT id, app_bundle, app_name, window_title, url, doc_path FROM observations
            WHERE url IS NOT NULL OR doc_path IS NOT NULL OR window_title IS NOT NULL
            """)
        rows.observations = candidates.compactMap { row in
            let classified = RuleClassifier.classify(appBundle: row["app_bundle"], appName: row["app_name"], windowTitle: row["window_title"],
                                                     url: row["url"], docPath: row["doc_path"], home: home, fileExists: { _ in false })
            return classified?.key == key ? row["id"] : nil
        }
        rows.cards = try Int64.fetchAll(conn, sql: "SELECT id FROM screen_cards WHERE uri = ?", arguments: [key])
        return rows
    }
}
