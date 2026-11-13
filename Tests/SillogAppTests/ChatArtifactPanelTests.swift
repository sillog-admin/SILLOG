import AppKit
import SwiftUI
import XCTest
@testable import SillogApp
@testable import SillogCore

/// An open artifact shows beside the conversation with its version, and an id that no longer resolves shows nothing.
@MainActor
final class ChatArtifactPanelTests: XCTestCase {
    private func window(open: (ChatArtifact, ChatArtifact) -> String?) throws -> (NSWindow, NSHostingView<AnyView>, ChatState, ChatArtifact, ChatArtifact) {
        let database = try SillogDatabase.inMemory()
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        let chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        let v1 = ChatArtifact(title: "주간 보고서", format: "docx", content: "# 초안")
        var v2 = ChatArtifact(title: "주간 보고서", format: "docx", content: "# 수정본")
        v2.baseID = v1.id
        let id = chat.current.id
        var a1 = ConversationMessage(conversationID: id, role: "assistant", text: "초안입니다.")
        a1.artifacts = [v1]
        var a2 = ConversationMessage(conversationID: id, role: "assistant", text: "고쳤습니다.")
        a2.artifacts = [v2]
        chat.messages = [.init(conversationID: id, role: "user", text: "보고서 써줘"), a1,
                         .init(conversationID: id, role: "user", text: "고쳐줘"), a2]
        chat.openArtifactID = open(v1, v2)
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .chat; s.chat = chat })
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        settle(host)
        return (window, host, chat, v1, v2)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func text(open: (ChatArtifact, ChatArtifact) -> String?) throws -> String {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR reads CI screens differently")
        let (_, host, _, _, _) = try window(open: open)
        return OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
    }

    private func hasComposer(_ view: NSView) -> Bool { view is ChatTextView || view.subviews.contains { hasComposer($0) } }

    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }

    func testTheOpenVersionShowsBesideTheConversation() throws {
        let text = try text { _, v2 in v2.id }
        // OCR sometimes drops the slash once the pill is first in the footer.
        XCTAssertNotNil(text.range(of: "버전2/?2", options: .regularExpression), text)
        XCTAssertTrue(text.contains("버전1"), text)     // the first card names its own version
        XCTAssertTrue(text.contains("고쳤습니다"), text)
    }

    func testAnIDThatNoLongerResolvesShowsNoPanel() throws {
        XCTAssertNil(try text { _, _ in "gone" }.range(of: "버전2/?2", options: .regularExpression))     // cards still name their versions
    }

    func testExpandingHidesTheChatUntilThePanelCloses() throws {
        let (window, host, chat, v1, v2) = try window { _, v2 in v2.id }
        // SwiftUI buttons ignore events sent to a window that was never ordered in; keep it off every screen.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        settle(host)
        XCTAssertTrue(hasComposer(host))
        // The expand icon, left of the panel's close button.
        click(host.convert(NSPoint(x: 1118, y: host.isFlipped ? 22 : 716 - 22), to: nil), in: window)
        settle(host)
        XCTAssertFalse(hasComposer(host), "the panel takes the whole width")
        chat.openArtifactID = v1.id
        settle(host)
        XCTAssertFalse(hasComposer(host), "switching versions keeps the size")
        chat.openArtifactID = nil
        settle(host)
        chat.openArtifactID = v2.id
        settle(host)
        XCTAssertTrue(hasComposer(host), "a closed panel opens again at 480")
    }

    func testEscClosesSearchBeforeThePanel() throws {
        let (window, host, chat, _, v2) = try window { _, v2 in v2.id }
        key("k", code: 40, modifiers: .command, in: window)
        settle(host)
        key("\u{1b}", code: 53, in: window)
        settle(host)
        XCTAssertEqual(chat.openArtifactID, v2.id, "the first Esc closes search")
        key("\u{1b}", code: 53, in: window)
        settle(host)
        XCTAssertNil(chat.openArtifactID)
    }

    private func composer(in view: NSView) -> ChatTextView? {
        view as? ChatTextView ?? view.subviews.lazy.compactMap { self.composer(in: $0) }.first
    }

    private func orderedIn(_ open: (ChatArtifact, ChatArtifact) -> String?) throws -> (NSWindow, NSHostingView<AnyView>, ChatState, ChatTextView) {
        let (window, host, chat, _, _) = try window(open: open)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        settle(host)
        let input = try XCTUnwrap(composer(in: host))
        window.makeFirstResponder(input)
        return (window, host, chat, input)
    }

    func testEscInTheComposerClosesThePanel() throws {
        let (window, host, chat, _) = try orderedIn { _, v2 in v2.id }
        key("\u{1b}", code: 53, in: window)
        settle(host)
        XCTAssertNil(chat.openArtifactID)
    }

    func testUpMovesTheFocusIntoTheQuestionEditor() throws {
        let (window, host, _, input) = try orderedIn { _, _ in nil }
        key("\u{f700}", code: 126, modifiers: [.command, .numericPad, .function], in: window)
        settle(host)
        XCTAssertTrue(window.firstResponder === input, "Cmd+Up does not open the edit")
        key("\u{f700}", code: 126, modifiers: [.numericPad, .function], in: window)
        settle(host)
        XCTAssertTrue(window.firstResponder is NSTextView)
        XCTAssertFalse(window.firstResponder === input, "typing goes into the edit, not the composer")
    }

    func testCopyPutsTheTextAndRichTextOnThePasteboard() {
        let board = NSPasteboard(name: .init("sillog-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        ArtifactPreview.copy(.init(title: "t", format: "markdown", content: "## 제목"), to: board)
        XCTAssertEqual(board.string(forType: .string), "## 제목")
        XCTAssertTrue(board.string(forType: .html)?.contains("<h2>제목</h2>") == true)
        ArtifactPreview.copy(.init(title: "t", format: "csv", content: "a,b"), to: board)
        XCTAssertEqual(board.string(forType: .string), "a,b")
        XCTAssertNil(board.string(forType: .html))
    }

    func testOpeningInAnAppWritesARealFile() throws {
        let url = try ArtifactPreview.writeTemporary(.init(title: "발표/초안", format: "pptx", content: "# 하나\n- a"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "발표-초안.pptx")
        XCTAssertEqual(try Data(contentsOf: url).prefix(2), Data([0x50, 0x4B]))
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: url.path), "edits can't land in the temp folder")
    }
}
