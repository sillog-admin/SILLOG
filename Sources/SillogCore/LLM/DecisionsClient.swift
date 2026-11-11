import Foundation

/// OpenAI Decisions API judge. Like Jev it only picks options, so it plugs into the same `ChoiceModel` path.
public struct DecisionsClient: Sendable {
    public static let url = "https://api.openai.com/v1/decisions"
    public static let defaultModel = "gpt-6-luna"

    public let key: String
    public let model: String
    private let url: String
    private let timeout: TimeInterval
    private let session: URLSession

    public init(key: String, model: String = DecisionsClient.defaultModel, url: String = DecisionsClient.url,
                timeout: TimeInterval = 30, session: URLSession = .shared) {
        self.key = key; self.model = model; self.url = url; self.timeout = timeout; self.session = session
    }

    /// Sends all questions in one request.
    /// Args: state is the evidence text, questions maps a question name to its options.
    /// Returns: question name → answer. Refused or missing questions are left out.
    /// Raises: ChoiceError for a bad URL, HTTP errors and unreadable responses.
    public func choose(state: String, questions: [String: ChoiceQuestion]) async throws -> [String: ChoiceAnswer] {
        guard let endpoint = URL(string: url) else { throw ChoiceError.badURL }
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let items: [[String: Any]] = questions.sorted { $0.key < $1.key }.map { name, question in
            ["type": "choice", "name": name, "instructions": question.instructions,
             "choices": question.options.sorted { $0.key < $1.key }.map { ["value": $0.key, "description": $0.value] }]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": state, "questions": items])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw ChoiceError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [[String: Any]] else { throw ChoiceError.badResponse }
        var out: [String: ChoiceAnswer] = [:]
        for a in answers {
            guard a["type"] as? String == "choice", let name = a["name"] as? String, let choice = a["choice"] as? String else { continue }
            var probs: [String: Double] = [:]
            for p in a["probabilities"] as? [[String: Any]] ?? [] {
                if let value = p["value"] as? String, let probability = (p["probability"] as? NSNumber)?.doubleValue { probs[value] = probability }
            }
            out[name] = ChoiceAnswer(choice: choice, confidence: (a["confidence"] as? NSNumber)?.doubleValue ?? probs[choice] ?? 0, probabilities: probs)
        }
        return out
    }

    /// Sends one small question with no personal data.
    /// Raises: ChoiceError when the key is wrong or the server is unreachable.
    public func verify() async throws {
        let q = ChoiceQuestion(instructions: "Which word is a color?", options: ["red": "a color", "table": "a piece of furniture"])
        guard try await choose(state: "Connection check.", questions: ["check": q])["check"] != nil else { throw ChoiceError.badResponse }
    }
}

extension DecisionsClient: ChoiceModel {
    public var modelName: String { model }
}
