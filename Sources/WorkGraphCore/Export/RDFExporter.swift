import Foundation

/// 그래프를 W3C 표준 어휘(PROV-O, SKOS, Dublin Core)에 매핑해 Turtle(RDF)로 내보낸다.
/// 세션은 prov:Activity, 자료는 prov:Entity, 앱은 prov:SoftwareAgent, "봤다"는 prov:used.
/// 우리 어휘(wg:)는 표준 클래스·속성의 하위로 선언해서 표준 도구가 그대로 읽을 수 있게 한다.
public enum RDFExporter {
    public static let prefixes = """
    @prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .
    @prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
    @prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
    @prefix prov: <http://www.w3.org/ns/prov#> .
    @prefix dcterms: <http://purl.org/dc/terms/> .
    @prefix skos: <http://www.w3.org/2004/02/skos/core#> .
    @prefix wg: <urn:workgraph:ontology:> .
    @prefix wgi: <urn:workgraph:node:> .
    """

    /// 우리 어휘 선언 (T-Box). 클래스는 표준 클래스의 하위, 자체 속성은 정의역·치역과 함께.
    public static func vocabulary() -> String {
        var out: [String] = [prefixes, "", "# ── 클래스 (ClassSchema) ──"]
        for cls in ClassSchema.classes where cls.standardSuperclass != "rdfs:Class" {
            out.append("wg:\(cls.label) a rdfs:Class ;\n    rdfs:subClassOf \(cls.standardSuperclass) ;\n    rdfs:label \(literal(cls.name)) ;\n    rdfs:comment \(literal(cls.meaning)) .")
        }
        out.append("")
        out.append("# ── 자체 속성 (RelationSchema 중 표준 속성으로 바로 대응되지 않는 것) ──")
        let own: [(name: String, domain: String, range: String, sub: String?, label: String)] = [
            ("wg:resolvedBy", "wg:Problem", "wg:Resource", "prov:wasInfluencedBy", "문제를 해결한 자료"),
            ("wg:onProject", "wg:Task", "wg:Project", nil, "업무가 속한 프로젝트"),
            ("wg:switchedTo", "wg:Session", "wg:Session", nil, "다음 세션"),
            ("wg:forTask", "wg:LaterItem", "wg:Task", nil, "나중에 할 일의 대상 업무"),
        ]
        for property in own {
            var lines = ["\(property.name) a rdf:Property ;", "    rdfs:domain \(property.domain) ;", "    rdfs:range \(property.range) ;"]
            if let sub = property.sub { lines.append("    rdfs:subPropertyOf \(sub) ;") }
            lines.append("    rdfs:label \(literal(property.label)) .")
            out.append(lines.joined(separator: "\n"))
        }
        let literals: [(String, String, String)] = [
            ("wg:key", "xsd:string", "정규화된 키 (같은 자료를 하나로 모으는 기준)"),
            ("wg:activeSeconds", "xsd:integer", "실제 작업 시간(초)"),
            ("wg:dwellSeconds", "xsd:integer", "자료에 머문 시간(초)"),
            ("wg:secondsUsed", "xsd:integer", "앱을 쓴 시간(초)"),
            ("wg:arrivedBy", "xsd:string", "이 세션에 온 방식: planned / blocked / drift"),
            ("wg:status", "xsd:string", "업무 상태"),
            ("wg:kind", "xsd:string", "문제의 종류"),
        ]
        for (name, range, label) in literals {
            out.append("\(name) a rdf:Property ;\n    rdfs:range \(range) ;\n    rdfs:label \(literal(label)) .")
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// 어휘 + 클래스 층(업무·자료 종류) + 인스턴스.
    public static func export(_ graph: Subgraph) -> String {
        var out = [vocabulary(), "# ── 종류 (TaskType / ResourceType 노드) ──"]
        let byId = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let parent: [Int64: Int64] = Dictionary(graph.edges.filter { $0.type == EdgeType.subclassOf }.map { ($0.src, $0.dst) }, uniquingKeysWith: { first, _ in first })

        for node in graph.nodes where NodeLabel.tbox.contains(node.label) {
            let root = node.label == NodeLabel.taskType ? "wg:Task" : "wg:Resource"
            let superclass = parent[node.id].flatMap { byId[$0] }.map { iri($0) } ?? root
            out.append("\(iri(node)) a rdfs:Class ;\n    rdfs:label \(literal(node.title)) ;\n    rdfs:subClassOf \(superclass) .")
        }

        out.append("")
        out.append("# ── 인스턴스 ──")
        let typeOf: [Int64: [Int64]] = Dictionary(grouping: graph.edges.filter { $0.type == EdgeType.instanceOf }, by: \.src).mapValues { $0.map(\.dst) }
        for node in graph.nodes where !NodeLabel.tbox.contains(node.label) {
            guard let cls = ClassSchema.definition(node.label) else { continue }
            var types = ["wg:\(node.label)", cls.standardSuperclass]
            types += (typeOf[node.id] ?? []).compactMap { byId[$0] }.map { iri($0) }
            var lines = ["\(iri(node)) a \(types.joined(separator: ", ")) ;", "    rdfs:label \(literal(node.title)) ;", "    wg:key \(literal(node.key)) ;"]
            if let start = node.props["start"]?.doubleValue { lines.append("    prov:startedAtTime \(dateTime(start)) ;") }
            if let end = node.props["end"]?.doubleValue { lines.append("    prov:endedAtTime \(dateTime(end)) ;") }
            if let seconds = node.props["active_seconds"]?.doubleValue { lines.append("    wg:activeSeconds \(Int(seconds)) ;") }
            if let summary = node.props["summary"]?.stringValue, !summary.isEmpty { lines.append("    rdfs:comment \(literal(summary)) ;") }
            if let status = node.props["status"]?.stringValue { lines.append("    wg:status \(literal(status)) ;") }
            if let kind = node.props["kind"]?.stringValue { lines.append("    wg:kind \(literal(kind)) ;") }
            if let subtype = node.subtype, node.label != NodeLabel.resource, !subtype.isEmpty { lines.append("    dcterms:type \(literal(subtype)) ;") }
            lines[lines.count - 1] = String(lines[lines.count - 1].dropLast(2)) + " ."
            out.append(lines.joined(separator: "\n"))
        }

        out.append("")
        out.append("# ── 관계 ──")
        for edge in graph.edges {
            guard let src = byId[edge.src], let dst = byId[edge.dst] else { continue }
            let s = iri(src), o = iri(dst)
            switch edge.type {
            case EdgeType.instanceOf, EdgeType.subclassOf:
                continue                                                    // 위에서 처리됨
            case EdgeType.partOf:
                out.append("\(s) dcterms:isPartOf \(o) .")
            case EdgeType.touched:
                out.append("\(s) prov:used \(o) .")
                out.append("\(s) prov:qualifiedUsage [ a prov:Usage ; prov:entity \(o) ; prov:atTime \(dateTime(edge.lastAt)) ; wg:dwellSeconds \(Int(edge.weight)) ] .")
            case EdgeType.used:
                out.append("\(s) prov:wasAssociatedWith \(o) .")
                out.append("\(s) prov:qualifiedAssociation [ a prov:Association ; prov:agent \(o) ; wg:secondsUsed \(Int(edge.weight)) ] .")
            case EdgeType.about:
                out.append("\(s) dcterms:subject \(o) .")
            case EdgeType.belongsTo:
                out.append("\(o) prov:hadMember \(s) .")
            case EdgeType.on:
                out.append("\(s) wg:onProject \(o) .")
            case EdgeType.hit:
                out.append("\(o) prov:wasGeneratedBy \(s) .")
            case EdgeType.resolvedBy:
                out.append("\(s) wg:resolvedBy \(o) .")
            case EdgeType.switchedTo:
                out.append("\(s) wg:switchedTo \(o) .")
                if let kind = edge.props["kind"]?.stringValue, kind != "unknown" { out.append("\(o) wg:arrivedBy \(literal(kind)) .") }
            case EdgeType.forTask:
                out.append("\(s) wg:forTask \(o) .")
            case EdgeType.createdDuring:
                out.append("\(s) prov:wasGeneratedBy \(o) .")
            case EdgeType.derivedFrom:
                out.append("\(s) prov:wasDerivedFrom \(o) .")
            default:
                out.append("\(s) wg:\(edge.type) \(o) .")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: 표기

    /// 클래스 층 노드는 어휘(wg:)의 클래스, 나머지는 인스턴스(wgi:) 로.
    static func iri(_ node: GraphNode) -> String {
        NodeLabel.tbox.contains(node.label) ? classIRI(label: node.label, key: node.key) : "wgi:n\(node.id)"
    }

    static func classIRI(label: String, key: String) -> String {
        let safe = key.unicodeScalars.map { scalar -> String in
            let ok = CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
            return ok ? String(scalar) : "_"
        }.joined()
        return "wg:\(label)_\(safe)"
    }

    static func literal(_ text: String) -> String {
        var escaped = ""
        for char in text {
            switch char {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(char)
            }
        }
        return "\"\(escaped)\""
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    static func dateTime(_ unix: Double) -> String {
        "\"\(isoFormatter.string(from: Date(timeIntervalSince1970: unix)))\"^^xsd:dateTime"
    }
}
