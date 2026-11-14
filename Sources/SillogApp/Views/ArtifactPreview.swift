import SwiftUI
import UniformTypeIdentifiers
import WebKit
import SillogCore

struct ArtifactPreview: View {
    let artifact: ChatArtifact
    var versions: [ChatArtifact] = []
    var onSelect: (ChatArtifact) -> Void = { _ in }
    /// Set when shown as the chat side panel instead of a sheet.
    var onClose: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    var expanded = false
    /// Saves edited text as a new version; nil hides 편집.
    var onEdit: ((String) -> Void)? = nil
    /// Takes text selected in the preview to ask about; nil shows no 질문하기.
    var onAsk: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = ArtifactWebState()
    @State private var error: String?
    @State private var copied = false
    /// The text being edited; nil while previewing.
    @State private var draft: String?

    var body: some View {
        ChatDialogFrame(title: artifact.title, width: onClose == nil ? 760 : nil, height: onClose == nil ? 679 : nil,
                        compact: onClose != nil, onExpand: onExpand, expanded: expanded, onClose: onClose ?? { dismiss() }) {
            VStack(spacing: 0) {
                if let draft {
                    // Code-like formats keep their columns in a fixed-width font.
                    TextEditor(text: Binding(get: { draft }, set: { self.draft = $0 }))
                        .font(["html", "csv", "json", "xlsx"].contains(artifact.format) ? .system(size: 12 * Brand.scale, design: .monospaced) : Brand.font(.body))
                        .foregroundStyle(Brand.text).scrollContentBackground(.hidden).padding(16)
                        .accessibilityLabel(tr("결과물 편집"))
                } else {
                    ArtifactWebView(state: preview).overlay { if onAsk != nil { askPill } }
                        .overlay { if !preview.loaded { ZStack { Color.white; ProgressView().controlSize(.small).accessibilityLabel(tr("불러오는 중…")) } } }
                }
                if let error { Text(error).font(Brand.font(.body)).foregroundStyle(Brand.ink).padding(12) }
            }
        } footer: {
            if let draft {
                Spacer(minLength: 0)
                Button(tr("취소")) { self.draft = nil }.buttonStyle(ChatDialogButtonStyle()).fixedSize()
                Button(tr("새 버전으로 저장")) { onEdit?(draft) }.buttonStyle(ChatDialogButtonStyle(primary: true)).fixedSize()
                    .disabled(draft == artifact.content || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                normalFooter
            }
        }
        .onAppear { preview.webView.loadHTMLString(ChatArtifactHTML.render(artifact), baseURL: nil) }
    }

    /// Floats under the selection; clamped so it stays inside the preview.
    private var askPill: some View {
        GeometryReader { geometry in
            if !preview.selection.isEmpty {
                ChatPillButton(title: tr("질문하기"), systemName: "text.bubble") {
                    onAsk?(preview.selection)
                    preview.clearSelection()
                }.fixedSize().shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                    .position(x: min(max(preview.selectionPoint.x, 50), geometry.size.width - 50),
                              y: min(preview.selectionPoint.y + 20, geometry.size.height - 16))
            }
        }
    }

    @ViewBuilder private var normalFooter: some View {
            if versions.count > 1, let index = versions.firstIndex(where: { $0.id == artifact.id }) {
                // Tight groups keep the 480pt footer on one line.
                HStack(spacing: 2) {
                    versionButton("chevron.left", tr("이전 버전"), to: index - 1)
                    Text(tr("버전 \(index + 1)/\(versions.count)")).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).monospacedDigit()
                    versionButton("chevron.right", tr("다음 버전"), to: index + 1)
                }.fixedSize()
            }
            HStack(spacing: 0) {
                if onEdit != nil {
                    ChatIconButton(systemName: "pencil", help: tr("편집")) { draft = artifact.content; preview.clearSelection() }
                }
                ChatIconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: tr("복사")) {
                    Self.copy(artifact)
                    AccessibilityNotification.Announcement(tr("복사됨")).post()
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                ChatIconButton(systemName: "arrow.up.forward.app", help: tr("앱에서 열기")) {
                    do { NSWorkspace.shared.open(try Self.writeTemporary(artifact)); error = nil }
                    catch { self.error = tr("열기 실패: \(error.localizedDescription)") }
                }
            }
            Spacer(minLength: 0)
            Button { save(pdf: false) } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.down.to.line").font(.system(size: 11)); Text(tr("파일로 저장")) }
            }.buttonStyle(ChatDialogButtonStyle()).fixedSize()
            Button(tr("PDF로 내보내기")) { save(pdf: true) }.buttonStyle(ChatDialogButtonStyle(primary: true)).fixedSize().disabled(!preview.loaded)
    }

    private func versionButton(_ symbol: String, _ label: String, to index: Int) -> some View {
        Button { onSelect(versions[index]) } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Brand.tabText).disabled(!versions.indices.contains(index))
            .help(label).accessibilityLabel(label)
    }

    /// Args: pdf가 true면 미리보기 전체를 PDF로 저장한다.
    /// Returns: 없음. 사용자가 선택한 경로에만 결과물을 쓴다.
    /// Raises: 없음. 렌더링·파일 저장 오류는 화면에 표시한다.
    private func save(pdf: Bool) {
        let panel = NSSavePanel()
        let ext = pdf ? "pdf" : artifact.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(artifact, ext: ext)
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
                    try Self.fileData(artifact).write(to: url, options: .atomic)
                }
                error = nil
            } catch { self.error = tr("저장 실패: \(error.localizedDescription)") }
        }
    }
}

extension ArtifactPreview {
    static func fileName(_ artifact: ChatArtifact, ext: String) -> String {
        let name = artifact.title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(separator: "-")
        return "\(name.isEmpty ? tr("결과물") : name).\(ext)"
    }

    /// Args: artifact is the shown result.
    /// Returns: the bytes a saved file holds; html is saved with scripts stripped.
    /// Raises: Office packaging errors.
    static func fileData(_ artifact: ChatArtifact) throws -> Data {
        artifact.format == "html" ? Data(ChatArtifactHTML.render(artifact).utf8) : try artifact.fileData()
    }

    /// Rich text goes along for documents, so pasting into Pages or Mail keeps headings and tables.
    static func copy(_ artifact: ChatArtifact, to board: NSPasteboard = .general) {
        ChatView.write(artifact.content, html: ["markdown", "docx"].contains(artifact.format) ? ChatArtifactHTML.render(artifact) : nil, to: board)
    }

    /// Args: artifact is the shown result.
    /// Returns: a new file in its own temp folder, named like a saved file, for the default app to open.
    /// Raises: folder, file write or Office packaging errors.
    static func writeTemporary(_ artifact: ChatArtifact) throws -> URL {
        // shortcut: left for macOS to clear from the temp dir, delete on close if the files pile up.
        // Read-only so the app opening it can't save edits into a folder macOS will purge.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(artifact, ext: artifact.fileExtension))
        try fileData(artifact).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }
}

@MainActor
private final class ArtifactWebState: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var loaded = false
    /// Text selected in the page and the point under it, in the web view's top-left coordinates.
    @Published var selection = ""
    @Published var selectionPoint = CGPoint.zero
    /// Runs in the app's own script world, which the page's disabled JavaScript doesn't stop.
    private static let selectionScript = """
        (() => {
          let timer;
          const report = () => {
            const s = document.getSelection(), text = s ? s.toString() : '';
            if (!text.trim() || !s.rangeCount) { webkit.messageHandlers.selection.postMessage({ text: '' }); return; }
            const r = s.getRangeAt(0).getBoundingClientRect();
            webkit.messageHandlers.selection.postMessage({ text, x: r.left + r.width / 2, y: r.bottom });
          };
          const later = () => { clearTimeout(timer); timer = setTimeout(report, 120); };
          document.addEventListener('selectionchange', later);
          window.addEventListener('scroll', later, true);
        })();
        """

    /// Args: 없음.
    /// Returns: 스크립트와 지속 저장을 사용하지 않는 미리보기 상태.
    /// Raises: 없음.
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let bridge = SelectionBridge()
        configuration.userContentController.addUserScript(WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(bridge, contentWorld: .defaultClient, name: "selection")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        bridge.state = self
        webView.navigationDelegate = self
    }

    func clearSelection() {
        selection = ""
        webView.evaluateJavaScript("getSelection().removeAllRanges()", in: nil, in: .defaultClient)
    }

    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any] else { return }
        selection = body["text"] as? String ?? ""
        selectionPoint = CGPoint(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0)
    }

    /// Hides the loading placeholder and enables PDF export.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// Args: navigationAction은 문서의 탐색 요청, decisionHandler는 허용 여부 콜백이다.
    /// Returns: 없음. 생성 문서가 외부 사이트·파일로 이동하는 것을 막는다.
    /// Raises: 없음.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

/// Weak so the web view's content controller doesn't keep the panel's state alive.
private final class SelectionBridge: NSObject, WKScriptMessageHandler {
    weak var state: ArtifactWebState?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { state?.receive(message.body) }
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
