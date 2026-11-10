import XCTest
@testable import WorkGraphCore

final class AppPhaseTests: XCTestCase {
    func testLoginIsRequiredBeforeAnythingElse() {
        XCTAssertEqual(AppPhase.decide(loggedIn: false, onboardingCompleted: false), .login)
        // 예전에 온보딩을 끝냈더라도 로그아웃 상태면 다시 로그인부터
        XCTAssertEqual(AppPhase.decide(loggedIn: false, onboardingCompleted: true), .login)
    }

    func testPermissionsStepIsShownOnceAfterFirstLogin() {
        XCTAssertEqual(AppPhase.decide(loggedIn: true, onboardingCompleted: false), .permissions)
        XCTAssertEqual(AppPhase.decide(loggedIn: true, onboardingCompleted: true), .ready)
    }

    func testOnlyReadyPhaseRunsServices() {
        XCTAssertFalse(AppPhase.login.runsServices)
        XCTAssertFalse(AppPhase.permissions.runsServices)
        XCTAssertTrue(AppPhase.ready.runsServices)
    }
}
