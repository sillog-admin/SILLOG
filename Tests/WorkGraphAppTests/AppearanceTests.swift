import AppKit
import XCTest
@testable import WorkGraphApp

@MainActor
final class AppearanceTests: XCTestCase {
    override func tearDown() {
        NSApp.appearance = nil
        super.tearDown()
    }

    func testAppDrawsInLightAppearanceEvenInDarkMode() {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)                       // 시스템이 다크 모드일 때
        AppDelegate().applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        XCTAssertEqual(NSApp.appearance?.name, .aqua, "디자인이 밝은 화면 전용이라, 다크 모드여도 유리 재질과 그래프를 밝게 그려야 한다")
    }
}
