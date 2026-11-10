import XCTest
import GRDB
@testable import WorkGraphCore

final class ChatLogTests: XCTestCase {
    // MARK: Claude Code

    func testParsesHumanTextMessagesOnly() throws {
        let lines = [
            #"{"type":"user","isSidechain":false,"userType":"external","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:11:15.154Z","message":{"role":"user","content":[{"type":"text","text":"카드 컴포넌트 key prop 경고 고쳐줘"}]}}"#,
            #"{"type":"user","isSidechain":false,"userType":"external","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:12:00.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"..."}]}}"#,
            #"{"type":"assistant","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:12:10.000Z","message":{"role":"assistant","content":[{"type":"text","text":"고쳤습니다"}]}}"#,
            #"{"type":"user","isSidechain":true,"userType":"external","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:13:00.000Z","message":{"role":"user","content":[{"type":"text","text":"서브에이전트 지시"}]}}"#,
            #"{"type":"user","isSidechain":false,"userType":"external","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:14:00.000Z","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>주입된 안내</system-reminder>"}]}}"#,
            #"{"type":"user","isSidechain":false,"userType":"external","cwd":"/Users/me/proj","sessionId":"abc-123","timestamp":"2026-09-21T11:15:00.000Z","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"이 화면 왜 이래?"}]}}"#,
            "not json at all",
        ]
        let messages = ChatLogReader.parseClaude(lines: lines)
        XCTAssertEqual(messages.map(\.text), ["카드 컴포넌트 key prop 경고 고쳐줘", "이 화면 왜 이래?"])
        XCTAssertEqual(messages.first?.tool, "claude-code")
        XCTAssertEqual(messages.first?.sessionId, "abc-123")
        XCTAssertEqual(messages.first?.cwd, "/Users/me/proj")
        XCTAssertEqual(messages.first?.ts ?? 0, 1_789_989_075.154, accuracy: 0.01)
    }

    func testLongPastedMessagesAreTruncatedAndSystemLikeOnesDropped() {
        let long = String(repeating: "가", count: 5_000)
        let lines = [
            "{\"type\":\"user\",\"userType\":\"external\",\"cwd\":\"/p\",\"sessionId\":\"s\",\"timestamp\":\"2026-09-21T11:11:15Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(long)\"}]}}",
            #"{"type":"user","userType":"external","cwd":"/p","sessionId":"s","timestamp":"2026-09-21T11:11:16Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            #"{"type":"user","userType":"external","cwd":"/p","sessionId":"s","timestamp":"2026-09-21T11:11:17Z","message":{"role":"user","content":"문자열 형태 content 도 받는다"}}"#,
        ]
        let messages = ChatLogReader.parseClaude(lines: lines)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].text.count, ChatLogReader.maxChars)
        XCTAssertEqual(messages[1].text, "문자열 형태 content 도 받는다")
    }

    // MARK: Codex CLI

    func testParsesCodexHistoryWithSessionCwdLookup() {
        let lines = [
            #"{"session_id":"019ebb80-aaaa","ts":1781262219,"text":"로그인 페이지 만들어줘"}"#,
            #"{"session_id":"019ebb80-aaaa","ts":1781262242,"text":"에러 나는데 고쳐줘"}"#,
            #"{"session_id":"unknown-sess","ts":1781262300,"text":"cwd 를 모르는 세션"}"#,
        ]
        let messages = ChatLogReader.parseCodexHistory(lines: lines, cwdBySession: ["019ebb80-aaaa": "/Users/me/genllms/Front"])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].tool, "codex-cli")
        XCTAssertEqual(messages[0].cwd, "/Users/me/genllms/Front")
        XCTAssertEqual(messages[0].ts, 1_781_262_219)
        XCTAssertNil(messages[2].cwd)
    }

    func testCodexSessionMetaGivesCwd() {
        let meta = #"{"timestamp":"2026-06-23T08:33:21.408Z","type":"session_meta","payload":{"id":"019ef39c-d1e9","timestamp":"2026-06-23T08:33:21.408Z","cwd":"/Users/me/genllms/Front","originator":"codex_exec"}}"#
        XCTAssertEqual(ChatLogReader.codexSessionMeta(firstLine: meta)?.id, "019ef39c-d1e9")
        XCTAssertEqual(ChatLogReader.codexSessionMeta(firstLine: meta)?.cwd, "/Users/me/genllms/Front")
        XCTAssertNil(ChatLogReader.codexSessionMeta(firstLine: #"{"type":"response_item"}"#))
    }

    // MARK: 저장

    func testStoreDeduplicatesAndQueriesByWindow() throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let a = ChatMessage(ts: 100, tool: "claude-code", sessionId: "s1", cwd: "/p", text: "첫 질문")
        let b = ChatMessage(ts: 200, tool: "claude-code", sessionId: "s1", cwd: "/p", text: "둘째 질문")
        XCTAssertEqual(try store.insertChatMessages([a, b, a]), 2)          // 같은 메시지는 한 번만
        XCTAssertEqual(try store.insertChatMessages([a]), 0)
        XCTAssertEqual(try store.chatMessages(from: 150, to: 300).map(\.text), ["둘째 질문"])
        XCTAssertEqual(try store.chatMessages(from: 0, to: 300).count, 2)
        try store.setChatCursor(path: "/x.jsonl", offset: 1234)
        XCTAssertEqual(try store.chatCursor(path: "/x.jsonl"), 1234)
        XCTAssertNil(try store.chatCursor(path: "/y.jsonl"))
    }

    func testMessagesAndCursorCommitTogether() throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let message = ChatMessage(ts: 100, tool: "codex-cli", sessionId: "s1", cwd: nil, text: "질문")
        try db.writer.write { conn in
            try conn.execute(sql: "CREATE TEMP TRIGGER fail_cursor BEFORE INSERT ON chat_cursors BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        XCTAssertThrowsError(try store.insertChatMessages([message], cursors: ["/test.jsonl": 100]))
        XCTAssertTrue(try store.chatMessages(from: 0, to: 200).isEmpty)
        XCTAssertNil(try store.chatCursor(path: "/test.jsonl"))
        try db.writer.write { try $0.execute(sql: "DROP TRIGGER fail_cursor") }
        XCTAssertEqual(try store.insertChatMessages([message], cursors: ["/test.jsonl": 100]), 1)
        XCTAssertEqual(try store.chatCursor(path: "/test.jsonl"), 100)
        XCTAssertEqual(try store.insertChatMessages([], cursors: ["/test.jsonl": 200]), 0)
        XCTAssertEqual(try store.chatCursor(path: "/test.jsonl"), 200)
    }
}

final class ChatRowTests: XCTestCase {
    private func row(_ n: Int, _ start: Double, _ end: Double, app: String) -> ActivityRow {
        ActivityRow(row: n, start: start, end: end, dwell: Int(end - start), app: app, appBundle: "b.\(app)", title: app, uri: nil, type: nil,
                    projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [Int64(n)])
    }

    func testChatSessionsBecomeZeroDwellRowsInTimeOrder() {
        let rows = [row(1, 1000, 1600, app: "Cursor"), row(2, 1600, 2200, app: "Chrome")]
        let chats = [
            ChatMessage(ts: 1100, tool: "claude-code", sessionId: "s1", cwd: "/Users/me/proj/dashboard", text: "카드 컴포넌트 key prop 경고 고쳐줘"),
            ChatMessage(ts: 1300, tool: "claude-code", sessionId: "s1", cwd: "/Users/me/proj/dashboard", text: "간격 16px 로"),
            ChatMessage(ts: 1700, tool: "codex-cli", sessionId: "c9", cwd: nil, text: "테스트 돌려봐"),
        ]
        let merged = EventCompressor.merge(rows, chats: chats, home: "/Users/me", fileExists: { $0 == "/Users/me/proj/dashboard/package.json" }, snippetChars: 300)
        XCTAssertEqual(merged.map(\.row), [1, 2, 3, 4])
        XCTAssertEqual(merged.map(\.app), ["Cursor", "Claude Code", "Chrome", "Codex CLI"])
        let claude = merged[1]
        XCTAssertTrue(claude.isChat)
        XCTAssertEqual(claude.dwell, 0)
        XCTAssertEqual(claude.uri, "chat:claude-code:s1")
        XCTAssertEqual(claude.type, "AIChat")
        XCTAssertEqual(claude.title, "Claude Code: 카드 컴포넌트 key prop 경고 고쳐줘")
        XCTAssertEqual(claude.snippet, "「카드 컴포넌트 key prop 경고 고쳐줘」 「간격 16px 로」")
        XCTAssertEqual(claude.projectKey, "file:~/proj/dashboard")
        XCTAssertEqual(claude.projectTitle, "dashboard")
        XCTAssertNil(merged[3].projectKey)
        XCTAssertEqual(merged.reduce(0) { $0 + $1.dwell }, 1200, "대화 행은 시간 집계에 들어가지 않는다")
    }

    func testChatRowsFlowIntoPromptAndGraph() throws {
        let rows = EventCompressor.merge(Fixtures.frontendRows(), chats: [
            ChatMessage(ts: 1_000_000 + 600, tool: "claude-code", sessionId: "s1", cwd: "/Users/me/proj/dashboard", text: "TaskCard 에 shadcn Card 적용해줘"),
        ], home: "/Users/me", fileExists: { _ in false }, snippetChars: 300)
        let prompt = OntologyPrompt.build(rows: rows, openTasks: [], now: 1_005_280)
        XCTAssertTrue(prompt.user.contains("| 0s | Claude Code | AIChat |"))
        XCTAssertTrue(prompt.user.contains("text: 「TaskCard 에 shadcn Card 적용해줘」"))
        XCTAssertTrue(prompt.system.contains("Claude Code"))

        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let patch = try Fixtures.patch("""
            {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],"rows":[{"rows":"1-\(rows.count)","task":"A"}],
             "work":[{"task":"A","summary":"s","topics":["React"]}]}
            """)
            _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000)
            let chat = try XCTUnwrap(tx.node(label: "Resource", key: "chat:claude-code:s1"))
            XCTAssertEqual(chat.subtype, "AIChat")
            XCTAssertEqual(try tx.edges(to: chat.id, type: "TOUCHED").count, 1)
            XCTAssertEqual(try tx.edges(from: chat.id, type: "BELONGS_TO").count, 1)          // cwd → 프로젝트
            XCTAssertNil(try tx.node(label: "App", key: "chat.claude-code"), "대화 도구는 앱 노드로 만들지 않는다")
        }
    }
}

final class ChatBatchTests: XCTestCase {
    func testLateChatMessagesAreUsedOnceByTheNextBatch() async throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        // 관측 행: 100~460초. 대화는 그보다 앞선 50초에 있었지만(늦게 읽힘) 아직 어느 배치에도 안 들어감
        for (i, ts) in [100.0, 160, 400, 460].enumerated() {
            try store.insert(Observation(ts: ts, trigger: "app_activate", appBundle: "b\(i % 2)", appName: "App\(i % 2)", windowTitle: "w\(i % 2)"))
        }
        try store.insertChatMessages([ChatMessage(ts: 50, tool: "claude-code", sessionId: "s1", cwd: "/p", text: "TaskCard 고쳐줘")])
        let llm = StubLLM([.success("""
        {"tasks":[{"ref":"A","match":"new","title":"카드 UI","task_type":"코드작성"}],"rows":[{"rows":"1-5","task":"A"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """), .success("""
        {"tasks":[{"ref":"A","match":"new","title":"다른 작업","task_type":"기타"}],"rows":[{"rows":"1-2","task":"A"}],"work":[{"task":"A","summary":"s","topics":[]}]}
        """)])
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 2_000 })
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("첫 배치 성공해야 함") }
        XCTAssertTrue(llm.lastUser.contains("| Claude Code | AIChat |"), "창보다 오래된 미처리 대화도 들어간다")
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"; clock.timeZone = .current
        let at100 = clock.string(from: Date(timeIntervalSince1970: 100))
        let rowsSection = llm.lastUser.components(separatedBy: "ROWS (").last ?? ""
        // 같은 시각(100초)의 관측 행 다음에 놓이므로 2번 행
        XCTAssertTrue(rowsSection.contains("2 | \(at100)-\(at100) | 0s | Claude Code"), "늦은 대화는 창 시작 시각(100초)에 놓인다:\n\(rowsSection.prefix(500))")
        let used = try XCTUnwrap(store.chatMessage(id: 1))
        XCTAssertNotNil(used.batchId, "쓰인 메시지는 처리됨 표시")
        XCTAssertTrue(try store.unprocessedChatMessages(upTo: 10_000, notOlderThan: 0).isEmpty)

        // 두 번째 배치에는 같은 메시지가 다시 들어가지 않는다
        try store.insert(Observation(ts: 900, trigger: "app_activate", appBundle: "b9", appName: "App9"))
        try store.insert(Observation(ts: 960, trigger: "app_activate", appBundle: "b8", appName: "App8"))
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("둘째 배치 성공해야 함") }
        XCTAssertFalse(llm.lastUser.contains("AIChat"))
    }
}
