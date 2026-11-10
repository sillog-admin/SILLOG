import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 캘린더(달력 탭, 메뉴 막대 캘린더 줄, 일정 제안)는 꺼 둔다 (11/06 사용자 요청). 코드는 남기고 숨은 설정 하나로 다시 켤 수 있다
@MainActor
final class CalendarHiddenTests: XCTestCase {
    func testCalendarIsOffUnlessTurnedOn() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "calendar-flag-\(UUID().uuidString)"))
        XCTAssertFalse(AppFeatures.calendar(defaults))
        defaults.set(true, forKey: AppFeatures.calendarKey)
        XCTAssertTrue(AppFeatures.calendar(defaults))
    }

    func testTheRailHidesTheCalendarTab() {
        XCTAssertEqual(MainWindow.Tab.visible(calendar: false).map(\.rawValue), ["그래프", "채팅", "정리", "커넥터", "설정"])
        XCTAssertEqual(MainWindow.Tab.visible(calendar: true).map(\.rawValue), ["그래프", "채팅", "정리", "커넥터", "설정", "캘린더"])
    }

    func testTheMenuBarPanelHasNoCalendarRow() {
        let state = AppState(preview: { s in s.phase = .ready })
        let host = NSHostingView(rootView: AnyView(MenuBarView().environmentObject(state)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        XCTAssertTrue(text.contains("일시정지"), text)
        XCTAssertFalse(text.contains("캘린더"), "메뉴 막대에 캘린더 줄이 없다: \(text)")
    }

    func testBatchesDoNotLookForEvents() {
        XCTAssertFalse(AppState.batchConfig(themes: false, pipeline: nil, calendar: false).findEvents)
        XCTAssertTrue(AppState.batchConfig(themes: false, pipeline: nil, calendar: true).findEvents)
    }
}
