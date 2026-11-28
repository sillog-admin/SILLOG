import XCTest
@testable import SillogCore

final class MCPServerTests: XCTestCase {
    private func result(_ server: MCPServer, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        let request = JSONValue.encodeObject(["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": .object(params)])
        let reply = await server.handle(request)
        let line = try XCTUnwrap(reply)
        XCTAssertFalse(line.contains("\n"))
        return try XCTUnwrap(JSONValue.decodeObject(line)["result"]?.objectValue)
    }

    private func callText(_ server: MCPServer, _ name: String, _ arguments: [String: JSONValue]) async throws -> String {
        let result = try await result(server, "tools/call", ["name": .string(name), "arguments": .object(arguments)])
        XCTAssertEqual(result["isError"], false)
        return try XCTUnwrap(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    }

    func testHandshakeListsTheTools() async throws {
        let server = MCPServer(db: try SillogDatabase.inMemory())
        let hello = try await result(server, "initialize", ["protocolVersion": "2025-03-26"])
        XCTAssertEqual(hello["protocolVersion"], "2025-03-26")
        let notification = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)
        let tools = try await result(server, "tools/list")["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.compactMap { $0.objectValue?["name"]?.stringValue }, ["search", "fetch", "summarize_period", "list_items", "get_related"])
        let unknown = await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        XCTAssertTrue(unknown?.contains("-32601") ?? false)
        let broken = await server.handle("not json")
        XCTAssertTrue(broken?.contains("-32700") ?? false)
    }

    func testSearchFetchAndRelatedHideProjectOnlyTasks() async throws {
        let db = try SillogDatabase.inMemory()
        let (taskId, fileId) = try await db.writer.write { conn -> (Int64, Int64) in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_mcp", subtype: nil, title: "연동서버 만들기", props: ["status": "active"], at: 100)
            let file = try tx.upsertNode(label: NodeLabel.topic, key: "spec", subtype: nil, title: "명세검토", props: [:], at: 100)
            _ = try tx.upsertEdge(src: task, dst: file, type: EdgeType.about, props: [:], addWeight: 1, at: 100)
            return (task, file)
        }
        let server = MCPServer(db: db)

        let found = try await callText(server, "search", ["query": "연동서버", "kind": "node"])
        XCTAssertTrue(found.contains("node:\(taskId)"))
        let none = try await callText(server, "search", ["query": "연동서버", "kind": "recording"])
        XCTAssertEqual(none, "[]")
        let read = try await callText(server, "fetch", ["id": .string("node:\(taskId)"), "start": 1])
        XCTAssertTrue(read.contains("명세검토"))
        let related = try await callText(server, "get_related", ["id": .string("node:\(taskId)"), "hops": 2])
        XCTAssertTrue(related.hasPrefix("node:\(taskId) | Task | 연동서버 만들기"))
        XCTAssertTrue(related.contains("node:\(taskId) -[\(EdgeType.about)]-> node:\(fileId)"))

        let badDate = try await result(server, "tools/call", ["name": "summarize_period", "arguments": .object(["from": "어제", "to": "2026-11-16"])])
        XCTAssertEqual(badDate["isError"], true)

        let projects = ProjectStore(db)
        var project = ChatProject(title: "전용", goal: "분리")
        project.memoryMode = .projectOnly
        try projects.save(project)
        try projects.move("task:\(taskId)", to: project.id)
        let hiddenSearch = try await callText(server, "search", ["query": "연동서버"])
        XCTAssertFalse(hiddenSearch.contains("node:\(taskId)"))
        let hiddenRelated = try await callText(server, "get_related", ["id": .string("node:\(taskId)")])
        XCTAssertEqual(hiddenRelated, "[]")
    }

    func testListItemsReturnsOneKindInTimeOrderWithinThePeriod() async throws {
        let db = try SillogDatabase.inMemory()
        let hidden = try await db.writer.write { conn -> Int64 in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_secret", subtype: nil, title: "비공개 업무", props: [:], at: 1_000)
            for (key, start) in [("s_late", 5_000.0), ("s_early", 2_000.0), ("s_old", 100.0)] {
                _ = try tx.upsertNode(label: NodeLabel.session, key: key, subtype: nil, title: key, props: ["start": .number(start), "end": .number(start + 600)], at: start)
            }
            let solved = try tx.upsertNode(label: NodeLabel.problem, key: "p_solved", subtype: nil, title: "빌드 오류", props: ["at": 3_000], at: 3_000)
            let fix = try tx.upsertNode(label: NodeLabel.resource, key: "https://fix", subtype: nil, title: "해결 글", props: [:], at: 3_000)
            _ = try tx.upsertEdge(src: solved, dst: fix, type: EdgeType.resolvedBy, props: [:], addWeight: 1, at: 3_000)
            _ = try tx.upsertNode(label: NodeLabel.problem, key: "p_open", subtype: nil, title: "배포 실패", props: ["at": 4_000], at: 4_000)
            return task
        }
        let search = ContextSearch(db)
        XCTAssertEqual(try search.nodes(label: NodeLabel.session, from: 1_000, to: 9_000).map(\.location), ["s_early", "s_late"])
        let problems = try search.nodes(label: NodeLabel.problem)
        XCTAssertTrue(problems[0].excerpt.contains("해결됨"))
        XCTAssertTrue(problems[0].excerpt.contains("- \(EdgeType.resolvedBy) Resource · 해결 글 (https://fix) [node:"))
        XCTAssertTrue(problems[1].excerpt.contains("미해결"))
        XCTAssertFalse(problems[1].excerpt.contains("연결:"))

        let server = MCPServer(db: db)
        let sessions = try await callText(server, "list_items", ["type": "session"])
        XCTAssertTrue(sessions.contains("s_old"))
        let bad = try await result(server, "tools/call", ["name": "list_items", "arguments": .object(["type": "note"])])
        XCTAssertEqual(bad["isError"], true)

        let projects = ProjectStore(db)
        var project = ChatProject(title: "전용", goal: "분리")
        project.memoryMode = .projectOnly
        try projects.save(project)
        try projects.move("task:\(hidden)", to: project.id)
        let tasks = try await callText(server, "list_items", ["type": "task"])
        XCTAssertEqual(tasks, "[]")
    }

    // The in-app chat gets the same graph tools as MCP clients, and what it follows can be cited
    func testChatListsSessionsAndFollowsATaskToItsMaterials() async throws {
        let db = try SillogDatabase.inMemory()
        let task = try await db.writer.write { conn -> Int64 in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t", subtype: nil, title: "전환", props: [:], at: 1_000)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s", subtype: nil, title: "세션", props: ["start": .number(1_000), "end": .number(2_000)], at: 1_000)
            let doc = try tx.upsertNode(label: NodeLabel.resource, key: "https://doc", subtype: nil, title: "결정 문서", props: [:], at: 1_000)
            _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1_000)
            _ = try tx.upsertEdge(src: session, dst: doc, type: EdgeType.touched, props: [:], addWeight: 0, at: 1_000)
            return task
        }
        let tools = ChatTools(db: db, scope: .init())
        XCTAssertTrue(["list_items", "get_related"].allSatisfy { name in tools.specs.contains { $0.name == name } })
        let sessions = try await tools.execute(.init(id: "a", name: "list_items", arguments: #"{"type":"session","from":"","to":""}"#))
        XCTAssertEqual(sessions.sources.map(\.location), ["s"])
        XCTAssertTrue(sessions.text.contains("결정 문서"), "a session lists the material it touched")
        let related = try await tools.execute(.init(id: "b", name: "get_related", arguments: "{\"id\":\"node:\(task)\",\"hops\":\"2\"}"))
        XCTAssertTrue(related.text.contains("| Resource | 결정 문서 |"), "two hops reach the material through the session")
        XCTAssertTrue(related.sources.contains { $0.title == "Resource · 결정 문서" })
    }

    func testListItemsSaysWhenOlderItemsAreLeftOut() async throws {
        let db = try SillogDatabase.inMemory()
        try await db.writer.write { conn in
            let tx = GraphTx(conn)
            for i in 0...MCPServer.maxItems {
                let start = Double(1_000 + i * 100)
                _ = try tx.upsertNode(label: NodeLabel.session, key: "s_\(i)", subtype: nil, title: "s_\(i)", props: ["start": .number(start), "end": .number(start + 50)], at: start)
            }
        }
        let text = try await callText(MCPServer(db: db), "list_items", ["type": "session"])
        XCTAssertTrue(text.contains("\"s_\(MCPServer.maxItems)\""), "the newest is kept")
        XCTAssertFalse(text.contains("\"s_0\""), "the oldest is the one left out")
        XCTAssertTrue(text.hasSuffix("to an earlier date.]"))
        let bad = try await result(MCPServer(db: db), "tools/call", ["name": "list_items", "arguments": .object(["type": "note"])])
        XCTAssertTrue(bad["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue?.contains("task, session, problem, todo") ?? false)
    }

    // Listing by period alone mixed in every other task's sessions; with a task the list is that project's
    func testListItemsKeepsToOneTask() async throws {
        let db = try SillogDatabase.inMemory()
        let mine = try await db.writer.write { conn -> Int64 in
            let tx = GraphTx(conn)
            var tasks: [Int64] = []
            for name in ["mine", "theirs"] {
                let task = try tx.upsertNode(label: NodeLabel.task, key: "t_\(name)", subtype: nil, title: name, props: [:], at: 1_000)
                let session = try tx.upsertNode(label: NodeLabel.session, key: "s_\(name)", subtype: nil, title: "s_\(name)", props: ["start": .number(1_000), "end": .number(2_000)], at: 1_000)
                let problem = try tx.upsertNode(label: NodeLabel.problem, key: "p_\(name)", subtype: nil, title: "p_\(name)", props: ["at": 1_500], at: 1_500)
                let later = try tx.upsertNode(label: NodeLabel.laterItem, key: "l_\(name)", subtype: nil, title: "l_\(name)", props: ["at": 1_600], at: 1_600)
                _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1_000)
                _ = try tx.upsertEdge(src: session, dst: problem, type: EdgeType.hit, props: [:], addWeight: 0, at: 1_500)
                _ = try tx.upsertEdge(src: later, dst: task, type: EdgeType.forTask, props: [:], addWeight: 0, at: 1_600)
                tasks.append(task)
            }
            return tasks[0]
        }
        let tools = ChatTools(db: db, scope: .init())
        for (type, expected) in [("task", "t_mine"), ("session", "s_mine"), ("problem", "p_mine"), ("todo", "l_mine")] {
            let listed = try await tools.execute(.init(id: type, name: "list_items", arguments: #"{"type":"\#(type)","from":"","to":"","task":"node:\#(mine)"}"#))
            XCTAssertEqual(listed.sources.map(\.location), [expected], type)
        }
        let all = try await tools.execute(.init(id: "all", name: "list_items", arguments: #"{"type":"session","from":"","to":"","task":""}"#))
        XCTAssertEqual(all.sources.count, 2)
        do {
            _ = try await tools.execute(.init(id: "bad", name: "list_items", arguments: #"{"type":"session","from":"","to":"","task":"mine"}"#))
            XCTFail("a task name is not an id")
        } catch {}
    }

    // Switched-to sessions of other tasks and the apps once filled a project's map and pushed its problems past the cap
    func testATaskMapLeavesOutOtherTasksAndPutsProblemsFirst() async throws {
        let db = try SillogDatabase.inMemory()
        let (task, problem, others) = try await db.writer.write { conn -> (Int64, Int64, [Int64]) in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t", subtype: nil, title: "전환", props: [:], at: 1_000)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s", subtype: nil, title: "세션", props: [:], at: 1_000)
            let problem = try tx.upsertNode(label: NodeLabel.problem, key: "p", subtype: nil, title: "오래된 문제", props: [:], at: 100)
            let app = try tx.upsertNode(label: NodeLabel.app, key: "com.google.Chrome", subtype: nil, title: "Chrome", props: [:], at: 2_000)
            let elsewhere = try tx.upsertNode(label: NodeLabel.task, key: "t2", subtype: nil, title: "채용", props: [:], at: 2_000)
            let switched = try tx.upsertNode(label: NodeLabel.session, key: "s2", subtype: nil, title: "다른 업무 세션", props: [:], at: 2_000)
            _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1_000)
            _ = try tx.upsertEdge(src: session, dst: problem, type: EdgeType.hit, props: [:], addWeight: 0, at: 1_000)
            _ = try tx.upsertEdge(src: session, dst: app, type: EdgeType.used, props: [:], addWeight: 0, at: 1_000)
            _ = try tx.upsertEdge(src: session, dst: switched, type: EdgeType.switchedTo, props: [:], addWeight: 0, at: 1_000)
            _ = try tx.upsertEdge(src: switched, dst: elsewhere, type: EdgeType.partOf, props: [:], addWeight: 0, at: 2_000)
            for i in 0..<MCPServer.maxNodes {
                let doc = try tx.upsertNode(label: NodeLabel.resource, key: "https://doc/\(i)", subtype: nil, title: "자료 \(i)", props: [:], at: Double(3_000 + i))
                _ = try tx.upsertEdge(src: session, dst: doc, type: EdgeType.touched, props: [:], addWeight: 0, at: 3_000)
            }
            return (task, problem, [app, switched])
        }
        let graph = try ContextSearch(db).related("node:\(task)", hops: 2)
        XCTAssertEqual(graph.nodes.prefix(2).map(\.id), [task, problem], "an old problem comes before newer materials")
        XCTAssertFalse(graph.nodes.contains { others.contains($0.id) }, "other tasks' sessions and apps stay off a task's map")
        let text = MCPServer.describe(graph)
        XCTAssertTrue(text.contains("| Problem | 오래된 문제 |"))
        XCTAssertTrue(text.contains("[Showing \(MCPServer.maxNodes) of \(graph.nodes.count): problems"), "the cap says what comes first")
    }

    // Reading a material from the map brings its own screen texts, so it takes no search by name
    func testReadingAMaterialNodeBringsItsScreenTexts() throws {
        let db = try SillogDatabase.inMemory()
        let url = "https://www.notion.so/team/BaaS-review-1a2b"
        let node = try db.writer.write { conn -> Int64 in
            let doc = try GraphTx(conn).upsertNode(label: NodeLabel.resource, key: URINormalizer.normalize(url: url), subtype: "Note", title: "BaaS review", props: [:], at: 100)
            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'a', 'ax', '초안: Express 유지', 100), (2, 'b', 'ax', '결정: Supabase로 전환한다. 인증과 RLS를 쓴다', 100), (3, 'c', 'ax', '다른 페이지', 100)")
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, window_title, url, text_id) VALUES
                  (1, 110, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'BaaS review - Google Chrome', ?, 1),
                  (2, 120, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'BaaS review - Google Chrome', ?, 2),
                  (3, 130, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'BaaS review - Google Chrome', ?, 2),
                  (4, 140, 'app_activate', 'com.google.Chrome', 'Google Chrome', 'BaaS-review-1a2b 사본', 'https://example.com/BaaS-review-1a2b-copy', 3)
                """, arguments: [url, url, url])
            return doc
        }
        let read = try ContextSearch(db).read("node:\(node)")
        XCTAssertEqual(read.map(\.id), ["node:\(node)", "observation:1", "observation:3"], "each text once at its latest record, oldest first, and only this material's")
        XCTAssertTrue(read[2].excerpt.hasSuffix("인증과 RLS를 쓴다"))
    }

    // An excerpt says when it stops short, so a whole one isn't read again; the source cards never show that line
    func testASearchExcerptSaysWhenItStopsShort() throws {
        let db = try SillogDatabase.inMemory()
        try db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO text_snapshots(id, hash, source, text, created_at) VALUES (1, 'a', 'ax', ?, 100), (2, 'b', 'ax', '짧은 배포 메모', 100)",
                             arguments: ["배포 " + String(repeating: "가", count: 2_000)])
            try conn.execute(sql: """
                INSERT INTO observations(id, ts, trigger_kind, app_bundle, app_name, window_title, text_id) VALUES
                  (1, 110, 'app_activate', 'com.apple.Notes', 'Notes', '긴 메모', 1), (2, 120, 'app_activate', 'com.apple.Notes', 'Notes', '짧은 메모', 2)
                """)
        }
        let found = try ContextSearch(db).search(query: "배포", kind: "observation")
        let cut = try XCTUnwrap(found.first { $0.id == "observation:1" }), whole = try XCTUnwrap(found.first { $0.id == "observation:2" })
        XCTAssertTrue(cut.excerpt.hasSuffix("\n[2003 characters in all · this excerpt shows 1600 · read_context reads the full text]"))
        XCTAssertFalse(whole.excerpt.contains("characters in all"))
        XCTAssertFalse(cut.shownExcerpt.contains("characters in all"), "the source card hides the line")
    }

    func testSearchReachesLibraryFilesAndWholeConversations() async throws {
        let db = try SillogDatabase.inMemory()
        let server = MCPServer(db: db)
        // An unlinked file counts as unassigned only while no project-only project exists.
        try await db.writer.write { try $0.execute(sql: "INSERT INTO file_events(ts, path, kind, origin_url) VALUES (100, '/nowhere/견적서.pdf', 'created', 'https://shop.example/q')") }
        let mixed = try await callText(server, "search", ["query": "견적서"])
        XCTAssertFalse(mixed.contains("file:"), "files only come when asked for")
        let file = try await callText(server, "search", ["query": "견적서", "kind": "file"])
        XCTAssertTrue(file.contains("shop.example"))
        let id = try XCTUnwrap(file.range(of: #"file:\d+"#, options: .regularExpression).map { String(file[$0]) })
        let detail = try await callText(server, "fetch", ["id": .string(id)])
        XCTAssertTrue(detail.contains("이 위치에 없음"))

        let shared = ChatLibraryItem(title: "회의록", filename: "a.md", kind: "upload"), secret = ChatLibraryItem(title: "비밀 회의록", filename: "b.md", kind: "upload")
        var project = ChatProject(title: "전용", goal: "분리")
        project.memoryMode = .projectOnly
        try ProjectStore(db).save(project)
        let projectID = project.id
        let conversation = ChatConversation(), message = ConversationMessage(conversationID: conversation.id, role: "user", text: "배포순서 정리해줘")
        try ChatStore(db).save(conversation)
        try ChatStore(db).save(message)
        try await db.writer.write { conn in
            for item in [shared, secret] {
                try conn.execute(sql: "INSERT INTO app_library VALUES (?, 1, NULL, ?, ?)", arguments: [item.id, String(decoding: try JSONEncoder().encode(item), as: UTF8.self), "분기계획 본문"])
            }
            try conn.execute(sql: "INSERT INTO library_project_sources VALUES (?, ?)", arguments: [projectID, secret.id])
            try conn.execute(sql: "INSERT INTO library_conversation_sources VALUES (?, ?)", arguments: [conversation.id, shared.id])
        }

        let library = try await callText(server, "search", ["query": "분기계획"])
        XCTAssertTrue(library.contains("library:\(shared.id)"))
        XCTAssertFalse(library.contains(secret.id))
        let read = try await callText(server, "fetch", ["id": .string("library:\(shared.id)")])
        XCTAssertTrue(read.contains("분기계획 본문"))
        let hidden = try await result(server, "tools/call", ["name": "fetch", "arguments": .object(["id": .string("library:\(secret.id)")])])
        XCTAssertEqual(hidden["isError"], true)

        let chat = try await callText(server, "search", ["query": "배포순서", "kind": "message"])
        XCTAssertTrue(chat.contains("conversation:\(conversation.id) · 사용자 메시지"))
        XCTAssertFalse(try ContextSearch(db).search(query: "배포순서").contains { $0.excerpt.hasPrefix("[conversation:") }, "the app's source cards stay as they were")
        let badKind = try await result(server, "tools/call", ["name": "search", "arguments": .object(["query": "x", "kind": "mail"])])
        XCTAssertEqual(badKind["isError"], true)
    }

    func testRecordsThatLostTheirProjectLinkStayHidden() async throws {
        let db = try SillogDatabase.inMemory()
        var project = ChatProject(title: "전용", goal: "분리")
        project.memoryMode = .projectOnly
        try ProjectStore(db).save(project)
        var conversation = ChatConversation()
        conversation.projectID = project.id
        try ChatStore(db).save(conversation)
        var result = ChatLibraryItem(title: "전용 결과물", filename: "r.md", kind: "generated")
        result.originID = "artifact-1"
        let upload = ChatLibraryItem(title: "올린 자료", filename: "u.md", kind: "upload")
        let items = [result, upload], resultID = result.id, uploadID = upload.id, conversationID = conversation.id
        try await db.writer.write { conn in
            for item in items {
                try conn.execute(sql: "INSERT INTO app_library VALUES (?, 1, ?, ?, '숨김본문')", arguments: [item.id, item.originID, String(decoding: try JSONEncoder().encode(item), as: UTF8.self)])
            }
            for id in [resultID, uploadID] { try conn.execute(sql: "INSERT INTO library_conversation_sources VALUES (?, ?)", arguments: [conversationID, id]) }
            // Pruning clears the observation link of an old download.
            try conn.execute(sql: "INSERT INTO file_events(ts, path, kind) VALUES (100, '/Downloads/숨김.pdf', 'created')")
        }
        try ChatStore(db).deleteConversations([conversationID])
        let server = MCPServer(db: db)
        let library = try await callText(server, "search", ["query": "숨김본문", "kind": "library"])
        XCTAssertFalse(library.contains(resultID), "an item whose project-only conversation is gone has no trace of where it came from")
        XCTAssertFalse(library.contains(uploadID))
        let files = try await callText(server, "search", ["query": "숨김", "kind": "file"])
        XCTAssertEqual(files, "[]")
    }

    func testSummarizeRejectsATaskNameThatMatchesNothing() async throws {
        let db = try SillogDatabase.inMemory()
        let task = try await db.writer.write { try GraphTx($0).upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "로그인 화면", props: [:], at: 100) }
        let project = ChatProject(title: "모바일 앱", goal: "")
        try ProjectStore(db).save(project)
        try ProjectStore(db).move("task:\(task)", to: project.id)
        let server = MCPServer(db: db)
        let missing = try await result(server, "tools/call", ["name": "summarize_period", "arguments": .object(["from": "2026-11-01", "to": "2026-11-02", "task": "결제"])])
        XCTAssertEqual(missing["isError"], true)
        let byProject = try await callText(server, "summarize_period", ["from": "2026-11-01", "to": "2026-11-02", "task": "모바일"])
        XCTAssertTrue(byProject.contains("t_a"))
    }

    func testResultsAreMasked() async throws {
        let db = try SillogDatabase.inMemory()
        _ = try await db.writer.write { conn in
            try GraphTx(conn).upsertNode(label: NodeLabel.task, key: "t_card", subtype: nil, title: "결제확인 4242 4242 4242 4242", props: [:], at: 100)
        }
        let found = try await callText(MCPServer(db: db), "search", ["query": "결제확인"])
        XCTAssertFalse(found.contains("4242 4242 4242 4242"))
    }
}
