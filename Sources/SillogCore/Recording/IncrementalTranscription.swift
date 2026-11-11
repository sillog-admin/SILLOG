import Foundation

/// 녹음 중 미리 받아쓰기: 16kHz 소리를 받다가 30초쯤 모이면 그 끝 쪽에서 가장 조용한 순간에 잘라(말 중간을 끊지 않게) 차례로 받아쓴다.
/// 녹음이 끝나면 남은 조각만 받아쓰면 되어 긴 녹음도 끝나자마자 글이 나온다 (파일 전체는 녹음 길이의 약 6%가 걸림, 10/13 측정).
/// 한 조각이라도 실패하면 finish 가 오류를 던진다: 그때는 녹음 파일 전체를 다시 받아쓴다
public actor IncrementalTranscription {
    public typealias ChunkTranscriber = @Sendable ([Float]) async throws -> [String]
    /// Whisper 가 받는 소리 (16kHz 모노)
    public static let sampleRate = 16_000.0

    private let target: Int
    private let search: Int
    private let transcribe: ChunkTranscriber
    private var pending: [Float] = []
    private var utterances: [String] = []
    private var chain: Task<Void, Never>?
    private var failure: Error?

    /// Args: chunkSeconds 는 한 조각 길이, searchSeconds 는 조각 끝에서 자를 자리를 찾는 범위, transcribe 는 조각 하나를 받아쓴다.
    public init(chunkSeconds: Double = 30, searchSeconds: Double = 5, transcribe: @escaping ChunkTranscriber) {
        target = Int(chunkSeconds * Self.sampleRate)
        search = Int(min(searchSeconds, chunkSeconds / 2) * Self.sampleRate)
        self.transcribe = transcribe
    }

    /// 녹음기에서 들어오는 소리 (16kHz 모노)
    public func append(_ samples: [Float]) {
        pending += samples
        while pending.count >= target {
            let cut = Self.quietestCut(pending, from: target - search, to: target)
            enqueue(Array(pending[..<cut]))
            pending.removeFirst(cut)
        }
    }

    /// 녹음이 끝나면: 남은 조각까지 받아쓰고 녹음 순서대로 모은 글을 돌려준다.
    /// Raises: 중간에 실패한 조각의 오류 (그러면 파일 전체를 다시 받아쓴다).
    public func finish() async throws -> [String] {
        if !pending.isEmpty { enqueue(pending); pending = [] }
        await chain?.value
        if let failure { throw failure }
        return utterances
    }

    /// 앞 조각이 끝난 뒤에 받아쓴다 (순서를 지키고, 모델을 하나만 쓴다)
    private func enqueue(_ chunk: [Float]) {
        let previous = chain, transcribe = transcribe
        chain = Task {
            await previous?.value
            guard await self.failure == nil, !Self.isSilent(chunk) else { return }
            do { await self.add(try await transcribe(chunk)) } catch { await self.fail(error) }
        }
    }

    private func add(_ lines: [String]) { utterances += lines }
    private func fail(_ error: Error) { if failure == nil { failure = error } }

    /// 0.1초 창
    private static var window: Int { Int(sampleRate / 10) }

    /// from..<to 에서 가장 조용한 곳: 0.1초 창(반씩 겹쳐)의 에너지가 가장 작은 창들이 이어진 구간의 가운데. 조각을 자를 자리
    static func quietestCut(_ samples: [Float], from: Int, to: Int) -> Int {
        let window = Self.window, step = window / 2
        var energies: [(start: Int, sum: Float)] = []
        var start = max(0, from)
        while start + window <= min(to, samples.count) {
            var sum: Float = 0
            for index in start..<(start + window) { sum += samples[index] * samples[index] }
            energies.append((start, sum))
            start += step
        }
        guard let quietest = energies.map(\.sum).min() else { return max(1, min(to, samples.count)) }
        let limit = quietest * 1.1 + 1e-9
        // 가장 조용한 창들이 가장 길게 이어진 구간을 고른다 (말 사이의 쉼 한가운데에서 자르게)
        var bestRun = 0..<0, runStart: Int?
        for (index, item) in energies.enumerated() {
            if item.sum <= limit {
                if runStart == nil { runStart = index }
                if let begin = runStart, index + 1 - begin > bestRun.count { bestRun = begin..<(index + 1) }
            } else {
                runStart = nil
            }
        }
        let middle = energies[bestRun.lowerBound + (bestRun.count - 1) / 2]
        return max(1, min(middle.start + window / 2, samples.count))
    }

    /// 소리가 거의 없는 조각인지 (0.1초 창 RMS 위쪽 10%가 약 -56dBFS 아래). Whisper 가 '감사합니다' 같은 말을 지어내지 않게 건너뛴다
    static func isSilent(_ chunk: [Float]) -> Bool {
        let window = Self.window
        guard chunk.count >= window else { return chunk.allSatisfy { abs($0) < 0.0015 } }
        var levels: [Float] = []
        var start = 0
        while start + window <= chunk.count {
            var sum: Float = 0
            for index in start..<(start + window) { sum += chunk[index] * chunk[index] }
            levels.append((sum / Float(window)).squareRoot())
            start += window
        }
        levels.sort()
        return levels[min(levels.count - 1, Int(Double(levels.count) * 0.9))] < 0.0015
    }
}
