import XCTest
@testable import SillogCore

final class ChatPinSearchTests: XCTestCase {
    private func turn(_ store: ChatStore, _ title: String, _ question: String, _ answer: String, at time: Double = 100) throws -> ChatConversation {
        var conversation = ChatConversation(); conversation.title = title; conversation.updatedAt = time
        try store.startTurn(conversation: conversation,
                            user: .init(conversationID: conversation.id, role: "user", text: question),
                            answer: .init(conversationID: conversation.id, role: "assistant", text: answer))
        return conversation
    }

    func testPinSurvivesSaveAndUnpins() throws {
        let store = ChatStore(try .inMemory())
        var c = try turn(store, "고정 시험", "질문", "답")
        try store.setPinned(c.id, pinned: true, at: 500)
        var loaded = try store.conversations().first!
        XCTAssertEqual(loaded.pinnedAt, 500)
        XCTAssertEqual(loaded.updatedAt, 100)
        c.updatedAt = 200
        try store.save(c)
        loaded = try store.conversations().first!
        XCTAssertEqual(loaded.pinnedAt, 500)
        try store.setPinned(c.id, pinned: false)
        XCTAssertNil(try store.conversations().first!.pinnedAt)
    }

    func testSearchTitleBodyEscapeAndEmpty() async throws {
        let store = ChatStore(try .inMemory())
        let body = String(repeating: "가", count: 30) + "환율 전망" + String(repeating: "나", count: 200)
        let a = try turn(store, "일반", "질문", body, at: 100)
        let b = try turn(store, "예산 정리", "질문", "마지막 답", at: 200)
        _ = try turn(store, "퍼센트", "질문", "할인 100% 적용", at: 50)
        let hits = try await store.searchConversations("환율")
        XCTAssertEqual(hits.map(\.conversationID), [a.id])
        XCTAssertTrue(hits[0].snippet.hasPrefix(String(repeating: "가", count: 20) + "환율"))
        XCTAssertEqual(hits[0].snippet.count, 120)
        XCTAssertEqual(hits[0].messageID, try store.messages(a.id).first { $0.role == "assistant" }?.id)
        let byTitle = try await store.searchConversations("예산")
        XCTAssertEqual(byTitle.map(\.conversationID), [b.id])
        XCTAssertEqual(byTitle[0].snippet, "마지막 답")
        XCTAssertNil(byTitle[0].messageID)
        let percent = try await store.searchConversations("100%"), anyPercent = try await store.searchConversations("%")
        XCTAssertEqual(percent.count, 1)
        XCTAssertEqual(anyPercent.count, 1)
        let blank = try await store.searchConversations("  ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testSearchMatchesEveryWordInAnyOrder() async throws {
        let store = ChatStore(try .inMemory())
        let a = try turn(store, "일반", "질문", "이번 주간 회의 내용을 보고서로 정리했어요", at: 100)
        _ = try turn(store, "다른", "질문", "주간 일정만 있어요", at: 200)
        let hits = try await store.searchConversations("보고 주간")
        XCTAssertEqual(hits.map(\.conversationID), [a.id])
        XCTAssertNotNil(hits[0].messageID)
        XCTAssertTrue(hits[0].snippet.contains("보고서"))
    }

    func testOldPayloadDecodes() throws {
        let json = #"{"id":"x","title":"예전","skillID":"general","scope":{},"updatedAt":1}"#
        XCTAssertNil(try JSONDecoder().decode(ChatConversation.self, from: Data(json.utf8)).pinnedAt)
    }
}
