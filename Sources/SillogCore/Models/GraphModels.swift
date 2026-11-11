import Foundation

public enum NodeLabel {
    public static let task = "Task"
    public static let session = "Session"
    public static let resource = "Resource"
    public static let app = "App"
    public static let topic = "Topic"
    public static let problem = "Problem"
    public static let project = "Project"
    public static let taskType = "TaskType"
    public static let resourceType = "ResourceType"
    public static let file = "File"
    public static let folder = "Folder"
    public static let laterItem = "LaterItem"
    /// 업무를 묶는 넓은 분야 (업무 위의 상위 분류)
    public static let theme = "Theme"

    /// 클래스 층(T-Box) 라벨. 그래프 뷰에서 기본으로 숨긴다.
    public static let tbox: Set<String> = [taskType, resourceType]
}

public enum EdgeType {
    public static let partOf = "PART_OF"
    public static let instanceOf = "INSTANCE_OF"
    public static let subclassOf = "SUBCLASS_OF"
    public static let used = "USED"
    public static let touched = "TOUCHED"
    public static let about = "ABOUT"
    public static let belongsTo = "BELONGS_TO"
    public static let on = "ON"
    public static let hit = "HIT"
    public static let resolvedBy = "RESOLVED_BY"
    public static let switchedTo = "SWITCHED_TO"
    public static let forTask = "FOR"
    public static let createdDuring = "CREATED_DURING"
    public static let derivedFrom = "DERIVED_FROM"
}

public struct GraphNode: Codable, Equatable, Sendable {
    public let id: Int64
    public let label: String
    public let key: String
    public let subtype: String?
    public let title: String
    public let props: [String: JSONValue]
    public let createdAt: Double
    public let updatedAt: Double

    public init(id: Int64, label: String, key: String, subtype: String?, title: String,
                props: [String: JSONValue], createdAt: Double, updatedAt: Double) {
        self.id = id; self.label = label; self.key = key; self.subtype = subtype
        self.title = title; self.props = props; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct GraphEdge: Codable, Equatable, Sendable {
    public let id: Int64
    public let src: Int64
    public let dst: Int64
    public let type: String
    public let props: [String: JSONValue]
    public let weight: Double
    public let hits: Int
    public let firstAt: Double
    public let lastAt: Double

    public init(id: Int64, src: Int64, dst: Int64, type: String, props: [String: JSONValue],
                weight: Double, hits: Int, firstAt: Double, lastAt: Double) {
        self.id = id; self.src = src; self.dst = dst; self.type = type; self.props = props
        self.weight = weight; self.hits = hits; self.firstAt = firstAt; self.lastAt = lastAt
    }
}

public struct Subgraph: Equatable, Sendable {
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public init(nodes: [GraphNode] = [], edges: [GraphEdge] = []) { self.nodes = nodes; self.edges = edges }
}

/// LLM 프롬프트에 넣는 "열려 있는 업무" 요약.
public struct TaskDigest: Codable, Equatable, Sendable {
    public let id: String          // Task 노드의 key
    public let title: String
    public let taskType: String?
    public let topics: [String]
    public let recentResources: [String]
    public let lastActive: Double
    /// 이 업무에서 본 자료의 키와 주로 쓴 앱 (짧은 구간을 기존 업무로 돌릴 때 비교한다)
    public let resourceKeys: [String]
    public let apps: [String]
    /// 최근 세션들에서 무엇을 했는지 (최신 순, 한 문장씩). 같은 업무인지 가를 때 제목보다 확실한 텍스트 근거
    public let recentSummaries: [String]
    /// 이 업무가 무엇을 위한 것인지 (업무가 생길 때 LLM 이 적은 한 문장)
    public let goal: String?
    /// 이 업무를 한 프로젝트 폴더 이름 (오래 일한 순). 업무 합치기가 같은 코드베이스인지 볼 때 쓴다
    public let folders: [String]

    public init(id: String, title: String, taskType: String?, topics: [String], recentResources: [String], lastActive: Double,
                resourceKeys: [String] = [], apps: [String] = [], recentSummaries: [String] = [], goal: String? = nil, folders: [String] = []) {
        self.id = id; self.title = title; self.taskType = taskType
        self.topics = topics; self.recentResources = recentResources; self.lastActive = lastActive
        self.resourceKeys = resourceKeys; self.apps = apps; self.recentSummaries = recentSummaries; self.goal = goal; self.folders = folders
    }
}
