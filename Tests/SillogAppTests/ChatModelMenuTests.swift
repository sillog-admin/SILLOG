import AppKit
import SwiftUI
import XCTest
@testable import SillogApp
import SillogCore

/// 채팅 화면의 모델 칩: 설정 탭으로 가지 않고 그 자리에서 채팅 모델을 바꾼다
@MainActor
final class ChatModelMenuTests: XCTestCase {
    private let models = [CodexModel(slug: "gpt-a", displayName: "GPT A", defaultEffort: nil),
                          CodexModel(slug: "gpt-b", displayName: "GPT B", defaultEffort: nil)]

    func testPickingAModelInChatChangesOnlyTheChatModel() {
        let state = AppState(preview: { s in
            s.settings.chatProvider = "codex"; s.settings.chatCodexModel = "gpt-a"; s.settings.codexModel = "gpt-batch"
            s.chatCodexModels = self.models
        })
        state.selectChatModel("gpt-b")
        XCTAssertEqual(state.settings.chatCodexModel, "gpt-b")
        XCTAssertEqual(state.settings.chatModelName, "gpt-b", "칩에 보이는 이름도 바뀌어야 한다")
        XCTAssertEqual(state.settings.codexModel, "gpt-batch", "업무 정리 모델은 그대로 (채팅 모델과 따로 저장)")
    }

    func testChatConnectedOnlyFailsWhenSendingCannotWork() {
        let state = AppState(preview: { s in s.settings.chatSameAsOrganize = false; s.settings.chatProvider = "codex" })
        XCTAssertFalse(state.chatConnected, "logged out")
        state.codexStatus = .loggedIn(email: nil, plan: nil, expiresAt: nil)
        XCTAssertTrue(state.chatConnected, "model list not checked yet")
        state.chatCodexModelsError = "timeout"
        XCTAssertTrue(state.chatConnected, "a failed check may be transient")
        state.settings.chatProvider = "openai"; state.settings.chatBaseURL = "http://localhost:5010/v1"; state.settings.chatModel = ""
        XCTAssertFalse(state.chatConnected, "API server without a model")
        state.settings.chatModel = "local"
        XCTAssertTrue(state.chatConnected, "an API key is optional")
    }

    func testChatHeaderShowsTheModelChip() throws {
        let database = try SillogDatabase.inMemory()
        let state = AppState(preview: { s in
            s.phase = .ready; s.selectedTab = .chat
            s.settings.chatSameAsOrganize = false; s.settings.chatProvider = "codex"; s.settings.chatCodexModel = "gpt-6-luna"; s.chatCodexModels = self.models
            let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
            s.chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        })
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let text = OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
        // 글자 인식이 luna 의 l 을 | 로 읽기도 해서 앞부분만 본다 (창에 이 글자는 칩뿐)
        XCTAssertTrue(text.contains("gpt-6-"), "채팅 머리에 모델 칩이 보여야 한다: \(text.prefix(300))")
    }

    func testMenuListsTheModelsAndKeepsAnUnverifiedCurrentOne() {
        XCTAssertEqual(ChatModelMenu.options(models: models, current: "gpt-b").map(\.title), ["GPT A", "GPT B"])
        // 목록에 없는 지금 모델도 맨 위에 남겨 체크가 보이게 (설정 화면과 같은 규칙)
        let options = ChatModelMenu.options(models: models, current: "gpt-old")
        XCTAssertEqual(options.map(\.slug), ["gpt-old", "gpt-a", "gpt-b"])
        XCTAssertEqual(options.first?.title, "gpt-old (확인되지 않음)")
    }
}
