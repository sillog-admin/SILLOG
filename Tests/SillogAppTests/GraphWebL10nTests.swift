import AppKit
import WebKit
import XCTest
@testable import SillogApp
import SillogCore

/// The graph page in English: it loads, and text built in Korean by its scripts comes out fully translated.
@MainActor
final class GraphWebL10nTests: XCTestCase {
    private final class Ready: NSObject, WKScriptMessageHandler {
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if (message.body as? [String: Any])?["type"] as? String == "ready" { done.fulfill() }
        }
    }

    /// The page's own inline script text once went through the translation patterns and never finished loading.
    func testEnglishGraphLoadsAndTranslatesBuiltText() throws {
        L10n.current = .en
        defer { L10n.current = .ko }
        let config = WKWebViewConfiguration()
        let ready = Ready(expectation(description: "ready"))
        config.userContentController.add(ready, name: "wg")
        WebL10n.install(on: config.userContentController)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        let dir = try XCTUnwrap(GraphWebView.graphDirectory())
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir.deletingLastPathComponent())
        wait(for: [ready.done], timeout: 15)

        let translated = expectation(description: "translated")
        var texts: [String] = []
        web.callAsyncJavaScript("return [slT('업무 3개, 2시간 40분'), slT('업무 2'), slT('학업')]", arguments: [:], in: nil, in: .page) { result in
            texts = (try? result.get()) as? [String] ?? []
            translated.fulfill()
        }
        wait(for: [translated], timeout: 10)
        XCTAssertEqual(texts, ["3 tasks, 2 h 40 min", "Tasks 2", "Studies"])
    }
}
