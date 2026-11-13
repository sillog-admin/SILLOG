import AVFoundation
import Speech
import SwiftUI
import SillogCore

/// Chat composer dictation. Apple on-device recognition streams into the draft; without it, a downloaded Whisper model transcribes on stop.
/// Server recognition is never used, like recordings (SpeechTranscriber).
@MainActor
final class ChatDictation: ObservableObject {
    @Published private(set) var listening = false
    /// Whisper is transcribing what was recorded.
    @Published private(set) var transcribing = false
    /// 0...1 loudness of the latest audio.
    @Published private(set) var level: Double = 0
    @Published var problem: RecordingProblem?
    /// Neither on-device recognition for this language nor a Whisper model.
    @Published private(set) var unavailable: Bool
    /// Whisper is holding speech that lands in the draft only on stop.
    var holdsSpeech: Bool { transcribing || (listening && feed?.request == nil) }

    private enum Mode { case apple(SFSpeechRecognizer), whisper }

    private var draft: Binding<String>?
    private var lastWritten = ""
    private var merge = DictationDraft(draft: "", selection: nil)
    private var recorder: VoiceRecorder?
    private var file: URL?
    private var feed: DictationFeed?
    private var task: SFSpeechRecognitionTask?
    // A released recognizer stops delivering results, so it is held until the task ends.
    private var recognizer: SFSpeechRecognizer?
    private var session = 0

    init() {
        // Only once authorized: the recognizer is created after the permission check otherwise.
        unavailable = SFSpeechRecognizer.authorizationStatus() == .authorized && Self.mode() == nil
    }

    private static func mode() -> Mode? {
        let locale = Locale(identifier: L10n.current == .ko ? "ko-KR" : "en-US")
        if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition { return .apple(recognizer) }
        // WhisperEngine decodes Korean only.
        if L10n.current == .ko, WhisperEngine.localModelFolder() != nil { return .whisper }
        return nil
    }

    /// Starts listening, or stops and keeps the final text when already listening.
    func toggle(draft: Binding<String>, selection: NSRange?, permissions: any RecordingPermissions) {
        if listening { stop(); return }
        session += 1
        task?.cancel(); task = nil
        let current = session
        Task {
            problem = nil
            if let problem = await permissions.check() { self.problem = problem; return }
            guard current == session else { return }
            guard let mode = Self.mode() else { unavailable = true; return }
            start(mode, draft: draft, selection: selection)
        }
    }

    private func start(_ mode: Mode, draft: Binding<String>, selection: NSRange?) {
        self.draft = draft
        lastWritten = draft.wrappedValue
        merge = DictationDraft(draft: draft.wrappedValue, selection: selection)
        let feed: DictationFeed
        switch mode {
        case .apple(let recognizer):
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.taskHint = .dictation
            feed = DictationFeed(request: request)
            self.recognizer = recognizer
            let current = session
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString, ended = result?.speechRecognitionMetadata != nil
                let final = result?.isFinal ?? false, kind = error.map { SpeechTranscriber.kind(of: $0) }, failure = error.map { "\($0)" }
                Task { @MainActor in self?.receive(text, ended: ended, final: final, error: kind, failure: failure, session: current) }
            }
        case .whisper:
            feed = DictationFeed(request: nil)
            Task.detached { await WhisperEngine.shared.prewarm() }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sillog-dictation-\(UUID().uuidString).m4a")
        let recorder = VoiceRecorder()
        do {
            try recorder.start(to: url, samples: { [weak self] samples in
                let level = feed.append(samples)
                Task { @MainActor in self?.level = level }
            })
        } catch {
            AppLog.write("chat dictation: microphone did not start \(error)")
            problem = .failed(tr("마이크를 시작하지 못했어요"))
            task?.cancel(); task = nil; self.recognizer = nil
            try? FileManager.default.removeItem(at: url)
            return
        }
        self.recorder = recorder; self.file = url; self.feed = feed
        listening = true
    }

    /// Stops listening and lets the last result or the Whisper transcript land in the draft.
    func stop() {
        guard listening, let feed else { return }
        endRecording()
        guard feed.request == nil else { feed.request?.endAudio(); return }
        transcribing = true
        let current = session, samples = feed.samples
        Task {
            defer { if current == session { transcribing = false } }
            do {
                // 30s pieces like recordings: one decode over long audio hits its deadline or VAD drops speech.
                let chunks = IncrementalTranscription { try await WhisperEngine.shared.transcribe(samples: $0) }
                await chunks.append(samples)
                let spoken = try await chunks.finish().joined(separator: " ")
                guard current == session, let draft else { return }
                // Typed while recording: keep their text and add the speech after it.
                let base = draft.wrappedValue == lastWritten ? merge : DictationDraft(draft: draft.wrappedValue, selection: nil)
                draft.wrappedValue = base.merged(spoken)
            } catch {
                AppLog.write("chat dictation: whisper failed \(error.localizedDescription)")
                if current == session { problem = .failed(tr("받아쓰지 못했어요")) }
            }
        }
    }

    /// Stops without waiting for more text: what was already written stays (Escape, sending, switching chats).
    func cancel() {
        session += 1
        endRecording()
        task?.cancel(); task = nil; recognizer = nil
        transcribing = false
    }

    private func endRecording() {
        _ = recorder?.stop()
        recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        listening = false
        level = 0
    }

    private func receive(_ text: String?, ended: Bool, final: Bool, error: SpeechTranscriber.ErrorKind?, failure: String?, session current: Int) {
        guard current == session else { return }
        if let text { write(merge.hear(text, utteranceEnded: ended, isFinal: final)) }
        if error == .dictationOff { problem = .dictation }
        if error == .other { problem = .failed(tr("받아쓰지 못했어요")) }
        if let failure, error != .noSpeech { AppLog.write("chat dictation: recognition failed \(failure)") }
        if final || error != nil { endRecording(); task = nil; recognizer = nil }
    }

    private func write(_ text: String) {
        // The user typed over the dictation: keep their text and stop.
        guard let draft, draft.wrappedValue == lastWritten else { cancel(); return }
        lastWritten = text
        draft.wrappedValue = text
    }
}

/// Audio-thread side: feeds the recognizer, or keeps 16kHz samples for Whisper.
private final class DictationFeed: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    private var kept: [Float] = []
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: IncrementalTranscription.sampleRate, channels: 1, interleaved: false)!

    init(request: SFSpeechAudioBufferRecognitionRequest?) { self.request = request }

    var samples: [Float] { lock.lock(); defer { lock.unlock() }; return kept }

    /// Returns: loudness 0...1 for the mic button.
    func append(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        if let request {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] {
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                request.append(buffer)
            }
        } else {
            lock.lock(); kept += samples; lock.unlock()
        }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        return min(1, Double(rms) * 12)
    }
}
