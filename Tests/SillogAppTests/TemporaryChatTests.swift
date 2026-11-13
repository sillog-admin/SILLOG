import XCTest
@testable import SillogApp
@testable import SillogCore

/// Answers "답", except a question containing "wait" which runs until stopped; counts title requests.
private final class CountingChatModel: ChatModelClient, @unchecked Sendable {
    var modelName: String { "stub" }
    private let lock = NSLock()
    private var titles = 0
    var titleCalls: Int { lock.withLock { titles } }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if system.hasPrefix("Write only a short") { lock.withLock { titles += 1 }; return .init(text: "제목") }
        if system.hasPrefix("Write the one follow-up") { return .init(text: "다음 질문") }
        if messages.last(where: { $0.role == "user" })?.text.contains("wait") == true {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return .init(text: "답")
    }
}

@MainActor
final class TemporaryChatTests: XCTestCase {
    override func setUp() { UserDefaults.standard.set([String](), forKey: "sillog.connectors.remote") }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testATemporaryChatRunLeavesNoRowsAndIsDroppedOnLeaving() async throws {
        let db = try SillogDatabase.inMemory()
        let model = CountingChatModel()
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        let chat = ChatState(db: db, makeClient: { .model(model) }, makeProjectClient: { offline })
        chat.newConversation(temporary: true); chat.draft = "a"
        XCTAssertTrue(chat.isTemporary)
        XCTAssertTrue(chat.send())
        try await waitUntil { !chat.running }
        let id = chat.current.id
        XCTAssertEqual(chat.messages.map(\.text), ["a", "답"])
        XCTAssertEqual(model.titleCalls, 0)
        XCTAssertTrue(try ChatStore(db).conversations().isEmpty)
        XCTAssertTrue(try ChatStore(db).messages(id).isEmpty)
        XCTAssertTrue(chat.conversations.isEmpty)

        chat.attach([URL(fileURLWithPath: "/etc/hosts")])
        XCTAssertNotNil(chat.error, "attaching a file would save it to the library")
        XCTAssertTrue(try chat.library.store.items().isEmpty)

        chat.draft = "wait"
        XCTAssertTrue(chat.send())
        chat.newConversation()
        XCTAssertFalse(chat.isTemporary)
        XCTAssertTrue(chat.messages.isEmpty)
        try await waitUntil { !chat.running }
        XCTAssertTrue(try ChatStore(db).conversations().isEmpty, "the stopped run writes nothing back")
        XCTAssertTrue(try ChatStore(db).messages(id).isEmpty)
    }

    func testComingBackToTheChatTabKeepsAnOpenTemporaryChat() async throws {
        let db = try SillogDatabase.inMemory()
        var saved = ChatConversation(); saved.title = "저장된 대화"
        try ChatStore(db).save(saved)
        UserDefaults.standard.set(saved.id, forKey: ChatState.lastConversationKey)
        let model = CountingChatModel()
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        let chat = ChatState(db: db, makeClient: { .model(model) }, makeProjectClient: { offline })
        chat.newConversation(temporary: true); chat.draft = "wait"
        XCTAssertTrue(chat.send())
        chat.reopenLast()
        XCTAssertTrue(chat.isTemporary)
        XCTAssertTrue(chat.currentRunning)
        chat.cancel()
        try await waitUntil { !chat.running }
    }
}
