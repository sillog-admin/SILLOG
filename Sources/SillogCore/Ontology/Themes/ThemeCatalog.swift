import Foundation
import GRDB

/// 업무 위의 넓은 분야(테마). 기본 분야로 시작하고, 맞는 것이 없을 때만 새로 만든다
public enum ThemeCatalog {
    public static let defaults = ["학업", "취업 준비", "프로젝트", "직장 업무", "생활 행정", "자기계발"]
    /// 분야 노드의 최대 수 (기본 분야 포함). Jev 선택지 제한과 같다
    public static let limit = 20
    /// Longer answers are sentences, not names. English names need about twice the characters.
    public static var nameLimit: Int { L10n.current == .ko ? 20 : 40 }

    /// 표시 이름: 공백을 하나로
    public static func normalize(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 같은 분야인지 비교하는 키: 공백·대소문자 무시
    public static func matchKey(_ name: String) -> String {
        name.filter { !$0.isWhitespace }.lowercased()
    }

    /// Keys a theme matches by: its own spelling and, for a stored Korean name, the English shown for it.
    static func matchKeys(_ name: String) -> Set<String> {
        Set([name, L10n.english[name]].compactMap { $0 }.map(matchKey))
    }

    /// The default theme's spelling when the name differs only in spacing or case, or is its English name.
    public static func canonical(_ name: String) -> String {
        let clean = normalize(name)
        return defaults.first { matchKeys($0).contains(matchKey(clean)) } ?? clean
    }
}

/// 분야 노드와 업무 → 분야 관계 (열린 트랜잭션 안에서)
public enum ThemeGraph {
    /// 업무가 속한 분야. 없으면 nil
    public static func theme(ofTask taskId: Int64, _ tx: GraphTx) throws -> GraphNode? {
        for edge in try tx.edges(from: taskId, type: EdgeType.partOf) {
            if let node = try tx.node(id: edge.dst), node.label == NodeLabel.theme { return node }
        }
        return nil
    }

    /// The theme with this name, ignoring spacing and case, or whose English name it is.
    public static func find(_ name: String, _ tx: GraphTx) throws -> GraphNode? {
        let key = ThemeCatalog.matchKey(name)
        return try tx.nodes(label: NodeLabel.theme).first { ThemeCatalog.matchKeys($0.title).contains(key) }
    }

    /// 업무를 분야에 잇는다. 같은 이름의 분야가 있으면 그것을, 없으면 자리가 남을 때만 만든다.
    /// 업무에 이미 분야가 있거나, 이름이 비었거나 너무 길거나, 자리가 없으면 nil.
    /// linkedAt: 연결의 시각 (기본 now). 옛 업무를 최근 활동처럼 보이게 하지 않으려면 업무의 마지막 활동 시각을 준다
    @discardableResult
    public static func attach(taskId: Int64, to name: String, _ tx: GraphTx, now: Double, linkedAt: Double? = nil) throws -> (node: GraphNode, created: Bool)? {
        let clean = ThemeCatalog.canonical(name)
        guard !clean.isEmpty, clean.count <= ThemeCatalog.nameLimit, try theme(ofTask: taskId, tx) == nil else { return nil }
        var created = false
        let node: GraphNode
        if let existing = try find(clean, tx) {
            node = existing
        } else {
            guard try tx.nodes(label: NodeLabel.theme).count < ThemeCatalog.limit else { return nil }
            let id = try tx.upsertNode(label: NodeLabel.theme, key: clean, subtype: nil, title: clean, props: [:], at: now)
            guard let made = try tx.node(id: id) else { return nil }
            node = made
            created = true
        }
        try tx.upsertEdge(src: taskId, dst: node.id, type: EdgeType.partOf, props: [:], addWeight: 0, at: linkedAt ?? now, countHit: false)
        return (node, created)
    }

    /// 업무를 분야에서 뺀다 (빈 분야는 지운다). 뺀 분야가 있었으면 true
    @discardableResult
    public static func detach(taskId: Int64, _ tx: GraphTx) throws -> Bool {
        guard let theme = try theme(ofTask: taskId, tx) else { return false }
        try tx.db.execute(sql: "DELETE FROM edges WHERE src = ? AND dst = ? AND type = 'PART_OF'", arguments: [taskId, theme.id])
        try pruneEmpty(tx)
        return true
    }

    /// 업무가 하나도 없는 분야를 지운다. 지운 수
    @discardableResult
    public static func pruneEmpty(_ tx: GraphTx) throws -> Int {
        let empty = try Int64.fetchAll(tx.db, sql: """
            SELECT id FROM nodes WHERE label = 'Theme' AND id NOT IN (SELECT dst FROM edges WHERE type = 'PART_OF')
            """)
        for id in empty {
            try tx.db.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [id, id])
            try tx.db.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [id])
        }
        return empty.count
    }
}
