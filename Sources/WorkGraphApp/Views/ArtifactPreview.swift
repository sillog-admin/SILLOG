import SwiftUI
import UniformTypeIdentifiers
import WebKit
import WorkGraphCore

struct ArtifactPreview: View {
    let artifact: ChatArtifact
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = ArtifactWebState()
    @State private var error: String?

    var body: some View {
        ChatDialogFrame(title: artifact.title, width: 760, height: 679, onClose: { dismiss() }) {
            VStack(spacing: 0) {
                ArtifactWebView(state: preview)
                if let error { Text(error).font(Brand.suit(12)).foregroundStyle(Brand.ink).padding(12) }
            }
        } footer: {
            Text(artifact.format.uppercased()).font(Brand.suit(10)).foregroundStyle(Brand.gray)
            Spacer()
            Button { save(pdf: false) } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.down.to.line").font(.system(size: 11)); Text("파일로 저장") }
            }.buttonStyle(ChatDialogButtonStyle())
            Button("PDF로 내보내기") { save(pdf: true) }.buttonStyle(ChatDialogButtonStyle(primary: true)).disabled(!preview.loaded)
        }
        .onAppear { preview.webView.loadHTMLString(ChatArtifactHTML.render(artifact), baseURL: nil) }
    }

    /// Args: pdf가 true면 미리보기 전체를 PDF로 저장한다.
    /// Returns: 없음. 사용자가 선택한 경로에만 결과물을 쓴다.
    /// Raises: 없음. 렌더링·파일 저장 오류는 화면에 표시한다.
    private func save(pdf: Bool) {
        let panel = NSSavePanel()
        let ext = pdf ? "pdf" : artifact.format == "markdown" ? "md" : artifact.format
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        let name = artifact.title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: "-")
        panel.nameFieldStringValue = "\(name.isEmpty ? "결과물" : name).\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                if pdf {
                    let height = try await preview.webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") as? Double ?? 1000
                    let configuration = WKPDFConfiguration()
                    configuration.rect = CGRect(x: 0, y: 0, width: preview.webView.bounds.width, height: height)
                    let data = try await preview.webView.pdf(configuration: configuration)
                    try data.write(to: url, options: .atomic)
                } else {
                    let text = artifact.format == "html" ? ChatArtifactHTML.render(artifact) : artifact.content
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
                error = nil
            } catch { self.error = "저장 실패: \(error.localizedDescription)" }
        }
    }
}

@MainActor
private final class ArtifactWebState: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var loaded = false

    /// Args: 없음.
    /// Returns: 스크립트와 지속 저장을 사용하지 않는 미리보기 상태.
    /// Raises: 없음.
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    /// Args: webView·navigation은 완료된 미리보기 탐색이다.
    /// Returns: 없음. PDF 저장을 활성화한다.
    /// Raises: 없음.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// Args: navigationAction은 문서의 탐색 요청, decisionHandler는 허용 여부 콜백이다.
    /// Returns: 없음. 생성 문서가 외부 사이트·파일로 이동하는 것을 막는다.
    /// Raises: 없음.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

private struct ArtifactWebView: NSViewRepresentable {
    @ObservedObject var state: ArtifactWebState
    /// Args: context는 SwiftUI 브리지 상태이다.
    /// Returns: 미리보기용 WKWebView.
    /// Raises: 없음.
    func makeNSView(context: Context) -> WKWebView { state.webView }
    /// Args: nsView·context는 기존 미리보기 브리지이다.
    /// Returns: 없음. 내용은 상위 화면에서 한 번 로드한다.
    /// Raises: 없음.
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
