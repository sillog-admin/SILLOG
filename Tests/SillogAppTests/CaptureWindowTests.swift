import CoreGraphics
import XCTest
@testable import SillogCollectors

/// 스크린샷 찍을 창 고르기. Chrome 은 접근성 제목에 " - Chrome - 프로필" 을 붙여서(화면 캡처 쪽 제목에는 없다) 예전에는 Chrome 탭을 한 번도 못 찍었다
final class CaptureWindowTests: XCTestCase {
    private let full = CGRect(x: 0, y: 47, width: 1366, height: 873)

    private func window(_ title: String?, pid: pid_t = 7, frame: CGRect? = nil) -> ScreenCapturer.WindowInfo {
        .init(pid: pid, title: title, frame: frame ?? full)
    }

    func testChromeTabsMatchThoughTheAccessibilityTitleCarriesTheProfile() {
        let windows = [window("자료구조 기초 및 활용 (26F)")]
        XCTAssertEqual(ScreenCapturer.pick(windows, pid: 7, title: "자료구조 기초 및 활용 (26F) - Chrome - Me (personal)", frame: full, allowChromeSuffix: true), 0)
        XCTAssertNil(ScreenCapturer.pick(windows, pid: 7, title: "자료구조 기초 및 활용 (26F) - Chrome - Me (personal)", frame: full))
    }

    func testSameTitleStillMatches() {
        XCTAssertEqual(ScreenCapturer.pick([window("TaskCard.tsx — dashboard")], pid: 7, title: "TaskCard.tsx — dashboard", frame: full), 0)
    }

    /// 최대화한 창 두 개는 위치·크기가 같다. 제목으로 하나를 고르고, 더 길게 맞는 제목을 고른다
    func testPicksTheWindowWhoseTitleMatchesMost() {
        let windows = [window("Goorm"), window("Goorm - Login"), window("새 탭")]
        XCTAssertEqual(ScreenCapturer.pick(windows, pid: 7, title: "Goorm - Login - Chrome - Me (personal)", frame: full, allowChromeSuffix: true), 1)
    }

    func testDoesNotGuessWhenNoWindowOrSeveralFit() {
        XCTAssertNil(ScreenCapturer.pick([window("다른 페이지")], pid: 7, title: "자료구조 - Chrome - Me", frame: full, allowChromeSuffix: true), "제목이 다르면")
        XCTAssertNil(ScreenCapturer.pick([window("자료구조", pid: 8)], pid: 7, title: "자료구조 - Chrome - Me", frame: full, allowChromeSuffix: true), "다른 프로그램")
        XCTAssertNil(ScreenCapturer.pick([window("자료구조", frame: CGRect(x: 0, y: 0, width: 400, height: 300))], pid: 7, title: "자료구조 - Chrome - Me", frame: full, allowChromeSuffix: true), "다른 크기")
        XCTAssertNil(ScreenCapturer.pick([window("자료구조"), window("자료구조")], pid: 7, title: "자료구조 - Chrome - Me", frame: full, allowChromeSuffix: true), "같은 창이 둘")
        XCTAssertNil(ScreenCapturer.pick([window(""), window(nil)], pid: 7, title: "자료구조 - Chrome - Me", frame: full, allowChromeSuffix: true), "제목 없는 창은 앞부분 맞추기에 쓰지 않는다")
    }
}
