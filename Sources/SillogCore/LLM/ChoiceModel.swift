import Foundation

/// A judge that only picks one option per question: Jev or OpenAI Decisions.
public protocol ChoiceModel: Sendable {
    /// Model name kept in batch records.
    var modelName: String { get }
    func choose(state: String, questions: [String: ChoiceQuestion]) async throws -> [String: ChoiceAnswer]
}

/// One choice question. `options` maps option name to description.
public struct ChoiceQuestion: Sendable {
    public var instructions: String
    public var options: [String: String]

    public init(instructions: String, options: [String: String]) {
        self.instructions = instructions
        self.options = options
    }
}

/// The picked option and its probabilities.
public struct ChoiceAnswer: Sendable, Equatable {
    public let choice: String
    public let confidence: Double
    public let probabilities: [String: Double]
}


public enum ChoiceError: Error, LocalizedError {
    case badURL
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .badURL: return "판단 모델 주소가 올바르지 않아요"
        case .http(let code, let body): return "판단 모델 응답 오류 \(code): \(body.prefix(200))"
        case .badResponse: return "판단 모델 응답을 읽지 못했어요"
        }
    }
}
