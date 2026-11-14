import XCTest
@testable import SillogCore

private actor ReasoningBox {
    var updates: [(String, String)] = []
    func add(_ id: String, _ text: String) { updates.append((id, text)) }
    func add(_ event: ChatRunEvent) { if case .reasoning(let id, let text) = event { updates.append((id, text)) } }
}

/// Streams one reasoning summary through onReasoning before answering.
private struct ThinkingModel: ChatModelClient {
    var modelName: String { "thinking" }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply { .init(text: "답") }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void,
                 onReasoning: @escaping @Sendable (String, String) async -> Void) async throws -> ChatModelReply {
        await onReasoning("rs_1", "**Checking the records**")
        return .init(text: "답")
    }
}

final class ChatReasoningTests: XCTestCase {
    private func client(effort: String?) -> CodexResponsesClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        return CodexResponsesClient(auth: StubCredentials(), model: "gpt-5.4-mini", reasoningEffort: effort, session: URLSession(configuration: config))
    }

    private func sse(_ events: [String]) -> String { events.map { "data: \($0)\n" }.joined(separator: "\n") + "\n" }

    func testResponsesStreamShowsTheSummaryAtLineAndPartEnds() async throws {
        StubURLProtocol.reset([.init(status: 200, body: sse([
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"**Checking the docs"}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":" tools**\n\nI will look"}"#,
            #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":" first."}"#,
            #"{"type":"response.reasoning_summary_text.done","item_id":"rs_1","summary_index":0,"text":"**Checking the docs tools**\n\nI will look first."}"#,
            #"{"type":"response.output_text.delta","delta":"답"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#,
        ]))])
        let box = ReasoningBox()
        let reply = try await client(effort: "low").respond(system: "s", messages: [.init(role: "user", text: "q")], tools: [],
                                                            onText: { _ in }, onReasoning: { await box.add($0, $1) })
        XCTAssertEqual(reply.text, "답")
        let updates = await box.updates
        XCTAssertEqual(updates.map(\.0), ["rs_1#0", "rs_1#0"])
        XCTAssertEqual(updates.map(\.1), ["**Checking the docs tools**\n\nI will look", "**Checking the docs tools**\n\nI will look first."])
        let reasoning = StubURLProtocol.requests.first?.body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["summary"] as? String, "auto")
        XCTAssertEqual(reasoning?["effort"] as? String, "low")
    }

    func testResponsesWithoutAnEffortSendsNoReasoningAndStillAnswers() async throws {
        StubURLProtocol.reset([.init(status: 200, body: sse([
            #"{"type":"response.output_text.delta","delta":"네"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#,
        ]))])
        let reply = try await client(effort: nil).respond(system: "s", messages: [.init(role: "user", text: "q")], tools: []) { _ in }
        XCTAssertEqual(reply.text, "네")
        XCTAssertNil(StubURLProtocol.requests.first?.body["reasoning"])
    }

    func testCodexNotificationsBecomeReasoningUpdates() {
        let stream: [(String, [String: JSONValue])] = [
            ("item/started", ["item": .object(["type": "reasoning", "id": "rs_1"])]),
            ("item/reasoning/summaryTextDelta", ["itemId": "rs_1", "summaryIndex": 0, "delta": "**Reading the week**\n\n"]),
            ("item/reasoning/summaryTextDelta", ["itemId": "rs_1", "summaryIndex": 0, "delta": "Looking at Monday."]),
            ("item/reasoning/summaryPartAdded", ["itemId": "rs_1", "summaryIndex": 1]),
            ("item/reasoning/summaryTextDelta", ["itemId": "rs_1", "summaryIndex": 1, "delta": "**Comparing days**"]),
            ("item/agentMessage/delta", ["delta": "답"]),
            ("item/completed", ["item": .object(["type": "reasoning", "id": "rs_1", "summary": .array(["**Reading the week**\n\nLooking at Monday.", "**Comparing days**"])])]),
            ("item/completed", ["item": .object(["type": "agentMessage", "text": "답"])]),
        ]
        var summaries = ReasoningSummaries()
        let updates = stream.flatMap { CodexAppServerClient.reasoning($0.0, $0.1, into: &summaries) }.map { event -> String in
            guard case .reasoning(let id, let text) = event else { return "" }
            return id + ": " + text
        }
        XCTAssertEqual(updates, [
            "rs_1#0: **Reading the week**\n\n",
            "rs_1#0: **Reading the week**\n\nLooking at Monday.",
            "rs_1#0: **Reading the week**\n\nLooking at Monday.",
            "rs_1#1: **Comparing days**",
        ])
    }

    func testRunnerForwardsTheAnswersReasoning() async throws {
        let runner = ChatRunner(client: ThinkingModel(), tools: ChatTools(db: try .inMemory(), scope: .init()))
        let box = ReasoningBox()
        _ = try await runner.run(history: [.init(conversationID: "t", role: "user", text: "q")], skillIDs: []) { await box.add($0) }
        let updates = await box.updates
        XCTAssertEqual(updates.map(\.1), ["**Checking the records**"])
    }

    func testReasoningStepTakesTheHeadingAndUpdatesInPlace() throws {
        var message = ConversationMessage(conversationID: "c", role: "assistant", text: "", status: "running")
        message.setReasoning(id: "rs_1", text: "**Checking the docs")
        message.trace?.append(ChatStep(title: "기록 검색"))
        message.setReasoning(id: "rs_1", text: "**Checking the docs tools**\n\nI will look first.")
        message.setReasoning(id: "rs_2", text: "  ")
        message.setReasoning(id: "rs_3", text: "Looking at the week before answering.")
        XCTAssertEqual(message.trace?.map(\.title), ["Checking the docs tools", "기록 검색", ""])
        XCTAssertEqual(message.trace?.last?.result, "Looking at the week before answering.")
        XCTAssertEqual(message.trace?.last?.displayTitle, tr("생각"))
        XCTAssertEqual(message.trace?.first?.result, "I will look first.")
        XCTAssertEqual(message.trace?.first?.kind, .reasoning)
        XCTAssertEqual(message.trace?.first?.displayTitle, "Checking the docs tools")

        let saved = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(saved.trace?.first?.kind, .reasoning)
        let old = #"{"id":"s","title":"기록 검색","detail":"","result":"","status":"done","startedAt":1}"#
        XCTAssertNil(try JSONDecoder().decode(ChatStep.self, from: Data(old.utf8)).kind)
    }
}
