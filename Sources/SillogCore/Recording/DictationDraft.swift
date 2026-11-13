import Foundation

/// Chat dictation into the draft: the text around the caret is fixed when listening starts, and each recognizer result rewrites only the spoken part.
public struct DictationDraft: Sendable {
    private let before: String
    private let after: String
    private var collector = TranscriptCollector(duration: 0)

    /// Args: draft is the input when listening starts, selection its UTF-16 selection (replaced by speech); nil or out of range appends.
    public init(draft: String, selection: NSRange?) {
        let text = draft as NSString
        let range = selection.flatMap { NSMaxRange($0) <= text.length ? $0 : nil } ?? NSRange(location: text.length, length: 0)
        before = text.substring(to: range.location)
        after = text.substring(from: NSMaxRange(range))
    }

    /// Args: text is one recognizer result, utteranceEnded its end-of-utterance mark, isFinal the last result.
    /// Returns: the whole draft with everything heard so far at the caret.
    public mutating func hear(_ text: String, utteranceEnded: Bool, isFinal: Bool) -> String {
        collector.add(text: text, utteranceEnded: utteranceEnded, isFinal: isFinal, lastWordEnd: 0)
        return merged(collector.heard)
    }

    /// Returns: the draft with spoken placed at the caret, spaced from the words around it.
    public func merged(_ spoken: String) -> String {
        let spoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return before + after }
        let lead = before.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let trail = after.first.map { $0.isWhitespace ? "" : " " } ?? ""
        return before + lead + spoken + trail + after
    }
}
