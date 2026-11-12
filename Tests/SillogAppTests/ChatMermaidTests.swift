import XCTest
import WebKit
@testable import SillogApp

/// The bundled mermaid page draws a valid diagram and reports a parse error for a broken one.
@MainActor
final class ChatMermaidTests: XCTestCase {
    private final class Probe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let code: String
        let done: XCTestExpectation
        var body: [String: Any] = [:]
        init(code: String, done: XCTestExpectation) { self.code = code; self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.callAsyncJavaScript("await renderDiagram(code)", arguments: ["code": code], in: nil, in: .page) { _ in }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            body = message.body as? [String: Any] ?? [:]; done.fulfill()
        }
    }

    private func render(_ code: String) throws -> [String: Any] {
        let directory = try XCTUnwrap(ChatMermaidView.directory())
        let probe = Probe(code: code, done: expectation(description: "rendered"))
        let config = WKWebViewConfiguration()
        config.userContentController.add(probe, name: "sillog")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: config)
        webView.navigationDelegate = probe
        webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        wait(for: [probe.done], timeout: 20)
        config.userContentController.removeScriptMessageHandler(forName: "sillog")
        return probe.body
    }

    func testValidDiagramReportsItsHeight() throws {
        let body = try render("flowchart LR\n  A[기록] --> B[업무] --> C[채팅]")
        XCTAssertGreaterThan(body["height"] as? Double ?? 0, 40, "\(body)")
    }

    func testBrokenDiagramReportsAnError() throws {
        XCTAssertNotNil(try render("flowchart LR\n  A -->")["error"])
    }
}
