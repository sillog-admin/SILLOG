import XCTest
@testable import SillogApp
import SillogCore

/// Screen text held in a static let kept the language it was first read in, so the connector page stayed Korean after switching.
@MainActor
final class LanguageSwitchTests: XCTestCase {
    override func tearDown() { L10n.current = .ko }

    func testScreenTextFollowsALanguageSwitch() {
        L10n.current = .ko
        XCTAssertEqual(ConnectorEntry.all.first?.summary, "고른 파일 검색과 읽기")
        XCTAssertEqual(PrivacyNote.title, "무엇이 기기 밖으로 나가나요?")

        L10n.current = .en
        XCTAssertEqual(ConnectorEntry.all.first?.summary, "Search and read picked files")
        XCTAssertEqual(PrivacyNote.title, "What leaves your device?")
        XCTAssertEqual(AppState.alreadyRunningMessage, "SILLOG is already running. Check the icon in the menu bar.")
        XCTAssertEqual(TasksView.kinds.first?.name, L10n.english["참고자료"])
    }
}
