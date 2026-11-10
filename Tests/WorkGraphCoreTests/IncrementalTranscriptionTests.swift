import XCTest
@testable import WorkGraphCore

/// 녹음 중 미리 받아쓰기: 30초쯤 모이면 끝 쪽에서 가장 조용한 순간에 잘라 차례로 받아쓰고, 끝나면 남은 조각만 받아쓴다
final class IncrementalTranscriptionTests: XCTestCase {
    private let rate = IncrementalTranscription.sampleRate

    /// 말소리 대신 0.1 크기의 소리, quiet 구간(초)은 0
    private func audio(seconds: Double, quiet: [ClosedRange<Double>] = []) -> [Float] {
        (0..<Int(seconds * rate)).map { index in
            let time = Double(index) / rate
            return quiet.contains { $0.contains(time) } ? 0 : Float(0.1 * sin(Double(index) * 0.05))
        }
    }

    /// 받은 조각의 길이(초)를 적고 "조각 n" 을 돌려준다. delays 가 있으면 조각마다 그만큼 늦게 끝난다
    private actor Recorder {
        private(set) var lengths: [Double] = []
        func chunk(_ samples: [Float], rate: Double, delay: UInt64 = 0) async -> [String] {
            lengths.append(Double(samples.count) / rate)
            let number = lengths.count
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            return ["조각 \(number)"]
        }
    }

    private func feed(_ samples: [Float], into live: IncrementalTranscription) async {
        var start = 0
        while start < samples.count {                                   // 녹음기처럼 1초씩
            let end = min(samples.count, start + Int(rate))
            await live.append(Array(samples[start..<end]))
            start = end
        }
    }

    func testChunksAreCutAtTheQuietestMomentNearThirtySeconds() async throws {
        let recorder = Recorder(), rate = rate
        let live = IncrementalTranscription { await recorder.chunk($0, rate: rate) }
        await feed(audio(seconds: 75, quiet: [27.0...27.5, 55.0...55.6]), into: live)
        let lines = try await live.finish()
        XCTAssertEqual(lines, ["조각 1", "조각 2", "조각 3"])
        let lengths = await recorder.lengths
        XCTAssertEqual(lengths.count, 3)
        XCTAssertEqual(lengths[0], 27.25, accuracy: 0.2, "첫 조각은 27초 무렵 조용한 순간에서: \(lengths)")
        XCTAssertEqual(lengths[0] + lengths[1], 55.3, accuracy: 0.2, "둘째 조각은 55초 무렵 조용한 순간까지: \(lengths)")
        XCTAssertEqual(lengths.reduce(0, +), 75, accuracy: 0.01, "남은 조각까지 빠짐없이")
    }

    func testLinesStayInRecordingOrderEvenWhenChunksFinishAtDifferentSpeeds() async throws {
        let recorder = Recorder(), rate = rate
        let delays: [UInt64] = [80_000_000, 0, 30_000_000]
        let counter = Counter()
        let live = IncrementalTranscription { samples in
            let index = await counter.next()
            return await recorder.chunk(samples, rate: rate, delay: delays[min(index, delays.count - 1)])
        }
        await feed(audio(seconds: 80), into: live)
        let lines = try await live.finish()
        XCTAssertEqual(lines, ["조각 1", "조각 2", "조각 3"], "앞 조각이 늦게 끝나도 순서대로")
    }

    func testAFailedChunkMakesFinishThrowSoTheWholeFileIsTranscribedInstead() async {
        let counter = Counter()
        let live = IncrementalTranscription { _ in
            if await counter.next() == 1 { throw URLError(.cannotDecodeContentData) }
            return ["말"]
        }
        await feed(audio(seconds: 70), into: live)
        do {
            _ = try await live.finish()
            XCTFail("중간 조각이 실패했으면 끝낼 때 알려야 한다")
        } catch {}
    }

    func testSilentChunksAreSkipped() async throws {
        let recorder = Recorder(), rate = rate
        let live = IncrementalTranscription { await recorder.chunk($0, rate: rate) }
        await feed(audio(seconds: 31, quiet: [0...31]), into: live)          // 소리가 아예 없음
        let lines = try await live.finish()
        XCTAssertEqual(lines, [])
        let lengths = await recorder.lengths
        XCTAssertTrue(lengths.isEmpty, "소리가 없는 조각은 받아쓰지 않는다 (지어낸 말 방지)")
    }

    private actor Counter {
        private var value = -1
        func next() -> Int { value += 1; return value }
    }
}
