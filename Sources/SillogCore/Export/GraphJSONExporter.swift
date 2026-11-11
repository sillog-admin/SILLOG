import Foundation

/// 그래프 뷰(force-graph)가 바로 읽는 형식: {nodes:[…], links:[…]}
public enum GraphJSONExporter {
    struct NodeDTO: Encodable {
        let id: Int64
        let label: String
        let subtype: String?
        let title: String
        let key: String
        let props: [String: JSONValue]
        let degree: Int
        let updatedAt: Double
    }

    struct LinkDTO: Encodable {
        let source: Int64
        let target: Int64
        let type: String
        let weight: Double
        let hits: Int
        let props: [String: JSONValue]
        let lastAt: Double
    }

    struct GraphDTO: Encodable {
        let generatedAt: Double
        let nodes: [NodeDTO]
        let links: [LinkDTO]
    }

    public static func export(_ graph: Subgraph, now: Double = Date().timeIntervalSince1970) throws -> Data {
        var degree: [Int64: Int] = [:]
        for edge in graph.edges {
            degree[edge.src, default: 0] += 1
            degree[edge.dst, default: 0] += 1
        }
        // 분야는 거기 속한 업무 중 가장 최근 것만큼 최근으로 보낸다. 그래프 뷰가 노드의 updatedAt 으로 오늘·7일을 거르므로
        let updated = Dictionary(graph.nodes.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        let themes = Set(graph.nodes.filter { $0.label == NodeLabel.theme }.map(\.id))
        var themeRecency: [Int64: Double] = [:]
        for edge in graph.edges where edge.type == EdgeType.partOf && themes.contains(edge.dst) {
            themeRecency[edge.dst] = max(themeRecency[edge.dst] ?? 0, updated[edge.src] ?? 0)
        }
        let dto = GraphDTO(
            generatedAt: now,
            nodes: graph.nodes.map { NodeDTO(id: $0.id, label: $0.label, subtype: $0.subtype, title: $0.title, key: $0.key,
                                             props: $0.props, degree: degree[$0.id] ?? 0, updatedAt: max($0.updatedAt, themeRecency[$0.id] ?? 0)) },
            links: graph.edges.map { LinkDTO(source: $0.src, target: $0.dst, type: $0.type, weight: $0.weight, hits: $0.hits,
                                             props: $0.props, lastAt: $0.lastAt) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(dto)
    }
}
