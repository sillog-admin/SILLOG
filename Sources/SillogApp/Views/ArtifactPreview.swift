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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = ArtifactWebState()
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        ChatDialogFrame(title: artifact.title, width: onClose == nil ? 760 : nil, height: onClose == nil ? 679 : nil,
                        compact: onClose != nil, onExpand: onExpand, expanded: expanded, onClose: onClose ?? { dismiss() }) {
            VStack(spacing: 0) {
                ArtifactWebView(state: preview)
                if let error { Text(error).font(Brand.font(.body)).foregroundStyle(Brand.ink).padding(12) }
            }
        } footer: {
            if versions.count > 1, let index = versions.firstIndex(where: { $0.id == artifact.id }) {
                // Tight groups keep the 480pt footer on one line.
                HStack(spacing: 2) {
                    versionButton("chevron.left", tr("이전 버전"), to: index - 1)
                    Text(tr("버전 \(index + 1)/\(versions.count)")).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).monospacedDigit()
                    versionButton("chevron.right", tr("다음 버전"), to: index + 1)
                }.fixedSize()
            }
            HStack(spacing: 0) {
                ChatIconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: tr("복사")) {
                    Self.copy(artifact)
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
        .onAppear { preview.webView.loadHTMLString(ChatArtifactHTML.render(artifact), baseURL: nil) }
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
