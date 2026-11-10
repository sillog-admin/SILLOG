import XCTest
@testable import WorkGraphCore

final class MenuBarModelTests: XCTestCase {
    private func mode(_ phase: AppPhase = .ready, failed: Bool = false, paused: Bool = false, running: Bool = true,
                      ax: Bool = true, screen: Bool = true) -> MenuBarMode {
        MenuBarModel.mode(phase: phase, startupFailed: failed, paused: paused, running: running,
                          accessibility: ax, screenRecording: screen)
    }

    func testNotReadyWinsOverEverything() {
        XCTAssertEqual(mode(.login, paused: true, ax: false), .notReady)
        XCTAssertEqual(mode(.permissions), .notReady)
        XCTAssertEqual(mode(.ready, failed: true), .notReady)
    }

    func testPausedWinsOverMissingPermission() {
        XCTAssertEqual(mode(paused: true, ax: false, screen: false), .paused)
    }

    func testMissingEitherPermissionWarns() {
        XCTAssertEqual(mode(ax: false), .permissionMissing)
        XCTAssertEqual(mode(screen: false), .permissionMissing)
    }

    func testNormalWhenReadyWithBothPermissions() {
        XCTAssertEqual(mode(), .normal)
    }

    func testPermissionsUnknownBeforeFirstReportDoNotWarn() {
        // 앱이 막 켜져 수집기가 아직 권한을 알려 주지 않은 순간: 기본값(false) 때문에 W6 가 깜빡이면 안 된다
        XCTAssertEqual(mode(running: false, ax: false, screen: false), .normal)
    }

    func testTwoDigits() {
        XCTAssertEqual(MenuBarModel.twoDigits(0), "00")
        XCTAssertEqual(MenuBarModel.twoDigits(6), "06")
        XCTAssertEqual(MenuBarModel.twoDigits(9), "09")
        XCTAssertEqual(MenuBarModel.twoDigits(10), "10")
        XCTAssertEqual(MenuBarModel.twoDigits(62), "62")
        XCTAssertEqual(MenuBarModel.twoDigits(-3), "00")
    }

    func testTwoDigitsKeepsLargeNumbers() {
        XCTAssertEqual(MenuBarModel.twoDigits(1234), "1234")
    }

    func testBatchSummaryMatchesFigma() {
        XCTAssertEqual(MenuBarModel.batchSummary(clock: "14:05", newTasks: 1, resources: 3), "14:05 정리 완료(새 업무 1개, 자료 3개)")
    }

    func testNotReadyMessage() {
        XCTAssertEqual(MenuBarModel.notReadyMessage(phase: .login, startupFailed: false), "시작하려면 ChatGPT 로그인이 필요해요")
        XCTAssertEqual(MenuBarModel.notReadyMessage(phase: .permissions, startupFailed: false), "시작하려면 권한 설정을 마쳐 주세요")
        XCTAssertEqual(MenuBarModel.notReadyMessage(phase: .ready, startupFailed: true), "Sillog을 시작하지 못했어요")
    }

    func testStatusText() {
        XCTAssertNil(MenuBarModel.statusText(mode: .notReady, running: false, idle: false))
        XCTAssertEqual(MenuBarModel.statusText(mode: .paused, running: true, idle: false), "일시정지됨")
        XCTAssertEqual(MenuBarModel.statusText(mode: .permissionMissing, running: true, idle: false), "■ 수집 중")
        XCTAssertEqual(MenuBarModel.statusText(mode: .normal, running: true, idle: false), "■ 기록 중")
        XCTAssertEqual(MenuBarModel.statusText(mode: .normal, running: true, idle: true), "자리 비움")
        XCTAssertEqual(MenuBarModel.statusText(mode: .normal, running: false, idle: false), "시작하는 중")
    }
}
