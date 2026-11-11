import Foundation

/// OpenAI 호환 `/chat/completions` 클라이언트.
/// 기본 대상은 gpt-proxy (http://localhost:5010/v1). Ollama, LM Studio 등도 같은 코드로 붙는다.
public final class OpenAICompatClient: LLMClient, @unchecked Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String?
    let timeout: TimeInterval
    let session: URLSession

    public var modelName: String { model }

    public init(baseURL: URL, model: String, apiKey: String? = nil, timeout: TimeInterval = 180, session: URLSession = .shared) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey
        self.timeout = timeout; self.session = session
    }

    public func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        do {
            return try await send(system: system, user: user, tool: tool, forceTool: true)
        } catch LLMError.http(let status, let body) where status == 400 || status == 422 || body.contains("tool_choice") {
            // tool_choice 를 모르는 서버: 빼고 한 번만 다시 시도 (본문 JSON 폴백으로 받는다).
            return try await send(system: system, user: user, tool: tool, forceTool: false)
        }
    }

    /// GET {base}/models 가 200 이면 서버는 살아 있다. (토큰이 유효한지는 selfTest 로 확인)
    public func ping() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 5
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func availableModels() async throws -> [String] {
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 12
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else {
            throw LLMError.backend("API에서 모델 목록을 가져오지 못했어요.")
        }
        let ids = try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).filter { !$0.isEmpty }
        return Array(Set(ids)).sorted()
    }

    // MARK: 요청·응답

    private struct RequestBody: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Tool: Encodable {
            struct Function: Encodable { let name: String; let description: String; let parameters: JSONValue }
            let type = "function"
            let function: Function
        }
        let model: String
        let stream = false
        let messages: [Message]
        let tools: [Tool]
        let tool_choice: String?
    }

    private func send(system: String, user: String, tool: ToolSpec, forceTool: Bool) async throws -> LLMResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body = RequestBody(model: model,
                               messages: [.init(role: "system", content: PIIMasker.mask(system)), .init(role: "user", content: PIIMasker.mask(user))],
                               tools: [.init(function: .init(name: tool.name, description: tool.description, parameters: tool.parameters))],
                               tool_choice: forceTool ? "required" : nil)
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.http(status, String(raw.prefix(600))) }
        return try Self.parse(raw: raw, data: data, fallbackModel: model)
    }

    static func parse(raw: String, data: Data, fallbackModel: String) throws -> LLMResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.noJSON(String(raw.prefix(300)))
        }
        let usage = root["usage"] as? [String: Any]
        let promptTokens = (usage?["prompt_tokens"] as? Int) ?? 0
        let completionTokens = (usage?["completion_tokens"] as? Int) ?? 0
        let model = (root["model"] as? String) ?? fallbackModel

        var candidates: [String] = []
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                if let function = call["function"] as? [String: Any], let arguments = function["arguments"] as? String {
                    candidates.append(arguments)
                }
            }
        }
        if let content = message["content"] as? String { candidates.append(content) }

        for candidate in candidates {
            if let json = extractJSON(from: candidate), let jsonData = json.data(using: .utf8) {
                return LLMResult(arguments: jsonData, model: model, promptTokens: promptTokens,
                                 completionTokens: completionTokens, raw: raw)
            }
        }
        throw LLMError.noJSON(String((candidates.first ?? raw).prefix(300)))
    }

    /// 텍스트에서 첫 번째 완결된 JSON 객체를 찾는다. 문자열 안의 중괄호는 무시한다.
    static func extractJSON(from text: String) -> String? {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else { index += 1; continue }
            var depth = 0, inString = false, escaped = false, cursor = index
            while cursor < chars.count {
                let c = chars[cursor]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(chars[index...cursor])
                        if let data = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
                            return candidate
                        }
                        break
                    }
                }
                cursor += 1
            }
            index += 1
        }
        return nil
    }
}
