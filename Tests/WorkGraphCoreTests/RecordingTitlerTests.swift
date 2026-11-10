import XCTest
@testable import WorkGraphCore

/// 녹음 제목·요약(빠른 모델), 받아쓴 글 파일 이름과 본문
final class RecordingTitlerTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    /// 2026-10-10 15:32 (서울)
    private var start: Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 32))!.timeIntervalSince1970
    }

    func testNameSendsTheTranscriptHeadAndReadsTheToolAnswer() async {
        let llm = StubLLM([.success(#"{"title":" “자료구조 3주차 강의” ","summary":"연결 리스트를 설명한 강의."}"#)])
        let transcript = String(repeating: "가", count: 4_000) + "끝부분은보내지않음"
        let naming = await RecordingTitler(llm: llm).name(transcript: transcript, startedAt: start, duration: 3_130, timeZone: seoul)
        XCTAssertEqual(naming, RecordingTitler.Naming(title: "자료구조 3주차 강의", summary: "연결 리스트를 설명한 강의."))
        XCTAssertTrue(llm.lastUser.contains("RECORDED: 2026-10-10 15:32 (52분 10초)"))
        XCTAssertTrue(llm.lastUser.contains("TRANSCRIPT (first 4000 characters):"))
        XCTAssertFalse(llm.lastUser.contains("끝부분은보내지않음"), "앞 4,000자만 보낸다")
    }

    func testEmptyTranscriptModelFailureAndBlankAnswerGiveTheDateTitle() async {
        let llm = StubLLM([.failure(.transport("offline")), .success(#"{"title":"  ","summary":""}"#)])
        let titler = RecordingTitler(llm: llm)
        let fallback = RecordingTitler.Naming(title: "녹음 2026-10-10 15-32", summary: nil)
        let empty = await titler.name(transcript: " \n ", startedAt: start, duration: 5, timeZone: seoul)
        XCTAssertEqual(empty, fallback)
        XCTAssertEqual(llm.calls, 0, "받아쓴 글이 비면 모델을 부르지 않는다")
        let failed = await titler.name(transcript: "말", startedAt: start, duration: 5, timeZone: seoul)
        XCTAssertEqual(failed, fallback)
        let blank = await titler.name(transcript: "말", startedAt: start, duration: 5, timeZone: seoul)
        XCTAssertEqual(blank, fallback)
    }

    func testFileNameDropsCharactersFilesCannotHaveAndKeepsOneDate() {
        XCTAssertEqual(RecordingTitler.fileName(title: "자료구조: 3주차/강의?", startedAt: start, timeZone: seoul), "2026-10-10 자료구조 3주차 강의.md")
        XCTAssertEqual(RecordingTitler.fileName(title: "녹음 2026-10-10 15-32", startedAt: start, timeZone: seoul), "녹음 2026-10-10 15-32.md")
        XCTAssertEqual(RecordingTitler.fileName(title: "...", startedAt: start, timeZone: seoul), "녹음 2026-10-10 15-32.md", "남는 글자가 없으면 날짜 제목")
    }

    func testMarkdownHasTitleTimeLengthSummaryAndOneParagraphPerUtterance() {
        let text = RecordingTitler.markdown(title: "자료구조 3주차 강의", summary: "연결 리스트를 설명한 강의.", utterances: ["첫 문장.", "둘째 문장."],
                                            startedAt: start, duration: 3_130, timeZone: seoul)
        XCTAssertEqual(text, """
        # 자료구조 3주차 강의

        - 녹음: 2026년 10월 10일 15:32, 52분 10초
        - 요약: 연결 리스트를 설명한 강의.

        ## 받아쓴 글

        첫 문장.

        둘째 문장.

        """)
    }

    func testWriteAddsANumberWhenTheNameIsTaken() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wg-titler-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recording = Recording(id: 1, startedAt: start, endedAt: start + 60, duration: 60, audioPath: "/a.m4a", title: "회의", transcript: "가\n나", status: .transcribing)
        let first = try RecordingTitler.write(recording, into: folder, timeZone: seoul)
        let second = try RecordingTitler.write(recording, into: folder, timeZone: seoul)
        XCTAssertEqual(first.lastPathComponent, "2026-10-10 회의.md")
        XCTAssertEqual(second.lastPathComponent, "2026-10-10 회의 (2).md")
        XCTAssertTrue(try String(contentsOf: first, encoding: .utf8).contains("가\n\n나"))
    }

    func testDurationAndClockText() {
        XCTAssertEqual(RecordingText.duration(45), "45초")
        XCTAssertEqual(RecordingText.duration(120), "2분")
        XCTAssertEqual(RecordingText.duration(3_130), "52분 10초")
        XCTAssertEqual(RecordingText.duration(3_780), "1시간 3분")
        XCTAssertEqual(RecordingText.clock(751), "12:31")
        XCTAssertEqual(RecordingText.clock(3_723), "1:02:03")
    }

    func testExcerptIsTheSummaryThenTheFirst800Characters() {
        let transcript = "첫 줄\n" + String(repeating: "나", count: 900)
        let excerpt = RecordingTitler.excerpt(summary: "요약 한 줄.", transcript: transcript)
        XCTAssertTrue(excerpt.hasPrefix("요약 한 줄.\n첫 줄 나"))
        XCTAssertEqual(excerpt.count, "요약 한 줄.\n".count + 800)
        XCTAssertEqual(RecordingTitler.excerpt(summary: nil, transcript: "가\n나"), "가 나")
    }

    func testDateTextUsesThePatternAndTimeZone() {
        XCTAssertEqual(RecordingText.date(start, "yyyy-MM-dd HH:mm", timeZone: seoul), "2026-10-10 15:32")
        XCTAssertEqual(RecordingText.date(start, "yyyy년 M월 d일 HH:mm", timeZone: TimeZone(identifier: "UTC")!), "2026년 10월 10일 06:32")
    }
}
