import Foundation

/// 같은 그래프를 Neo4j 에 올리기 위한 Cypher 스크립트. 발표·탐색용.
/// 앱 자체는 SQLite 만 쓰고, Cypher 질의를 실제 데이터로 보여주고 싶을 때 이 파일을 Neo4j Browser 에 붙여 넣는다.
public enum CypherExporter {
    public static func export(_ graph: Subgraph) -> String {
        var lines: [String] = ["// Sillog export — Neo4j Browser 에 붙여 넣어 실행"]
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for node in graph.nodes {
            var sets = ["n.title = \(quote(node.title))"]
            if let subtype = node.subtype, !subtype.isEmpty { sets.append("n:\(identifier(subtype))") }
            for (key, value) in node.props.sorted(by: { $0.key < $1.key }) {
                if let literal = literal(value) { sets.append("n.\(identifier(key)) = \(literal)") }
            }
            lines.append("MERGE (n:\(identifier(node.label)) {key: \(quote(node.key))}) SET \(sets.joined(separator: ", "));")
        }
        for edge in graph.edges {
            guard let src = byId[edge.src], let dst = byId[edge.dst] else { continue }
            var sets = ["r.weight = \(number(edge.weight))", "r.hits = \(edge.hits)"]
            for (key, value) in edge.props.sorted(by: { $0.key < $1.key }) {
                if let literal = literal(value) { sets.append("r.\(identifier(key)) = \(literal)") }
            }
            lines.append("MATCH (a:\(identifier(src.label)) {key: \(quote(src.key))}), (b:\(identifier(dst.label)) {key: \(quote(dst.key))}) "
                         + "MERGE (a)-[r:\(identifier(edge.type))]->(b) SET \(sets.joined(separator: ", "));")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n") + "'"
    }

    static func identifier(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    static func literal(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return quote(s)
        case .number(let d): return number(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array(let items):
            let parts = items.compactMap { item -> String? in
                switch item {
                case .string, .number, .bool: return literal(item)
                default: return nil
                }
            }
            return "[" + parts.joined(separator: ", ") + "]"
        case .object(let dict): return quote(JSONValue.encodeObject(dict))
        }
    }
}
