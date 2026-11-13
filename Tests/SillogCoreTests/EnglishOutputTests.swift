import XCTest
@testable import SillogCore

/// Text the app builds or matches in code follows the English setting, while stored Korean keys keep working.
final class EnglishOutputTests: XCTestCase {
    override func setUp() { L10n.current = .en }
    override func tearDown() { L10n.current = .ko }

    func testEnglishThemeAnswersFindTheStoredKoreanTheme() throws {
        XCTAssertEqual(ThemeCatalog.canonical("Studies"), "학업")
        XCTAssertEqual(ThemeCatalog.canonical("job search"), "취업 준비")
        let db = try SillogDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: NodeLabel.task, key: "a", subtype: nil, title: "A", props: [:], at: 1)
            let b = try tx.upsertNode(label: NodeLabel.task, key: "b", subtype: nil, title: "B", props: [:], at: 1)
            let first = try XCTUnwrap(try ThemeGraph.attach(taskId: a, to: "학업", tx, now: 1))
            let second = try XCTUnwrap(try ThemeGraph.attach(taskId: b, to: "Studies", tx, now: 1))
            XCTAssertEqual(second.node.id, first.node.id)
            XCTAssertFalse(second.created)
        }
        XCTAssertEqual(ThemeCatalog.nameLimit, 40)
    }

    func testEnglishTaskTypeTitlesAreCategories() {
        XCTAssertTrue(AssignmentApplier.isCategory("Coding"))
        XCTAssertTrue(AssignmentApplier.isCategory("other"))
        XCTAssertTrue(AssignmentApplier.isCategory("코드작성"))
        XCTAssertFalse(AssignmentApplier.isCategory("Coding the login page"))
    }

    func testTimesAndDurationsFollowTheLanguageButDigestInputStaysKorean() {
        XCTAssertEqual(TimePhrase.approx(9000), "about 2 h 30 min")
        XCTAssertEqual(TimePhrase.approx(9000, localized: false), "약 2시간 30분")
        XCTAssertEqual(RecordingText.duration(3130), "52m 10s")
    }

    func testFileNotificationsUseEnglishFolderNames() {
        XCTAssertEqual(FileSuggestionCopy.title, "Move this file?")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me/Downloads/Stats", home: "/Users/me"), "Downloads / Stats")
        XCTAssertEqual(FileSuggestionCopy.folderLabel("/Users/me", home: "/Users/me"), "Home")
        XCTAssertEqual(FileSuggestionCopy.transcribedBody(fileName: "a.md", folder: "/Users/me/Documents/Notes", home: "/Users/me"), "Saved 'a.md' to Documents / Notes.")
    }

    func testStorageSummaryIsEnglishOnScreenAndKoreanInTheLog() {
        var report = Consolidator.Report(startedAt: 0)
        report.weekly = 3; report.weeklyDrafts = 1; report.prunedDays = 2
        XCTAssertEqual(report.localizedSummary, "weekly summaries: 3 (drafts: 1), tidied 2 days of raw records")
        XCTAssertEqual(report.summary, "주간 요약 3개 (초안 1개), 2일치 원문 정리")
    }

    func testAFailureSavedInKoreanIsRestoredInEnglish() {
        let saved = L10n.korean("받아쓰기가 꺼져 있어요. 시스템 설정 → 키보드 → 받아쓰기를 켠 뒤 다시 받아쓰세요.")
        XCTAssertEqual(TranscriptionError.restored(from: saved).message, TranscriptionError.dictationDisabled.message)
        XCTAssertTrue(TranscriptionError.dictationDisabled.message.hasPrefix("Dictation is off"))
    }

    func testChatSourceTitlesTranslateTheirParts() {
        XCTAssertEqual(ChatRunner.displayTitle("notes.md · 1부터"), "notes.md · from 1")
        XCTAssertEqual(ChatRunner.displayTitle("Slack · 메시지"), "Slack · Message")
    }
}
