import XCTest
@testable import WorkGraphCore

final class OnboardingFlowTests: XCTestCase {
    func testFirstLoginStaysOnStepOneUntilNext() {
        XCTAssertEqual(OnboardingFlow.step(after: .login, phase: .permissions), .login)
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .login, phase: .permissions))
        XCTAssertEqual(OnboardingFlow.advance(from: .login, phase: .permissions), .permissions)
    }

    func testNextIsDisabledBeforeLogin() {
        XCTAssertFalse(OnboardingFlow.canAdvance(from: .login, phase: .login))
        XCTAssertEqual(OnboardingFlow.advance(from: .login, phase: .login), .login)
    }

    func testRelaunchDuringPermissionsReopensStepTwo() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .permissions), .permissions)
    }

    func testFinishingPermissionsClosesSheet() {
        XCTAssertNil(OnboardingFlow.step(after: .permissions, phase: .ready))
    }

    func testReloginOfFinishedAccountShowsSuccessThenCloses() {
        XCTAssertEqual(OnboardingFlow.step(after: .login, phase: .ready), .login)
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .login, phase: .ready))
        XCTAssertNil(OnboardingFlow.advance(from: .login, phase: .ready))
    }

    func testLogoutAlwaysReturnsToLogin() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .login), .login)
        XCTAssertEqual(OnboardingFlow.step(after: .permissions, phase: .login), .login)
    }

    func testReadyLaunchShowsNoSheet() {
        XCTAssertNil(OnboardingFlow.step(after: nil, phase: .ready))
    }

    func testCloseKeepsUnfinishedStep() {
        XCTAssertEqual(OnboardingFlow.close(.permissions, phase: .permissions), .permissions)
        XCTAssertEqual(OnboardingFlow.close(.login, phase: .login), .login)
        XCTAssertNil(OnboardingFlow.close(.login, phase: .ready))
    }

    func testStartLooksReadyOnlyWithBothGrantsAndNoPendingRelaunch() {
        let both = PermissionGrants(accessibility: true, screenRecording: true)
        XCTAssertTrue(OnboardingFlow.startLooksReady(both, askedScreenRecording: false))
        XCTAssertFalse(OnboardingFlow.startLooksReady(both, askedScreenRecording: true), "OUT-05: 다시 실행 전")
        XCTAssertFalse(OnboardingFlow.startLooksReady(PermissionGrants(accessibility: true, screenRecording: false), askedScreenRecording: false))
        XCTAssertFalse(OnboardingFlow.startLooksReady(PermissionGrants(accessibility: false, screenRecording: false), askedScreenRecording: false))
    }

    func testSheetSitsBelowTabsOrCentersWhenTooTall() {
        XCTAssertEqual(OnboardingFlow.sheetTop(available: 716, card: 624), 53, "OUT-01: 탭 막대 바로 아래")
        XCTAssertEqual(OnboardingFlow.sheetTop(available: 700, card: 680), 10, "안 들어가면 가운데")
        XCTAssertEqual(OnboardingFlow.sheetTop(available: 716, card: 741), 0, "창보다 높으면 맨 위에서 스크롤")
    }
}
