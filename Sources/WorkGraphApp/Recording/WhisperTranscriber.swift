import Foundation
import WhisperKit
import WorkGraphCore

/// 녹음 받아쓰기: Whisper(large-v3-turbo, 626MB 압축판)를 Core ML 로 기기 안에서 돌린다 (WhisperKit). 녹음은 Mac 밖으로 나가지 않는다.
/// 애플 기기 안 인식(SpeechTranscriber)은 작은 소리·긴 녹음·여러 사람 대화를 놓친다 (10/13: 11분 녹음에서 4마디).
/// 모델은 처음 한 번 데이터 폴더의 models 아래로 내려받는다. 쓸 수 없으면(내려받기·불러오기 실패) fallback(애플 인식)으로 받아쓴다
struct WhisperTranscriber: Transcribing {
    static let model = "openai_whisper-large-v3-v20240930_626MB"
    var fallback: (any Transcribing)? = SpeechTranscriber()
    /// 개발용 진단 (TranscribeTrace)
    var trace: (@Sendable (String) -> Void)? = nil
    /// 시험용: Whisper 대신 받아쓰는 것 (nil 이면 WhisperEngine)
    var engine: (@Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> [String])? = nil

    func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        do {
            if let engine { return try await engine(audio, progress) }
            return try await WhisperEngine.shared.transcribe(audio: audio, progress: progress, trace: trace)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            trace?("whisper failed: \(error)")
            AppLog.write("Whisper 받아쓰기를 못 해 기기 음성 인식으로 받아씀: \(error.localizedDescription)")
            guard let fallback else { throw TranscriptionError.failed(error.localizedDescription) }
            return try await fallback.transcribe(audio: audio, duration: duration, progress: progress)
        }
    }
}

/// 모델은 한 번만 내려받는다 (처음엔 Core ML 컴파일까지 2분 남짓, 10/13 측정). 쓸 때 불러오고(약 2초) idleSeconds 동안 안 쓰면 내려놓는다:
/// 녹음 중에는 30초마다 조각을 받아써 계속 올라가 있고, 평소에는 메뉴 막대 앱이 약 500MB 를 들고 있지 않는다.
/// 받아쓰기는 한 번에 하나씩 (녹음 중 조각과 앞 녹음의 파일 받아쓰기가 겹쳐도 차례로)
actor WhisperEngine {
    static let shared = WhisperEngine()
    /// 이만큼(초) 안 쓰면 내려놓는다
    static let idleSeconds: Double = 90
    private var pipe: WhisperKit?
    private var loading = false
    private var busy = false
    private var lastUse = Date.distantPast
    private var unloader: Task<Void, Never>?

    /// 내려받은 모델이 있는 곳: 데이터 폴더/models
    static var downloadBase: URL { WGDatabase.defaultDirectory().appendingPathComponent("models", isDirectory: true) }

    /// 이미 내려받은 모델 폴더 (Core ML 모델 셋이 다 있을 때). 있으면 인터넷으로 확인하지 않고 쓴다 (오프라인에서도 받아쓰기)
    static func localModelFolder(in base: URL = downloadBase) -> URL? {
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(WhisperTranscriber.model)", isDirectory: true)
        let parts = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]
        return parts.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ? folder : nil
    }

    private static var options: DecodingOptions {
        DecodingOptions(task: .transcribe, language: "ko", usePrefillPrompt: true, detectLanguage: false,
                        skipSpecialTokens: true, chunkingStrategy: .vad)
    }

    /// 녹음을 시작할 때 모델을 미리 불러 둔다 (첫 조각에서 기다리지 않게). 실패하면 조각을 받아쓸 때 다시 해 본다
    func prewarm() async {
        _ = try? await loaded(progress: { _ in }, trace: nil)
        touched()
    }

    /// 녹음 중 조각 하나 (16kHz 모노). Returns: 말소리 구간마다 한 줄
    func transcribe(samples: [Float]) async throws -> [String] {
        try await exclusively { try await decode(samples) }
    }

    /// Args: audio 는 녹음 파일, progress 는 0~1 (모델을 불러와야 하면 앞 30%), trace 는 개발용 진단.
    /// 녹음 중 미리 받아쓰기와 같은 30초 조각으로 받아쓴다 (IncrementalTranscription). WhisperKit 이 파일 전체를 말소리 구간으로 나누게 두면
    /// 작은 소리로 시작한 강의 녹음의 앞 3분을 통째로 놓쳤다 (10/13, 두 번 다. 30초 조각은 두 번 다 받아씀).
    /// Returns: 말소리 구간마다 한 줄.
    /// Raises: 모델 내려받기·불러오기, 녹음 파일 읽기, 받아쓰기 오류.
    func transcribe(audio: URL, progress: @escaping @Sendable (Double) -> Void, trace: (@Sendable (String) -> Void)?) async throws -> [String] {
        try await exclusively {
            let preparing = pipe == nil
            let started = Date()
            _ = try await loaded(progress: { progress($0 * 0.3) }, trace: trace)
            if preparing { trace?(String(format: "model ready %.1fs", Date().timeIntervalSince(started))) }
            let share = preparing ? 0.7 : 1.0, offset = preparing ? 0.3 : 0.0
            let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)      // 16kHz 모노
            let total = Double(max(samples.count, 1)), done = Tally()
            let chunks = IncrementalTranscription { chunk in
                let begun = Date()
                let lines = try await self.decode(chunk)
                trace?(String(format: "chunk %.1fs audio → %.1fs, %d lines", Double(chunk.count) / IncrementalTranscription.sampleRate,
                              Date().timeIntervalSince(begun), lines.count))
                progress(min(0.99, offset + share * Double(done.add(chunk.count)) / total))
                return lines
            }
            let second = Int(IncrementalTranscription.sampleRate)
            for start in stride(from: 0, to: samples.count, by: second) {          // 1초씩 (조각을 자를 때 남은 소리만 옮기게)
                await chunks.append(Array(samples[start..<min(start + second, samples.count)]))
            }
            return try await chunks.finish()
        }
    }

    /// 조각 하나를 받아쓴다 (exclusively 안에서만: 한 번에 하나씩). 되풀이를 멈추고 chunkSeconds 안에 끝낸다 (shouldContinue)
    private func decode(_ chunk: [Float]) async throws -> [String] {
        let pipe = try await loaded(progress: { _ in }, trace: nil)
        let deadline = Date().addingTimeInterval(Self.chunkSeconds)
        let results = try await pipe.transcribe(audioArray: chunk, decodeOptions: Self.options) { progress in
            Self.shouldContinue(progress, deadline: deadline)
        }
        return Self.lines(results)
    }

    /// 조각 하나에 쓰는 시간 (초). 보통 1~5초 (10/13 측정)
    static let chunkSeconds: Double = 20

    /// 받아쓰는 동안 토큰마다: false 면 이 시도를 멈춘다. Whisper 가 같은 말을 되풀이하기 시작하면(마지막 60토큰의 압축률이 2.4 넘음,
    /// WhisperKit 실시간 받아쓰기와 같은 기준) 멈춰 온도를 올려 다시 해 보게 하고, deadline 이 지나면 이 조각은 그만 받아쓴다.
    /// 10/13 강의 녹음의 조용한 출석 구간에서 되풀이와 재시도가 이어져 28.7초 조각 하나에 111초가 걸렸다
    static func shouldContinue(_ progress: TranscriptionProgress, deadline: Date) -> Bool? {
        if Date() > deadline { return false }
        if progress.tokens.count > 60, TextUtilities.compressionRatio(of: Array(progress.tokens.suffix(60))) > 2.4 { return false }
        return nil
    }

    private static func lines(_ results: [TranscriptionResult]) -> [String] {
        results.flatMap(\.segments).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 한 번에 하나씩 받아쓰고, 끝나면 안 쓴 시간을 다시 잰다
    private func exclusively<T>(_ work: () async throws -> T) async throws -> T {
        while busy { try await Task.sleep(nanoseconds: 50_000_000) }
        busy = true
        defer { busy = false; touched() }
        return try await work()
    }

    /// 쓴 시각을 남기고, idleSeconds 뒤에도 안 썼으면 모델을 내려놓는다
    private func touched() {
        lastUse = Date()
        unloader?.cancel()
        unloader = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.idleSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard !busy, !loading, Date().timeIntervalSince(lastUse) >= Self.idleSeconds - 1 else { return }
        pipe = nil
    }

    private func loaded(progress: @escaping @Sendable (Double) -> Void, trace: (@Sendable (String) -> Void)?) async throws -> WhisperKit {
        while loading { try await Task.sleep(nanoseconds: 100_000_000) }   // 다른 쪽(prewarm)이 불러오는 중
        if let pipe { return pipe }
        loading = true
        defer { loading = false }
        let folder: URL
        if let local = Self.localModelFolder() {
            folder = local
        } else {
            folder = try await WhisperKit.download(variant: WhisperTranscriber.model, downloadBase: Self.downloadBase) { download in
                progress(download.fractionCompleted)
            }
        }
        trace?("model folder \(folder.path)")
        let config = WhisperKitConfig(model: WhisperTranscriber.model, downloadBase: Self.downloadBase, modelFolder: folder.path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        let pipe = try await WhisperKit(config)
        self.pipe = pipe
        return pipe
    }
}

/// 받아쓴 소리 길이를 모은다 (파일 받아쓰기 진행률)
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ more: Int) -> Int { lock.lock(); defer { lock.unlock() }; count += more; return count }
}
