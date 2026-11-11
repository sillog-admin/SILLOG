import Foundation

/// 판단 모델(Jev) 연결 정보. TypeSafe 에 자기 키로 붙는다.
/// 요청 본문: model, state(판단 근거 글), questions(choice 문항).
public struct JevEndpoint: Equatable, Sendable {
    public var url: String
    public var model: String
    public var key: String

    public init(url: String, model: String, key: String) {
        self.url = url
        self.model = model
        self.key = key
    }

    public static let typesafeURL = "https://api.typesafe.ai/v1/systemone"
    /// 새 판이 나오면 바뀌는 별칭
    public static let defaultModel = "jev-latest"
}

/// Jev 에 고르기 문항을 묻는 클라이언트. 글을 만들지 않고 보기 중 하나와 확률만 돌려준다.
public struct JevClient: Sendable {
    public let endpoint: JevEndpoint
    private let timeout: TimeInterval
    private let session: URLSession

    public init(endpoint: JevEndpoint, timeout: TimeInterval = 30, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.session = session
    }

    /// 문항 여러 개를 한 요청으로 묻는다.
    /// Args: state 는 판단 근거 글, questions 는 문항 id → 문항.
    /// Returns: 문항 id → 답. 응답에 없는 문항은 빠진다.
    /// Raises: ChoiceError (주소, HTTP 오류, 응답 형식).
    public func choose(state: String, questions: [String: ChoiceQuestion]) async throws -> [String: ChoiceAnswer] {
        guard let url = URL(string: endpoint.url.trimmingCharacters(in: .whitespaces)) else { throw ChoiceError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let qs = questions.mapValues { ["type": "choice", "instructions": PIIMasker.mask($0.instructions), "criteria": $0.options.mapValues(PIIMasker.mask)] as [String: Any] }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": endpoint.model, "state": PIIMasker.mask(state), "questions": qs])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ChoiceError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { throw ChoiceError.badResponse }
        var out: [String: ChoiceAnswer] = [:]
        for (id, raw) in answers {
            guard let a = raw as? [String: Any], let choice = a["choice"] as? String else { continue }
            let probs = (a["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
            out[id] = ChoiceAnswer(choice: choice, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? probs[choice] ?? 0, probabilities: probs)
        }
        return out
    }

    /// 연결 확인: 개인 자료 없이 작은 문항 하나를 보낸다.
    /// Raises: 키가 틀리거나 서버에 닿지 않으면 ChoiceError.
    public func verify() async throws {
        let q = ChoiceQuestion(instructions: "Which word is a color?", options: ["red": "a color", "table": "a piece of furniture"])
        let answers = try await choose(state: "Connection check.", questions: ["check": q])
        guard answers["check"] != nil else { throw ChoiceError.badResponse }
    }
}

extension JevClient: ChoiceModel {
    public var modelName: String { endpoint.model }
}
