import XCTest
@testable import SillogApp
@testable import SillogCore

/// Answers right away, except a question containing "wait" which runs until it is stopped.
private struct StubChatModel: ChatModelClient {
    let title: String?
    var modelName: String { "stub" }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if system.hasPrefix("사용자의 첫 요청") {
            guard let title else { throw LLMError.backend("no title") }
            return .init(text: title)
        }
        if messages.last(where: { $0.role == "user" })?.text.contains("wait") == true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return .init(text: "답")
    }
}

@MainActor
final class ChatStateTests: XCTestCase {
    override func setUp() {
        // Keeps begin() from reading connector tokens out of the Keychain.
        UserDefaults.standard.set([String](), forKey: "sillog.connectors.remote")
    }
    override func tearDown() { L10n.current = .ko }

    private func chatState(title: String? = "제목") throws -> ChatState {
        let model = StubChatModel(title: title)
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        return ChatState(db: try SillogDatabase.inMemory(), makeClient: { .model(model) }, makeProjectClient: { offline })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Sends `text` in a new chat and waits for the answer.
    private func finishedChat(_ chat: ChatState, _ text: String) async throws -> ChatConversation {
        chat.newConversation(); chat.draft = text
        XCTAssertTrue(chat.send())
        try await waitUntil { !chat.running }
        return chat.current
    }

    func testSendingWhileAnotherChatAnswersExplainsWhyAndKeepsThatAnswer() async throws {
        let chat = try chatState()
        let other = try await finishedChat(chat, "b")
        chat.newConversation(); chat.draft = "wait"
        XCTAssertTrue(chat.send())
        let answering = chat.current.id
        chat.select(other)
        chat.draft = "x"
        XCTAssertFalse(chat.send())
        XCTAssertEqual(chat.error, tr("다른 대화의 응답이 끝나면 보낼 수 있어요"))
        XCTAssertEqual(chat.activeMessage?.conversationID, answering, "the other answer is not stopped")
        chat.cancel()
        try await waitUntil { !chat.running }
    }

    func testAnEnglishChatGetsATitleAndAStoppedFirstAnswerGetsOneNextTurn() async throws {
        L10n.current = .en
        let chat = try chatState(title: "X")
        let first = try await finishedChat(chat, "hello")
        try await waitUntil { chat.conversations.first { $0.id == first.id }?.title == "X" }

        chat.newConversation(); chat.draft = "wait"
        XCTAssertTrue(chat.send())
        chat.cancel()
        try await waitUntil { !chat.running }
        XCTAssertEqual(chat.current.title, ChatConversation.defaultTitle)
        XCTAssertEqual(ChatConversation.display(chat.current.title), "New chat")
        chat.draft = "again"
        XCTAssertTrue(chat.send())
        try await waitUntil { chat.current.title == "X" }
    }

    func testAFailedTitleLeavesNoError() async throws {
        let chat = try chatState(title: nil)
        _ = try await finishedChat(chat, "hello")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(chat.error)
    }

    func testDraftsStayWithTheirChat() async throws {
        let chat = try chatState()
        let a = try await finishedChat(chat, "a")
        let b = try await finishedChat(chat, "b")
        chat.select(a); chat.draft = "half written"
        chat.select(b)
        XCTAssertEqual(chat.draft, "")
        chat.select(a)
        XCTAssertEqual(chat.draft, "half written")
        chat.select(a)
        XCTAssertEqual(chat.draft, "half written", "clicking the open chat keeps it")

        chat.newConversation(); chat.draft = "home"
        chat.newConversation()
        XCTAssertEqual(chat.draft, "home", "a tab round trip keeps the home input")
    }

    func testTheInputIsFocusedAfterSendingAndSwitching() async throws {
        let chat = try chatState()
        let a = try await finishedChat(chat, "a")
        var last = chat.inputFocusRequest
        chat.newConversation()
        XCTAssertGreaterThan(chat.inputFocusRequest, last); last = chat.inputFocusRequest
        chat.select(a)
        XCTAssertGreaterThan(chat.inputFocusRequest, last); last = chat.inputFocusRequest
        chat.draft = "next"
        XCTAssertTrue(chat.send())
        XCTAssertGreaterThan(chat.inputFocusRequest, last)
        try await waitUntil { !chat.running }
    }
}
