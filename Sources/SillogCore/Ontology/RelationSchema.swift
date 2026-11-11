import Foundation

/// 클래스 층의 나머지 절반: 어떤 종류의 것이 있고(ClassSchema), 어떤 관계가 어느 종류 사이에만 성립하는지(RelationSchema).
/// 저장소가 이 규칙을 강제하고, RDF 내보내기가 이 규칙에서 어휘를 만든다. 코드 한 곳이 단일 진실 원천이다.

public struct ClassDefinition: Equatable, Sendable {
    public let label: String
    public let name: String          // 화면·문서용 한국어 이름
    /// 표준 온톨로지의 상위 클래스 (PROV-O, SKOS). 우리 클래스는 이것의 하위 클래스로 선언된다.
    public let standardSuperclass: String
    public let meaning: String

    public init(label: String, name: String, standardSuperclass: String, meaning: String) {
        self.label = label; self.name = name; self.standardSuperclass = standardSuperclass; self.meaning = meaning
    }
}

public enum ClassSchema {
    public static let classes: [ClassDefinition] = [
        .init(label: NodeLabel.task, name: "업무", standardSuperclass: "prov:Activity", meaning: "하나의 목표를 가진 일. 여러 세션으로 이루어진다"),
        .init(label: NodeLabel.theme, name: "분야", standardSuperclass: "skos:Concept", meaning: "업무를 묶는 넓은 분야. 업무는 분야 하나에 속한다"),
        .init(label: NodeLabel.session, name: "세션", standardSuperclass: "prov:Activity", meaning: "한 업무를 이어서 한 시간 구간"),
        .init(label: NodeLabel.resource, name: "자료", standardSuperclass: "prov:Entity", meaning: "본 것 또는 만든 것 (문서, 코드 파일, 웹페이지 …)"),
        .init(label: NodeLabel.app, name: "앱", standardSuperclass: "prov:SoftwareAgent", meaning: "활동에 쓴 프로그램"),
        .init(label: NodeLabel.topic, name: "주제", standardSuperclass: "skos:Concept", meaning: "업무가 다루는 주제 태그"),
        .init(label: NodeLabel.problem, name: "문제", standardSuperclass: "prov:Entity", meaning: "겪은 에러나 막힘. 자료가 아니라 상태"),
        .init(label: NodeLabel.project, name: "프로젝트", standardSuperclass: "prov:Collection", meaning: "코드 파일들이 속한 저장소·폴더"),
        .init(label: NodeLabel.laterItem, name: "나중에 할 일", standardSuperclass: "prov:Entity", meaning: "작업 중 들어온 요청이나 할 일"),
        .init(label: NodeLabel.file, name: "파일", standardSuperclass: "prov:Entity", meaning: "작업 중 새로 생긴 파일"),
        .init(label: NodeLabel.folder, name: "폴더", standardSuperclass: "prov:Collection", meaning: "파일이 놓인 폴더"),
        .init(label: NodeLabel.taskType, name: "업무 종류", standardSuperclass: "rdfs:Class", meaning: "업무의 분류 (문헌조사, 코드작성 …)"),
        .init(label: NodeLabel.resourceType, name: "자료 종류", standardSuperclass: "rdfs:Class", meaning: "자료의 분류 (Documentation, QnA …)"),
    ]

    public static func definition(_ label: String) -> ClassDefinition? { classes.first { $0.label == label } }
}

public struct RelationPair: Hashable, Sendable {
    public let from: String
    public let to: String
    public init(_ from: String, _ to: String) { self.from = from; self.to = to }
}

public struct RelationRule: Equatable, Sendable {
    public let type: String
    /// 허용되는 (출발 클래스, 도착 클래스) 쌍. 정의역·치역을 쌍으로 두어 "자료 → 업무 종류" 같은 교차를 막는다.
    public let pairs: Set<RelationPair>
    public let meaning: String
    /// 표준 어휘 대응. 내보낼 때 이 속성으로 쓴다 (문서용 표기).
    public let standard: String

    public init(type: String, pairs: Set<RelationPair>, meaning: String, standard: String) {
        self.type = type; self.pairs = pairs; self.meaning = meaning; self.standard = standard
    }

    /// 출발·도착이 각각 하나이거나 모든 조합이 허용될 때의 짧은 표기.
    public init(type: String, from: Set<String>, to: Set<String>, meaning: String, standard: String) {
        var pairs = Set<RelationPair>()
        for f in from { for t in to { pairs.insert(RelationPair(f, t)) } }
        self.init(type: type, pairs: pairs, meaning: meaning, standard: standard)
    }

    public var from: Set<String> { Set(pairs.map(\.from)) }
    public var to: Set<String> { Set(pairs.map(\.to)) }
}

public enum RelationSchema {
    public static let rules: [RelationRule] = [
        .init(type: EdgeType.partOf, pairs: [RelationPair(NodeLabel.session, NodeLabel.task), RelationPair(NodeLabel.task, NodeLabel.theme)],
              meaning: "세션이 업무에, 업무가 분야에 속한다", standard: "dcterms:isPartOf"),
        .init(type: EdgeType.instanceOf, pairs: [RelationPair(NodeLabel.task, NodeLabel.taskType), RelationPair(NodeLabel.resource, NodeLabel.resourceType)],
              meaning: "업무·자료가 어떤 종류인지", standard: "rdf:type"),
        .init(type: EdgeType.subclassOf, pairs: [RelationPair(NodeLabel.taskType, NodeLabel.taskType), RelationPair(NodeLabel.resourceType, NodeLabel.resourceType)],
              meaning: "종류의 상하위 (코드작성 ⊂ 산출물작성)", standard: "rdfs:subClassOf"),
        .init(type: EdgeType.used, from: [NodeLabel.session], to: [NodeLabel.app],
              meaning: "세션에서 앱을 썼다 (초)", standard: "prov:wasAssociatedWith + prov:qualifiedAssociation"),
        .init(type: EdgeType.touched, from: [NodeLabel.session], to: [NodeLabel.resource],
              meaning: "세션에서 자료를 봤다·편집했다 (체류 초)", standard: "prov:used + prov:qualifiedUsage"),
        .init(type: EdgeType.about, from: [NodeLabel.task, NodeLabel.resource], to: [NodeLabel.topic],
              meaning: "업무·자료의 주제", standard: "dcterms:subject"),
        .init(type: EdgeType.belongsTo, pairs: [RelationPair(NodeLabel.resource, NodeLabel.project), RelationPair(NodeLabel.file, NodeLabel.folder)],
              meaning: "자료가 프로젝트에, 파일이 폴더에 속한다", standard: "prov:hadMember (역방향)"),
        .init(type: EdgeType.on, from: [NodeLabel.task], to: [NodeLabel.project],
              meaning: "업무의 프로젝트. 업무당 하나, 프로젝트당 하나 (1:1). 거기서 일한 시간이 가장 긴 업무가 그 프로젝트의 업무", standard: "wg:onProject"),
        .init(type: EdgeType.hit, from: [NodeLabel.session], to: [NodeLabel.problem],
              meaning: "세션 중에 문제를 겪었다", standard: "prov:wasGeneratedBy (역방향)"),
        .init(type: EdgeType.resolvedBy, from: [NodeLabel.problem], to: [NodeLabel.resource],
              meaning: "문제가 이 자료로 해결됐다", standard: "wg:resolvedBy ⊂ prov:wasInfluencedBy"),
        .init(type: EdgeType.switchedTo, from: [NodeLabel.session], to: [NodeLabel.session],
              meaning: "다음 세션으로 넘어갔다 (계획 / 막힘 / 딴짓)", standard: "wg:switchedTo, wg:arrivedBy"),
        .init(type: EdgeType.forTask, from: [NodeLabel.laterItem], to: [NodeLabel.task],
              meaning: "나중에 할 일이 어느 업무 것인지", standard: "wg:forTask"),
        .init(type: EdgeType.createdDuring, from: [NodeLabel.file], to: [NodeLabel.session],
              meaning: "파일이 이 세션 중에 생겼다", standard: "prov:wasGeneratedBy"),
        .init(type: EdgeType.derivedFrom, from: [NodeLabel.file], to: [NodeLabel.resource],
              meaning: "파일의 출처 (내려받은 URL 등)", standard: "prov:wasDerivedFrom"),
    ]

    public static func rule(for type: String) -> RelationRule? { rules.first { $0.type == type } }

    public static func allows(type: String, from: String, to: String) -> Bool {
        rule(for: type)?.pairs.contains(RelationPair(from, to)) ?? false
    }
}

public enum OntologyError: Error, Equatable, CustomStringConvertible {
    case unknownRelation(String)
    case invalidRelation(type: String, from: String, to: String)
    case missingNode(Int64)

    public var description: String {
        switch self {
        case .unknownRelation(let type):
            return "정의되지 않은 관계 \(type). 허용: \(RelationSchema.rules.map(\.type).joined(separator: ", "))"
        case .invalidRelation(let type, let from, let to):
            let rule = RelationSchema.rule(for: type)
            let allowed = rule.map { $0.pairs.map { "\($0.from) → \($0.to)" }.sorted().joined(separator: ", ") } ?? "-"
            return "관계 \(type) 은 \(from) → \(to) 사이에 성립할 수 없음. 허용: \(allowed)"
        case .missingNode(let id):
            return "노드 \(id) 가 없음"
        }
    }
}
