import XCTest
@testable import SillogApp
@testable import SillogCore

/// Answers right away, except a question containing "wait" which runs until it is stopped.
private struct StubChatModel: ChatModelClient {
    let title: String?
    var modelName: String { "stub" }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if system.hasPrefix("Write only a short") {
            guard let title else { throw LLMError.backend("no title") }
            return .init(text: title)
        }
        if messages.last(where: { $0.role == "user" })?.text.contains("wait") == true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return .init(text: "답")
    }
}

/// Records what the last answer was sent, fails run number `failRun`, and answers "read <id>" by reading that library item.
private final class ScriptedChatModel: ChatModelClient, @unchecked Sendable {
    var modelName: String { "scripted" }
    var failRun = 0
    private let lock = NSLock()
    private var runs = 0, lastSent: [ChatModelMessage] = []
    var sent: [ChatModelMessage] { lock.withLock { lastSent } }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if system.hasPrefix("Write only a short") { return .init(text: "제목") }
        if messages.last?.role == "tool" { return .init(text: "답") }
        let run: Int = lock.withLock { runs += 1; lastSent = messages; return runs }
        if run == failRun { throw LLMError.backend("down") }
        if let question = messages.last?.text, question.hasPrefix("read ") {
            return .init(text: "", calls: [.init(id: "c1", name: "read_library", arguments: #"{"id":"\#(question.dropFirst(5))"}"#)])
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

    private func chatState(title: String? = "제목", model: (any ChatModelClient)? = nil, db: SillogDatabase? = nil) throws -> ChatState {
        let model = model ?? StubChatModel(title: title)
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        return ChatState(db: try db ?? SillogDatabase.inMemory(), makeClient: { .model(model) }, makeProjectClient: { offline })
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

    func testAFailedTitleLeavesNoErrorAndTitlesFromTheQuestion() async throws {
        let chat = try chatState(title: nil)
        let question = String(repeating: "질문", count: 30)
        let conversation = try await finishedChat(chat, question)
        try await waitUntil { chat.conversations.first { $0.id == conversation.id }?.title == String(question.prefix(48)) }
        XCTAssertNil(chat.error)
    }

    func testDeletingTheOpenChatOpensANewOne() async throws {
        let chat = try chatState()
        let other = try await finishedChat(chat, "a")
        let open = try await finishedChat(chat, "b")
        try chat.deleteConversations([open.id])
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNotEqual(chat.current.id, other.id)
        XCTAssertEqual(chat.conversations.map(\.id), [other.id])
    }

    func testEditingTheQuestionClosesItsAnswersArtifact() async throws {
        let chat = try chatState()
        _ = try await finishedChat(chat, "q")
        let artifact = ChatArtifact(title: "t", format: "markdown", content: "x")
        chat.messages[1].artifacts = [artifact]
        chat.openArtifactID = artifact.id
        XCTAssertTrue(chat.resend(from: chat.messages[0], text: "edited"))
        XCTAssertNil(chat.openArtifactID)
        try await waitUntil { !chat.running }
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
        chat.select(a); chat.newConversation()
        XCTAssertEqual(chat.draft, "home", "opening a chat and starting a new one keeps the home input")
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

    func testATaskStarterFillsTheInputAndNarrowsTheScope() throws {
        let chat = try chatState()
        let task = ChatFocus(kind: .task, key: "t1", title: "온보딩 개편")
        chat.focusChoices = ChatFocusChoices(tasks: [.init(focus: task, theme: nil, themeKey: nil)])
        XCTAssertEqual(chat.starterPrompts.count, 3)
        let starter = chat.starterPrompts[2]
        let last = chat.inputFocusRequest
        chat.useStarter(starter.prompt, focus: starter.focus)
        XCTAssertEqual(chat.draft, "온보딩 개편 진행 상황 정리해 줘")
        XCTAssertEqual(chat.current.scope.focus, [task])
        XCTAssertGreaterThan(chat.inputFocusRequest, last)
        XCTAssertNil(chat.activeMessage, "a starter never sends")
    }
    func testRegeneratingKeepsEarlierAnswersAndTheModel() async throws {
        let chat = try chatState()
        _ = try await finishedChat(chat, "q")
        for _ in 0..<2 {
            XCTAssertTrue(chat.resend(from: chat.messages[1]))
            try await waitUntil { !chat.running }
        }
        let answer = chat.messages[1]
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(answer.model, "stub")
        XCTAssertEqual(answer.previous?.count, 2, "two regenerates keep two earlier answers")
        XCTAssertTrue(answer.previous?.allSatisfy { $0.previous == nil } == true, "earlier answers are not nested")
        XCTAssertEqual(answer.versions.last?.id, answer.id)

        XCTAssertTrue(chat.resend(from: chat.messages[0], text: "edited"))
        try await waitUntil { !chat.running }
        XCTAssertNil(chat.messages[1].previous, "an edited question starts over")
    }

    func testResendingTheSameQuestionKeepsEarlierAnswers() async throws {
        let chat = try chatState()
        _ = try await finishedChat(chat, "q")
        XCTAssertTrue(chat.resend(from: chat.messages[0], text: " q\n"))
        try await waitUntil { !chat.running }
        XCTAssertEqual(chat.messages[1].previous?.count, 1, "an unchanged edit is a regenerate")
    }

    func testRegeneratingSendsTheStoredHistory() async throws {
        let model = ScriptedChatModel(), db = try SillogDatabase.inMemory()
        let chat = try chatState(model: model, db: db)
        _ = try await finishedChat(chat, "q1")
        chat.draft = "q2"; XCTAssertTrue(chat.send())
        try await waitUntil { !chat.running }
        XCTAssertTrue(chat.resend(from: chat.messages[3]))
        try await waitUntil { !chat.running }
        let stored = try ChatStore(db).messages(chat.current.id).dropLast()
        XCTAssertEqual(model.sent.map(\.text), stored.map(\.text))
        XCTAssertEqual(model.sent.map(\.role), stored.map(\.role))
    }

    func testRegeneratingKeepsAtMostTenVersionsAndNoFailedOnes() async throws {
        let model = ScriptedChatModel(), db = try SillogDatabase.inMemory(); model.failRun = 4
        let chat = try chatState(model: model, db: db)
        _ = try await finishedChat(chat, "q")
        for _ in 0..<12 {
            XCTAssertTrue(chat.resend(from: chat.messages.last!))
            try await waitUntil { !chat.running }
        }
        let versions = chat.messages.last!.versions
        XCTAssertEqual(versions.count, 10)
        XCTAssertFalse(versions.contains { $0.status == "failed" })
        XCTAssertEqual(try ChatStore(db).messages(chat.current.id).last?.versions.count, 10)
    }

    func testToolSourcesAreSavedWithTheAnswer() async throws {
        let db = try SillogDatabase.inMemory()
        let chat = try chatState(model: ScriptedChatModel(), db: db)
        _ = try await finishedChat(chat, "a")
        let item = try chat.library.store.saveResponse(chat.messages[1], title: "note")
        chat.attachLibraryItem(item)
        chat.draft = "read \(item.id)"; XCTAssertTrue(chat.send())
        try await waitUntil { !chat.running }
        let saved = try XCTUnwrap(ChatStore(db).messages(chat.current.id).last)
        XCTAssertEqual(saved.status, "complete")
        XCTAssertTrue(saved.sources.contains { $0.id == "library:\(item.id):1" }, "the tool source survives without its own save")
    }

    func testCollectingOldArtifactsDoesNotBlockSending() async throws {
        let chat = try chatState()
        chat.library.collectExisting()
        XCTAssertFalse(chat.library.busy)
        chat.draft = "a"
        XCTAssertTrue(chat.send())
        try await waitUntil { !chat.running }
    }

    func testAttachmentsFollowTheChatOnScreen() async throws {
        let chat = try chatState()
        let first = try await finishedChat(chat, "a")
        let item = try chat.library.store.saveResponse(chat.messages[1], title: "note")
        chat.attachLibraryItem(item)
        XCTAssertEqual(chat.library.attached.map(\.id), [item.id])
        chat.newConversation()
        XCTAssertEqual(chat.library.attached, [])
        chat.select(first)
        XCTAssertEqual(chat.library.attached.map(\.id), [item.id])
    }

    func testAHungScheduledRunStopsAtTheCap() async throws {
        let db = try SillogDatabase.inMemory()
        var conversation = ChatConversation(); conversation.scope.useActivity = false
        var job = ChatAutomation(proposal: .init(title: "예약", prompt: "wait", intervalHours: 1), conversation: conversation, now: 0)
        job.nextRun = 0
        try ChatStore(db).save(job)
        let chat = try chatState(db: db)
        let limit = ChatState.scheduledRunLimit
        ChatState.scheduledRunLimit = .milliseconds(200)
        defer { ChatState.scheduledRunLimit = limit }
        chat.runDueAutomation()
        XCTAssertTrue(chat.running)
        try await waitUntil { !chat.running }
        let answer = try ChatStore(db).messages(try XCTUnwrap(chat.automations.first?.lastConversationID)).last
        XCTAssertEqual(answer?.status, "cancelled")
    }
}
