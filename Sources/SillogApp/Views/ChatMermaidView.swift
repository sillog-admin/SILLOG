import SwiftUI
import WebKit
import SillogCore

/// Draws one ```mermaid block of a chat answer in a local web view. Reports the drawn height, or failure so the caller shows the source.
struct ChatMermaidView: NSViewRepresentable {
    let code: String
    @Binding var height: CGFloat
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sillog")
        let webView = PassThroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        if let directory = Self.directory() {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        } else {
            DispatchQueue.main.async { failed = true }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) { context.coordinator.parent = self }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sillog")
    }

    /// .app 번들이면 Contents/Resources/mermaid, `swift run` 이면 SwiftPM 리소스 번들
    static func directory() -> URL? {
        BundledResources.url(forResource: "mermaid", withExtension: nil, subdirectory: nil, main: .main) { .module }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ChatMermaidView
        init(_ parent: ChatMermaidView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.callAsyncJavaScript("await renderDiagram(code)", arguments: ["code": parent.code], in: nil, in: .page) { _ in }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double { parent.height = max(40, height) }
            if let error = body["error"] as? String {
                AppLog.write("mermaid render failed: \(error.prefix(200))")
                parent.failed = true
            }
        }
    }
}

/// The diagram never scrolls itself; wheel events go to the chat scroll view behind it.
private final class PassThroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
