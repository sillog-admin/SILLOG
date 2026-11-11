import XCTest
import GRDB
@testable import SillogCore

private actor ProjectContextClient: ChatModelClient {
    nonisolated var modelName: String { "test" }
    var system = ""
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec], onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        self.system = system
        return .init(text: "확인")
    }
}

final class LibraryTests: XCTestCase {
    private func conversation(_ db: SillogDatabase, project: ChatProject? = nil, text: String = "기존 대화") throws -> ChatConversation {
        var conversation = ChatConversation(); conversation.projectID = project?.id
        try ChatStore(db).startTurn(conversation: conversation, user: .init(conversationID: conversation.id, role: "user", text: text), answer: .init(conversationID: conversation.id, role: "assistant", text: "답변"))
        return conversation
    }

    func testManualProjectAndLegacySettings() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        var project = ChatProject(title: "직접 만든 프로젝트", goal: "목표")
        project.instructions = "근거를 함께 설명해주세요."
        try store.save(project)
        XCTAssertTrue(try store.items().isEmpty)
        XCTAssertEqual(try store.projects().first?.instructions, project.instructions)
        XCTAssertEqual(try store.projects().first?.memoryMode, .allRecords)
        let old = #"{"id":"old","title":"기존","goal":"기존 목표","paths":[],"updatedAt":1}"#
        let decoded = try JSONDecoder().decode(ChatProject.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.instructions, "")
        XCTAssertEqual(decoded.memoryMode, .allRecords)
    }

    func testUploadSurvivesOriginalDeletionAndExplicitSharing() throws {
        let db = try SillogDatabase.inMemory(), projects = ProjectStore(db), library = LibraryStore(db)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try "확정 일정은 금요일입니다.".write(to: original, atomically: true, encoding: .utf8)
        let item = try library.importFile(original); try FileManager.default.removeItem(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: item).path))
        let project = ChatProject(title: "일정", goal: "일정 계획"); try projects.save(project)
        let a = try conversation(db, project: project), b = try conversation(db, project: project)
        try library.attach(item.id, conversationID: a.id)
        XCTAssertEqual(try projects.scope(for: a).libraryIDs, [item.id])
        XCTAssertTrue(try projects.scope(for: b).libraryIDs.isEmpty)
        XCTAssertThrowsError(try library.read(item.id, ids: projects.scope(for: b).libraryIDs))
        try library.attach(item.id, projectID: project.id)
        XCTAssertEqual(try projects.scope(for: b).libraryIDs, [item.id])
        XCTAssertTrue(try library.read(item.id, ids: [item.id]).excerpt.contains("금요일"))
        try library.detach(item.id, projectID: project.id)
        XCTAssertTrue(try projects.scope(for: b).libraryIDs.isEmpty)
        XCTAssertEqual(try projects.scope(for: a).libraryIDs, [item.id])
    }

    func testGeneratedFilesAreDeduplicatedRetainedAndNotResurrected() throws {
        let db = try SillogDatabase.inMemory(), library = LibraryStore(db)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let conversation = try conversation(db)
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "결과")
        answer.artifacts = [.init(title: "결과 문서", format: "markdown", content: "확정한 결과")]
        try ChatStore(db).save(answer)
        try library.collectArtifacts([answer]); try library.collectArtifacts([answer])
        XCTAssertEqual(try library.items().count, 1)
        let item = try XCTUnwrap(library.items().first)
        try ChatStore(db).deleteConversation(conversation.id)
        XCTAssertEqual(try library.items().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.url(for: item).path))
        let fresh = try self.conversation(db); answer.conversationID = fresh.id
        try library.attach(item.id, conversationID: fresh.id)
        try library.delete(item)
        XCTAssertTrue(try library.sourceIDs(conversationID: fresh.id).isEmpty)
        try library.collectArtifacts([answer])
        XCTAssertTrue(try library.items().isEmpty)
        XCTAssertThrowsError(try library.read("library:", ids: ["other"]))
    }

    func testProjectOnlyMemoryBlocksSearchAndDirectReadsInBothDirections() throws {
        let db = try SillogDatabase.inMemory(), projects = ProjectStore(db)
        var privateProject = ChatProject(title: "전용", goal: "분리"); privateProject.memoryMode = .projectOnly
        let publicProject = ChatProject(title: "기본", goal: "전체 기록")
        try projects.save(privateProject); try projects.save(publicProject)
        let a = try conversation(db, project: privateProject, text: "공유 키워드 전용 결정")
        let b = try conversation(db, project: publicProject, text: "공유 키워드 공개 결정")
        let message = try XCTUnwrap(ChatStore(db).messages(a.id).first)
        let global = ContextSearch(db)
        XCTAssertTrue(try global.read("conversation:\(a.id)").isEmpty)
        XCTAssertTrue(try global.read("message:\(message.id)").isEmpty)
        XCTAssertFalse(try global.search(query: "전용 결정").contains { $0.excerpt.contains("전용 결정") })
        XCTAssertTrue(try ContextSearch(db, projectID: privateProject.id).read("conversation:\(b.id)").isEmpty)
        XCTAssertFalse(try ContextSearch(db, projectID: privateProject.id).read("conversation:\(a.id)").isEmpty)
        XCTAssertTrue(try ContextSearch(db, projectID: publicProject.id).read("conversation:\(a.id)").isEmpty)
        privateProject.memoryMode = .allRecords; try projects.save(privateProject)
        XCTAssertFalse(try global.read("message:\(message.id)").isEmpty)
        XCTAssertFalse(try ContextSearch(db, projectID: publicProject.id).read("conversation:\(a.id)").isEmpty)
    }

    func testOldMessagesAndLongArtifactBodiesRemainSearchable() throws {
        let db = try SillogDatabase.inMemory(), chats = ChatStore(db)
        let conversation = try conversation(db, text: "초기확정 기준")
        for index in 0..<40 {
            var message = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "뒤의 대화 \(index)"); message.createdAt = Date().timeIntervalSince1970 + Double(index)
            try chats.save(message)
        }
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "파일 생성")
        answer.artifacts = [.init(title: "보고서", format: "markdown", content: String(repeating: "앞", count: 19000) + "후반부확정 근거")]
        try chats.save(answer)
        let search = ContextSearch(db, includeActivity: false)
        try chats.renameConversation(conversation.id, title: "보관된결정모음")
        XCTAssertFalse(try search.search(query: "보관된결정모음").isEmpty)
        XCTAssertTrue(try search.search(query: "초기확정").contains { $0.excerpt.contains("초기확정") })
        XCTAssertTrue(try search.search(query: "후반부확정").contains { $0.excerpt.contains("후반부확정") })
        XCTAssertTrue(try search.read("message:\(answer.id)", start: 18001).first?.excerpt.contains("후반부확정") == true)
        XCTAssertTrue(try search.read("conversation:\(conversation.id)", start: 21).first?.excerpt.contains("뒤의 대화") == true)
        answer.status = "failed"; try chats.save(answer)
        XCTAssertTrue(try search.read("message:\(answer.id)").isEmpty)
        XCTAssertTrue(try search.search(query: "후반부확정").isEmpty)
    }

    func testProjectInstructionsAndSavedDecisionsReachNewChats() async throws {
        let db = try SillogDatabase.inMemory(), projects = ProjectStore(db), library = LibraryStore(db)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        var project = ChatProject(title: "보고서", goal: "문서 완성"); project.instructions = "답변은 세 문장으로 작성해주세요."
        try projects.save(project)
        let old = try conversation(db, project: project)
        let answer = ConversationMessage(conversationID: old.id, role: "assistant", text: "확정 기준: 조사 기간은 두 달입니다.")
        try ChatStore(db).save(answer)
        let note = try library.saveResponse(answer, title: "조사 기간 결정"); try library.attach(note.id, projectID: project.id)
        let fresh = try conversation(db, project: project)
        let request = ConversationMessage(conversationID: fresh.id, role: "user", text: "보고서를 이어서 작성해줘")
        let client = ProjectContextClient()
        let result = try await ChatRunner(client: client, tools: ChatTools(db: db, scope: projects.scope(for: fresh))).run(history: [request], skillIDs: [], project: project) { _ in }
        let system = await client.system
        XCTAssertTrue(system.contains(project.instructions))
        XCTAssertTrue(system.contains("조사 기간은 두 달"))
        XCTAssertTrue(result.sources.contains { $0.id == "library:\(note.id)" })
    }

    func testLibraryAndFullMessageSearchMigrationKeepsOldData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("old.sqlite").path, queue = try DatabaseQueue(path: path)
        try SillogDatabase.migrator.migrate(queue, upTo: "v12-chat-projects")
        let old = ChatConversation(), message = ConversationMessage(conversationID: old.id, role: "assistant", text: "이전확정 규칙")
        try queue.write {
            try $0.execute(sql: "INSERT INTO app_conversations VALUES (?, 1, ?, NULL)", arguments: [old.id, String(decoding: try JSONEncoder().encode(old), as: UTF8.self)])
            try $0.execute(sql: "INSERT INTO app_messages VALUES (?, ?, 1, ?)", arguments: [message.id, old.id, String(decoding: try JSONEncoder().encode(message), as: UTF8.self)])
        }
        let migrated = try SillogDatabase(path: path)
        XCTAssertEqual(try ChatStore(migrated).conversations().count, 1)
        XCTAssertTrue(try ContextSearch(migrated).search(query: "이전확정").contains { $0.excerpt.contains("이전확정") })
        XCTAssertTrue(try LibraryStore(migrated).items().isEmpty)
    }

    func testLibraryToolsRespectProjectMemoryAndLiveUnlinking() async throws {
        let db = try SillogDatabase.inMemory(), library = LibraryStore(db), projects = ProjectStore(db)
        defer { try? FileManager.default.removeItem(at: library.directory) }
        var project = ChatProject(title: "전용 자료", goal: "자료 분리"); project.memoryMode = .projectOnly
        try projects.save(project)
        let item = try library.saveArtifact(.init(title: "확정 자료", format: "markdown", content: "전용확정 계획"))
        try library.attach(item.id, projectID: project.id)
        let chat = try conversation(db, project: project)
        let scope = try projects.scope(for: chat), tools = ChatTools(db: db, scope: scope)
        let call = ChatToolCall(id: "read", name: "read_library", arguments: "{\"id\":\"\(item.id)\",\"start\":\"1\"}")
        let allowed = try await tools.execute(call)
        XCTAssertTrue(allowed.text.contains("전용확정"))
        do { _ = try await ChatTools(db: db, scope: ChatScope()).execute(call); XCTFail("전용 자료가 일반 채팅에 노출됨") } catch {}
        try library.detach(item.id, projectID: project.id)
        do { _ = try await tools.execute(call); XCTFail("연결 해제 뒤에도 자료를 읽음") } catch {}
        project.memoryMode = .allRecords; try projects.save(project); try library.attach(item.id, projectID: project.id)
        let shared = try await ChatTools(db: db, scope: ChatScope()).execute(call)
        XCTAssertTrue(shared.text.contains("전용확정"))
    }

    func testOfficeFilesExtractWordSlidesAndSpreadsheetText() throws {
        let db = try SillogDatabase.inMemory(), library = LibraryStore(db)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: library.directory) }
        let fixtures: [(String, [(String, String)], String)] = [
            ("docx", [("word/document.xml", "<document><p><t>문서확정 내용</t></p></document>")], "문서확정"),
            ("pptx", [("ppt/slides/slide1.xml", "<slide><p><t>발표확정 내용</t></p></slide>")], "발표확정"),
            ("xlsx", [("xl/sharedStrings.xml", "<sst><si><t>표확정 내용</t></si></sst>"), ("xl/worksheets/sheet1.xml", "<worksheet><row><c t=\"s\"><v>0</v></c><c><v>42</v></c></row></worksheet>")], "표확정")
        ]
        for (ext, entries, expected) in fixtures {
            let folder = directory.appendingPathComponent(ext)
            for (name, text) in entries {
                let file = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
            let archive = directory.appendingPathComponent("fixture.\(ext)")
            let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.currentDirectoryURL = folder; zip.arguments = ["-qr", archive.path, "."]
            try zip.run(); zip.waitUntilExit(); XCTAssertEqual(zip.terminationStatus, 0)
            let item = try library.importFile(archive)
            XCTAssertTrue(try library.read(item.id, ids: [item.id]).excerpt.contains(expected))
            XCTAssertTrue(item.extractionNote.isEmpty)
        }
    }

    func testMixedScreenCardCannotExposePrivateActivity() throws {
        let db = try SillogDatabase.inMemory(), projects = ProjectStore(db)
        var project = ChatProject(title: "전용", goal: "분리"); project.memoryMode = .projectOnly; try projects.save(project)
        let ids = try db.writer.write { conn -> (Int64, Int64) in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: "Task", key: "private", subtype: nil, title: "전용", props: [:], at: 1)
            let b = try tx.upsertNode(label: "Task", key: "public", subtype: nil, title: "공개", props: [:], at: 1)
            return (a, b)
        }
        try projects.move("task:\(ids.0)", to: project.id)
        let card = try db.writer.write { conn -> Int64 in
            try conn.execute(sql: "INSERT INTO screen_cards(ts_start, ts_end, screen_hash, app_bundle, app_name, activity, content, kind, created_at) VALUES (1, 2, 'mixed', 'test', 'test', '혼합화면', '전용 내용과 공개 내용', 'test', 2)")
            let id = conn.lastInsertedRowID
            for task in [ids.0, ids.1] { try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, task_id, card_id) VALUES (1, 'test', 'test', 'test', ?, ?)", arguments: [task, id]) }
            return id
        }
        XCTAssertTrue(try ContextSearch(db).read("card:\(card)").isEmpty)
        XCTAssertFalse(try ContextSearch(db).search(query: "혼합화면").contains { $0.id == "card:\(card)" })
    }
}
