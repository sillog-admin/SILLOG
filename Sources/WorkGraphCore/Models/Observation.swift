import Foundation
import GRDB

/// L0 원시층의 한 행: "이 시각에 이 앱·창·URL을 보고 있었다".
public struct Observation: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "observations"

    public var id: Int64?
    public var ts: Double
    /// app_activate | window_change | periodic | manual | demo
    public var trigger: String
    public var appBundle: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var docPath: String?
    public var textId: Int64?
    public var screenshotPath: String?
    public var batchId: Int64?
    /// LLM 이 정한 업무 (Task 노드 id). nil 이면 아직 안 정했거나 일이 아닌 행
    public var taskId: Int64?
    /// 이 행의 파일·페이지가 그 업무의 자료인지 (false: 보이기만 했음)
    public var resourceRelevant: Bool
    /// 어떤 목표에도 기여하지 않는 행 (집중 이탈)
    public var offTask: Bool
    /// LLM 이 적은 판정 이유
    public var taskReason: String?
    /// 이 행의 스크린샷 차이 해시 (64비트, 비트 패턴 그대로)
    public var screenHash: Int64?
    /// 이 행을 덮는 화면 기억 카드
    public var cardId: Int64?

    public init(id: Int64? = nil, ts: Double, trigger: String, appBundle: String, appName: String,
                windowTitle: String? = nil, url: String? = nil, docPath: String? = nil,
                textId: Int64? = nil, screenshotPath: String? = nil, batchId: Int64? = nil,
                taskId: Int64? = nil, resourceRelevant: Bool = true, offTask: Bool = false, taskReason: String? = nil) {
        self.id = id; self.ts = ts; self.trigger = trigger
        self.appBundle = appBundle; self.appName = appName
        self.windowTitle = windowTitle; self.url = url; self.docPath = docPath
        self.textId = textId; self.screenshotPath = screenshotPath; self.batchId = batchId
        self.taskId = taskId; self.resourceRelevant = resourceRelevant; self.offTask = offTask; self.taskReason = taskReason
        self.screenHash = nil; self.cardId = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, ts
        case trigger = "trigger_kind"
        case appBundle = "app_bundle"
        case appName = "app_name"
        case windowTitle = "window_title"
        case url
        case docPath = "doc_path"
        case textId = "text_id"
        case screenshotPath = "screenshot_path"
        case batchId = "batch_id"
        case taskId = "task_id"
        case resourceRelevant = "resource_relevant"
        case offTask = "off_task"
        case taskReason = "task_reason"
        case screenHash = "screen_hash"
        case cardId = "card_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// 같은 컨텍스트인지 판단하는 키 (앱 + 창 제목 + URL + 문서 경로).
    public var contextKey: String {
        [appBundle, windowTitle ?? "", url ?? "", docPath ?? ""].joined(separator: "\u{1F}")
    }
}

/// AI 코딩 도구에 사용자가 보낸 메시지 한 건.
public struct ChatMessage: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chat_messages"
    public var id: Int64?
    public var ts: Double
    /// claude-code | codex-cli
    public var tool: String
    public var sessionId: String
    public var cwd: String?
    public var text: String
    public var ingestedAt: Double
    public var batchId: Int64?
    public var taskId: Int64?

    public init(id: Int64? = nil, ts: Double, tool: String, sessionId: String, cwd: String?, text: String,
                ingestedAt: Double = Date().timeIntervalSince1970, batchId: Int64? = nil, taskId: Int64? = nil) {
        self.id = id; self.ts = ts; self.tool = tool; self.sessionId = sessionId; self.cwd = cwd; self.text = text
        self.ingestedAt = ingestedAt; self.batchId = batchId; self.taskId = taskId
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, tool
        case sessionId = "session_id"
        case cwd, text
        case ingestedAt = "ingested_at"
        case batchId = "batch_id"
        case taskId = "task_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var toolName: String { ChatMessage.toolNames[tool] ?? tool }
    public static let toolNames = ["claude-code": "Claude Code", "codex-cli": "Codex CLI"]
}

public struct FileEvent: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "file_events"
    public var id: Int64?
    public var ts: Double
    public var path: String
    /// created | renamed | modified
    public var kind: String
    public var originUrl: String?
    public var observationId: Int64?

    public init(id: Int64? = nil, ts: Double, path: String, kind: String, originUrl: String? = nil, observationId: Int64? = nil) {
        self.id = id; self.ts = ts; self.path = path; self.kind = kind
        self.originUrl = originUrl; self.observationId = observationId
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, path, kind
        case originUrl = "origin_url"
        case observationId = "observation_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct IdleSpan: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "idle_spans"
    public var id: Int64?
    public var startTs: Double
    public var endTs: Double?

    public init(id: Int64? = nil, startTs: Double, endTs: Double? = nil) {
        self.id = id; self.startTs = startTs; self.endTs = endTs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startTs = "start_ts"
        case endTs = "end_ts"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct BatchRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "batches"
    public var id: Int64?
    public var startedAt: Double
    public var finishedAt: Double?
    public var fromObs: Int64?
    public var toObs: Int64?
    public var rowCount: Int
    /// running | ok | failed
    public var status: String
    public var model: String?
    public var promptTokens: Int
    public var completionTokens: Int
    public var error: String?
    public var rawResponse: String?
    public var stats: String?
    /// LLM 이 받은 것: 시스템 프롬프트와 그 배치의 사용자 메시지(활동 행)
    public var systemPrompt: String?
    public var userPrompt: String?
    /// LLM 이 돌려준 구조화 결과(JSON)와, 짧은 구간을 다듬은 뒤 실제로 그래프에 반영한 결과(JSON)
    public var llmPatch: String?
    public var appliedPatch: String?
    /// 시스템 프롬프트 원문은 prompt_blobs 에 한 번만 두고 해시로 가리킨다 (읽을 때 EventStore 가 원문을 채운다)
    public var systemPromptHash: String?

    public init(id: Int64? = nil, startedAt: Double, finishedAt: Double? = nil, fromObs: Int64? = nil, toObs: Int64? = nil,
                rowCount: Int = 0, status: String, model: String? = nil, promptTokens: Int = 0, completionTokens: Int = 0,
                error: String? = nil, rawResponse: String? = nil, stats: String? = nil,
                systemPrompt: String? = nil, userPrompt: String? = nil, llmPatch: String? = nil, appliedPatch: String? = nil,
                systemPromptHash: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.fromObs = fromObs; self.toObs = toObs; self.rowCount = rowCount
        self.status = status; self.model = model
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.error = error; self.rawResponse = rawResponse; self.stats = stats
        self.systemPrompt = systemPrompt; self.userPrompt = userPrompt; self.llmPatch = llmPatch; self.appliedPatch = appliedPatch
        self.systemPromptHash = systemPromptHash
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case fromObs = "from_obs"
        case toObs = "to_obs"
        case rowCount = "row_count"
        case status, model
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case error
        case rawResponse = "raw_response"
        case stats
        case systemPrompt = "system_prompt"
        case userPrompt = "user_prompt"
        case llmPatch = "llm_patch"
        case appliedPatch = "applied_patch"
        case systemPromptHash = "system_prompt_hash"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// 목록 화면(SwiftUI Table)에서 바로 쓸 수 있게.
extension Observation: Identifiable {}
extension BatchRecord: Identifiable {}
