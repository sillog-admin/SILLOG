import CoreGraphics
import XCTest
@testable import WorkGraphCollectors

/// 기기 제어 없이 화면 기록만 있을 때 찍을 창과 찍지 않을 창
final class ScreenRecordingOnlyTests: XCTestCase {
    private func window(pid: Int32, number: UInt32, layer: Int = 0, alpha: Double = 1,
                        size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowNumber as String: NSNumber(value: number),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation as NSDictionary as! [String: Any]]
    }

    func testTheFrontWindowIsTheFirstNormalWindowOfTheApp() {
        let infos = [
            window(pid: 9, number: 1),                                        // 다른 앱
            window(pid: 7, number: 2, layer: 25),                             // 메뉴·떠 있는 패널
            window(pid: 7, number: 3, size: CGSize(width: 40, height: 40)),  // 아주 작은 창
            window(pid: 7, number: 4, alpha: 0),                              // 투명한 창
            window(pid: 7, number: 5),
            window(pid: 7, number: 6),
        ]
        XCTAssertEqual(ScreenCapturer.frontWindowID(in: infos, pid: 7), 5)
        XCTAssertNil(ScreenCapturer.frontWindowID(in: infos, pid: 8))
    }

    func testBrowsersAreNotCapturedWithoutAWindowTitle() {
        let privacy = PrivacyFilter()
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.Chrome", windowTitle: nil))      // 기기 제어 없음: 시크릿 창인지 모른다
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.Chrome.beta", windowTitle: nil))
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.Chrome.dev", windowTitle: nil))
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.chrome.for.testing", windowTitle: nil))
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.Chrome", windowTitle: ""))
        XCTAssertFalse(privacy.mayCapture(bundle: "com.google.Chrome", windowTitle: "Example Domain - Chrome (시크릿 모드)"))
        XCTAssertTrue(privacy.mayCapture(bundle: "com.google.Chrome", windowTitle: "Example Domain - Chrome"))
        XCTAssertTrue(privacy.mayCapture(bundle: "com.apple.TextEdit", windowTitle: nil))     // 브라우저가 아니면 맨 앞 창을 찍는다
        XCTAssertFalse(privacy.mayCapture(bundle: "com.apple.keychainaccess", windowTitle: nil))
    }

    func testAWindowSwitchChangesTheScreenOnlyContext() {
        let before = ContextSnapshot(appBundle: "com.apple.TextEdit", appName: "TextEdit", windowTitle: nil,
                                     url: nil, docPath: nil, pid: 7, screenWindowID: 5)
        var after = before
        after.screenWindowID = 6
        XCTAssertFalse(after.sameContext(as: before))
    }

    func testSystemAuthenticationWindowsAreExcludedEvenWithAnOldSavedList() {
        let saved = PrivacyFilter(excludedBundles: ["com.apple.keychainaccess"])
        XCTAssertTrue(saved.isExcluded(bundle: "com.apple.LocalAuthentication.UIAgent"))      // Touch ID 확인 창
        XCTAssertTrue(saved.isExcluded(bundle: "com.apple.SecurityAgent"))                    // 암호 확인 창
        XCTAssertFalse(saved.mayCapture(bundle: "com.apple.SecurityAgent", windowTitle: "암호 확인"))
    }
}
