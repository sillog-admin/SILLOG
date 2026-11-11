import Foundation

/// 업무 하나의 자료: 업무 드로어의 자료 탭. 그래프 화면의 업무 팝업(graph/index.html loadGraph, related)과 같은 기준이다.
/// 세션(PART_OF 업무)이 건드린 자료(TOUCHED)는 산출물(코드, 노트, 문서, 디자인)과 참고자료로 나누고, 쓴 앱(USED), 업무의 주제(ABOUT, 자주 본 8개),
/// 부딪힌 문제(HIT), 나중에 할 일(FOR)을 모은다. 같은 맥락 업무 = 같은 자료나 주제를 쓴 다른 업무('기타' 분야는 뺀다)
public struct TaskMaterials: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let name: String
        /// 노드 키: 자료는 열 수 있는 주소(file:, 웹 주소 등), 앱은 번들 id
        public let key: String
        public var id: String { key }
    }

    public struct Related: Equatable, Sendable, Identifiable {
        public let taskId: Int64
        public let title: String
        /// 함께 쓴 자료와 주제 이름
        public let shared: [String]
        public var id: Int64 { taskId }
    }

    public var references: [Item] = []
    public var outputs: [Item] = []
    public var apps: [Item] = []
    public var topics: [Item] = []
    public var problems: [Item] = []
    public var later: [Item] = []
    public var related: [Related] = []

    public init() {}

    public var isEmpty: Bool {
        references.isEmpty && outputs.isEmpty && apps.isEmpty && topics.isEmpty && problems.isEmpty && later.isEmpty && related.isEmpty
    }

    /// 산출물로 치는 자료 종류 (그래프의 OUTPUT_SUBTYPES)
    public static let outputSubtypes: Set<String> = ["CodeFile", "Note", "Document", "Design"]
    /// 업무당 보여 줄 주제 수 (그래프의 TOPICS_MAX). 추출된 주제는 뜻이 겹치는 게 많아 자주 본 순으로 자른다
    public static let topicsMax = 8

    public static func read(_ tx: GraphTx, taskId: Int64) throws -> TaskMaterials {
        var materials = try own(tx, taskId: taskId)
        let mine = keys(materials)
        guard !mine.isEmpty else { return materials }
        for task in try tx.nodes(label: NodeLabel.task) where task.id != taskId {
            guard try !isMisc(tx, taskId: task.id) else { continue }
            let other = keys(try own(tx, taskId: task.id))
            let shared = mine.filter { other.contains($0) }
            if !shared.isEmpty { materials.related.append(Related(taskId: task.id, title: task.title, shared: shared)) }
        }
        materials.related.sort { $0.shared.count > $1.shared.count }
        return materials
    }

    /// 같은 맥락을 가리는 열쇠: 자료(참고자료, 산출물)와 주제 이름. 나온 순서를 지킨다
    private static func keys(_ m: TaskMaterials) -> [String] {
        unique((m.references + m.outputs + m.topics).map(\.name))
    }

    private static func own(_ tx: GraphTx, taskId: Int64) throws -> TaskMaterials {
        var m = TaskMaterials()
        let sessions = try tx.edges(to: taskId, type: EdgeType.partOf)
            .compactMap { try tx.node(id: $0.src) }
            .filter { $0.label == NodeLabel.session }
            .sorted { ($0.props["start"]?.doubleValue ?? 0) < ($1.props["start"]?.doubleValue ?? 0) }
        let targets = { (type: String) -> [GraphNode] in
            try sessions.flatMap { session in try tx.edges(from: session.id, type: type).compactMap { try tx.node(id: $0.dst) } }
        }
        let touched = try targets(EdgeType.touched)
        m.outputs = items(touched.filter { outputSubtypes.contains($0.subtype ?? "") })
        m.references = items(touched.filter { !outputSubtypes.contains($0.subtype ?? "") })
        m.apps = items(try targets(EdgeType.used))
        m.problems = items(try targets(EdgeType.hit))
        let topics = try tx.edges(from: taskId, type: EdgeType.about)
            .sorted { ($0.hits, $0.lastAt) > ($1.hits, $1.lastAt) }                 // 자주 본 것, 같으면 최근 것
            .compactMap { try tx.node(id: $0.dst) }
        m.topics = Array(items(topics).prefix(topicsMax))
        m.later = items(try tx.edges(to: taskId, type: EdgeType.forTask).compactMap { try tx.node(id: $0.src) })
        return m
    }

    /// '기타' 분야(PART_OF 분야 '기타')에 든 업무
    private static func isMisc(_ tx: GraphTx, taskId: Int64) throws -> Bool {
        try tx.edges(from: taskId, type: EdgeType.partOf).contains { edge in
            guard let theme = try tx.node(id: edge.dst) else { return false }
            return theme.label == NodeLabel.theme && theme.title == "기타"
        }
    }

    /// 이름이 같은 것은 처음 나온 것 하나만
    private static func items(_ nodes: [GraphNode]) -> [Item] {
        var seen = Set<String>()
        return nodes.compactMap { node in seen.insert(node.title).inserted && !node.title.isEmpty ? Item(name: node.title, key: node.key) : nil }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
