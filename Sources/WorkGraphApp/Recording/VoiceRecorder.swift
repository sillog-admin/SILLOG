import AVFoundation
import Foundation
import WorkGraphCore

/// 녹음기 (테스트에서는 가짜로 바꾼다). Core 의 녹음 기록(Recording)과 이름이 겹치지 않게 AudioRecording
@MainActor
protocol AudioRecording: AnyObject {
    /// url 에 녹음을 시작한다. samples 가 있으면 녹음하는 동안 16kHz 모노 소리를 흘려보낸다 (녹음 중 미리 받아쓰기). 시작하지 못하면 던진다
    func start(to url: URL, samples: (@Sendable ([Float]) -> Void)?) throws
    /// 녹음을 끝내고 길이(초)를 돌려준다
    func stop() -> Double
}

/// 마이크 → AVAudioEngine 탭 → CaptureWriter (m4a 와 16kHz 소리).
/// AVAudioRecorder 는 녹음이 끝나야 m4a 가 완성돼 녹음 중에는 읽을 수 없어서, 탭에서 소리를 직접 받아 파일에 쓰면서 미리 받아쓰기로도 흘려보낸다.
/// 입력 장치가 바뀌면(이어폰을 꽂는 등) 엔진이 멈추므로 새 입력 형식으로 탭을 다시 건다
final class VoiceRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var observer: NSObjectProtocol?

    func start(to url: URL, samples: (@Sendable ([Float]) -> Void)?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let engine = AVAudioEngine()
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else { throw CocoaError(.fileWriteUnknown) }   // 입력 장치가 없음
        let writer = try CaptureWriter(url: url, input: input, samples: samples)
        Self.tap(engine, into: writer, format: input)
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.writer = writer
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterDeviceChange() }
        }
    }

    func stop() -> Double {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let seconds = writer?.seconds ?? 0
        writer?.close()
        writer = nil
        return seconds
    }

    /// 입력 장치가 바뀌어 엔진이 멈췄을 때: 새 입력 형식으로 탭을 다시 걸고 이어서 녹음한다 (같은 파일에 이어 쓴다)
    private func restartAfterDeviceChange() {
        guard let engine, let writer else { return }
        engine.inputNode.removeTap(onBus: 0)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0, (try? writer.change(input: input)) != nil else {
            AppLog.write("녹음: 입력 장치가 바뀐 뒤 다시 시작하지 못함")
            return
        }
        Self.tap(engine, into: writer, format: input)
        engine.prepare()
        do { try engine.start() } catch { AppLog.write("녹음: 입력 장치가 바뀐 뒤 다시 시작하지 못함 \(error)") }
    }

    /// 탭은 오디오 스레드에서 불린다: writer 는 그 스레드에서만 쓴다 (멈출 때는 탭을 먼저 뗀다)
    private nonisolated static func tap(_ engine: AVAudioEngine, into writer: CaptureWriter, format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in writer.write(buffer) }
    }
}

/// 녹음기 탭에서 받은 소리를 m4a 로 쓰고(AAC 44.1kHz 모노 64kbps, 1시간에 약 28MB: 7일 뒤 지울 파일이라 10/10 측정에서 가장 정확했던 형식),
/// 같은 소리를 16kHz 모노로 바꿔 미리 받아쓰기로 흘려보낸다
final class CaptureWriter: @unchecked Sendable {
    private var file: AVAudioFile?
    private var toFile: AVAudioConverter
    private var toSpeech: AVAudioConverter
    private let fileFormat: AVAudioFormat
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let samples: (@Sendable ([Float]) -> Void)?
    private let lock = NSLock()
    private var framesWritten: AVAudioFramePosition = 0

    /// 지금까지 쓴 길이 (초)
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(framesWritten) / fileFormat.sampleRate }

    init(url: URL, input: AVAudioFormat, samples: (@Sendable ([Float]) -> Void)?) throws {
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        fileFormat = file.processingFormat
        guard let toFile = AVAudioConverter(from: input, to: fileFormat),
              let toSpeech = AVAudioConverter(from: input, to: speechFormat) else { throw CocoaError(.fileWriteUnknown) }
        self.file = file
        self.toFile = toFile
        self.toSpeech = toSpeech
        self.samples = samples
    }

    /// 입력 장치가 바뀌면 새 입력 형식으로 바꿔 이어 쓴다
    func change(input: AVAudioFormat) throws {
        guard let toFile = AVAudioConverter(from: input, to: fileFormat),
              let toSpeech = AVAudioConverter(from: input, to: speechFormat) else { throw CocoaError(.fileWriteUnknown) }
        lock.lock(); self.toFile = toFile; self.toSpeech = toSpeech; lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = self.file, toFile = self.toFile, toSpeech = self.toSpeech
        lock.unlock()
        guard let file else { return }
        if let converted = Self.convert(buffer, with: toFile, to: fileFormat) {
            do {
                try file.write(from: converted)
                lock.lock(); framesWritten += AVAudioFramePosition(converted.frameLength); lock.unlock()
            } catch {
                AppLog.write("녹음 파일 쓰기 실패: \(error)")
            }
        }
        if let samples, let speech = Self.convert(buffer, with: toSpeech, to: speechFormat), let channel = speech.floatChannelData?[0] {
            samples(Array(UnsafeBufferPointer(start: channel, count: Int(speech.frameLength))))
        }
    }

    /// 파일을 닫는다 (닫아야 m4a 가 완성된다)
    func close() {
        lock.lock()
        let file = self.file
        self.file = nil
        lock.unlock()
        if #available(macOS 15.0, *) { file?.close() }
    }

    /// 표본률·채널 바꾸기. 변환기는 버퍼 사이에 상태를 이어 가므로 녹음 내내 같은 것을 쓴다
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered { inputStatus.pointee = .noDataNow; return nil }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

enum AudioFileInfo {
    /// 읽히는 녹음 파일이면 길이(초). 녹음 중 앱이 꺼져 마무리되지 않은 파일이면 nil
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}
