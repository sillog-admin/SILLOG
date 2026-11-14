import AVFoundation
import SillogCore

/// Reads text aloud in the app language and tracks which item is being read.
@MainActor
final class ChatSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speakingID: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var reading: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts reading text for id, or stops when id is already being read.
    func toggle(_ text: String, id: String) {
        let wasSpeaking = speakingID == id
        stop()
        guard !wasSpeaking, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: L10n.current == .ko ? "ko-KR" : "en-US")
        speakingID = id; reading = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        speakingID = nil; reading = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // isSpeaking can still be true here, so match the utterance; a replaced one must not clear the newer one's state.
        let finished = ObjectIdentifier(utterance)
        Task { @MainActor in if self.reading == finished { self.speakingID = nil; self.reading = nil } }
    }
}
