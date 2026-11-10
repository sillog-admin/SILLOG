import Foundation
import WorkGraphCore

/// 녹음 하나의 미리 받아쓰기: 녹음기가 오디오 스레드에서 흘려보내는 16kHz 소리를 들어온 차례대로 받아 조각마다 받아쓴다 (IncrementalTranscription)
final class LiveTranscription: Sendable {
    private let continuation: AsyncStream<[Float]>.Continuation
    private let result: Task<[String], Error>

    init(chunk: @escaping IncrementalTranscription.ChunkTranscriber) {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        let incremental = IncrementalTranscription(transcribe: chunk)
        result = Task {
            for await samples in stream { await incremental.append(samples) }
            try Task.checkCancellation()                                    // 버린 녹음: 남은 조각은 받아쓰지 않는다
            return try await incremental.finish()
        }
    }

    /// 녹음기에서 (오디오 스레드). 들어온 차례가 지켜진다
    func append(_ samples: [Float]) { continuation.yield(samples) }

    /// 녹음이 끝나면: 남은 조각까지 받아쓴 글. 중간 조각이 실패했으면 던진다
    func finish() async throws -> [String] {
        continuation.finish()
        return try await result.value
    }

    /// 쓰지 않게 됐을 때 (녹음이 실패로 끝남 등)
    func cancel() {
        result.cancel()
        continuation.finish()
    }
}

/// 녹음마다의 미리 받아쓰기를 들고 있다가 정리 단계(LiveFirstTranscriber)에 꺼내 준다. 앱을 다시 켜면 비어 있다 (그러면 파일 전체를 받아쓴다)
@MainActor
final class LiveTranscriptions {
    private var sessions: [String: LiveTranscription] = [:]
    private let prewarm: (@Sendable () async -> Void)?
    private let chunk: IncrementalTranscription.ChunkTranscriber

    /// Args: prewarm 은 녹음을 시작할 때 모델을 미리 불러 둔다 (첫 조각에서 기다리지 않게), chunk 는 조각 하나를 받아쓴다.
    init(prewarm: (@Sendable () async -> Void)? = nil, chunk: @escaping IncrementalTranscription.ChunkTranscriber) {
        self.prewarm = prewarm
        self.chunk = chunk
    }

    /// 녹음을 시작할 때: 이 녹음 파일의 미리 받아쓰기
    func begin(audio: URL) -> LiveTranscription {
        let session = LiveTranscription(chunk: chunk)
        sessions[audio.path]?.cancel()
        sessions[audio.path] = session
        if let prewarm { Task.detached { await prewarm() } }
        return session
    }

    func session(for audio: URL) -> LiveTranscription? { sessions[audio.path] }

    /// 정리할 때 꺼낸다 (한 번만)
    func take(_ audio: URL) -> LiveTranscription? { sessions.removeValue(forKey: audio.path) }

    /// 녹음이 실패로 끝나 쓰지 않을 때
    func discard(_ audio: URL) { take(audio)?.cancel() }
}

/// 정리 단계의 받아쓰기: 녹음 중 미리 받아쓴 것이 있으면 그 글(끝난 뒤엔 남은 조각만 받아씀), 없거나 실패했으면 파일 전체(fallback)
struct LiveFirstTranscriber: Transcribing {
    let live: LiveTranscriptions
    let fallback: any Transcribing

    func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        if let session = await live.take(audio) {
            do {
                let lines = try await session.finish()
                progress(1)
                return lines
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.write("녹음 중 미리 받아쓰기 실패: 파일 전체를 받아씀 (\(error.localizedDescription))")
            }
        }
        return try await fallback.transcribe(audio: audio, duration: duration, progress: progress)
    }
}
