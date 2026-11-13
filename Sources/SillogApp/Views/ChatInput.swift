import AppKit
import SillogCore
import SwiftUI

/// 커서 바로 앞에서 시작한 커넥터 또는 스킬 토큰.
struct ChatShortcut: Equatable {
    enum Kind { case connector, skill }
    let kind: Kind
    let query: String
    let range: NSRange

    static func at(_ caret: NSRange, in text: String) -> Self? {
        let source = text as NSString
        guard caret.length == 0, caret.location <= source.length else { return nil }
        let prefix = source.substring(to: caret.location)
        guard let start = prefix.lastIndex(where: { $0.isWhitespace }) else { return token(prefix, start: 0) }
        let word = String(prefix[prefix.index(after: start)...])
        return token(word, start: caret.location - word.utf16.count)
    }

    private static func token(_ word: String, start: Int) -> Self? {
        guard let first = word.first, first == "@" || first == "/" else { return nil }
        let query = String(word.dropFirst())
        guard !query.contains("@"), !query.contains("/") else { return nil }
        return .init(kind: first == "@" ? .connector : .skill, query: query, range: NSRange(location: start, length: word.utf16.count))
    }
}

/// 한글 조합 중 Enter는 조합을 확정하고, 일반 Enter는 전송한다.
struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var minimumHeight: CGFloat = 56
    /// 바뀌면 입력칸으로 커서를 옮긴다 (범위를 고른 직후 바로 쓰게)
    var focusRequest = 0
    var selectionOnFocus: NSRange?
    var onShortcut: (ChatShortcut?) -> Void = { _ in }
    var shortcutKey: (UInt16) -> Bool = { _ in false }
    var onFiles: ([URL]) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onEditLast: (() -> Void)? = nil
    var onSend: () -> Void

    /// Args: context는 SwiftUI 연결 상태이다.
    /// Returns: 여러 줄 입력과 스크롤을 지원하는 입력창.
    /// Raises: 없음.
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = ChatTextView()
        editor.isRichText = false; editor.allowsUndo = true
        editor.font = NSFont(name: "SUIT-Regular", size: 12) ?? .systemFont(ofSize: 12)
        let ink = NSColor(srgbRed: 20 / 255, green: 18 / 255, blue: 16 / 255, alpha: 1)
        editor.textColor = ink; editor.insertionPointColor = ink
        editor.drawsBackground = false; editor.textContainerInset = NSSize(width: 0, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator; editor.onSend = onSend
        editor.shortcutKey = shortcutKey; editor.onFiles = onFiles; editor.onEscape = onEscape; editor.onEditLast = onEditLast
        editor.setAccessibilityLabel(tr("메시지 입력"))
        scroll.documentView = editor; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        return scroll
    }

    /// Args: view는 입력창, context는 연결 상태이다.
    /// Returns: 없음. 외부에서 변경된 초안을 반영한다.
    /// Raises: 없음.
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? ChatTextView else { return }
        context.coordinator.parent = self; editor.onSend = onSend
        editor.shortcutKey = shortcutKey; editor.onFiles = onFiles; editor.onEscape = onEscape; editor.onEditLast = onEditLast
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        context.coordinator.resize(editor)
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            if let selectionOnFocus, NSMaxRange(selectionOnFocus) <= (editor.string as NSString).length {
                editor.setSelectedRange(selectionOnFocus)
            }
            DispatchQueue.main.async { editor.window?.makeFirstResponder(editor) }
        }
    }

    /// Args: 없음.
    /// Returns: 텍스트 변경을 SwiftUI에 전달하는 연결 객체.
    /// Raises: 없음.
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        /// 처리한 커서 요청. 0 에서 시작해, 업무 드로어에서 범위를 골라 채팅 탭이 새로 그려질 때도 커서가 입력칸으로 간다
        var focusRequest = 0
        /// Args: parent는 입력 바인딩이다.
        /// Returns: 입력 상태 연결 객체.
        /// Raises: 없음.
        init(_ parent: ChatInput) { self.parent = parent }

        /// Args: notification은 편집 완료 알림이다.
        /// Returns: 없음. 초안과 높이를 갱신한다.
        /// Raises: 없음.
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; resize(editor)
            publishShortcut(editor)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { publishShortcut(editor) }
        }

        private func publishShortcut(_ editor: NSTextView) {
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, !editor.hasMarkedText() else { return }
                parent.onShortcut(ChatShortcut.at(editor.selectedRange(), in: editor.string))
            }
        }

        /// Args: editor는 현재 입력창이다.
        /// Returns: 없음. 지정한 최소 높이부터 160pt까지 내용에 맞춰 높이를 바꾼다.
        /// Raises: 없음.
        func resize(_ editor: NSTextView) {
            guard let container = editor.textContainer, let layout = editor.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = min(160, max(parent.minimumHeight, ceil(layout.usedRect(for: container).height) + 16))
            if parent.height != height { DispatchQueue.main.async { self.parent.height = height } }
        }
    }
}

final class ChatTextView: NSTextView {
    var onSend: (() -> Void)?
    var shortcutKey: ((UInt16) -> Bool)?
    var onFiles: (([URL]) -> Void)?
    var onEscape: (() -> Void)?
    var onEditLast: (() -> Void)?

    /// Args: pasteboard is a paste or drop.
    /// Returns: copied or dropped files, or a pasted image saved as a temporary PNG. Nil for plain text.
    /// Raises: 없음.
    static func files(on pasteboard: NSPasteboard) -> [URL]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return urls }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = LibraryState.pasteFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("\(tr("붙여넣은 이미지")) \(formatter.string(from: Date())).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            return [url]
        } catch { AppLog.write("paste image failed: \(error.localizedDescription)"); return nil }
    }

    override func paste(_ sender: Any?) {
        if let onFiles, let urls = Self.files(on: .general) { onFiles(urls) } else { super.paste(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFiles, let urls = Self.files(on: sender.draggingPasteboard) { onFiles(urls); return true }
        return super.performDragOperation(sender)
    }
    /// Args: event는 키보드 입력이다.
    /// Returns: 없음. Enter 전송, Shift+Enter 줄바꿈, 조합 중 Enter 확정을 처리한다.
    /// Raises: 없음.
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), !event.modifierFlags.contains(.shift), shortcutKey?(event.keyCode) == true { return }
        if event.keyCode == 126, string.isEmpty, !hasMarkedText(), let onEditLast { onEditLast(); return }
        // Esc would otherwise open NSTextView's word completion list.
        if event.keyCode == 53, !hasMarkedText() { onEscape?(); return }
        if [36, 76].contains(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewline(nil) }
            else { onSend?() }
            return
        }
        super.keyDown(with: event)
    }
}
