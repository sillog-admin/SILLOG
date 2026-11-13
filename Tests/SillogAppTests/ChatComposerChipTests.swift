import XCTest
@testable import SillogApp
@testable import SillogCore

/// Composer attachment chips: the chat's own artifacts are hidden, and project-wide items are marked so they get no remove button.
@MainActor
final class ChatComposerChipTests: XCTestCase {
    private func chatState(_ db: SillogDatabase) -> ChatState {
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)
        return ChatState(db: db, makeClient: { .model(offline) }, makeProjectClient: { offline })
    }

    func testTheChatsOwnArtifactIsNotAnAttachmentChip() throws {
        let db = try SillogDatabase.inMemory()
        let chat = chatState(db)
        try ChatStore(db).save(chat.current)
        var answer = ConversationMessage(conversationID: chat.current.id, role: "assistant", text: "초안입니다.")
        answer.artifacts = [ChatArtifact(title: "주간 보고서", format: "markdown", content: "# 초안")]
        chat.messages = [.init(conversationID: chat.current.id, role: "user", text: "보고서 써줘"), answer]
        let note = try chat.library.store.saveResponse(answer, title: "참고 메모")
        try chat.library.store.attach(note.id, conversationID: chat.current.id)
        try chat.library.store.collectArtifacts(chat.messages)
        chat.library.reload()
        XCTAssertEqual(chat.library.attached.count, 2, "the saved copy stays attached for the model")
        XCTAssertEqual(ChatComposer.shownAttachments(chat.library.attached, messages: chat.messages).map(\.id), [note.id])
    }

    func testAProjectWideItemIsMarkedForNoRemoveButton() throws {
        let db = try SillogDatabase.inMemory()
        let chat = chatState(db)
        let project = ChatProject(title: "보고", goal: "")
        try ProjectStore(db).save(project)
        chat.current.projectID = project.id
        try ChatStore(db).save(chat.current)
        let message = ConversationMessage(conversationID: chat.current.id, role: "assistant", text: "메모")
        let shared = try chat.library.store.saveResponse(message, title: "공유 메모")
        let own = try chat.library.store.saveResponse(.init(conversationID: chat.current.id, role: "assistant", text: "다른 메모"), title: "대화 메모")
        try chat.library.store.attach(shared.id, projectID: project.id)
        try chat.library.store.attach(own.id, conversationID: chat.current.id)
        chat.library.showAttachments(conversationID: chat.current.id, projectID: project.id)
        chat.library.reload()
        XCTAssertEqual(Set(chat.library.attached.map(\.id)), [shared.id, own.id])
        XCTAssertEqual(chat.library.projectAttached, [shared.id])
        chat.newConversation()
        XCTAssertEqual(chat.library.projectAttached, [])
    }
}
