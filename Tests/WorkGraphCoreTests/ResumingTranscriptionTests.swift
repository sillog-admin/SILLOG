import XCTest
@testable import WorkGraphCore

/// 기기 안 인식은 말이 한동안 끊기면 파일 끝까지 가지 않고 끝낸다 (10/13 측정: 77초 녹음에서 34초 뒤 40초를 놓침).
/// 끝난 자리 바로 뒤에서 다시 시작하고, 아무것도 안 나오면 건너뛰며 파일 끝까지 받아쓴다
final class ResumingTranscriptionTests: XCTestCase {
    /// 가짜 인식기: start 부터 말을 듣다가, 앞 말(또는 시작)과 12초 넘게 떨어진 말이 나오면 거기서 끝낸다
    private actor EarlyStopper {
        let speech: [(text: String, end: Double)]
        private(set) var starts: [Double] = []
        init(_ speech: [(text: String, end: Double)]) { self.speech = speech }

        func pass(from start: Double) -> ResumingTranscription.Pass {
            starts.append(start)
            var heard: [(text: String, end: Double)] = [], previous = start
            for item in speech where item.end > start {
                guard item.end - previous <= 12 else { break }
                heard.append(item); previous = item.end
            }
            return .init(utterances: heard.map(\.text), lastEnd: heard.last.map { $0.end - start })
        }
    }

    func testItResumesWhereTheRecognizerStoppedUntilTheEnd() async throws {
        let speech = [("녹음이 될 거예요", 2.4), ("그래서", 5.4), ("저장이 되구요", 21.1), ("생각보다 크더라", 32.5),
                      ("모르겠는데", 50), ("되긴", 53), ("설정 부분은 활동", 67), ("설정 쪽에 빼고", 72)].map { (text: $0.0, end: $0.1) }
        let recognizer = EarlyStopper(speech)
        let utterances = try await ResumingTranscription.run(duration: 77.3) { start in await recognizer.pass(from: start) }
        XCTAssertEqual(utterances, speech.map(\.text), "끝까지, 차례대로, 겹치지 않게")
        let starts = await recognizer.starts
        XCTAssertEqual(starts.first, 0)
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $0 < $1 }, "다시 시작할 때마다 앞으로만: \(starts)")
        XCTAssertLessThan(starts.last ?? 99, 77.3)
    }

    func testAPassThatHearsEverythingNeedsOnlyALookAtTheTail() async throws {
        let recognizer = EarlyStopper([("하나", 10), ("둘", 20), ("셋", 29)].map { (text: $0.0, end: $0.1) })
        let utterances = try await ResumingTranscription.run(duration: 30) { start in await recognizer.pass(from: start) }
        XCTAssertEqual(utterances, ["하나", "둘", "셋"])
        let starts = await recognizer.starts
        XCTAssertLessThanOrEqual(starts.count, 2, "끝까지 들었으면 남은 꼬리만 한 번 더: \(starts)")
    }

    func testUnknownEndTimesStillMoveForwardAndStop() async throws {
        var calls = 0
        let utterances = try await ResumingTranscription.run(duration: 60) { _ in
            calls += 1
            return .init(utterances: ["끝 시각 모름"], lastEnd: nil)
        }
        XCTAssertLessThanOrEqual(calls, 7, "끝 시각을 모르면 건너뛰는 간격만큼 나아간다")
        XCTAssertEqual(utterances.count, calls)
    }

    func testQuietRecordingsAreRaisedButLoudOnesAreLeftAlone() {
        // 10/13: 77초 녹음을 1·1.5·2·3·4·8배로 비교하니 2~3배가 앞뒤 모두 가장 많이 받아썼다 (더 키우면 잡음도 커져 뒤쪽이 토막 난다)
        XCTAssertEqual(TranscriptionGain.factor(windowRMS: [0.004, 0.006, 0.01, 0.012]), 3, "아주 작아도 최대 3배")
        XCTAssertEqual(TranscriptionGain.factor(windowRMS: Array(repeating: 0.04, count: 9) + [0.08]), 2, accuracy: 0.01,
                       "말소리 부분(위쪽 10%)이 -16dBFS 쯤 되게: 0.08 → 2배")
        XCTAssertEqual(TranscriptionGain.factor(windowRMS: [0.2, 0.3, 0.4]), 1, "충분히 크면 그대로 (줄이지 않는다)")
        XCTAssertEqual(TranscriptionGain.factor(windowRMS: [0, 0, 0]), 1, "소리가 없으면 그대로")
        XCTAssertEqual(TranscriptionGain.factor(windowRMS: []), 1)
    }
}
