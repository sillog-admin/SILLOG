import Foundation

public struct ChatSkill: Codable, Identifiable, Sendable {
    public let id: String
    public private(set) var title: String
    public let icon: String
    public private(set) var summary: String
    private let instructionFile: String?
    private var customInstructions: String?
    public var isCustom: Bool { instructionFile == nil }
    /// Built-in titles come from the bundled catalog, so they follow the app language.
    public var displayTitle: String { isCustom ? title : L10n.tr(key: title) }
    public var displaySummary: String { isCustom ? summary : L10n.tr(key: summary) }

    public init(title: String, instructions: String, summary: String = "") {
        self.id = UUID().uuidString
        self.title = title
        self.icon = "sparkles"
        self.summary = summary
        self.instructionFile = nil
        self.customInstructions = instructions
    }

    func edited(title: String, instructions: String, summary: String) -> Self {
        var copy = self
        copy.title = title
        copy.summary = summary
        copy.customInstructions = instructions
        return copy
    }

    /// Args: 없음.
    /// Returns: 앱에 포함된 여섯 스킬 정의.
    /// Raises: 번들 리소스 누락, JSON 읽기·디코딩 오류.
    public static func load() throws -> [ChatSkill] {
        guard let url = resourceBundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Skills") else { throw ChatToolError.unavailable("스킬 목록을 찾을 수 없습니다.") }
        return try JSONDecoder().decode([ChatSkill].self, from: Data(contentsOf: url))
    }

    /// Args: 없음.
    /// Returns: 이 스킬의 작업 절차.
    /// Raises: 지침 리소스 누락·읽기 오류.
    public func instructions() throws -> String {
        if let customInstructions { return customInstructions }
        guard let instructionFile, let url = Self.resourceBundle.url(forResource: instructionFile, withExtension: nil, subdirectory: "Skills") else { throw ChatToolError.unavailable("스킬 지침을 찾을 수 없습니다: \(title)") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static var resourceBundle: Bundle {
        if let url = Bundle.main.url(forResource: "Sillog_SillogCore", withExtension: "bundle"), let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }
}

public enum ChatRunEvent: Sendable {
    case textReset
    case text(String)
    case step(String)
    case source(ChatSource)
    case artifact(ChatArtifact)
    case automation(ChatAutomationProposal)
}

public struct ChatRunResult: Sendable {
    public var text: String
    public var sources: [ChatSource]
    public var artifacts: [ChatArtifact]
    public var automation: ChatAutomationProposal?
}

private actor ChatRunLedger {
    var sources: [String: ChatSource] = [:]
    var artifacts: [ChatArtifact] = []
    var automation: ChatAutomationProposal?
    var calls = 0
    var userText = ""

    func setUserText(_ text: String) { userText = text }

    /// Blocks prompt-injected exfiltration: web_read only follows URLs the user wrote or a tool returned.
    func knows(_ url: String) -> Bool {
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        return !trimmed.isEmpty && (userText.contains(trimmed) || sources.values.contains { $0.location == url || $0.location == trimmed })
    }

    /// Args: 없음.
    /// Returns: 없음. 주·하위 에이전트가 공유하는 실행 예산을 차감한다.
    /// Raises: 한 요청에서 모델 호출이 24회를 초과한 경우.
    func consume() throws {
        guard calls < 24 else { throw ChatToolError.unavailable("조사 단계 한도에 도달했습니다. 요청 범위를 좁혀 다시 시도하세요.") }
        calls += 1
    }

    /// Args: values는 실제 도구에서 얻은 출처이다.
    /// Returns: 없음. 중복 출처는 최신 조회 내용으로 갱신한다.
    /// Raises: 없음.
    func record(_ values: [ChatSource]) { for value in values { sources[value.id] = value } }

    /// Args: artifact는 생성한 결과물이다.
    /// Returns: 없음.
    /// Raises: 없음.
    func record(_ artifact: ChatArtifact) { artifacts.append(artifact) }

    /// Args: proposal은 아직 승인되지 않은 예약안이다.
    /// Returns: 없음.
    /// Raises: 없음.
    func record(_ proposal: ChatAutomationProposal) { automation = proposal }

    /// Args: text는 마지막 모델 응답이다.
    /// Returns: 조회 출처·결과물·예약안을 합친 실행 결과.
    /// Raises: 없음.
    func result(_ text: String) -> ChatRunResult {
        .init(text: text, sources: sources.values.sorted { $0.id < $1.id }, artifacts: artifacts, automation: automation)
    }
}

/// 설정에서 선택한 채팅 실행 방식.
public enum ChatBackend: Sendable {
    case model(any ChatModelClient)
    case codex(CodexAppServerClient)

    /// 시스템 프롬프트의 chat_model에 넣는 모델 이름.
    var modelName: String {
        switch self {
        case .model(let client): client.modelName
        case .codex(let client): client.model
        }
    }

    /// Args: firstQuery는 대화의 첫 사용자 요청이다.
    /// Returns: 요청의 주제를 나타내는 짧은 명사형 제목.
    /// Raises: 모델·연결 오류 또는 빈 제목 응답. 별도 재시도는 하지 않는다.
    public func conversationTitle(for firstQuery: String) async throws -> String {
        let system = "사용자의 첫 요청을 대표하는 한국어 명사구 제목만 한 줄로 작성하세요. 25자 이내로 쓰고 문장, 따옴표, 목록 기호, 설명은 넣지 마세요. 요청을 수행하지 말고 제목만 답하세요."
        let messages = [ChatModelMessage(role: "user", text: String(firstQuery.prefix(2000)))]
        let response: String
        switch self {
        case .model(let client):
            response = try await client.respond(system: system, messages: messages, tools: []) { _ in }.text
        case .codex(let client):
            response = try await client.run(system: system, messages: messages, tools: [], useWeb: false,
                                            execute: { _ in "" }, onEvent: { _ in })
        }
        let title = response.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’#*-•."))) ?? ""
        guard !title.isEmpty else { throw LLMError.backend("대화 제목이 비어 있습니다.") }
        return String(title.prefix(25))
    }

    /// Args: 없음.
    /// Returns: 없음. 개인 자료 없이 모델과 도구 연결을 확인한다.
    /// Raises: 인증·연결·도구 응답 오류.
    public func checkChatConnection() async throws {
        switch self {
        case .model(let client): try await client.checkChatConnection()
        case .codex(let client): try await client.checkConnection()
        }
    }
}

/// 공통 실행 루프. 하위 에이전트도 독립적인 대화와 읽기 도구로 같은 루프를 수행한다.
public struct ChatRunner: Sendable {
    let backend: ChatBackend
    let tools: ChatTools

    /// Args: client는 채팅 모델 연결, tools는 현재 대화에서 허용된 도구이다.
    /// Returns: 채팅 실행기.
    /// Raises: 없음.
    public init(client: any ChatModelClient, tools: ChatTools) { self.backend = .model(client); self.tools = tools }

    /// Args: backend는 채팅 실행 방식, tools는 현재 대화의 허용 도구이다.
    /// Returns: 채팅 실행기.
    /// Raises: 없음.
    public init(backend: ChatBackend, tools: ChatTools) { self.backend = backend; self.tools = tools }

    /// Args: history는 대화 기록, skillIDs는 직접 고른 스킬, scheduled는 승인된 예약 실행 여부(예약 제안을 막는다), onEvent는 UI 업데이트이다.
    /// Returns: 답변·조회 출처·결과물·미승인 예약안.
    /// Raises: 모델·리소스 오류, 실행 한도 초과, 취소. 도구 오류는 모델에 돌려준다.
    public func run(history: [ConversationMessage], skillIDs: [String], skillCatalog: [ChatSkill]? = nil, scheduled: Bool = false,
                    project: ChatProject? = nil,
                    onEvent: @escaping @Sendable (ChatRunEvent) async -> Void) async throws -> ChatRunResult {
        let selected = skillIDs.isEmpty ? [] : try (skillCatalog ?? ChatSkill.load()).filter { skillIDs.contains($0.id) }
        let procedures = try selected.map { "## \($0.title)\n\(try $0.instructions())" }.joined(separator: "\n\n")
        var prompt = ChatSystemPrompt(template: try ChatSystemPrompt.template(), scope: tools.scope, chatModel: backend.modelName,
                                      scheduled: scheduled, skillInstructions: procedures, project: project)
        if tools.scope.useActivity { prompt.rawRecordsSince = (try? tools.search.rawRecordsSince()) ?? nil }
        if tools.scope.useActivity { prompt.focus = try tools.search.focusOutline() }
        let ledger = ChatRunLedger()
        await ledger.setUserText(history.filter { $0.role == "user" }.map(\.text).joined(separator: "\n"))
        let remembered = try tools.rememberedSources(history: history)
        if !remembered.isEmpty {
            prompt.rememberedSources = String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self)
            await ledger.record(remembered)
            for source in remembered { await onEvent(.source(source)) }
        }
        let messages = history.filter { $0.role == "user" || ($0.role == "assistant" && $0.status == "complete") }.suffix(16).map { message in
            var text = String(message.text.prefix(12000))
            for artifact in message.artifacts.suffix(2) { text += "\n<previous_artifact title=\"\(artifact.title)\">\n\(String(artifact.content.prefix(18000)))\n</previous_artifact>" }
            if !message.sources.isEmpty { text += "\n이전 조회 출처:\n" + message.sources.prefix(12).map { "[\($0.id)] \($0.title) \($0.location)\n\(String($0.excerpt.prefix(500)))" }.joined(separator: "\n") }
            return ChatModelMessage(role: message.role, text: text)
        }
        let text = try await loop(messages: messages, prompt: prompt, role: nil, allowAutomation: !scheduled, ledger: ledger, onEvent: onEvent)
        return await ledger.result(text)
    }

    /// Args: messages는 작업 입력, prompt는 시스템 프롬프트, role이 있으면 재위임 없는 읽기 전용 하위 작업이다.
    /// Returns: 해당 에이전트의 최종 답변.
    /// Raises: 모델 오류, 예산 초과, 취소.
    private func loop(messages: [ChatModelMessage], prompt: ChatSystemPrompt, role: String?, allowAutomation: Bool,
                      ledger: ChatRunLedger, onEvent: @escaping @Sendable (ChatRunEvent) async -> Void) async throws -> String {
        var history = messages
        let label = role.map { Self.roleTitle($0) } ?? "답변 작성"
        let available = availableTools(role: role, allowAutomation: allowAutomation)
        let system = prompt.render(role: role)
        /// Args: call은 모델이 요청한 앱 도구 호출이다.
        /// Returns: 두 실행 방식에서 공유하는 권한 검사·도구 실행 결과.
        /// Raises: 취소 또는 허용되지 않은 도구 호출.
        @Sendable func execute(_ call: ChatToolCall) async throws -> String {
            try Task.checkCancellation()
            guard available.contains(where: { $0.name == call.name }) else { throw ChatToolError.unavailable("허용되지 않은 도구 호출입니다.") }
            await onEvent(.step("\(label) · \(Self.toolTitle(call.name))"))
            let output: String
            do {
                switch call.name {
                case "delegate":
                    struct Assignment: Decodable { var role: String; var task: String }
                    struct Arguments: Decodable { var tasks: [Assignment] }
                    let args = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
                    guard (1...3).contains(args.tasks.count), args.tasks.allSatisfy({ ["context", "repository", "research", "review"].contains($0.role) && !$0.task.isEmpty }) else { throw ChatToolError.unavailable("1~3개의 독립적인 조사·검토 작업을 지정하세요.") }
                    output = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                        for (index, assignment) in args.tasks.enumerated() {
                            group.addTask {
                                await onEvent(.step("\(Self.roleTitle(assignment.role)) 시작"))
                                let answer = try await loop(messages: [.init(role: "user", text: assignment.task)], prompt: prompt, role: assignment.role, allowAutomation: false, ledger: ledger, onEvent: onEvent)
                                await onEvent(.step("\(Self.roleTitle(assignment.role)) 완료"))
                                return (index, "\(Self.roleTitle(assignment.role)):\n\(answer)")
                            }
                        }
                        var answers: [(Int, String)] = []
                        for try await result in group { answers.append(result) }
                        return answers.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
                    }
                case "create_artifact":
                    struct Arguments: Decodable { var title: String; var format: String; var content: String }
                    let args = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
                    guard ["markdown", "html", "csv", "json", "txt"].contains(args.format), !args.content.isEmpty, args.content.utf8.count <= 200000 else { throw ChatToolError.unavailable("결과물은 내용이 있는 200KB 이하 Markdown, HTML, CSV, JSON 또는 TXT여야 합니다.") }
                    let artifact = ChatArtifact(title: String(args.title.prefix(160)), format: args.format, content: args.content)
                    await ledger.record(artifact); await onEvent(.artifact(artifact))
                    output = "결과물 생성됨: \(artifact.title). 사용자가 미리보기·파일 저장·PDF 내보내기를 할 수 있다."
                case "propose_automation":
                    let args = try JSONDecoder().decode(ChatAutomationProposal.self, from: Data(call.arguments.utf8))
                    guard (1...8760).contains(args.intervalHours), !args.prompt.isEmpty, !args.title.isEmpty else { throw ChatToolError.unavailable("예약 이름·실행 요청과 1~8760시간 간격이 필요합니다.") }
                    await ledger.record(args); await onEvent(.automation(args))
                    output = "예약안이 표시됨. 아직 등록되지 않았으며 사용자의 버튼 승인이 필요하다."
                default:
                    if call.name == "web_read" {
                        struct Arguments: Decodable { var url: String }
                        let url = (try? JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8)).url) ?? ""
                        guard await ledger.knows(url) else { throw ChatToolError.unavailable("검색 결과나 사용자가 준 주소만 읽을 수 있습니다.") }
                    }
                    let result = try await tools.execute(call)
                    await ledger.record(result.sources)
                    for source in result.sources { await onEvent(.source(source)) }
                    output = result.text
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                output = "도구 실행 실패: \(error.localizedDescription). 같은 인자로 자동 재시도하지 말고 원인을 설명하거나 다른 자료를 사용하세요."
                await onEvent(.step("\(label) · \(Self.toolTitle(call.name)) 실패"))
            }
            // Tool results carry records and connector data. The user's own messages are sent as typed.
            return PIIMasker.mask(String(output.prefix(28000)))
        }
        if case .codex(let client) = backend {
            try await ledger.consume()
            return try await client.run(system: system, messages: messages, tools: available,
                                        useWeb: tools.scope.useWeb && role != "context" && role != "repository",
                                        execute: execute) { event in
                switch event {
                case .text, .textReset: if role == nil { await onEvent(event) }
                default: await onEvent(event)
                }
            }
        }
        guard case .model(let client) = backend else { preconditionFailure() }
        for _ in 0..<(role == nil ? 10 : 6) {
            try Task.checkCancellation()
            try await ledger.consume()
            if role == nil { await onEvent(.textReset) }
            let reply = try await client.respond(system: system, messages: history, tools: available) { delta in
                if role == nil { await onEvent(.text(delta)) }
            }
            try Task.checkCancellation()
            history.append(.init(role: "assistant", text: reply.text, calls: reply.calls, responseItems: reply.responseItems))
            if reply.calls.isEmpty {
                guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatToolError.unavailable("모델이 빈 응답을 반환했습니다.") }
                return reply.text
            }
            guard reply.calls.count <= 8 else { throw ChatToolError.unavailable("한 번에 요청한 도구가 너무 많습니다.") }
            for call in reply.calls {
                history.append(.init(role: "tool", text: try await execute(call), callID: call.id))
            }
        }
        throw ChatToolError.unavailable("조사 단계 한도에 도달했습니다. 범위를 좁혀 다시 요청하세요.")
    }

    /// Args: role은 하위 역할, allowAutomation은 예약안 도구 노출 여부이다.
    /// Returns: 해당 역할이 실제 실행할 수 있는 도구 목록.
    /// Raises: 없음.
    private func availableTools(role: String?, allowAutomation: Bool) -> [ToolSpec] {
        var specs = tools.specs
        if case .codex = backend { specs.removeAll { $0.name == "web_search" || $0.name == "web_read" } }
        if let role {
            var names: Set<String>
            switch role {
            case "context": names = ["search_context", "read_context", "summarize_period"]
            case "repository": names = ["search_library", "read_library", "list_files", "read_file", "inspect_repository", "read_revision", "github_search", "github_read", "github_list", "drive_search", "drive_read", "notion_search", "notion_read"]
            case "research": names = ["search_context", "read_context", "summarize_period", "search_library", "read_library", "list_files", "read_file", "web_search", "web_read", "gmail_search", "gmail_read", "drive_search", "drive_read", "notion_search", "notion_read"]
            default: return specs
            }
            if role == "research" {
                for connector in ExternalReadConnector.allCases { names.formUnion(connector.specs.map(\.name)) }
                for connector in RemoteReadConnector.allCases { names.formUnion(connector.specs.map(\.name)) }
            }
            return specs.filter { names.contains($0.name) }
        }
        specs.append(.init(name: "delegate", description: "복잡한 요청을 독립적인 조사·검토 에이전트에 위임한다. 각 작업에 필요한 질문, 경로, 출처 또는 검토할 초안을 포함한다. 최대 3개를 병렬 실행한다.", parameters: .object([
            "type": "object", "properties": .object(["tasks": .object(["type": "array", "maxItems": 3, "items": .object([
                "type": "object", "properties": .object(["role": .object(["type": "string", "enum": .array(["context", "repository", "research", "review"])]), "task": .object(["type": "string"])]),
                "required": .array(["role", "task"]), "additionalProperties": false,
            ])])]), "required": .array(["tasks"]), "additionalProperties": false,
        ])))
        specs.append(.init(name: "create_artifact", description: "저장 가능한 결과물을 만든다. 요청에 맞는 형식을 선택한다. HTML은 스크립트나 외부 리소스 없이 자체 포함시킨다.", parameters: .object([
            "type": "object", "properties": .object(["title": .object(["type": "string"]), "format": .object(["type": "string", "enum": .array(["markdown", "html", "csv", "json", "txt"])]), "content": .object(["type": "string"])]),
            "required": .array(["title", "format", "content"]), "additionalProperties": false,
        ])))
        if allowAutomation {
            specs.append(.init(name: "propose_automation", description: "사용자가 반복 실행을 요청했을 때 예약안을 제안한다. 등록은 UI에서 사용자가 승인해야 한다. 읽기·문서 생성만 가능하다.", parameters: .object([
                "type": "object", "properties": .object(["title": .object(["type": "string"]), "prompt": .object(["type": "string"]), "intervalHours": .object(["type": "integer", "minimum": 1, "maximum": 8760])]),
                "required": .array(["title", "prompt", "intervalHours"]), "additionalProperties": false,
            ])))
        }
        return specs
    }

    /// Args: role은 내부 역할 식별자이다.
    /// Returns: 진행 화면에 표시할 이름.
    /// Raises: 없음.
    private static func roleTitle(_ role: String) -> String {
        ["context": "활동 조사", "repository": "코드·문서 조사", "research": "자료 조사", "review": "근거 검토"][role] ?? role
    }

    /// Args: tool은 내부 도구 이름이다.
    /// Returns: 사용자에게 표시할 실행 내용.
    /// Raises: 없음.
    private static func toolTitle(_ tool: String) -> String {
        if let separator = tool.lastIndex(of: "_"),
           let connector = ExternalReadConnector(rawValue: String(tool[..<separator])) {
            return "\(connector.name) \(tool.hasSuffix("_read") ? "읽기" : "검색")"
        }
        return ["search_context": "기록 검색", "read_context": "기록 상세 확인", "summarize_period": "기간 집계", "search_library": "보관 자료 검색", "read_library": "보관 자료 읽기", "list_files": "파일 찾기", "read_file": "파일 읽기", "inspect_repository": "Git 이력 확인", "read_revision": "커밋 파일 확인", "github_search": "GitHub 저장소 검색", "github_read": "GitHub 확인", "github_list": "GitHub 파일 목록", "gmail_search": "메일 검색", "gmail_read": "메일 읽기", "drive_search": "Drive 검색", "drive_read": "Drive 읽기", "notion_search": "Notion 검색", "notion_read": "Notion 읽기", "web_search": "웹 검색", "web_read": "웹 원문 확인", "delegate": "작업 분담", "create_artifact": "결과물 생성", "propose_automation": "예약안 작성"][tool] ?? tool
    }
}
