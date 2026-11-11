import Foundation

public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema (object)
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

public struct LLMResult: Sendable {
    /// 함수 호출 인자(JSON). 서버가 함수 호출을 안 쓰면 본문에서 뽑아낸 JSON.
    public let arguments: Data
    public let model: String
    public let promptTokens: Int
    public let completionTokens: Int
    public let raw: String

    public init(arguments: Data, model: String, promptTokens: Int, completionTokens: Int, raw: String) {
        self.arguments = arguments; self.model = model
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.raw = raw
    }
}

public enum LLMError: Error, Equatable, CustomStringConvertible {
    case http(Int, String)
    case noJSON(String)
    case transport(String)
    /// 로그인이 없거나 만료됨 (ChatGPT 로그인 방식)
    case auth(String)
    /// 서버가 요청은 받았지만 응답 생성에 실패함
    case backend(String)

    public var description: String {
        switch self {
        case .http(let status, let body): return "HTTP \(status): \(body)"
        case .noJSON(let text): return "응답에서 JSON을 찾지 못함: \(text)"
        case .transport(let message): return "연결 실패: \(message)"
        case .auth(let message): return message
        case .backend(let message): return "서버가 응답을 만들지 못함: \(message)"
        }
    }
}

public protocol LLMClient: Sendable {
    var modelName: String { get }
    /// 도구 하나를 강제 호출시켜 구조화된 JSON을 받는다.
    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult
}

extension LLMClient {
    /// 아주 작은 함수 호출을 실제로 보내 본다. 토큰 만료나 요청 형식 문제는 여기서 드러난다.
    public func selfTest() async -> Result<String, LLMError> {
        let tool = ToolSpec(name: "pong", description: "Reply with ok=true", parameters: .object([
            "type": "object", "properties": .object(["ok": .object(["type": "boolean"])]), "required": .array(["ok"]),
        ]))
        do {
            let result = try await callFunction(system: "Call the pong function.", user: "ping", tool: tool)
            return .success("\(result.model) 응답 정상 (입력 \(result.promptTokens) / 출력 \(result.completionTokens) 토큰)")
        } catch let error as LLMError {
            return .failure(error)
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }
}
