import Foundation

/// 음성 인식 결과를 차례로 받아 발화별 문장을 모은다.
/// 기기 안 인식은 말이 쉬는 틈마다 결과를 새로 시작하고, 마지막(isFinal) 결과에는 마지막 발화만 남는다 (10/10 측정).
/// 그래서 발화 끝 표시(speechRecognitionMetadata)가 붙은 결과를 모으고, 다시 보낸 발화는 글자가 같고 끝 시각이 가까울 때만 알아본다 (시각을 모르면 글자만 봄).
public struct TranscriptCollector: Sendable {
    public private(set) var utterances: [String] = []
    /// 0~0.99 (끝까지 받으면 1)
    public private(set) var progress: Double = 0
    /// 마지막으로 모은 발화가 끝난 시각 (초, 모르면 0). 인식기가 일찍 끝냈을 때 다시 시작할 자리 (ResumingTranscription)
    public private(set) var lastEnd: Double = 0
    private var pending = ""
    private var pendingEnd: Double = 0
    private let duration: Double

    public init(duration: Double) { self.duration = duration }

    /// Args: text 는 이 결과의 글(한 발화), utteranceEnded 는 발화 끝 표시, isFinal 은 마지막 결과,
    ///   lastWordEnd 는 마지막 단어가 끝난 시각(초, 파일 처음부터)이다.
    public mutating func add(text: String, utteranceEnded: Bool, isFinal: Bool, lastWordEnd: Double) {
        if duration > 0 { progress = min(0.99, max(progress, lastWordEnd / duration)) }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if isFinal || utteranceEnded {
            pending = ""
            if isFinal && isWholeTranscript(clean) {
                // 마지막 결과가 지금까지 모은 발화 전부를 이은 글 → 아무것도 하지 않음
            } else if isRedelivery(clean, end: lastWordEnd) {
                // 마지막으로 모은 발화를 다시 보낸 것 (문장부호 다를 수 있음) → 마지막 발화 교체
                utterances[utterances.count - 1] = clean
                if lastWordEnd > 0 { lastEnd = lastWordEnd }
            } else {
                // 새 발화 → 붙임
                utterances.append(clean)
                lastEnd = lastWordEnd
            }
        } else {
            pending = clean
            pendingEnd = lastWordEnd
        }
    }

    /// 끝까지 받은 뒤: 끝나지 않은 발화도 붙인다
    public mutating func finish() -> [String] {
        if !pending.isEmpty, !isRedelivery(pending, end: pendingEnd) { utterances.append(pending); lastEnd = max(lastEnd, pendingEnd) }
        pending = ""
        progress = 1
        return utterances
    }

    /// 마지막으로 모은 발화를 다시 보낸 것인지: 글자(빈칸·문장부호 빼고)가 같고, 끝 시각을 알면 1초 안
    private func isRedelivery(_ text: String, end: Double) -> Bool {
        guard let last = utterances.last, Self.letters(text) == Self.letters(last) else { return false }
        guard end > 0, lastEnd > 0 else { return true }
        return abs(end - lastEnd) < 1.0
    }

    /// 마지막 결과가 지금까지 모은 발화 전부를 이은 글인지 (빈칸·문장부호 차이는 무시)
    private func isWholeTranscript(_ text: String) -> Bool {
        utterances.count > 1 && Self.letters(text) == Self.letters(utterances.joined())
    }

    /// 비교용: 글자와 숫자만
    private static func letters(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber }) }
}
