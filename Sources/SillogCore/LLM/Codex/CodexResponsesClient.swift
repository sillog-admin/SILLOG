import Foundation

/// 로그인한 ChatGPT 계정에서 쓸 수 있는 모델 하나.
public struct CodexModel: Equatable, Sendable, Identifiable {
    public let slug: String
    public let displayName: String
    public let defaultEffort: String?
    public var id: String { slug }

    public init(slug: String, displayName: String, defaultEffort: String?) {
        self.slug = slug; self.displayName = displayName; self.defaultEffort = defaultEffort
    }
}

/// 모델 연결 검사에서 성공한 후보와 확인 실패를 모은 결과.
public struct CodexModelVerification: Sendable {
    public struct Failure: Sendable {
        public let model: CodexModel
        public let message: String
    }
    public let models: [CodexModel]
    public let failures: [Failure]
    /// 중단 없이 모든 후보를 확인했는지.
    public let isComplete: Bool
}

/// ChatGPT 구독의 Codex 사용량. Codex CLI 의 /status 와 같은 출처다.
public struct CodexUsage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public let usedPercent: Double
        public let windowSeconds: Int
        public let resetAt: Double

        public init(usedPercent: Double, windowSeconds: Int, resetAt: Double) {
            self.usedPercent = usedPercent; self.windowSeconds = windowSeconds; self.resetAt = resetAt
        }

        public var remainingPercent: Double { usedPercent.isFinite ? min(100, max(0, 100 - usedPercent)) : 0 }

        /// "5시간", "7일" 처럼 창 길이를 읽기 좋게.
        public var label: String {
            let hours = Double(windowSeconds) / 3600
            if hours >= 48 { return "\(Int((hours / 24).rounded()))일" }
            if hours >= 1 { return "\(Int(hours.rounded()))시간" }
            return "\(max(1, windowSeconds / 60))분"
        }
    }

    public let planType: String?
    /// 짧은 창(보통 5시간)과 긴 창(보통 주간)
    public let primary: Window?
    public let secondary: Window?

    public init(planType: String?, primary: Window?, secondary: Window?) {
        self.planType = planType; self.primary = primary; self.secondary = secondary
    }
}

/// ChatGPT 로그인 토큰으로 Codex 백엔드(Responses API)를 직접 부른다. 프록시가 필요 없다.
/// 공식 공개 API 가 아니라 Codex CLI 가 쓰는 엔드포인트라서, 규격이 바뀌면 여기만 고치면 된다.
public final class CodexResponsesClient: LLMClient, @unchecked Sendable {
    public static let defaultEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    public static let modelsEndpoint = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    /// 가벼운 배치 작업용 기본 모델. 계정마다 쓸 수 있는 모델이 다르므로 목록은 listModels 로 받아 온다.
    public static let defaultModel = "gpt-5.6-luna"
    /// CLI 없이 정리 기능만 사용할 때의 모델 목록 API 호환 버전.
    static let clientVersion = "0.155.1"

    public static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let usagePage = URL(string: "https://chatgpt.com/codex/settings/usage")!

    /// 구독 한도 대비 사용률. 5시간 창과 주간 창 두 가지가 온다.
    public static func fetchUsage(auth: any CodexCredentialProviding, session: URLSession = .shared) async throws -> CodexUsage {
        let credentials: CodexCredentials
        do { credentials = try await auth.credentials() } catch let error as CodexAuthError { throw LLMError.auth(error.description) }
        var request = URLRequest(url: usageEndpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId { request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw LLMError.transport(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.http(status, String((String(data: data, encoding: .utf8) ?? "").prefix(300))) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.noJSON("사용량 응답") }
        func window(_ value: Any?) -> CodexUsage.Window? {
            guard let item = value as? [String: Any], let used = (item["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            return CodexUsage.Window(usedPercent: used, windowSeconds: (item["limit_window_seconds"] as? NSNumber)?.intValue ?? 0,
                                     resetAt: (item["reset_at"] as? NSNumber)?.doubleValue ?? 0)
        }
        let limits = root["rate_limit"] as? [String: Any]
        return CodexUsage(planType: root["plan_type"] as? String, primary: window(limits?["primary_window"]), secondary: window(limits?["secondary_window"]))
    }

    /// 서버의 모델 후보 목록. 목록에 있어도 현재 연결에서 실제 요청을 지원한다는 보장은 없다.
    public static func listModels(auth: any CodexCredentialProviding, session: URLSession = .shared) async throws -> [CodexModel] {
        let credentials: CodexCredentials
        do { credentials = try await auth.credentials() } catch let error as CodexAuthError { throw LLMError.auth(error.description) }
        var components = URLComponents(url: modelsEndpoint, resolvingAgainstBaseURL: false)!
        let runtimeVersion = await Task.detached { CodexRuntime.clientVersion() }.value
        components.queryItems = [URLQueryItem(name: "client_version", value: runtimeVersion ?? clientVersion)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setCodexHeaders(credentials)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw LLMError.transport(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw LLMError.http(status, String((String(data: data, encoding: .utf8) ?? "").prefix(300))) }
        let root = try? JSONSerialization.jsonObject(with: data)
        let items = ((root as? [String: Any])?["models"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
        return items
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { (($0["priority"] as? NSNumber)?.intValue ?? 99) < (($1["priority"] as? NSNumber)?.intValue ?? 99) }
            .compactMap { item in
                guard let slug = item["slug"] as? String else { return nil }
                return CodexModel(slug: slug, displayName: item["display_name"] as? String ?? slug,
                                  defaultEffort: item["default_reasoning_level"] as? String)
            }
    }

    /// 성공한 후보와 확인 실패를 함께 반환한다. 인증·사용량 오류는 보고한 뒤 추가 요청을 멈춘다.
    public static func verifyModels(_ models: [CodexModel], check: (CodexModel) async throws -> Void) async throws -> CodexModelVerification {
        var available: [CodexModel] = []
        var failures: [CodexModelVerification.Failure] = []
        var isComplete = true
        for model in models {
            try Task.checkCancellation()
            do {
                try await check(model)
                try Task.checkCancellation()
                available.append(model)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let description = (error as? CodexAuthError)?.description ?? error.localizedDescription
                let message = description.lowercased()
                if message.contains("model"), message.contains("not supported") || message.contains("model_not_found")
                    || message.contains("requires a newer version of codex") { continue }
                failures.append(.init(model: model, message: description))
                if error is CodexAuthError { isComplete = false; break }
                if let error = error as? LLMError {
                    if case .auth = error { isComplete = false; break }
                    if case .http(let status, _) = error, [401, 403, 429].contains(status) { isComplete = false; break }
                }
            }
        }
        return CodexModelVerification(models: available, failures: failures, isComplete: isComplete)
    }

    let auth: any CodexCredentialProviding
    let model: String
    let reasoningEffort: String?
    let endpoint: URL
    let session: URLSession
    let timeout: TimeInterval

    public var modelName: String { model }

    public init(auth: any CodexCredentialProviding, model: String, reasoningEffort: String? = "low",
                endpoint: URL = CodexResponsesClient.defaultEndpoint, session: URLSession = .shared, timeout: TimeInterval = 300) {
        self.auth = auth; self.model = model; self.reasoningEffort = reasoningEffort
        self.endpoint = endpoint; self.session = session; self.timeout = timeout
    }

    public func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        try await callFunction(system: system, user: user, images: [], tool: tool)
    }

    /// 이미지(JPEG·PNG 데이터)를 함께 보내는 호출. detail: "low" | "high" | "auto"
    public func callFunction(system: String, user: String, images: [(data: Data, mime: String)], detail: String = "auto", tool: ToolSpec) async throws -> LLMResult {
        var credentials: CodexCredentials
        do { credentials = try await auth.credentials() } catch let error as CodexAuthError { throw LLMError.auth(error.description) }

        var refreshed = false, forceTool = true
        while true {
            let (status, raw) = try await send(system: system, user: user, images: images, detail: detail, tool: tool, credentials: credentials, forceTool: forceTool)
            if status == 401, !refreshed {                                  // 토큰이 거절됨: 한 번만 갱신하고 다시
                refreshed = true
                do { credentials = try await auth.refreshAfterRejection(of: credentials.accessToken) }
                catch let error as CodexAuthError { throw LLMError.auth(error.description) }
                continue
            }
            if (status == 400 || status == 422), forceTool, raw.contains("tool_choice") {
                forceTool = false                                           // 강제 호출을 안 받는 모델: auto 로 다시
                continue
            }
            guard (200..<300).contains(status) else { throw LLMError.http(status, String(raw.prefix(600))) }
            return try Self.parseEvents(raw, fallbackModel: model)
        }
    }

    // MARK: 요청

    private func send(system: String, user: String, images: [(data: Data, mime: String)] = [], detail: String = "auto", tool: ToolSpec,
                      credentials: CodexCredentials, forceTool: Bool) async throws -> (Int, String) {
        let parameters = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))) ?? [String: Any]()
        var content: [[String: Any]] = [["type": "input_text", "text": PIIMasker.mask(user)]]
        for image in images {
            content.append(["type": "input_image", "image_url": "data:\(image.mime);base64,\(image.data.base64EncodedString())", "detail": detail])
        }
        var body: [String: Any] = [
            "model": model,
            "instructions": PIIMasker.mask(system),
            "input": [["type": "message", "role": "user", "content": content]],
            "tools": [["type": "function", "name": tool.name, "description": tool.description, "parameters": parameters, "strict": false]],
            "tool_choice": forceTool ? ["type": "function", "name": tool.name] as Any : "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": true,
        ]
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setCodexHeaders(credentials, streaming: true)
        request.setValue(UUID().uuidString, forHTTPHeaderField: "session_id")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            // 배치 작업이라 토큰 단위 스트리밍이 필요 없다. 서버가 스트림을 닫을 때까지 받아서 한 번에 해석한다.
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }
    }

    // MARK: 응답 (SSE)

    /// `data: {...}` 줄을 읽어 함수 호출 인자를 찾는다. 우선순위: 완성된 항목 → 조각 누적 → 본문 텍스트.
    static func parseEvents(_ raw: String, fallbackModel: String) throws -> LLMResult {
        var completedArguments: [String] = []
        var deltas: [String: String] = [:], deltaOrder: [String] = []
        var text = "", failure: String?
        var model = fallbackModel, promptTokens = 0, completionTokens = 0
        var completed = false

        for line in raw.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                   let arguments = item["arguments"] as? String, !arguments.isEmpty { completedArguments.append(arguments) }
            case "response.function_call_arguments.delta":
                let id = event["item_id"] as? String ?? "_"
                if deltas[id] == nil { deltaOrder.append(id) }
                deltas[id, default: ""] += event["delta"] as? String ?? ""
            case "response.output_text.delta":
                text += event["delta"] as? String ?? ""
            case "response.completed":
                completed = true
                let response = event["response"] as? [String: Any]
                if let name = response?["model"] as? String { model = name }
                let usage = response?["usage"] as? [String: Any]
                promptTokens = (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0
                completionTokens = (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
            case "response.failed", "response.incomplete":
                let response = event["response"] as? [String: Any]
                failure = ((response?["error"] as? [String: Any])?["message"] as? String)
                    ?? ((response?["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? type
            case "error":
                failure = (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? "error"
            default:
                break
            }
        }

        if let failure { throw LLMError.backend(failure) }
        guard completed else { throw LLMError.backend("응답이 완료되기 전에 연결이 종료되었습니다.") }
        for candidate in completedArguments + deltaOrder.compactMap({ deltas[$0] }) + [text] {
            if let json = OpenAICompatClient.extractJSON(from: candidate), let data = json.data(using: .utf8) {
                return LLMResult(arguments: data, model: model, promptTokens: promptTokens, completionTokens: completionTokens, raw: raw)
            }
        }
        throw LLMError.noJSON(String((text.isEmpty ? raw : text).prefix(300)))
    }
}

extension URLRequest {
    /// Headers the ChatGPT Codex backend expects; streaming calls add the SSE ones.
    mutating func setCodexHeaders(_ credentials: CodexCredentials, streaming: Bool = false) {
        setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId { setValue(accountId, forHTTPHeaderField: "chatgpt-account-id") }
        setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        guard streaming else { return }
        setValue("application/json", forHTTPHeaderField: "Content-Type")
        setValue("text/event-stream", forHTTPHeaderField: "Accept")
        setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
    }
}
