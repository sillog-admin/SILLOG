import Foundation
import GRDB

/// 업무가 아닌 노드의 상세 (업무 드로어 자리): 머리(종류·이름·주소), 사실 몇 줄, 연결된 노드 묶음. 연결된 노드를 누르면 그 노드 상세로 넘어간다
public struct NodeDetail: Equatable, Sendable {
    public enum Value: Equatable, Sendable { case text(String), duration(Double), time(Double), count(Int) }

    public struct Fact: Equatable, Sendable {
        public var name: String
        public var value: Value
        public init(name: String, value: Value) { self.name = name; self.value = value }
    }

    /// 연결된 노드 한 줄. seconds 는 본·쓴 시간, at 은 시각 (없으면 nil)
    public struct Link: Equatable, Sendable, Identifiable {
        public var label: String
        public var key: String
        public var title: String
        public var seconds: Double?
        public var at: Double?
        public var id: String { label + "|" + key }
    }

    public struct Section: Equatable, Sendable {
        public var title: String
        public var links: [Link]
        /// 잘리기 전 수
        public var total: Int
    }

    public var label: String
    public var key: String
    public var title: String
    /// "자료 · Documentation"
    public var kindName: String
    /// 자료의 주소·경로, 앱의 번들 ID
    public var address: String?
    public var facts: [Fact] = []
    /// 세션에서 한 일
    public var notes: [String] = []
    public var sections: [Section] = []
    /// 열 수 있는 것 (자료, 앱)
    public var openable = false
    /// 그때 쓰던 것을 다시 열 수 있는 것 (세션)
    public var resumable = false
    public var erasable = true
}

public enum NodeDetailBuilder {
    public static let kindNames: [String: String] = [
        NodeLabel.theme: "분야", NodeLabel.task: "업무", NodeLabel.session: "세션", NodeLabel.resource: "자료", NodeLabel.app: "앱",
        NodeLabel.topic: "주제", NodeLabel.problem: "문제", NodeLabel.laterItem: "나중에 할 일", NodeLabel.project: "프로젝트",
        NodeLabel.taskType: "업무 종류", NodeLabel.resourceType: "자료 종류", NodeLabel.file: "파일", NodeLabel.folder: "폴더",
    ]

    /// Returns: 그 노드의 상세, 없는 노드면 nil. limit 는 묶음마다 보여 줄 수
    public static func build(label: String, key: String, conn: Database, limit: Int = 30) throws -> NodeDetail? {
        let tx = GraphTx(conn)
        guard let node = try tx.node(label: label, key: key) else { return nil }
        let kind = kindNames[label] ?? label
        var d = NodeDetail(label: label, key: key, title: node.title, kindName: node.subtype.map { "\(kind) · \($0)" } ?? kind)
        d.erasable = NodeEraser.canErase(label: label)

        func link(_ n: GraphNode, seconds: Double? = nil, at: Double? = nil) -> NodeDetail.Link {
            NodeDetail.Link(label: n.label, key: n.key, title: n.title, seconds: seconds, at: at)
        }
        func add(_ title: String, _ links: [NodeDetail.Link]) {
            guard !links.isEmpty else { return }
            d.sections.append(.init(title: title, links: Array(links.prefix(limit)), total: links.count))
        }
        func into(_ type: String) throws -> [(GraphNode, GraphEdge)] {
            try tx.edges(to: node.id, type: type).compactMap { e in try tx.node(id: e.src).map { ($0, e) } }
        }
        func out(_ type: String, from id: Int64? = nil) throws -> [(GraphNode, GraphEdge)] {
            try tx.edges(from: id ?? node.id, type: type).compactMap { e in try tx.node(id: e.dst).map { ($0, e) } }
        }
        func start(_ n: GraphNode) -> Double { n.props["start"]?.doubleValue ?? n.createdAt }
        /// 세션들이 속한 업무, 세션에서 쓴 시간을 더해 많은 순
        func tasks(of sessions: [(GraphNode, GraphEdge)]) throws -> [NodeDetail.Link] {
            var seconds: [Int64: Double] = [:], nodes: [Int64: GraphNode] = [:]
            for (session, edge) in sessions {
                for (task, _) in try out(EdgeType.partOf, from: session.id) where task.label == NodeLabel.task {
                    seconds[task.id, default: 0] += edge.weight
                    nodes[task.id] = task
                }
            }
            return nodes.values.sorted { (seconds[$0.id] ?? 0, $0.title) > (seconds[$1.id] ?? 0, $1.title) }.map { link($0, seconds: seconds[$0.id]) }
        }
        func sessionsRecentFirst(_ sessions: [(GraphNode, GraphEdge)]) -> [NodeDetail.Link] {
            sessions.sorted { start($0.0) > start($1.0) }.map { link($0.0, seconds: $0.1.weight, at: start($0.0)) }
        }

        switch label {
        case NodeLabel.theme:
            let members = try into(EdgeType.partOf).filter { $0.0.label == NodeLabel.task }.map(\.0)
            d.facts = [.init(name: "업무", value: .count(members.count)),
                       .init(name: "작업 시간", value: .duration(members.reduce(0) { $0 + ($1.props["active_seconds"]?.doubleValue ?? 0) }))]
            add("업무", members.sorted { ($0.props["last_active"]?.doubleValue ?? 0) > ($1.props["last_active"]?.doubleValue ?? 0) }
                .map { link($0, seconds: $0.props["active_seconds"]?.doubleValue, at: $0.props["last_active"]?.doubleValue) })
        case NodeLabel.session:
            d.facts = [.init(name: "시작", value: .time(start(node))), .init(name: "끝", value: .time(node.props["end"]?.doubleValue ?? start(node))),
                       .init(name: "활동 시간", value: .duration(node.props["active_seconds"]?.doubleValue ?? 0))]
            if case .array(let items)? = node.props["summaries"] {
                d.notes = items.compactMap { if case .string(let text) = $0 { return text } else { return nil } }
            } else if case .string(let summary)? = node.props["summary"] { d.notes = [summary] }
            d.resumable = true
            add("업무", try out(EdgeType.partOf).map { link($0.0) })
            add("만진 자료", try out(EdgeType.touched).sorted { $0.1.weight > $1.1.weight }.map { link($0.0, seconds: $0.1.weight) })
            add("쓴 앱", try out(EdgeType.used).sorted { $0.1.weight > $1.1.weight }.map { link($0.0, seconds: $0.1.weight) })
            add("문제", try out(EdgeType.hit).map { link($0.0) })
            let neighbours = (try into(EdgeType.switchedTo) + out(EdgeType.switchedTo)).map(\.0)
            add("이어진 세션", neighbours.sorted { start($0) < start($1) }.map { link($0, at: start($0)) })
        case NodeLabel.resource:
            let sessions = try into(EdgeType.touched)
            let last = max(node.props["last_seen"]?.doubleValue ?? 0, sessions.map(\.1.lastAt).max() ?? 0, node.createdAt)
            d.address = key
            d.openable = true
            d.facts = [.init(name: "본 시간", value: .duration(sessions.reduce(0) { $0 + $1.1.weight })),
                       .init(name: "처음", value: .time(node.createdAt)), .init(name: "마지막", value: .time(last))]
            add("쓴 업무", try tasks(of: sessions))
            add("세션", sessionsRecentFirst(sessions))
            add("프로젝트", try out(EdgeType.belongsTo).map { link($0.0) })
            add("해결한 문제", try into(EdgeType.resolvedBy).map { link($0.0) })
        case NodeLabel.app:
            let sessions = try into(EdgeType.used)
            d.address = key
            d.openable = true
            d.facts = [.init(name: "사용 시간", value: .duration(sessions.reduce(0) { $0 + $1.1.weight })),
                       .init(name: "마지막", value: .time(sessions.map(\.1.lastAt).max() ?? node.updatedAt))]
            add("쓴 업무", try tasks(of: sessions))
            add("최근 세션", sessionsRecentFirst(sessions))
        case NodeLabel.topic:
            let tasks = try into(EdgeType.about).filter { $0.0.label == NodeLabel.task }
            d.facts = [.init(name: "업무", value: .count(tasks.count))]
            add("업무", tasks.sorted { $0.1.hits > $1.1.hits }.map { link($0.0) })
        case NodeLabel.problem:
            let sessions = try into(EdgeType.hit)
            d.facts = [.init(name: "종류", value: .text(node.subtype ?? node.props["kind"]?.stringValue ?? "-")),
                       .init(name: "때", value: .time(node.props["at"]?.doubleValue ?? node.createdAt))]
            add("세션", sessionsRecentFirst(sessions))
            add("업무", try tasks(of: sessions))
            add("해결한 자료", try out(EdgeType.resolvedBy).map { link($0.0) })
        case NodeLabel.laterItem:
            let done: Bool = { if case .bool(let value)? = node.props["done"] { return value } else { return false } }()
            d.facts = [.init(name: "상태", value: .text(done ? "끝남" : "아직")),
                       .init(name: "때", value: .time(node.props["at"]?.doubleValue ?? node.createdAt))]
            add("업무", try out(EdgeType.forTask).map { link($0.0) })
        case NodeLabel.project:
            d.address = key
            add("업무", try into(EdgeType.on).map { link($0.0) })
            add("자료", try into(EdgeType.belongsTo).map { link($0.0) })
        case NodeLabel.taskType, NodeLabel.resourceType:
            add(label == NodeLabel.taskType ? "업무" : "자료", try into(EdgeType.instanceOf).map { link($0.0) })
            add("하위 종류", try into(EdgeType.subclassOf).map { link($0.0) })
            add("상위 종류", try out(EdgeType.subclassOf).map { link($0.0) })
        default:
            // 그 밖의 노드: 연결 종류별로 묶어서
            var groups: [String: [NodeDetail.Link]] = [:], order: [String] = []
            for e in try tx.edges(from: node.id) + tx.edges(to: node.id) {
                guard let other = try tx.node(id: e.src == node.id ? e.dst : e.src) else { continue }
                let name = kindNames[other.label] ?? other.label
                if groups[name] == nil { order.append(name) }
                groups[name, default: []].append(link(other))
            }
            order.forEach { add($0, groups[$0] ?? []) }
        }
        return d
    }
}
