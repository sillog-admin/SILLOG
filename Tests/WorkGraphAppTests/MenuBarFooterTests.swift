import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 정상 메뉴 맨 아래 줄: [일시정지] [앱 열기] [종료]
@MainActor
final class MenuBarFooterTests: XCTestCase {
    func testTheNormalMenuFooterHasPauseOpenAppAndQuit() {
        let state = AppState(preview: { s in s.phase = .ready })
        let host = NSHostingView(rootView: AnyView(MenuBarView().environmentObject(state)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        for expected in ["일시정지", "앱열기", "종료"] {
            XCTAssertTrue(text.contains(expected), "\(expected) 가 보여야 한다: \(text)")
        }
    }
}
