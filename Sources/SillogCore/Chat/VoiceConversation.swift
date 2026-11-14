import Foundation

/// Two-way voice chat: listen, send after a pause in speech, read the answer aloud, then listen again.
public struct VoiceConversation: Equatable, Sendable {
    public enum Phase: String, Sendable { case listening, answering, speaking }
    /// What the app does next.
    public enum Step: Equatable, Sendable { case listen, send, speak(String), end }

    /// Seconds of quiet after speech that end the user's turn.
    public static let pause: Double = 1.5

    /// nil while the mode is off.
    public private(set) var phase: Phase?
    private var heardAt: Double?

    public init() {}

    /// Args: none.
    /// Returns: .listen. Starts or restarts listening from any phase.
    /// Raises: none.
    @discardableResult public mutating func start() -> Step {
        phase = .listening
        heardAt = nil
        return .listen
    }

    /// Args: now is when dictation last wrote text, in Unix seconds.
    /// Returns: none. Ignored unless listening.
    /// Raises: none.
    public mutating func heard(at now: Double) {
        if phase == .listening { heardAt = now }
    }

    /// Args: now is the current time in Unix seconds.
    /// Returns: .send once nothing new was heard for `pause` seconds after some speech, else nil.
    /// Raises: none.
    public mutating func tick(at now: Double) -> Step? {
        guard phase == .listening, let heardAt, now - heardAt >= Self.pause else { return nil }
        return tap()
    }

    /// Args: none.
    /// Returns: .send while listening, .listen to skip the reading, nil while answering or off.
    /// Raises: none.
    public mutating func tap() -> Step? {
        switch phase {
        case .listening: phase = .answering; heardAt = nil; return .send
        case .speaking: return start()
        case .answering, nil: return nil
        }
    }

    /// Args: answer is the finished answer as speech, nil when the run failed or was stopped.
    /// Returns: .speak with the text, .end without one, nil unless answering.
    /// Raises: none.
    public mutating func answered(_ answer: String?) -> Step? {
        guard phase == .answering else { return nil }
        guard let answer, !answer.isEmpty else { return end() }
        phase = .speaking
        return .speak(answer)
    }

    /// Args: none.
    /// Returns: .listen when an answer finished being read, nil otherwise.
    /// Raises: none.
    public mutating func spoke() -> Step? {
        phase == .speaking ? start() : nil
    }

    /// Args: none.
    /// Returns: .end when the mode was on, nil when it was already off.
    /// Raises: none.
    @discardableResult public mutating func end() -> Step? {
        guard phase != nil else { return nil }
        phase = nil
        heardAt = nil
        return .end
    }
}
