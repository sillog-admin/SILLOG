import Foundation

public struct ChatToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
}

public struct ChatModelMessage: Sendable {
    public var role: String
    public var text: String
    public var calls: [ChatToolCall] = []
    public var callID: String? = nil
    /// Responses의 reasoning 항목도 다음 요청에 함께 전달한다.
    public var responseItems: [JSONValue] = []
    /// Image files sent as pictures with this message.
    public var images: [URL] = []
    /// The images as data URLs, encoded once so each request of a tool loop doesn't read the files again.
    public var imageData: [String] = []

    /// Args: role·text는 메시지, calls·callID는 도구 대화, responseItems는 Responses 재전송 항목, images는 함께 보낼 이미지 파일이다.
    /// Returns: 모델에 전달할 대화 항목.
    /// Raises: 없음.
    public init(role: String, text: String, calls: [ChatToolCall] = [], callID: String? = nil, responseItems: [JSONValue] = [], images: [URL] = []) {
        self.role = role; self.text = text; self.calls = calls; self.callID = callID; self.responseItems = responseItems; self.images = images
        imageData = Self.dataURLs(images)
    }

    static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]

    /// Data URLs of the images that could be read; unreadable files are skipped and logged.
    static func dataURLs(_ images: [URL]) -> [String] {
        images.compactMap { url in
            guard let mime = Self.imageTypes[url.pathExtension.lowercased()] else { return nil }
            do { return "data:\(mime);base64,\(try Data(contentsOf: url).base64EncodedString())" }
            catch { AppLog.write("chat image skipped \(url.lastPathComponent): \(error.localizedDescription)"); return nil }
        }
    }
}

public struct ChatModelReply: Sendable {
    public var text: String
    public var calls: [ChatToolCall]
    public var responseItems: [JSONValue]
    /// The server refused the images and the request went again without them.
    public var droppedImages = false

    /// Args: text는 본문, calls는 완료된 도구 호출, responseItems는 후속 요청에 보존할 항목이다.
    /// Returns: 한 번의 모델 응답.
    /// Raises: 없음.
    public init(text: String, calls: [ChatToolCall] = [], responseItems: [JSONValue] = []) {
        self.text = text; self.calls = calls; self.responseItems = responseItems
    }
}

public protocol ChatModelClient: Sendable {
    /// 시스템 프롬프트의 chat_model에 넣는 모델 이름.
    var modelName: String { get }

    /// Args: system은 작업 지침, messages는 대화, tools는 허용 도구, onText는 본문 조각 콜백이다.
    /// Returns: 완료된 본문과 도구 호출.
    /// Raises: 인증·HTTP·전송·응답 형식 오류 및 취소.
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply

    /// Args: as above, and onReasoning gets a reasoning step id and its summary so far.
    /// Returns: the finished text and tool calls.
    /// Raises: auth, HTTP, transport and response-format errors, and cancellation.
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void,
                 onReasoning: @escaping @Sendable (String, String) async -> Void) async throws -> ChatModelReply
}

extension ChatModelClient {
    /// A client without reasoning summaries answers as before.
    /// Args: as the requirement; onReasoning is never called.
    /// Returns: the reply from respond(system:messages:tools:onText:).
    /// Raises: whatever that call throws.
    public func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                        onText: @escaping @Sendable (String) async -> Void,
                        onReasoning: @escaping @Sendable (String, String) async -> Void) async throws -> ChatModelReply {
        try await respond(system: system, messages: messages, tools: tools, onText: onText)
    }
}

/// Reasoning summary text per summary part, released at line and part ends so the answer isn't redrawn per token.
/// Each part is its own step because each starts with its own heading.
struct ReasoningSummaries {
    private var parts: [String: String] = [:]

    /// Returns: the part's step id and text so far when delta ends a line, else nil.
    mutating func add(_ delta: String, item: String, part: Int) -> (id: String, text: String)? {
        let id = "\(item)#\(part)"
        parts[id, default: ""] += delta
        return delta.contains("\n") ? (id, parts[id] ?? "") : nil
    }

    /// Returns: the part's step id and finished text; value nil keeps the text streamed so far.
    mutating func finish(_ value: String?, item: String, part: Int) -> (id: String, text: String) {
        let id = "\(item)#\(part)"
        if let value { parts[id] = value }
        return (id, parts[id] ?? "")
    }
}

/// 두 연결 방식의 스트림 해석을 공유한다. 완료되지 않은 도구 인자는 실행하지 않는다.
struct ChatStreamParser {
    enum Format { case responses, completions }
    let format: Format
    var text = ""
    var calls: [Int: ChatToolCall] = [:]
    var items: [JSONValue] = []
    var finishedItems: [Int: JSONValue] = [:]
    var completed = false
    var summaries = ReasoningSummaries()
    /// A reasoning item's id and summary to show, set by accept and cleared by its reader.
    var reasoning: (id: String, text: String)?

    /// Args: payload는 하나의 SSE data 이벤트이다.
    /// Returns: 이번 이벤트에서 추가된 본문.
    /// Raises: JSON 오류, 서버 실패, 미완료 도구 호출.
    mutating func accept(_ payload: String) throws -> String {
        if payload == "[DONE]" { return "" }
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)).objectValue ?? [:]
        if let error = root["error"], error != .null { throw LLMError.backend(tr("채팅 응답 오류: \(error.objectValue?["message"]?.stringValue ?? tr("요청 실패"))")) }
        switch format {
        case .responses:
            switch root["type"]?.stringValue {
            case "response.output_text.delta", "response.refusal.delta":
                let delta = root["delta"]?.stringValue ?? ""
                text += delta
                return delta
            case "response.reasoning_summary_text.delta", "response.reasoning_summary_text.done":
                let item = root["item_id"]?.stringValue ?? "", part = Int(root["summary_index"]?.doubleValue ?? 0)
                if let done = root["text"]?.stringValue { reasoning = summaries.finish(done, item: item, part: part) }
                else if let summary = summaries.add(root["delta"]?.stringValue ?? "", item: item, part: part) { reasoning = summary }
            case "response.output_item.done":
                if let item = root["item"], let index = root["output_index"]?.doubleValue {
                    finishedItems[Int(index)] = item
                }
            case "response.completed":
                let response = root["response"]?.objectValue ?? [:]
                guard response["status"]?.stringValue == "completed" else { throw LLMError.backend(tr("응답이 완료되지 않았습니다.")) }
                // Codex는 개별 완료 이벤트에만 항목을 보내고 마지막 output은 비워 둘 수 있다.
                let output = response["output"]?.arrayValue ?? []
                for (index, item) in output.enumerated() { finishedItems[index] = item }
                items = finishedItems.sorted { $0.key < $1.key }.map(\.value)
                for (index, item) in items.enumerated() {
                    let value = item.objectValue ?? [:]
                    if value["type"]?.stringValue == "function_call" {
                        guard let id = value["call_id"]?.stringValue, let name = value["name"]?.stringValue,
                              let arguments = value["arguments"]?.stringValue else { throw LLMError.backend(tr("도구 호출 형식이 올바르지 않습니다.")) }
                        calls[index] = .init(id: id, name: name, arguments: arguments)
                    }
                }
                if text.isEmpty {
                    text = items.flatMap { $0.objectValue?["content"]?.arrayValue ?? [] }
                        .compactMap { $0.objectValue?["text"]?.stringValue ?? $0.objectValue?["refusal"]?.stringValue }.joined()
                }
                completed = true
            case "response.failed", "response.incomplete", "error":
                let response = root["response"]?.objectValue ?? [:]
                let detail = response["error"]?.objectValue?["message"]?.stringValue
                    ?? response["incomplete_details"]?.objectValue?["reason"]?.stringValue
                    ?? root["message"]?.stringValue ?? tr("모델 설정이나 사용량을 확인하세요.")
                throw LLMError.backend(tr("응답 생성 중단: \(detail)"))
            default: break
            }
        case .completions:
            guard let choice = root["choices"]?.arrayValue?.first?.objectValue else { return "" }
            let delta = choice["delta"]?.objectValue ?? [:]
            let fragment = delta["content"]?.stringValue ?? delta["refusal"]?.stringValue ?? ""
            text += fragment
            for value in delta["tool_calls"]?.arrayValue ?? [] {
                let call = value.objectValue ?? [:]
                let index = Int(call["index"]?.doubleValue ?? 0)
                var current = calls[index] ?? .init(id: "", name: "", arguments: "")
                if let id = call["id"]?.stringValue { current.id = id }
                let function = call["function"]?.objectValue ?? [:]
                current.name += function["name"]?.stringValue ?? ""
                current.arguments += function["arguments"]?.stringValue ?? ""
                calls[index] = current
            }
            if let finish = choice["finish_reason"]?.stringValue {
                guard finish == "stop" || finish == "tool_calls" else { throw LLMError.backend(tr("응답이 중단되었습니다: \(finish)")) }
                completed = true
            }
            return fragment
        }
        return ""
    }

    /// Args: 없음.
    /// Returns: 종료 이벤트까지 받은 응답.
    /// Raises: 중단된 스트림 또는 불완전한 도구 호출.
    func result() throws -> ChatModelReply {
        guard completed else { throw LLMError.transport(tr("채팅 스트림이 완료되기 전에 연결이 종료되었습니다.")) }
        let ordered = calls.sorted { $0.key < $1.key }.map(\.value)
        guard ordered.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { throw LLMError.backend(tr("도구 호출 식별자가 없습니다.")) }
        return .init(text: text, calls: ordered, responseItems: items)
    }
}

extension ChatModelClient {
    /// Args: 없음.
    /// Returns: 없음. 개인 자료를 전송하지 않고 도구 호출과 후속 본문 응답을 확인한다.
    /// Raises: 연결·도구 호출·빈 응답 오류. 자동 재시도하지 않는다.
    public func checkChatConnection() async throws {
        let tool = ToolSpec(name: "connection_check", description: "연결 확인용 도구. 인자 없이 한 번 호출한다.", parameters: .object([
            "type": "object", "properties": .object([:]), "additionalProperties": false,
        ]))
        let system = "연결 검사입니다. connection_check를 한 번 호출하고, 결과를 받은 뒤 '연결 확인 완료'라고 답하세요."
        var messages = [ChatModelMessage(role: "user", text: "연결을 확인해주세요.")]
        let reply = try await respond(system: system, messages: messages, tools: [tool]) { _ in }
        guard !reply.calls.isEmpty, reply.calls.allSatisfy({ $0.name == tool.name }) else {
            throw LLMError.backend(tr("본문 연결은 되었지만 도구 호출을 확인하지 못했습니다. 도구 호출을 지원하는 채팅 모델을 선택하세요."))
        }
        messages.append(.init(role: "assistant", text: reply.text, calls: reply.calls, responseItems: reply.responseItems))
        messages += reply.calls.map { .init(role: "tool", text: "확인 성공", callID: $0.id) }
        let answer = try await respond(system: system, messages: messages, tools: [tool]) { _ in }
        guard answer.calls.isEmpty, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.backend(tr("도구 호출 후 최종 답변을 확인하지 못했습니다."))
        }
    }
}

enum ChatStream {
    /// Args: request·session은 연결, format은 프로토콜, onText는 UI 본문 콜백이다.
    /// Returns: 스트림에서 완성한 모델 응답.
    /// Raises: HTTP·전송·파싱 오류와 취소. 자동 재시도하지 않는다.
    static func read(_ request: URLRequest, session: URLSession, format: ChatStreamParser.Format,
                     onText: @escaping @Sendable (String) async -> Void,
                     onReasoning: @escaping @Sendable (String, String) async -> Void = { _, _ in }) async throws -> ChatModelReply {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count >= 600 { break } }
            throw LLMError.http(status, String(data: body, encoding: .utf8) ?? "")
        }
        var parser = ChatStreamParser(format: format)
        var payload: [String] = []
        var lineBytes = Data()
        // AsyncBytes.lines는 빈 줄을 생략하므로 SSE 이벤트 경계를 직접 보존한다.
        for try await byte in bytes {
            if byte != 10 { lineBytes.append(byte); continue }
            try Task.checkCancellation()
            let line = String(decoding: lineBytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            lineBytes.removeAll(keepingCapacity: true)
            if line.hasPrefix("data:") { payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
            if line.isEmpty, !payload.isEmpty {
                let delta = try parser.accept(payload.joined(separator: "\n"))
                payload = []
                if !delta.isEmpty { await onText(delta) }
                if let reasoning = parser.reasoning { parser.reasoning = nil; await onReasoning(reasoning.id, reasoning.text) }
                if parser.completed { break }
            }
        }
        let lastLine = String(decoding: lineBytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        if lastLine.hasPrefix("data:") { payload.append(String(lastLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        if !payload.isEmpty {
            let delta = try parser.accept(payload.joined(separator: "\n"))
            if !delta.isEmpty { await onText(delta) }
        }
        return try parser.result()
    }
}

extension CodexResponsesClient: ChatModelClient {
    /// Args: system·messages·tools는 채팅 입력, onText는 스트리밍 콜백이다.
    /// Returns: reasoning 항목까지 보존한 Responses 응답.
    /// Raises: 인증·HTTP·전송 오류. 401일 때만 기존 인증 방식대로 한 번 갱신한다.
    public func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                        onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        try await respond(system: system, messages: messages, tools: tools, onText: onText, onReasoning: { _, _ in })
    }

    /// Args: chat input as above; onText gets text deltas, onReasoning reasoning summaries.
    /// Returns: the Responses reply with its reasoning items kept.
    /// Raises: auth, HTTP and transport errors. Refreshes the login once, on a 401 only.
    public func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                        onText: @escaping @Sendable (String) async -> Void,
                        onReasoning: @escaping @Sendable (String, String) async -> Void) async throws -> ChatModelReply {
        var credentials = try await auth.credentials()
        for attempt in 0...1 {
            var body: [String: JSONValue] = [
                "model": .string(model), "instructions": .string(system), "store": false, "stream": true,
                "include": .array(["reasoning.encrypted_content"]),
                "input": .array(messages.flatMap { message -> [JSONValue] in
                    if !message.responseItems.isEmpty { return message.responseItems }
                    if let id = message.callID {
                        return [.object(["type": "function_call_output", "call_id": .string(id), "output": .string(message.text)])]
                    }
                    let images = message.imageData
                    if images.isEmpty { return [.object(["role": .string(message.role), "content": .string(message.text)])] }
                    return [.object(["role": .string(message.role), "content": .array([.object(["type": "input_text", "text": .string(message.text)])]
                        + images.map { .object(["type": "input_image", "image_url": .string($0)]) })])]
                }),
                "tools": .array(tools.map { .object(["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters, "strict": false]) }),
            ]
            // Summaries ride on the reasoning object, sent only when an effort is, so a call without one stays as it was.
            if let reasoningEffort { body["reasoning"] = .object(["effort": .string(reasoningEffort), "summary": "auto"]) }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = timeout
            request.setCodexHeaders(credentials, streaming: true)
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
            do { return try await ChatStream.read(request, session: session, format: .responses, onText: onText, onReasoning: onReasoning) }
            catch LLMError.http(let status, _) where status == 401 && attempt == 0 {
                credentials = try await auth.refreshAfterRejection(of: credentials.accessToken)
            }
        }
        throw LLMError.auth(tr("다시 로그인해주세요."))
    }
}

extension OpenAICompatClient: ChatModelClient {
    /// Args: system·messages·tools는 채팅 입력, onText는 스트리밍 콜백이다.
    /// Returns: OpenAI 호환 서버의 본문과 도구 호출.
    /// Raises: HTTP·전송·응답 오류 및 취소. 자동 재시도하지 않는다.
    public func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                        onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        var values: [JSONValue] = [.object(["role": "system", "content": .string(system)])]
        values += messages.map { message in
            var value: [String: JSONValue] = ["role": .string(message.role), "content": .string(message.text)]
            let images = message.imageData
            if !images.isEmpty {
                value["content"] = .array([.object(["type": "text", "text": .string(message.text)])]
                    + images.map { .object(["type": "image_url", "image_url": .object(["url": .string($0)])]) })
            }
            if let id = message.callID { value["tool_call_id"] = .string(id) }
            if !message.calls.isEmpty {
                value["tool_calls"] = .array(message.calls.map { .object([
                    "id": .string($0.id), "type": "function", "function": .object(["name": .string($0.name), "arguments": .string($0.arguments)]),
                ]) })
            }
            return .object(value)
        }
        var body: [String: JSONValue] = ["model": .string(model), "stream": true, "messages": .array(values)]
        if let reasoningEffort { body["reasoning_effort"] = .string(reasoningEffort) }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { .object(["type": "function", "function": .object([
                "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters,
            ])]) })
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        do { return try await ChatStream.read(request, session: session, format: .completions, onText: onText) }
        catch LLMError.http(let status, let detail) where [400, 415, 422].contains(status) && messages.contains(where: { !$0.imageData.isEmpty }) {
            // Text-only models reject image parts; the files stay readable as OCR text through read_library.
            AppLog.write("chat model rejected images (\(status)): \(detail.prefix(200)); retrying without them")
            var reply = try await respond(system: system, messages: messages.map { var m = $0; m.images = []; m.imageData = []; return m }, tools: tools, onText: onText)
            reply.droppedImages = true
            return reply
        }
    }
}

/// Turns a failed chat run into the one sentence shown under the answer.
public enum ChatFailure {
    /// Korean keys of the sentences that a settings fix resolves; text after a `%@` is ignored when matching.
    public static let settingsMessages = [
        "API 키나 로그인이 거부됐어요. 설정에서 확인해 주세요.", "다시 로그인해주세요.", "ChatGPT 로그인이 필요합니다",
        "로그인이 만료되어 다시 로그인해야 합니다 (%@)", "Codex 계정 정보가 없습니다. 설정에서 다시 로그인하세요.",
    ]

    /// Args: error is what the chat run threw.
    /// Returns: the sentence to show, and whether the settings screen can fix it.
    /// Raises: none.
    public static func message(for error: Error) -> (text: String, needsSettings: Bool) {
        if let error = error as? CodexAuthError { return (error.description, needsSettings(error.description)) }
        if case LLMError.auth(let text) = error { return (text, true) }
        if case LLMError.http(let status, _) = error {
            switch status {
            case 401, 403: return (tr("API 키나 로그인이 거부됐어요. 설정에서 확인해 주세요."), true)
            case 429: return (tr("요청 한도에 걸렸어요. 잠시 뒤 다시 시도해 주세요."), false)
            case 500...599: return (tr("모델 서버에 문제가 있어요. 잠시 뒤 다시 시도해 주세요."), false)
            default: break
            }
        }
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost].contains(error.code) {
            return (tr("인터넷 연결이 끊겼어요. 연결을 확인하고 다시 시도해 주세요."), false)
        }
        // A local model server that is down or slow fails this way too, so don't blame the internet.
        if let error = error as? URLError, [.timedOut, .cannotConnectToHost].contains(error.code) {
            return (tr("모델 서버가 응답하지 않았어요. 서버 주소와 실행 상태를 확인해 주세요."), false)
        }
        return (error.localizedDescription, false)
    }

    /// Args: text is a stored failure line, written in whichever language was active then.
    /// Returns: true when it is one of the settings sentences.
    /// Raises: none.
    public static func needsSettings(_ text: String) -> Bool {
        settingsMessages.contains { key in
            [key, L10n.english[key] ?? key].contains { text.contains(String($0.components(separatedBy: "%@")[0])) }
        }
    }
}
