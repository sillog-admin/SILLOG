import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SillogApp
import SillogCore

/// Leaving the graph tab hides its page instead of dropping it: a hidden page draws nothing, and coming back needs no reload.
@MainActor
final class GraphTabTests: XCTestCase {
    func testTheGraphPageIsKeptAndHiddenOnOtherTabs() throws {
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .graph }, database: try SillogDatabase.inMemory())
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        func graphPage(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView, web.url?.path.contains("/graph/") == true { return web }
            return view.subviews.lazy.compactMap(graphPage).first
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

        var page: WKWebView?
        for _ in 0..<30 where page == nil { settle(); page = graphPage(in: host) }
        let graph = try XCTUnwrap(page, "그래프 웹 화면")
        XCTAssertFalse(graph.isHidden)

        state.selectedTab = .settings
        settle()
        XCTAssertTrue(graphPage(in: host) === graph, "다른 탭에서도 같은 웹 화면이 남는다")
        XCTAssertTrue(graph.isHidden, "다른 탭에서는 숨겨 그리지 않는다")

        state.selectedTab = .graph
        settle()
        XCTAssertTrue(graphPage(in: host) === graph, "돌아와도 새로 만들지 않는다")
        XCTAssertFalse(graph.isHidden)
    }
}
