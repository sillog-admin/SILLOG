import WhisperKit
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 받아쓰기는 Whisper(기기 안). 쓸 수 없으면(모델 내려받기·불러오기 실패) 애플 기기 안 인식으로 받아쓰고, 취소는 넘기지 않는다
final class WhisperTranscriberTests: XCTestCase {
    private struct Fixed: Transcribing {
        let lines: [String]
        func transcribe(audio: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [String] { lines }
    }
    private let audio = URL(fileURLWithPath: "/tmp/sillog-test.m4a")

    /// 받아쓰는 중인 조각의 토큰들
    private func decoding(_ tokens: [Int]) -> TranscriptionProgress {
        TranscriptionProgress(timings: TranscriptionTimings(), text: "", tokens: tokens)
    }

    // Whisper 가 같은 말을 되풀이하기 시작하면 그 시도를 바로 멈춘다 (10/13 강의 녹음의 조용한 출석 구간: 28.7초 조각에 111초)
    func testADecodeThatStartsRepeatingItselfIsStopped() {
        let loop = Array(repeating: [50365, 21423, 4022, 13], count: 20).flatMap { $0 }     // '최선은.' 되풀이
        XCTAssertEqual(WhisperEngine.shouldContinue(decoding(loop), deadline: .distantFuture), false)
    }

    func testOrdinarySpeechKeepsDecoding() {
        var seed: UInt64 = 7
        let speech = (0..<90).map { _ -> Int in seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % 50_000 }
        XCTAssertNil(WhisperEngine.shouldContinue(decoding(speech), deadline: .distantFuture))
    }

    func testAChunkThatRunsPastItsTimeStops() {
        XCTAssertEqual(WhisperEngine.shouldContinue(decoding([50365, 21423]), deadline: Date(timeIntervalSinceNow: -1)), false)
    }

    func testWhisperResultsAreUsedWhenItRuns() async throws {
        var transcriber = WhisperTranscriber(fallback: Fixed(lines: ["애플 인식"]))
        transcriber.engine = { _, _ in ["위스퍼가 받아쓴 말"] }
        let lines = try await transcriber.transcribe(audio: audio, duration: 10) { _ in }
        XCTAssertEqual(lines, ["위스퍼가 받아쓴 말"])
    }

    func testWhenWhisperCannotRunTheDeviceRecognizerTakesOver() async throws {
        var transcriber = WhisperTranscriber(fallback: Fixed(lines: ["애플 인식"]))
        transcriber.engine = { _, _ in throw URLError(.notConnectedToInternet) }          // 모델을 못 내려받음
        let lines = try await transcriber.transcribe(audio: audio, duration: 10) { _ in }
        XCTAssertEqual(lines, ["애플 인식"])
    }

    // 이미 내려받은 모델이 있으면 인터넷으로 확인하지 않고 그대로 쓴다 (오프라인에서도 받아쓰기). 셋 중 하나라도 없으면 내려받는다
    func testADownloadedModelIsFoundWithoutTheNetwork() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNil(WhisperEngine.localModelFolder(in: base), "아직 안 받음")
        let folder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(WhisperTranscriber.model)", isDirectory: true)
        for part in ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(part), withIntermediateDirectories: true)
        }
        XCTAssertNil(WhisperEngine.localModelFolder(in: base), "TextDecoder 가 없으면 다 받은 게 아니다")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("TextDecoder.mlmodelc"), withIntermediateDirectories: true)
        XCTAssertEqual(WhisperEngine.localModelFolder(in: base)?.standardizedFileURL, folder.standardizedFileURL)
    }

    func testCancellingDoesNotFallBack() async {
        var transcriber = WhisperTranscriber(fallback: Fixed(lines: ["애플 인식"]))
        transcriber.engine = { _, _ in throw CancellationError() }
        do {
            _ = try await transcriber.transcribe(audio: audio, duration: 10) { _ in }
            XCTFail("취소는 그대로 끝나야 한다")
        } catch is CancellationError {
        } catch {
            XCTFail("취소가 아닌 오류: \(error)")
        }
    }
}
