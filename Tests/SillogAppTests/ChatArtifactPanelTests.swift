import AppKit
import SwiftUI
import XCTest
@testable import SillogApp
@testable import SillogCore

/// An open artifact shows beside the conversation with its version, and an id that no longer resolves shows nothing.
@MainActor
final class ChatArtifactPanelTests: XCTestCase {
    private func text(open: (ChatArtifact, ChatArtifact) -> String?) throws -> String {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "OCR reads CI screens differently")
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
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
    }

    func testTheOpenVersionShowsBesideTheConversation() throws {
        let text = try text { _, v2 in v2.id }
        XCTAssertTrue(text.contains("버전2/2"), text)
        XCTAssertTrue(text.contains("고쳤습니다"), text)
    }

    func testAnIDThatNoLongerResolvesShowsNoPanel() throws {
        XCTAssertFalse(try text { _, _ in "gone" }.contains("버전"))
    }
}
