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

    /// Args: role·text는 메시지, calls·callID는 도구 대화, responseItems는 Responses 재전송 항목이다.
    /// Returns: 모델에 전달할 대화 항목.
    /// Raises: 없음.
    public init(role: String, text: String, calls: [ChatToolCall] = [], callID: String? = nil, responseItems: [JSONValue] = []) {
        self.role = role; self.text = text; self.calls = calls; self.callID = callID; self.responseItems = responseItems
    }
}

public struct ChatModelReply: Sendable {
    public var text: String
    public var calls: [ChatToolCall]
    public var responseItems: [JSONValue]

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

    /// Args: payload는 하나의 SSE data 이벤트이다.
    /// Returns: 이번 이벤트에서 추가된 본문.
    /// Raises: JSON 오류, 서버 실패, 미완료 도구 호출.
    mutating func accept(_ payload: String) throws -> String {
        if payload == "[DONE]" { return "" }
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)).objectValue ?? [:]
        if let error = root["error"], error != .null { throw LLMError.backend("채팅 응답 오류: \(error.objectValue?["message"]?.stringValue ?? "요청 실패")") }
        switch format {
        case .responses:
            switch root["type"]?.stringValue {
            case "response.output_text.delta", "response.refusal.delta":
                let delta = root["delta"]?.stringValue ?? ""
                text += delta
                return delta
            case "response.output_item.done":
                if let item = root["item"], let index = root["output_index"]?.doubleValue {
                    finishedItems[Int(index)] = item
                }
            case "response.completed":
                let response = root["response"]?.objectValue ?? [:]
                guard response["status"]?.stringValue == "completed" else { throw LLMError.backend("응답이 완료되지 않았습니다.") }
                // Codex는 개별 완료 이벤트에만 항목을 보내고 마지막 output은 비워 둘 수 있다.
                let output = response["output"]?.arrayValue ?? []
                for (index, item) in output.enumerated() { finishedItems[index] = item }
                items = finishedItems.sorted { $0.key < $1.key }.map(\.value)
                for (index, item) in items.enumerated() {
                    let value = item.objectValue ?? [:]
                    if value["type"]?.stringValue == "function_call" {
                        guard let id = value["call_id"]?.stringValue, let name = value["name"]?.stringValue,
                              let arguments = value["arguments"]?.stringValue else { throw LLMError.backend("도구 호출 형식이 올바르지 않습니다.") }
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
                    ?? root["message"]?.stringValue ?? "모델 설정이나 사용량을 확인하세요."
                throw LLMError.backend("응답 생성 중단: \(detail)")
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
                guard finish == "stop" || finish == "tool_calls" else { throw LLMError.backend("응답이 중단되었습니다: \(finish)") }
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
        guard completed else { throw LLMError.transport("채팅 스트림이 완료되기 전에 연결이 종료되었습니다.") }
        let ordered = calls.sorted { $0.key < $1.key }.map(\.value)
        guard ordered.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { throw LLMError.backend("도구 호출 식별자가 없습니다.") }
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
            throw LLMError.backend("본문 연결은 되었지만 도구 호출을 확인하지 못했습니다. 도구 호출을 지원하는 채팅 모델을 선택하세요.")
        }
        messages.append(.init(role: "assistant", text: reply.text, calls: reply.calls, responseItems: reply.responseItems))
        messages += reply.calls.map { .init(role: "tool", text: "확인 성공", callID: $0.id) }
        let answer = try await respond(system: system, messages: messages, tools: [tool]) { _ in }
        guard answer.calls.isEmpty, !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.backend("도구 호출 후 최종 답변을 확인하지 못했습니다.")
        }
    }
}

enum ChatStream {
    /// Args: request·session은 연결, format은 프로토콜, onText는 UI 본문 콜백이다.
    /// Returns: 스트림에서 완성한 모델 응답.
    /// Raises: HTTP·전송·파싱 오류와 취소. 자동 재시도하지 않는다.
    static func read(_ request: URLRequest, session: URLSession, format: ChatStreamParser.Format,
                     onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
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
                    return [.object(["role": .string(message.role), "content": .string(message.text)])]
                }),
                "tools": .array(tools.map { .object(["type": "function", "name": .string($0.name), "description": .string($0.description), "parameters": $0.parameters, "strict": false]) }),
            ]
            if let reasoningEffort { body["reasoning"] = .object(["effort": .string(reasoningEffort)]) }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"; request.timeoutInterval = timeout
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            if let account = credentials.accountId { request.setValue(account, forHTTPHeaderField: "chatgpt-account-id") }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
            do { return try await ChatStream.read(request, session: session, format: .responses, onText: onText) }
            catch LLMError.http(let status, _) where status == 401 && attempt == 0 {
                credentials = try await auth.refreshAfterRejection(of: credentials.accessToken)
            }
        }
        throw LLMError.auth("다시 로그인해주세요.")
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
            if let id = message.callID { value["tool_call_id"] = .string(id) }
            if !message.calls.isEmpty {
                value["tool_calls"] = .array(message.calls.map { .object([
                    "id": .string($0.id), "type": "function", "function": .object(["name": .string($0.name), "arguments": .string($0.arguments)]),
                ]) })
            }
            return .object(value)
        }
        var body: [String: JSONValue] = ["model": .string(model), "stream": true, "messages": .array(values)]
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
        return try await ChatStream.read(request, session: session, format: .completions, onText: onText)
    }
}
