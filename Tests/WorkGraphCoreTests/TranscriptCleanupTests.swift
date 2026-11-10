import XCTest
@testable import WorkGraphCore

/// Whisper 가 작은 소리·잡음에서 지어낸 줄을 거른다 (10/13 강의 녹음: 출석 부르는 구간에서 '최선은' 40번, '-' 여러 줄)
final class TranscriptCleanupTests: XCTestCase {
    func testALineRepeatedOverAndOverIsKeptOnce() {
        let loop = ["김정수", "최선은"] + Array(repeating: "최선은", count: 40) + ["이번 주가 설계 두 번째 주입니다."]
        XCTAssertEqual(TranscriptCleanup.clean(loop), ["김정수", "최선은", "이번 주가 설계 두 번째 주입니다."])
    }

    func testTheSameWordsWithDifferentPunctuationCountAsOneRun() {
        XCTAssertEqual(TranscriptCleanup.clean(["네.", "네", "네!", "네?"]), ["네."])
    }

    func testSaidTwiceInARowIsReal() {
        XCTAssertEqual(TranscriptCleanup.clean(["안녕하세요~", "안녕하세요~", "오늘은 설계 발표입니다."]),
                       ["안녕하세요~", "안녕하세요~", "오늘은 설계 발표입니다."], "두 사람이 인사하는 것처럼 두 번은 그대로 둔다")
    }

    func testLinesWithoutLettersOrNumbersAreDropped() {
        XCTAssertEqual(TranscriptCleanup.clean(["-", " ... ", "~", "10주차에 발표합니다.", "  "]), ["10주차에 발표합니다."])
    }
}
