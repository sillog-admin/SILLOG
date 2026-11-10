import AVFoundation
import Foundation
import Speech
import WorkGraphCore

/// 기기 안 음성 인식(ko-KR)으로 녹음 파일 하나를 받아쓴다.
/// 10/10 측정: 기기 안 인식에는 1분 제한이 없고(8분 17초를 한 요청으로), 결과는 발화마다 나뉘어 마지막 결과에는 마지막 발화만 남는다.
/// 그래서 중간 결과를 켜고, 발화 끝 표시(speechRecognitionMetadata)가 붙은 결과를 TranscriptCollector 로 모은다.
/// 10/13 측정: 말이 한동안 끊기면 파일 끝까지 가지 않고 끝내고(77초 녹음에서 34초 뒤 40초를 놓침), 작은 소리는 말소리로 못 알아듣는다.
/// 그래서 소리 크기를 맞춰(TranscriptionGain) 버퍼로 넣고, 끝난 자리 바로 뒤에서 다시 시작해 끝까지 받아쓴다 (ResumingTranscription). 원본 파일은 그대로
struct SpeechTranscriber: Transcribing {
    /// 개발용 진단: 인식기가 준 결과마다 한 줄 (TranscribeTrace). 평소에는 nil
    var trace: (@Sendable (String) -> Void)? = nil
    /// 개발용 진단: 키울 배수를 직접 정한다 (TranscribeTrace 의 WORKGRAPH_TRANSCRIBE_GAIN). 평소에는 nil (녹음 크기로 정함)
    var gainOverride: Float? = nil

    /// 인식 오류의 뜻
    enum ErrorKind: Equatable {
        /// 시스템 설정 → 키보드 → 받아쓰기가 꺼짐 (kLSRErrorDomain 201)
        case dictationOff
        /// 말소리가 없음 (kAFAssistantErrorDomain 1110): 받아쓴 글 없이 끝낸다
        case noSpeech
        case other
    }

    static func kind(of error: Error) -> ErrorKind {
        let error = error as NSError
        if error.domain == "kLSRErrorDomain", error.code == 201 { return .dictationOff }
        if error.domain == "kAFAssistantErrorDomain", error.code == 1110 { return .noSpeech }
        return .other
    }

    func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")), recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable("이 Mac 에서는 한국어를 기기 안에서 받아쓸 수 없어요")
        }
        let factor = gainOverride ?? (try? Self.gain(of: audio)) ?? 1
        trace?(String(format: "gain x%.2f", factor))
        return try await ResumingTranscription.run(duration: duration, progress: progress) { start in
            trace?(String(format: "pass from %.1fs", start))
            do {
                return try await pass(recognizer: recognizer, audio: audio, from: start, factor: factor, duration: duration, progress: progress)
            } catch TranscriptionError.failed(let reason) where start > 0 {
                // 뒤쪽에서 실패해도 앞에서 받아쓴 글은 살린다: 이 자리는 건너뛰고 이어 간다
                trace?("pass failed: \(reason)")
                return ResumingTranscription.Pass(utterances: [], lastEnd: nil)
            }
        }
    }

    /// start 초부터 파일 끝까지 한 번 받아쓴다. 인식기가 일찍 끝내면 거기까지
    private func pass(recognizer: SFSpeechRecognizer, audio: URL, from start: Double, factor: Float, duration: Double,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> ResumingTranscription.Pass {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        let remaining = max(duration - start, 0.1)
        let session = RecognitionSession(duration: remaining, progress: { part in progress(min(0.99, (start + part * remaining) / max(duration, 1))) },
                                         trace: trace)
        let trace = trace, feeding = Feeding(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResumingTranscription.Pass, Error>) in
                session.begin(continuation) {
                    let task = recognizer.recognitionTask(with: request) { result, error in session.receive(result, error, recognizer: recognizer) }
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { try Self.feed(feeding.request, audio: audio, from: start, factor: factor) } catch { trace?("feed failed: \(error)") }
                    }
                    return task
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    /// start 초부터 파일 끝까지 소리를 키워 넣고 닫는다
    static func feed(_ request: SFSpeechAudioBufferRecognitionRequest, audio: URL, from start: Double, factor: Float) throws {
        defer { request.endAudio() }
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        file.framePosition = min(file.length, AVAudioFramePosition(start * format.sampleRate))
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { return }
            if factor != 1, let channels = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    for index in 0..<Int(buffer.frameLength) { channels[channel][index] = TranscriptionGain.apply(channels[channel][index], factor: factor) }
                }
            }
            request.append(buffer)
        }
    }

    /// 0.1초 창마다 RMS 를 재서 키울 배수를 정한다 (TranscriptionGain)
    static func gain(of audio: URL) throws -> Float {
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let window = AVAudioFrameCount(max(1, format.sampleRate / 10))
        var levels: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            levels.append((sum / Float(buffer.frameLength)).squareRoot())
        }
        return TranscriptionGain.factor(windowRMS: levels)
    }
}

/// 소리 넣기를 다른 스레드에서: 버퍼 넣기(append·endAudio)는 오디오 탭 스레드에서 하는 것이 보통 쓰임새라 스레드를 가리지 않는다
private final class Feeding: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}

/// 인식 한 번의 상태. 인식기 콜백과 취소가 겹쳐도 continuation 은 한 번만 이어진다
private final class RecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var collector: TranscriptCollector
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<ResumingTranscription.Pass, Error>?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false
    private let trace: (@Sendable (String) -> Void)?

    init(duration: Double, progress: @escaping @Sendable (Double) -> Void, trace: (@Sendable (String) -> Void)? = nil) {
        collector = TranscriptCollector(duration: duration)
        self.progress = progress
        self.trace = trace
    }

    func begin(_ continuation: CheckedContinuation<ResumingTranscription.Pass, Error>, start: () -> SFSpeechRecognitionTask) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
        let task = start()
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// 지금까지 모은 발화와 마지막 발화가 끝난 시각
    private func passResult() -> ResumingTranscription.Pass {
        let utterances = collector.finish()
        return ResumingTranscription.Pass(utterances: utterances, lastEnd: collector.lastEnd > 0 ? collector.lastEnd : nil)
    }

    /// recognizer 는 인식이 끝날 때까지 붙잡아 두려고 받는다
    func receive(_ result: SFSpeechRecognitionResult?, _ error: Error?, recognizer: SFSpeechRecognizer) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        var outcome: Result<ResumingTranscription.Pass, Error>?
        if let result {
            let segments = result.bestTranscription.segments
            var end = segments.last.map { $0.timestamp + $0.duration } ?? 0
            if let metadata = result.speechRecognitionMetadata { end = max(end, metadata.speechStartTimestamp + metadata.speechDuration) }
            trace?(String(format: "final=%d meta=%d end=%.1f | ", result.isFinal ? 1 : 0, result.speechRecognitionMetadata == nil ? 0 : 1, end)
                   + result.bestTranscription.formattedString)
            collector.add(text: result.bestTranscription.formattedString, utteranceEnded: result.speechRecognitionMetadata != nil,
                          isFinal: result.isFinal, lastWordEnd: end)
            if result.isFinal { outcome = .success(passResult()) }
        }
        if outcome == nil, let error {
            trace?("error \((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)")
            switch SpeechTranscriber.kind(of: error) {
            case .dictationOff: outcome = .failure(TranscriptionError.dictationDisabled)
            case .noSpeech: outcome = .success(passResult())
            case .other: outcome = .failure(TranscriptionError.failed(error.localizedDescription))
            }
        }
        let value = collector.progress
        let waiting = outcome == nil ? nil : continuation
        if outcome != nil { continuation = nil; task = nil }
        lock.unlock()
        progress(value)
        if let waiting, let outcome { waiting.resume(with: outcome) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task, waiting = continuation
        continuation = nil
        lock.unlock()
        task?.cancel()
        waiting?.resume(throwing: CancellationError())
    }
}
