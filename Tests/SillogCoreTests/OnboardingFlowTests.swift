import XCTest
@testable import SillogCore

final class OnboardingFlowTests: XCTestCase {
    func testFirstLaunchAsksLanguageBeforeLogin() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .login, askLanguage: true), .language)
        XCTAssertEqual(OnboardingFlow.step(after: .language, phase: .login, askLanguage: true), .language, "a status refresh keeps the language step up")
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .language, phase: .login))
        XCTAssertEqual(OnboardingFlow.advance(from: .language, phase: .login), .login)
    }

    func testLanguageIsNotAskedAgain() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .login, askLanguage: false), .login, "finished account that logged out, or a quit before login")
        XCTAssertEqual(OnboardingFlow.step(after: .permissions, phase: .login, askLanguage: true), .login, "logout during onboarding")
    }

    func testTokenOnFirstLaunchStillAsksLanguage() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .permissions, askLanguage: true), .language, "leftover login from an earlier install")
        XCTAssertEqual(OnboardingFlow.step(after: .language, phase: .permissions, askLanguage: true), .language)
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .language, phase: .permissions))
        XCTAssertEqual(OnboardingFlow.advance(from: .language, phase: .permissions), .permissions)
    }

    func testFirstLoginStaysOnStepOneUntilNext() {
        XCTAssertEqual(OnboardingFlow.step(after: .login, phase: .permissions, askLanguage: true), .login)
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .login, phase: .permissions))
        XCTAssertEqual(OnboardingFlow.advance(from: .login, phase: .permissions), .permissions)
    }

    func testNextIsDisabledBeforeLogin() {
        XCTAssertFalse(OnboardingFlow.canAdvance(from: .login, phase: .login))
        XCTAssertEqual(OnboardingFlow.advance(from: .login, phase: .login), .login)
    }

    func testRelaunchDuringPermissionsReopensStepTwo() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .permissions, askLanguage: false), .permissions, "language already chosen, e.g. after Screen Recording's Quit & Reopen")
    }

    func testPermissionsLeadToPrivacyWhichStaysUntilStart() {
        XCTAssertEqual(OnboardingFlow.advance(from: .permissions, phase: .permissions), .privacy)
        XCTAssertEqual(OnboardingFlow.step(after: .privacy, phase: .permissions, askLanguage: false), .privacy, "a status refresh keeps the choice up")
        XCTAssertEqual(OnboardingFlow.step(after: .privacy, phase: .login, askLanguage: false), .login)
        XCTAssertNil(OnboardingFlow.step(after: .privacy, phase: .ready, askLanguage: false))
    }

    func testFinishingPermissionsClosesSheet() {
        XCTAssertNil(OnboardingFlow.step(after: .permissions, phase: .ready, askLanguage: false))
    }

    func testReloginOfFinishedAccountShowsSuccessThenCloses() {
        XCTAssertEqual(OnboardingFlow.step(after: .login, phase: .ready, askLanguage: false), .login)
        XCTAssertTrue(OnboardingFlow.canAdvance(from: .login, phase: .ready))
        XCTAssertNil(OnboardingFlow.advance(from: .login, phase: .ready))
    }

    func testLogoutAlwaysReturnsToLogin() {
        XCTAssertEqual(OnboardingFlow.step(after: nil, phase: .login, askLanguage: false), .login)
        XCTAssertEqual(OnboardingFlow.step(after: .permissions, phase: .login, askLanguage: false), .login)
    }

    func testReadyLaunchShowsNoSheet() {
        XCTAssertNil(OnboardingFlow.step(after: nil, phase: .ready, askLanguage: false))
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
