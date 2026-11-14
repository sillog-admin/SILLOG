import XCTest
@testable import SillogCore

final class ChatActivityTests: XCTestCase {
    func testToolUsesCountEachToolAndPointAtItsLatestAnswer() {
        var first = ConversationMessage(conversationID: "c", role: "assistant", text: "a")
        var thought = ChatStep(title: "Checking", status: .done); thought.kind = .reasoning
        first.trace = [thought, .init(title: "웹 검색", status: .done), .init(title: "기록 검색", status: .failed)]
        var second = ConversationMessage(conversationID: "c", role: "assistant", text: "b")
        second.trace = [.init(title: "활동 조사 시작", status: .done), .init(title: "활동 조사 · 웹 검색", status: .done),
                        .init(title: "활동 조사 완료", status: .done), .init(title: "웹 검색", status: .done)]
        var old = ConversationMessage(conversationID: "c", role: "assistant", text: "c")
        old.steps = ["기록 검색"]
        let question = ConversationMessage(conversationID: "c", role: "user", text: "q")

        let uses = ConversationMessage.toolUses(in: [question, first, second, old])
        XCTAssertEqual(uses.map(\.title), ["웹 검색", "기록 검색"])
        XCTAssertEqual(uses.map(\.count), [3, 2])
        XCTAssertEqual(uses.map(\.lastMessageID), [second.id, old.id])
        XCTAssertTrue(ConversationMessage.toolUses(in: [question]).isEmpty)
    }
}
