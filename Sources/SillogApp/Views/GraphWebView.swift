import AppKit
import SwiftUI
import WebKit
import SillogCore

/// 옵시디언식 그래프 뷰. 화면은 번들된 HTML/JS(force-graph)이고, Swift 는 데이터만 넣어준다.
struct GraphWebView: NSViewRepresentable {
    @EnvironmentObject private var state: AppState
    let version: Int

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "wg")
        WebL10n.install(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")              // 로딩 중 흰 화면 방지
        context.coordinator.webView = webView
        if let directory = Self.graphDirectory() {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory.deletingLastPathComponent())   // ../Brand/Fonts 의 SUIT 글꼴도 읽게
        } else {
            webView.loadHTMLString(tr("<body style='background:#1e1e1e;color:#ddd;font:14px -apple-system;padding:40px'>그래프 화면 리소스를 찾지 못했습니다.</body>"), baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.pushedVersion != version { context.coordinator.push(version: version) }
        // 드로어를 X 로 닫으면 지금 보기에서 기억한 업무도 지운다(보기를 바꿨다 돌아와도 다시 열리지 않게)
        let open = state.taskDetailOpen
        if context.coordinator.drawerOpen && !open { webView.evaluateJavaScript("window.WG && window.WG.detailClosed && window.WG.detailClosed()", completionHandler: nil) }
        context.coordinator.drawerOpen = open
        // 업무 목록에서 고른 업무를 그래프에도 알림(네 보기가 같은 업무를 고른 채로 반응)
        let sel = state.selectedTaskId
        if open, let sel, context.coordinator.sentSel != sel, let key = state.taskList.first(where: { $0.id == sel })?.key {
            context.coordinator.sentSel = sel
            webView.callAsyncJavaScript("window.WG && window.WG.select && window.WG.select(key)", arguments: ["key": key], in: nil, in: .page, completionHandler: nil)
        }
        if !open { context.coordinator.sentSel = nil }
    }

    /// 그래프가 보낸 노드 (label 과 key 가 다 있어야 한다)
    static func nodeRef(_ body: [String: Any]) -> NodeRef? {
        guard let label = body["label"] as? String, let key = body["key"] as? String, !label.isEmpty, !key.isEmpty else { return nil }
        return NodeRef(label: label, key: key)
    }

    /// .app 번들이면 Contents/Resources/graph, `swift run` 이면 SwiftPM 리소스 번들.
    static func graphDirectory() -> URL? {
        BundledResources.url(forResource: "graph", withExtension: nil, subdirectory: nil, main: .main) { .module }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let state: AppState
        weak var webView: WKWebView?
        var pushedVersion = -1
        var drawerOpen = false
        var sentSel: Int64?
        private var ready = false

        init(state: AppState) { self.state = state }

        func push(version: Int) {
            guard ready, let webView else { return }
            pushedVersion = version
            let json = MainActor.assumeIsolated { state.graphJSON() }
            webView.callAsyncJavaScript("window.WG.setGraph(JSON.parse(data))", arguments: ["data": json], in: nil, in: .page, completionHandler: nil)
        }

        /// 우클릭 메뉴: 마우스 자리에 [상세 보기] [지우기…]. 업무 종류 같은 클래스는 지우기를 끈다
        @MainActor func showMenu(_ ref: NodeRef) {
            guard let webView, let window = webView.window else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            let detail = NSMenuItem(title: tr("상세 보기"), action: #selector(menuDetail(_:)), keyEquivalent: "")
            let erase = NSMenuItem(title: tr("지우기…"), action: #selector(menuErase(_:)), keyEquivalent: "")
            for item in [detail, erase] { item.target = self; item.representedObject = [ref.label, ref.key] }
            erase.isEnabled = NodeEraser.canErase(label: ref.label) && !state.erasing
            menu.items = [detail, .separator(), erase]
            menu.popUp(positioning: nil, at: webView.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: webView)
        }

        @objc private func menuDetail(_ item: NSMenuItem) {
            guard let parts = item.representedObject as? [String], parts.count == 2 else { return }
            MainActor.assumeIsolated { state.openNodeDetail(NodeRef(label: parts[0], key: parts[1])) }
        }

        @objc private func menuErase(_ item: NSMenuItem) {
            guard let parts = item.representedObject as? [String], parts.count == 2 else { return }
            MainActor.assumeIsolated { state.askErase(NodeRef(label: parts[0], key: parts[1])) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                push(version: MainActor.assumeIsolated { state.graphVersion })
            case "log":
                if let message = body["message"] as? String { AppLog.write(message) }
            case "resume":
                guard let label = body["label"] as? String, let key = body["key"] as? String else { return }
                Task { @MainActor in self.state.prepareResume(label: label, key: key) }
            case "runBatch":
                Task { @MainActor in await self.state.runBatch(force: true) }
            case "open":                                                    // 카드에서 자료 누르기: 자료 키(file:·웹 주소·arxiv:·doi:·local:·recording:)
                guard let uri = body["uri"] as? String else { return }
                Task { @MainActor in self.state.openGraphItem(uri: uri) }
            case "openApp":                                                 // 카드에서 앱 누르기: 번들 id
                guard let bundle = body["bundle"] as? String else { return }
                Task { @MainActor in self.state.openApp(bundle: bundle) }
            case "ask":                                                   // 그래프 검색창에서 Enter: 그 글로 채팅을 시작
                guard let q = body["q"] as? String else { return }
                Task { @MainActor in self.state.askInChat(q) }
            case "closeTask":                                              // 보기를 바꿨는데 그 보기에서 연 업무가 없으면 드로어를 닫는다
                Task { @MainActor in self.state.taskDetailOpen = false }
            case "task":                                                    // 그래프에서 업무 누르기: 업무 드로어를 그 업무로 연다 (업무 상세는 드로어 하나)
                guard let key = body["key"] as? String else { return }
                Task { @MainActor in self.state.openTaskDetail(key: key) }
            case "node":                                                    // 업무가 아닌 노드 누르기: 드로어에 그 노드 상세
                guard let ref = GraphWebView.nodeRef(body) else { return }
                Task { @MainActor in self.state.openNodeDetail(ref) }
            case "nodeMenu":                                                // 노드 우클릭: [상세 보기] [지우기…]
                guard let ref = GraphWebView.nodeRef(body) else { return }
                Task { @MainActor in self.showMenu(ref) }
            default:
                break
            }
        }
    }
}
