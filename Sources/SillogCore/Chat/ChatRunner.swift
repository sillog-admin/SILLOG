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
        guard let url = resourceBundle.url(forResource: "catalog", withExtension: "json", subdirectory: "Skills") else { throw ChatToolError.unavailable(tr("스킬 목록을 찾을 수 없습니다.")) }
        return try JSONDecoder().decode([ChatSkill].self, from: Data(contentsOf: url))
    }

    /// Args: 없음.
    /// Returns: 이 스킬의 작업 절차.
    /// Raises: 지침 리소스 누락·읽기 오류.
    public func instructions() throws -> String {
        if let customInstructions { return customInstructions }
        guard let instructionFile, let url = Self.resourceBundle.url(forResource: instructionFile, withExtension: nil, subdirectory: "Skills") else { throw ChatToolError.unavailable(tr("스킬 지침을 찾을 수 없습니다: \(title)")) }
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
    case stepStarted(ChatStep)
    case stepFinished(id: String, result: String, failed: Bool)
    case source(ChatSource)
    case artifact(ChatArtifact)
    case automation(ChatAutomationProposal)
}

public struct ChatRunResult: Sendable {
    public var text: String
    public var sources: [ChatSource]
    public var artifacts: [ChatArtifact]
    public var automation: ChatAutomationProposal?
    public var memory: ChatMemory?
}

private actor ChatRunLedger {
    var sources: [String: ChatSource] = [:]
    var artifacts: [ChatArtifact] = []
    var earlier: [ChatArtifact] = []
    var automation: ChatAutomationProposal?
    var calls = 0
    var userText = ""

    func setUserText(_ text: String) { userText = text }
    func setEarlier(_ values: [ChatArtifact]) { earlier = values }

    /// Blocks prompt-injected exfiltration: web_read only follows URLs the user wrote or a tool returned.
    func knows(_ url: String) -> Bool {
        let trimmed = url.hasSuffix("/") ? String(url.dropLast()) : url
        return !trimmed.isEmpty && (userText.contains(trimmed) || sources.values.contains { $0.location == url || $0.location == trimmed })
    }

    /// Args: 없음.
    /// Returns: 없음. 주·하위 에이전트가 공유하는 실행 예산을 차감한다.
    /// Raises: 한 요청에서 모델 호출이 24회를 초과한 경우.
    func consume() throws {
        guard calls < 24 else { throw ChatToolError.unavailable(tr("조사 단계 한도에 도달했습니다. 요청 범위를 좁혀 다시 시도하세요.")) }
        calls += 1
    }

    /// Args: values는 실제 도구에서 얻은 출처이다.
    /// Returns: 없음. 중복 출처는 최신 조회 내용으로 갱신한다.
    /// Raises: 없음.
    func record(_ values: [ChatSource]) { for value in values { sources[value.id] = value } }

    /// Args: artifact is the new result, revises the id of an earlier one it replaces.
    /// Returns: the artifact joined to that one's series; an unknown id starts a new series.
    /// Raises: none.
    func record(_ artifact: ChatArtifact, revises: String?) -> ChatArtifact {
        var artifact = artifact
        artifact.baseID = (earlier + artifacts).last { $0.id == revises }?.seriesID
        artifacts.append(artifact)
        return artifact
    }

    /// Args: proposal은 아직 승인되지 않은 예약안이다.
    /// Returns: 없음.
    /// Raises: 없음.
    func record(_ proposal: ChatAutomationProposal) { automation = proposal }

    /// Args: text는 마지막 모델 응답이다.
    /// Returns: 조회 출처·결과물·예약안을 합친 실행 결과.
    /// Raises: 없음.
    func result(_ text: String, memory: ChatMemory?) -> ChatRunResult {
        .init(text: text, sources: sources.values.sorted { $0.id < $1.id }, artifacts: artifacts, automation: automation, memory: memory)
    }
}

/// 설정에서 선택한 채팅 실행 방식.
public enum ChatBackend: Sendable {
    case model(any ChatModelClient)
    case codex(CodexAppServerClient)

    /// 시스템 프롬프트의 chat_model에 넣는 모델 이름.
    public var modelName: String {
        switch self {
        case .model(let client): client.modelName
        case .codex(let client): client.model
        }
    }

    /// The reasoning effort sent with each turn; nil leaves it to the model.
    public var effort: String? {
        switch self {
        case .model(let client): (client as? OpenAICompatClient)?.reasoningEffort
        case .codex(let client): client.effort
        }
    }

    /// Args: firstQuery는 대화의 첫 사용자 요청이다.
    /// Returns: 요청의 주제를 나타내는 짧은 명사형 제목.
    /// Raises: 모델·연결 오류 또는 빈 제목 응답. 별도 재시도는 하지 않는다.
    public func conversationTitle(for firstQuery: String) async throws -> String {
        let system = "Write only a short \(L10n.current.promptName) noun-phrase title for the user's first request, on one line, within 25 characters. No sentence, quotes, list marks or explanation. Do not carry out the request; answer with the title only."
        let response = try await complete(system: system, text: String(firstQuery.prefix(2000)))
        let title = response.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’#*-•."))) ?? ""
        guard !title.isEmpty else { throw LLMError.backend("대화 제목이 비어 있습니다.") }
        return String(title.prefix(25))
    }

    /// Args: question is the user's request, answer the completed reply to it.
    /// Returns: one short question the user is likely to ask next, written as the user.
    /// Raises: model or connection errors, or an empty reply.
    public func followUpQuestion(question: String, answer: String) async throws -> String {
        let system = "Write the one follow-up question the user is most likely to ask next about this answer, as the user would type it, in \(L10n.current.promptName), on one line, within 40 characters. No quotes, list marks or explanation. Do not answer it."
        let text = "Question:\n\(question.prefix(2000))\n\nAnswer:\n\(answer.prefix(4000))"
        guard let line = Self.followUpLine(try await complete(system: system, text: text)) else { throw LLMError.backend("후속 질문이 비어 있습니다.") }
        return line
    }

    /// Args: response is the model's raw reply.
    /// Returns: its first non-empty line without quotes or list marks, at most 60 characters; nil if there is none.
    /// Raises: 없음.
    static func followUpLine(_ response: String) -> String? {
        let marks = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’#*-•>"))
        let line = response.components(separatedBy: .newlines).lazy
            .map { $0.trimmingCharacters(in: marks) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(60)) }
    }

    /// Args: system is the instruction, text the single user message.
    /// Returns: the model's reply, with no tools.
    /// Raises: model, connection or cancellation errors.
    func complete(system: String, text: String) async throws -> String {
        let messages = [ChatModelMessage(role: "user", text: text)]
        switch self {
        case .model(let client):
            // Short calls keep the server default, as Codex calls do below.
            let plain = (client as? OpenAICompatClient).map { OpenAICompatClient(baseURL: $0.baseURL, model: $0.model, apiKey: $0.apiKey, timeout: $0.timeout, session: $0.session) } ?? client
            return try await plain.respond(system: system, messages: messages, tools: []) { _ in }.text
        case .codex(var client):
            // Titles and memory summaries are short; they keep the model default whatever effort the user picked for answers.
            client.effort = client.defaultEffort
            return try await client.run(system: system, messages: messages, tools: [], useWeb: false, execute: { _ in "" }, onEvent: { _ in })
        }
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
    static let artifactFormats = ["markdown", "html", "csv", "json", "txt"] + OfficeFormat.allCases.map(\.rawValue)
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

    /// Args: history는 대화 기록, skillIDs는 직접 고른 스킬, scheduled는 승인된 예약 실행 여부(예약 제안을 막는다), memory는 저장된 앞부분 요약, userInstructions는 설정의 개인 답변 지침(비면 넣지 않음), onEvent는 UI 업데이트이다.
    /// Returns: 답변·조회 출처·결과물·미승인 예약안, and the summary to store when older messages no longer fit.
    /// Raises: 모델·리소스 오류, 실행 한도 초과, 취소. 도구 오류는 모델에 돌려준다.
    public func run(history: [ConversationMessage], skillIDs: [String], skillCatalog: [ChatSkill]? = nil, scheduled: Bool = false,
                    project: ChatProject? = nil, memory: ChatMemory? = nil, userInstructions: String = "",
                    onEvent: @escaping @Sendable (ChatRunEvent) async -> Void) async throws -> ChatRunResult {
        let selected = skillIDs.isEmpty ? [] : try (skillCatalog ?? ChatSkill.load()).filter { skillIDs.contains($0.id) }
        let procedures = try selected.map { "## \($0.title)\n\(try $0.instructions())" }.joined(separator: "\n\n")
        var prompt = ChatSystemPrompt(template: try ChatSystemPrompt.template(), scope: tools.scope, chatModel: backend.modelName,
                                      scheduled: scheduled, skillInstructions: procedures, project: project)
        prompt.userInstructions = userInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if tools.scope.useActivity { prompt.rawRecordsSince = (try? tools.search.rawRecordsSince()) ?? nil }
        if tools.scope.useActivity { prompt.focus = try tools.search.focusOutline() }
        let ledger = ChatRunLedger()
        await ledger.setUserText(history.filter { $0.role == "user" }.map(\.text).joined(separator: "\n"))
        await ledger.setEarlier(history.flatMap(\.artifacts))
        // A stopped answer's partial text stays in, so "continue" can pick up where it ended.
        let eligible = Array(history.filter { $0.role == "user" || ($0.role == "assistant" && ($0.status == "complete" || (["cancelled", "interrupted"].contains($0.status) && !$0.text.isEmpty))) })
        // Older versions of a revised artifact are replaced by the latest, so only that one is resent.
        let latest = Set(Dictionary(eligible.flatMap(\.artifacts).map { ($0.seriesID, $0.id) }, uniquingKeysWith: { $1 }).values)
        let rendered = eligible.indices.map { index in
            let message = eligible[index]
            // The question being asked now is sent whole up to the budget; window() always keeps it.
            let last = index == eligible.count - 1 && message.role == "user"
            var text = String(message.text.prefix(last ? Self.historyBudget : 12000))
            for artifact in message.artifacts.filter({ latest.contains($0.id) }).suffix(2) { text += "\n<previous_artifact id=\"\(artifact.id)\" format=\"\(artifact.format)\" title=\"\(artifact.title)\">\n\(String(artifact.content.prefix(18000)))\n</previous_artifact>" }
            if !message.sources.isEmpty { text += "\n이전 조회 출처:\n" + message.sources.prefix(12).map { "[\($0.id)] \($0.title) \($0.location)\n\(String($0.excerpt.prefix(500)))" }.joined(separator: "\n") }
            return text
        }
        let (start, memory) = try await window(eligible, rendered, memory: memory)
        let remembered = try tools.rememberedSources(history: history, sentIDs: eligible[start...].map(\.id))
        if !remembered.isEmpty {
            prompt.rememberedSources = String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self)
            await ledger.record(remembered)
            for source in remembered { await onEvent(.source(source)) }
        }
        var messages = zip(eligible[start...], rendered[start...]).map { ChatModelMessage(role: $0.role, text: $1) }
        if let memory, start > 0 {
            let note = "<earlier_conversation_summary>\n\(memory.summary)\n</earlier_conversation_summary>"
            if messages.first?.role == "user" { messages[0].text = note + "\n\n" + messages[0].text }
            else { messages.insert(.init(role: "user", text: note), at: 0) }
        }
        if !scheduled, let last = messages.indices.last, messages[last].role == "user" {
            let since = history.dropLast().last(where: { $0.role == "user" })?.createdAt ?? 0
            messages[last].images = try tools.newImages(since: since)
            messages[last].imageData = ChatModelMessage.dataURLs(messages[last].images)
        }
        let text = try await loop(messages: messages, prompt: prompt, role: nil, allowAutomation: !scheduled, ledger: ledger, onEvent: onEvent)
        return await ledger.result(text, memory: memory)
    }

    // shortcut: a fixed character budget, not per-model tokens; size it per model if small local models need less.
    static let historyBudget = 100_000

    static let memoryPrompt = """
    You keep a running summary of the earlier part of a chat between a user and SILLOG's assistant, so the chat can go on without the full text. Merge <previous_summary>, if any, with the new messages. Keep the user's goals and preferences, decisions and their reasons, facts and numbers later answers depend on, artifacts created (title and what they hold), and open questions or promised follow-ups. Drop small talk and anything later messages replaced. Write short bullet points in the conversation's language, under 3,000 characters. Output only the summary.
    """

    /// Args: messages are the sendable messages oldest first, texts their rendered form, memory the stored summary.
    /// Returns: the index of the first message to send in full, and the summary that covers the ones before it.
    /// Raises: cancellation. A failed summary is logged and falls back without a stale summary or a gap.
    private func window(_ messages: [ConversationMessage], _ texts: [String], memory: ChatMemory?) async throws -> (Int, ChatMemory?) {
        let size = { (from: Int) in texts[from...].reduce(0) { $0 + $1.count } }
        // Reuse the stored summary while everything after it still fits, so it isn't redone every turn.
        if let memory, let index = messages.firstIndex(where: { $0.id == memory.through }), size(index + 1) <= Self.historyBudget { return (index + 1, memory) }
        guard size(0) > Self.historyBudget else { return (0, memory) }
        // Keep headroom so the next few turns reuse this summary.
        var start = texts.count, used = 0
        while start > 1, used + texts[start - 1].count <= Self.historyBudget * 6 / 10 { start -= 1; used += texts[start].count }
        start = max(1, min(start, texts.count - 1))
        var from = 0, previous = ""
        if let memory, let index = messages[..<start].firstIndex(where: { $0.id == memory.through }) { from = index + 1; previous = memory.summary }
        // Share the budget across messages so the oldest still reach the summary.
        let cap = max(500, Self.historyBudget / max(1, start - from))
        let transcript = zip(messages[from..<start], texts[from..<start]).map { "<message role=\"\($0.role)\">\n\($1.prefix(cap))\n</message>" }.joined(separator: "\n")
        let input = (previous.isEmpty ? "" : "<previous_summary>\n\(previous)\n</previous_summary>\n") + transcript
        // A failed summary must not inject a stale one or skip the messages after a valid one.
        let fallback: (Int, ChatMemory?) = from > 0 ? (from, memory) : (start, nil)
        do {
            let summary = try await backend.complete(system: Self.memoryPrompt, text: input).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return fallback }
            return (start, ChatMemory(summary: String(summary.prefix(4000)), through: messages[start - 1].id))
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            AppLog.write("chat memory summary failed: \(error)")
            return fallback
        }
    }

    /// Args: messages는 작업 입력, prompt는 시스템 프롬프트, role이 있으면 재위임 없는 읽기 전용 하위 작업이다.
    /// Returns: 해당 에이전트의 최종 답변.
    /// Raises: 모델 오류, 예산 초과, 취소.
    private func loop(messages: [ChatModelMessage], prompt: ChatSystemPrompt, role: String?, allowAutomation: Bool,
                      ledger: ChatRunLedger, onEvent: @escaping @Sendable (ChatRunEvent) async -> Void) async throws -> String {
        var history = messages
        let label = role.map { Self.roleTitle($0) + " · " } ?? ""
        let available = availableTools(role: role, allowAutomation: allowAutomation)
        let system = prompt.render(role: role)
        /// Args: call은 모델이 요청한 앱 도구 호출이다.
        /// Returns: 두 실행 방식에서 공유하는 권한 검사·도구 실행 결과.
        /// Raises: 취소 또는 허용되지 않은 도구 호출.
        @Sendable func execute(_ call: ChatToolCall) async throws -> String {
            try Task.checkCancellation()
            guard available.contains(where: { $0.name == call.name }) else { throw ChatToolError.unavailable(tr("허용되지 않은 도구 호출입니다.")) }
            let step = ChatStep(title: label + Self.toolTitle(call.name), detail: Self.stepDetail(call))
            await onEvent(.stepStarted(step))
            var failed = false
            let output: String
            var shown: String?   // the work log's text when output is an instruction to the model
            do {
                switch call.name {
                case "delegate":
                    struct Assignment: Decodable { var role: String; var task: String }
                    struct Arguments: Decodable { var tasks: [Assignment] }
                    let args = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
                    guard (1...3).contains(args.tasks.count), args.tasks.allSatisfy({ ["context", "repository", "research", "review"].contains($0.role) && !$0.task.isEmpty }) else { throw ChatToolError.unavailable(tr("1~3개의 독립적인 조사·검토 작업을 지정하세요.")) }
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
                    struct Arguments: Decodable { var title: String; var format: String; var content: String; var revises: String? }
                    let args = try JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8))
                    guard Self.artifactFormats.contains(args.format), !args.content.isEmpty, args.content.utf8.count <= 200000 else { throw ChatToolError.unavailable(tr("결과물은 내용이 있는 200KB 이하 Markdown, HTML, CSV, JSON, TXT, DOCX, PPTX 또는 XLSX여야 합니다.")) }
                    let artifact = await ledger.record(ChatArtifact(title: String(args.title.prefix(160)), format: args.format, content: args.content), revises: args.revises)
                    await onEvent(.artifact(artifact))
                    output = "결과물 생성됨: \(artifact.title) (id: \(artifact.id)). 사용자가 미리보기·파일 저장·PDF 내보내기를 할 수 있다."
                    shown = tr("결과물 생성됨: \(artifact.title)")
                case "propose_automation":
                    let args = try JSONDecoder().decode(ChatAutomationProposal.self, from: Data(call.arguments.utf8))
                    guard (1...8760).contains(args.intervalHours), !args.prompt.isEmpty, !args.title.isEmpty else { throw ChatToolError.unavailable(tr("예약 이름·실행 요청과 1~8760시간 간격이 필요합니다.")) }
                    await ledger.record(args); await onEvent(.automation(args))
                    output = "예약안이 표시됨. 아직 등록되지 않았으며 사용자의 버튼 승인이 필요하다."
                    shown = tr("예약안을 표시했어요. 등록하려면 승인이 필요해요.")
                default:
                    if call.name == "web_read" {
                        struct Arguments: Decodable { var url: String }
                        let url = (try? JSONDecoder().decode(Arguments.self, from: Data(call.arguments.utf8)).url) ?? ""
                        guard await ledger.knows(url) else { throw ChatToolError.unavailable(tr("검색 결과나 사용자가 준 주소만 읽을 수 있습니다.")) }
                    }
                    let result = try await tools.execute(call)
                    await ledger.record(result.sources)
                    for source in result.sources { await onEvent(.source(source)) }
                    output = result.text
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                AppLog.write("chat tool \(call.name) failed: \(error) args(\(call.arguments.utf8.count)B)=\(PIIMasker.mask(String(call.arguments.prefix(120))))")
                output = "도구 실행 실패: \(error.localizedDescription). 같은 인자로 자동 재시도하지 말고 원인을 설명하거나 다른 자료를 사용하세요."
                shown = tr("도구 실행 실패: \(error.localizedDescription)")
                failed = true
            }
            // Tool results carry records and connector data. The user's own messages are sent as typed.
            let masked = PIIMasker.mask(String(output.prefix(28000)))
            await onEvent(.stepFinished(id: step.id, result: String((shown.map { PIIMasker.mask($0) } ?? masked).prefix(800)), failed: failed))
            return masked
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
            if reply.droppedImages {
                for index in history.indices { history[index].images = []; history[index].imageData = [] }
            }
            history.append(.init(role: "assistant", text: reply.text, calls: reply.calls, responseItems: reply.responseItems))
            if reply.calls.isEmpty {
                guard !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatToolError.unavailable(tr("모델이 빈 응답을 반환했습니다.")) }
                return reply.text
            }
            guard reply.calls.count <= 8 else { throw ChatToolError.unavailable(tr("한 번에 요청한 도구가 너무 많습니다.")) }
            for call in reply.calls {
                history.append(.init(role: "tool", text: try await execute(call), callID: call.id))
            }
        }
        throw ChatToolError.unavailable(tr("조사 단계 한도에 도달했습니다. 범위를 좁혀 다시 요청하세요."))
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
            case "repository": names = ["search_library", "read_library", "list_files", "read_file", "inspect_repository", "read_revision", "github_search", "github_read", "github_list", "drive_search", "drive_read", "notion_search", "notion_read", "notion_tools"]
            case "research": names = ["search_context", "read_context", "summarize_period", "search_library", "read_library", "list_files", "read_file", "web_search", "web_read", "drive_search", "drive_read", "notion_search", "notion_read"]
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
        specs.append(.init(name: "create_artifact", description: "저장 가능한 결과물을 만든다. 요청에 맞는 형식을 선택한다. HTML은 스크립트나 외부 리소스 없이 자체 포함시킨다. docx는 Markdown, pptx는 슬라이드마다 # 제목과 - 항목을 쓴 Markdown, xlsx는 머리글 행이 있는 CSV로 content를 쓴다. 이전 결과물을 고친 것이면 그 previous_artifact의 id를 revises에 넣는다.", parameters: .object([
            "type": "object", "properties": .object(["title": .object(["type": "string"]), "format": .object(["type": "string", "enum": .array(Self.artifactFormats.map { .string($0) })]), "content": .object(["type": "string"]),
                                                     "revises": .object(["type": "string", "description": "id of the previous_artifact this revises; omit for a new artifact"])]),
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

    /// Args: call is a tool call from the model.
    /// Returns: what the call looks at, such as its query, path, address or title, for the work log.
    /// Raises: none.
    static func stepDetail(_ call: ChatToolCall) -> String {
        guard let args = try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8)).objectValue else { return "" }
        if let tasks = args["tasks"]?.arrayValue { return String(tasks.compactMap { $0.objectValue?["task"]?.stringValue }.joined(separator: " / ").prefix(300)) }
        for key in ["query", "path", "url", "title", "id", "repository", "from"] {
            if let value = args[key]?.stringValue, !value.isEmpty {
                let text = key == "from" ? "\(value) – \(args["to"]?.stringValue ?? "")" : value
                return PIIMasker.mask(String(text.prefix(300)))
            }
        }
        return ""
    }

    /// Args: role은 내부 역할 식별자이다.
    /// Returns: 진행 화면에 표시할 이름.
    /// Raises: 없음.
    private static func roleTitle(_ role: String) -> String { roleTitles[role] ?? role }

    static let roleTitles = ["context": "활동 조사", "repository": "코드·문서 조사", "research": "자료 조사", "review": "근거 검토"]
    static let toolTitles = ["search_context": "기록 검색", "read_context": "기록 상세 확인", "summarize_period": "기간 집계", "search_library": "보관 자료 검색", "read_library": "보관 자료 읽기", "list_files": "파일 찾기", "read_file": "파일 읽기", "inspect_repository": "Git 이력 확인", "read_revision": "커밋 파일 확인", "github_search": "GitHub 저장소 검색", "github_read": "GitHub 확인", "github_list": "GitHub 파일 목록", "drive_search": "Drive 검색", "drive_read": "Drive 읽기", "notion_search": "Notion 검색", "notion_read": "Notion 읽기", "web_search": "웹 검색", "web_read": "웹 원문 확인", "delegate": "작업 분담", "create_artifact": "결과물 생성", "propose_automation": "예약안 작성"]

    /// Args: title is a stored step title such as "활동 조사 · 기록 검색" or "Slack 읽기".
    /// Returns: the title in the app language, a part repeating the one before it dropped. Titles are saved in Korean, so old answers follow a language change too.
    /// Raises: none.
    public static func displayTitle(_ title: String) -> String {
        title.components(separatedBy: " · ").map { part in
            guard L10n.english[part] == nil, let suffix = [" 시작", " 완료", " 읽기", " 검색", " 실패", " 사용자 메시지", "부터"].first(where: { part.hasSuffix($0) }) else { return L10n.tr(key: part) }
            var text = LocalizedText(stringLiteral: "%@" + suffix)
            text.args = [displayTitle(String(part.dropLast(suffix.count)))]
            return L10n.tr(text)
        }.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }.joined(separator: " · ")
    }

    /// Args: tool은 내부 도구 이름이다.
    /// Returns: 사용자에게 표시할 실행 내용.
    /// Raises: 없음.
    private static func toolTitle(_ tool: String) -> String {
        if let separator = tool.lastIndex(of: "_"),
           let connector = ExternalReadConnector(rawValue: String(tool[..<separator])) {
            return "\(connector.name) \(tool.hasSuffix("_read") ? "읽기" : "검색")"
        }
        return toolTitles[tool] ?? tool
    }
}
