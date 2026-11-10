import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 녹음 중 미리 받아쓴 글을 정리 단계가 쓴다. 미리 받아쓰기가 실패했거나(조각 오류) 없으면(앱을 다시 켬) 파일 전체를 받아쓴다
@MainActor
final class LiveTranscriptionTests: XCTestCase {
    private struct Fixed: Transcribing {
        let lines: [String]
        func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] { lines }
    }
    private let audio = URL(fileURLWithPath: "/tmp/7.m4a")

    /// 녹음기가 흘려보내는 것처럼 0.5초씩
    private func stream(seconds: Double, into session: LiveTranscription) {
        let half = [Float](repeating: 0.1, count: 8_000)
        for _ in 0..<Int(seconds * 2) { session.append(half) }
    }

    func testThePipelineUsesWhatWasTranscribedDuringTheRecording() async throws {
        let live = LiveTranscriptions { samples in ["\(samples.count / 16_000)초 조각"] }
        let session = live.begin(audio: audio)
        stream(seconds: 65, into: session)
        let lines = try await LiveFirstTranscriber(live: live, fallback: Fixed(lines: ["파일 전체"])).transcribe(audio: audio, duration: 65) { _ in }
        XCTAssertEqual(lines.count, 3, "30초쯤씩 두 조각과 남은 조각: \(lines)")
        XCTAssertFalse(lines.contains("파일 전체"))
        XCTAssertNil(live.session(for: audio), "쓴 뒤에는 꺼낸다")
    }

    func testAFailedLiveTranscriptionFallsBackToTheWholeFile() async throws {
        let live = LiveTranscriptions { _ in throw URLError(.cannotDecodeContentData) }
        stream(seconds: 40, into: live.begin(audio: audio))
        let lines = try await LiveFirstTranscriber(live: live, fallback: Fixed(lines: ["파일 전체"])).transcribe(audio: audio, duration: 40) { _ in }
        XCTAssertEqual(lines, ["파일 전체"])
    }

    func testWithoutALiveTranscriptionTheWholeFileIsTranscribed() async throws {
        let live = LiveTranscriptions { _ in ["쓰이면 안 됨"] }
        let lines = try await LiveFirstTranscriber(live: live, fallback: Fixed(lines: ["파일 전체"])).transcribe(audio: audio, duration: 40) { _ in }
        XCTAssertEqual(lines, ["파일 전체"], "앱을 다시 켜서 미리 받아쓴 것이 없을 때")
    }
}
