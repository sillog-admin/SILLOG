import AppKit
import SwiftUI
import XCTest
@testable import SillogApp
@testable import SillogCore

@MainActor
final class UpdateButtonTests: XCTestCase {
    /// SwiftUI builds no accessibility tree offscreen, so the installing spinner (an NSProgressIndicator) stands in for the button.
    private func spinners(_ configure: @escaping (AppState) -> Void) -> Int {
        let state = AppState(preview: { s in s.phase = .ready; s.updating = true; configure(s) })
        let host = NSHostingView(rootView: AnyView(NavRail().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: NavRail.width, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        func count(_ view: NSView) -> Int { (view is NSProgressIndicator ? 1 : 0) + view.subviews.map(count).reduce(0, +) }
        return count(host)
    }

    func testTheRailShowsTheUpdateButtonOnlyWhenAReleaseIsOut() {
        XCTAssertEqual(spinners { $0.availableUpdate = .init(build: 77, url: URL(string: "https://example.com/SILLOG.dmg")!) }, 1)
        XCTAssertEqual(spinners { $0.availableUpdate = nil }, 0)
    }
}
