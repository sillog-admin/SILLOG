import XCTest
import GRDB
@testable import SillogCore

private actor ProjectTestClient: LLMClient {
    nonisolated var modelName: String { "test" }
    var calls = 0
    let reply: Data
    let fail: Bool
    let started: AsyncStream<Void>.Continuation?
    init(reply: String = #"{"groups":[]}"#, fail: Bool = false, started: AsyncStream<Void>.Continuation? = nil) {
        self.reply = Data(reply.utf8); self.fail = fail; self.started = started
    }
    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        calls += 1
        if fail { throw LLMError.transport("offline") }
        if let started { started.yield(()); try await Task.sleep(nanoseconds: 10_000_000_000) }
        return .init(arguments: reply, model: modelName, promptTokens: 0, completionTokens: 0, raw: "")
    }
}

final class ProjectTests: XCTestCase {
    func testStoredDuplicateSuggestionsCombineItemsAndAcceptTogether() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let project = ChatProject(title: "보고서", goal: "공동 작성")
        try store.save(project)
        _ = try task(db); _ = try conversation(db)
        let items = try store.items()
        let first = ProjectProposal(projectID: project.id, title: project.title, goal: project.goal, reason: "조사", items: [items[0]])
        let second = ProjectProposal(projectID: project.id, title: "다른 표시 제목", goal: project.goal, reason: "검토", items: items)
        try db.writer.write { conn in
            try ProjectStore.save(first, conn); try ProjectStore.save(second, conn)
        }
        let grouped = try XCTUnwrap(store.proposals().first)
        XCTAssertEqual(try store.proposals().count, 1)
        XCTAssertEqual(grouped.items.count, 2)
        XCTAssertTrue(grouped.reason.contains("조사")); XCTAssertTrue(grouped.reason.contains("검토"))
        _ = try store.accept(grouped.id, title: grouped.title)
        XCTAssertEqual(Set(try store.items().compactMap(\.projectID)), [project.id])
        XCTAssertTrue(try db.writer.read { try ProjectStore.proposals($0).isEmpty })
    }

    func testSameTitleNewSuggestionsGroupAndDismissTogether() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        _ = try task(db); _ = try conversation(db)
        let items = try store.items()
        try db.writer.write { conn in
            try ProjectStore.save(ProjectProposal(title: "Release Plan", goal: "계획", reason: "조사", items: [items[0]]), conn)
            try ProjectStore.save(ProjectProposal(title: " release  PLAN ", goal: "계획", reason: "검토", items: [items[1]]), conn)
        }
        XCTAssertEqual(try store.proposals().count, 1)
        try store.dismiss(XCTUnwrap(store.proposals().first).id)
        XCTAssertTrue(try store.proposals().isEmpty)
        XCTAssertTrue(try store.review().items.isEmpty)
    }

    func testRepeatedSuggestionsForExistingProjectAreStoredAsOne() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let project = ChatProject(title: "공통 목표", goal: "문서 작성")
        try store.save(project)
        for _ in 0..<2 {
            let id = try task(db)
            try store.record([.init(target: "project:\(project.id)", title: project.title, goal: project.goal,
                                    reason: "같은 목표", items: ["task:\(id)"])], review: store.review())
        }
        XCTAssertEqual(try store.proposals().count, 1)
        XCTAssertEqual(try store.proposals().first?.items.count, 2)
        XCTAssertEqual(try db.writer.read { try ProjectStore.proposals($0).count }, 1)
    }

    func testIdenticalTitlesDoNotCombineDifferentExistingProjects() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let a = ChatProject(title: "보고서", goal: "A"), b = ChatProject(title: "보고서", goal: "B")
        try store.save(a); try store.save(b)
        try db.writer.write { conn in
            for project in [a, b] {
                try ProjectStore.save(ProjectProposal(projectID: project.id, title: project.title, goal: project.goal, reason: "근거", items: []), conn)
            }
            try ProjectStore.save(ProjectProposal(title: "보고서", goal: "새 목표", reason: "근거", items: []), conn)
        }
        XCTAssertEqual(try store.proposals().count, 3)
    }

    func testBulkConversationMoveAndDeleteOnlyAffectSelectedItems() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db), chats = ChatStore(db)
        let a = try conversation(db), b = try conversation(db), other = try conversation(db)
        let project = ChatProject(title: "문서", goal: "작성")
        try store.save(project)
        let selected = [a.id, b.id].map { "conversation:\($0)" }
        try store.move(selected, to: project.id)
        XCTAssertEqual(try chats.conversations().filter { $0.projectID == project.id }.count, 2)
        XCTAssertNil(try chats.conversations().first { $0.id == other.id }?.projectID)
        try store.move(selected, to: nil)
        XCTAssertTrue(try chats.conversations().allSatisfy { $0.projectID == nil })
        try chats.deleteConversations([a.id, b.id])
        XCTAssertEqual(try chats.conversations().map(\.id), [other.id])
        XCTAssertTrue(try chats.messages(a.id).isEmpty)
        XCTAssertTrue(try chats.messages(b.id).isEmpty)
        XCTAssertFalse(try chats.messages(other.id).isEmpty)
    }

    func testBulkMoveRollsBackWhenAnyConversationIsMissing() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let chat = try conversation(db), project = ChatProject(title: "문서", goal: "작성")
        try store.save(project)
        XCTAssertThrowsError(try store.move(["conversation:\(chat.id)", "conversation:missing"], to: project.id))
        XCTAssertNil(try ChatStore(db).conversations().first?.projectID)
        XCTAssertTrue(try db.writer.read { try String.fetchAll($0, sql: "SELECT decision FROM project_reviewed").isEmpty })
    }

    private func task(_ db: SillogDatabase, title: String = "문서 작성") throws -> Int64 {
        try db.writer.write { try GraphTx($0).upsertNode(label: "Task", key: UUID().uuidString, subtype: nil, title: title, props: [:], at: 10) }
    }

    private func conversation(_ db: SillogDatabase, title: String = "문서 조사", paths: [String] = []) throws -> ChatConversation {
        var conversation = ChatConversation(); conversation.title = title; conversation.scope.paths = paths
        var user = ConversationMessage(conversationID: conversation.id, role: "user", text: title); user.createdAt = 10
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "문서 내용"); answer.createdAt = 11
        try ChatStore(db).startTurn(conversation: conversation, user: user, answer: answer)
        return conversation
    }

    func testProposalRequiresAcceptanceAndMembershipCanMove() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let taskID = try task(db), chat = try conversation(db)
        let ids = ["task:\(taskID)", "conversation:\(chat.id)"]
        try store.record([.init(title: "보고서", goal: "보고서 작성", reason: "같은 보고서의 조사와 작성", items: ids)], review: store.review())
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.items().allSatisfy { $0.projectID == nil })
        let proposal = try XCTUnwrap(store.proposals().first)
        let accepted = try store.accept(proposal.id, title: "최종 보고서")
        XCTAssertEqual(accepted.title, "최종 보고서")
        XCTAssertEqual(Set(try store.items().compactMap(\.projectID)), [accepted.id])
        XCTAssertTrue(try store.proposals().isEmpty)
        let other = ChatProject(title: "다른 프로젝트", goal: "다른 목표")
        try store.save(other)
        try store.move(ids[0], to: other.id)
        XCTAssertEqual(try store.items().first(where: { $0.id == ids[0] })?.projectID, other.id)
        XCTAssertEqual(try ChatStore(db).conversations().first?.projectID, accepted.id)
        try store.move(ids[1], to: nil)
        XCTAssertNil(try ChatStore(db).conversations().first?.projectID)
        // 이전 화면에 남은 대화 설정을 저장해도 사용자가 옮긴 소속을 되돌리지 않는다.
        try ChatStore(db).save(chat)
        XCTAssertNil(try ChatStore(db).conversations().first?.projectID)
    }

    func testInvalidAndDuplicateResponsesLeaveReviewUnchanged() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        _ = try task(db); _ = try conversation(db)
        let review = try store.review(), ids = review.items.map(\.id)
        let valid = ProjectSuggestion(title: "공통 목표", goal: "문서 작성", reason: "근거", items: ids)
        let invalid = ProjectSuggestion(title: "오류", goal: "목표", reason: "근거", items: [ids[0], "task:999999"])
        XCTAssertThrowsError(try store.record([valid, invalid], review: review))
        XCTAssertTrue(try store.proposals().isEmpty)
        XCTAssertEqual(try store.review().newIDs, review.newIDs)
        XCTAssertThrowsError(try store.record([valid, valid], review: review))
        XCTAssertTrue(try store.proposals().isEmpty)
        XCTAssertEqual(try store.review().newIDs, review.newIDs)
    }

    func testReviewedItemsCanSupportNewItemsWithoutReclassifyingManualChoices() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let old = try task(db), manual = try task(db, title: "별도 업무")
        let first = try store.review()
        try store.move("task:\(manual)", to: nil)
        try store.record([], review: first)
        XCTAssertTrue(try store.review().newIDs.isEmpty)
        let chat = try conversation(db), review = try store.review()
        XCTAssertEqual(review.newIDs, ["conversation:\(chat.id)"])
        XCTAssertTrue(review.items.contains { $0.id == "task:\(old)" })
        XCTAssertFalse(review.items.contains { $0.id == "task:\(manual)" })
        try store.record([.init(title: "보고서", goal: "문서 작성", reason: "기존 업무를 위한 새 조사", items: ["task:\(old)", "conversation:\(chat.id)"])], review: review)
        let proposal = try XCTUnwrap(store.proposals().first)
        let newer = try conversation(db, title: "보고서 검토")
        let next = try store.review()
        XCTAssertTrue(next.destinations.contains { $0.id == "proposal:\(proposal.id)" })
        try store.record([.init(target: "proposal:\(proposal.id)", title: "보고서", goal: "문서 작성", reason: "보고서 검토", items: ["conversation:\(newer.id)"])], review: next)
        XCTAssertEqual(try store.proposals().count, 1)
        XCTAssertEqual(try store.proposals().first?.items.count, 3)
        try store.dismiss(proposal.id)
        XCTAssertTrue(try store.review().items.isEmpty)
    }

    func testProjectScopeSharesOnlyCurrentMembersMaterialsAndConversations() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ownPath = directory.appendingPathComponent("own.txt").path, otherPath = directory.appendingPathComponent("other.txt").path
        var a = ChatProject(title: "프로젝트 A", goal: "A 목표")
        a.memoryMode = .projectOnly
        let b = ChatProject(title: "프로젝트 B", goal: "B 목표")
        try store.save(a); try store.save(b)
        let own = try conversation(db, paths: [ownPath]), other = try conversation(db, paths: [otherPath])
        try store.move("conversation:\(own.id)", to: a.id); try store.move("conversation:\(other.id)", to: b.id)
        var fresh = ChatConversation(); fresh.projectID = a.id
        let scope = try store.scope(for: fresh)
        XCTAssertTrue(scope.paths.isEmpty)
        XCTAssertEqual(scope.projectID, a.id)
        let search = ContextSearch(db, projectID: a.id, includeActivity: false)
        XCTAssertFalse(try search.search(query: "문서").isEmpty)
        XCTAssertFalse(try search.read("conversation:\(own.id)").isEmpty)
        XCTAssertTrue(try search.read("conversation:\(other.id)").isEmpty)
        let messageIDs = Set(try ChatStore(db).messages(own.id).map { "message:\($0.id)" })
        XCTAssertTrue(try search.search(query: "문서").allSatisfy { messageIDs.contains($0.id) })
        XCTAssertFalse(try ContextSearch(db).read("conversation:\(other.id)").isEmpty)
        let tools = ChatTools(db: db, scope: scope)
        XCTAssertThrowsError(try tools.allowedURL(ownPath))
        XCTAssertThrowsError(try tools.allowedURL(otherPath))
        a.paths = [ownPath]; try store.save(a)
        XCTAssertEqual(try store.scope(for: fresh).paths, [ownPath])
        try store.move("conversation:\(own.id)", to: b.id)
        XCTAssertEqual(try store.scope(for: fresh).paths, [ownPath])
        a.paths = []; try store.save(a)
        XCTAssertTrue(try store.scope(for: fresh).paths.isEmpty)
        XCTAssertTrue(try search.read("conversation:\(own.id)").isEmpty)
        try store.delete(b.id)
        XCTAssertEqual(try ChatStore(db).conversations().count, 2)
        XCTAssertTrue(try ChatStore(db).conversations().allSatisfy { $0.projectID == nil })
    }

    func testProjectSearchAndDirectReadsCannotEscapeThroughSharedResources() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        var a = ChatProject(title: "A", goal: "A 목표"); a.memoryMode = .projectOnly
        let b = ChatProject(title: "B", goal: "B 목표")
        try store.save(a); try store.save(b)
        let own = try task(db), other = try task(db)
        try store.move("task:\(own)", to: a.id); try store.move("task:\(other)", to: b.id)
        let shared = try db.writer.write { conn -> (Int64, Int64) in
            let tx = GraphTx(conn)
            let resource = try tx.upsertNode(label: "Resource", key: "resource", subtype: nil, title: "문서 자료", props: [:], at: 10)
            var foreignSession: Int64 = 0
            for task in [own, other] {
                let session = try tx.upsertNode(label: "Session", key: "session-\(task)", subtype: nil, title: "문서 작업", props: [:], at: 10)
                _ = try tx.upsertEdge(src: session, dst: task, type: "PART_OF", props: [:], addWeight: 0, at: 10)
                _ = try tx.upsertEdge(src: session, dst: resource, type: "TOUCHED", props: [:], addWeight: 0, at: 10)
                if task == other { foreignSession = session }
                try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, window_title, task_id) VALUES (10, 'test', 'test', 'test', '문서', ?)", arguments: [task])
                try conn.execute(sql: "INSERT INTO chat_messages(ts, tool, session_id, text, ingested_at, task_id) VALUES (10, 'test', ?, '문서', 10, ?)", arguments: ["session-\(task)", task])
            }
            return (resource, foreignSession)
        }
        let search = ContextSearch(db, projectID: a.id)
        XCTAssertTrue(try store.items().first(where: { $0.id == "task:\(own)" })?.summary.contains("문서 자료") == true)
        XCTAssertTrue(try search.read("node:\(other)").isEmpty)
        XCTAssertTrue(try search.read("node:\(shared.1)").isEmpty)
        XCTAssertFalse(try search.read("node:\(shared.0)").contains { $0.id == "node:\(shared.1)" })
        let foreignObservation = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM observations WHERE task_id = ?", arguments: [other])! }
        let foreignChat = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM chat_messages WHERE task_id = ?", arguments: [other])! }
        XCTAssertTrue(try search.read("observation:\(foreignObservation)").isEmpty)
        XCTAssertTrue(try search.read("chat:\(foreignChat)").isEmpty)
        let results = try search.search(query: "문서")
        XCTAssertTrue(results.contains { $0.id == "node:\(own)" })
        XCTAssertFalse(results.contains { ["node:\(other)", "node:\(shared.1)", "observation:\(foreignObservation)", "chat:\(foreignChat)"].contains($0.id) })
    }

    func testOrganizerReviewsEveryExistingItemOnceAndPreservesFailures() async throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db), client = ProjectTestClient()
        for _ in 0..<45 { _ = try task(db) }
        let first = try await ProjectOrganizer.run(db: db, llm: client)
        let second = try await ProjectOrganizer.run(db: db, llm: client)
        let third = try await ProjectOrganizer.run(db: db, llm: client)
        XCTAssertEqual(first, 40)
        XCTAssertEqual(second, 5)
        XCTAssertEqual(third, 0)
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(try store.review().newIDs.isEmpty)
        XCTAssertTrue(try store.projects().isEmpty)
        _ = try conversation(db)
        do { _ = try await ProjectOrganizer.run(db: db, llm: ProjectTestClient(fail: true)); XCTFail("모델 실패가 전달돼야 함") }
        catch { XCTAssertEqual(error as? LLMError, .transport("offline")) }
        XCTAssertEqual(try store.review().newIDs.count, 1)
    }

    func testCancellationDoesNotSaveProposalsOrReviewProgress() async throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        _ = try task(db); _ = try conversation(db)
        let before = try store.review().newIDs
        let (started, signal) = AsyncStream<Void>.makeStream()
        let client = ProjectTestClient(started: signal)
        let work = Task { try await ProjectOrganizer.run(db: db, llm: client) }
        var iterator = started.makeAsyncIterator(); _ = await iterator.next(); work.cancel()
        do { _ = try await work.value; XCTFail("취소된 검사가 저장되면 안 됨") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try store.review().newIDs, before)
        XCTAssertTrue(try store.proposals().isEmpty)
    }

    func testLegacyConversationDecodingAndNewProjectConversation() throws {
        let old = try JSONDecoder().decode(ChatConversation.self, from: Data(#"{"id":"old","title":"기존 대화","skillID":"general","scope":{},"updatedAt":1}"#.utf8))
        XCTAssertNil(old.projectID)
        XCTAssertNil(old.scope.projectID)
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db), chats = ChatStore(db)
        let project = ChatProject(title: "프로젝트", goal: "목표"); try store.save(project)
        var new = ChatConversation(); new.projectID = project.id
        try chats.startTurn(conversation: new, user: .init(conversationID: new.id, role: "user", text: "질문"), answer: .init(conversationID: new.id, role: "assistant", text: "답"))
        XCTAssertEqual(try chats.conversations().first?.projectID, project.id)
        let job = ChatAutomation(proposal: .init(title: "예약", prompt: "질문", intervalHours: 24), conversation: new)
        XCTAssertEqual(job.scope.projectID, project.id)
        try chats.save(job)
        try store.delete(project.id)
        XCTAssertEqual(try chats.automations().count, 1)
        XCTAssertNil(try chats.automations().first?.scope.projectID)
    }

    func testExistingDatabaseMigrationRetainsConversations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("legacy.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try SillogDatabase.migrator.migrate(queue, upTo: "v11-context-chat")
        try queue.write {
            try $0.execute(sql: "INSERT INTO app_conversations VALUES ('old', 1, ?)", arguments: [#"{"id":"old","title":"기존 대화","skillID":"general","scope":{},"updatedAt":1}"#])
        }
        let migrated = try SillogDatabase(path: path)
        XCTAssertEqual(try ChatStore(migrated).conversations().first?.title, "기존 대화")
        XCTAssertNil(try ChatStore(migrated).conversations().first?.projectID)
        XCTAssertTrue(try ProjectStore(migrated).projects().isEmpty)
        let reopened = try SillogDatabase(path: path)
        XCTAssertEqual(try ChatStore(reopened).conversations().count, 1)
    }

    func testExistingProjectSuggestionKeepsItsGoal() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let project = ChatProject(title: "기존 보고서", goal: "확정한 목표")
        try store.save(project)
        let id = try task(db)
        try store.record([.init(target: "project:\(project.id)", title: "모델이 바꾼 이름", goal: "모델이 바꾼 목표", reason: "같은 보고서", items: ["task:\(id)"])], review: store.review())
        let proposal = try XCTUnwrap(store.proposals().first)
        XCTAssertEqual(proposal.title, project.title)
        XCTAssertEqual(proposal.goal, project.goal)
        XCTAssertEqual(try store.accept(proposal.id, title: "무시할 이름").id, project.id)
        XCTAssertEqual(try store.projects().count, 1)
    }

    func testTaskMergePreservesProjectAndManualUnassignment() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        let a = ChatProject(title: "A", goal: "A 목표"), b = ChatProject(title: "B", goal: "B 목표")
        try store.save(a); try store.save(b)
        let first = try task(db), second = try task(db), unassigned = try task(db)
        try store.move("task:\(first)", to: a.id); try store.move("task:\(second)", to: b.id)
        try store.move("task:\(unassigned)", to: nil)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let firstKey = try XCTUnwrap(tx.node(id: first)).key
            let secondKey = try XCTUnwrap(tx.node(id: second)).key
            let unassignedKey = try XCTUnwrap(tx.node(id: unassigned)).key
            XCTAssertEqual(try TaskMerger.merge(.init(keep: firstKey, merge: [secondKey, unassignedKey]), conn: conn, now: 20), 0)
            XCTAssertNotNil(try tx.node(id: second))
            XCTAssertNotNil(try tx.node(id: unassigned))
            XCTAssertEqual(try TaskMerger.merge(.init(keep: unassignedKey, merge: [firstKey]), conn: conn, now: 21), 0)
        }
        let victim = try task(db), survivor = try task(db)
        try store.record([.init(title: "보고서", goal: "문서 작성", reason: "같은 보고서", items: ["task:\(victim)", "task:\(survivor)"])], review: store.review())
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            XCTAssertEqual(try TaskMerger.merge(.init(keep: XCTUnwrap(tx.node(id: survivor)).key, merge: [XCTUnwrap(tx.node(id: victim)).key]), conn: conn, now: 22), 0)
        }
        let proposal = try XCTUnwrap(store.proposals().first)
        XCTAssertEqual(Set(proposal.items.map(\.id)), ["task:\(victim)", "task:\(survivor)"])
        let accepted = try store.accept(proposal.id, title: proposal.title)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            XCTAssertEqual(try TaskMerger.merge(.init(keep: XCTUnwrap(tx.node(id: survivor)).key, merge: [XCTUnwrap(tx.node(id: victim)).key]), conn: conn, now: 23), 1)
        }
        XCTAssertEqual(try store.items().first(where: { $0.id == "task:\(survivor)" })?.projectID, accepted.id)
    }

    func testScreenCardScopeAppliesBeforeSearchLimit() throws {
        let db = try SillogDatabase.inMemory(), store = ProjectStore(db)
        var project = ChatProject(title: "보고서", goal: "문서 작성"); project.memoryMode = .projectOnly; try store.save(project)
        let own = try task(db), other = try task(db)
        try store.move("task:\(own)", to: project.id)
        let cards = try db.writer.write { conn -> [Int64] in
            var ids: [Int64] = []
            for i in 0..<14 {
                try conn.execute(sql: "INSERT INTO screen_cards(ts_start, ts_end, screen_hash, app_bundle, app_name, activity, content, kind, created_at) VALUES (?, ?, ?, 'test', 'test', '문서', '문서 내용', 'test', ?)", arguments: [i + 10, i + 10, i, i + 10])
                let id = conn.lastInsertedRowID; ids.append(id)
                try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, task_id, card_id) VALUES (?, 'test', 'test', 'test', ?, ?)", arguments: [i + 10, i == 0 ? own : other, id])
            }
            return ids
        }
        let search = ContextSearch(db, projectID: project.id)
        XCTAssertTrue(try search.search(query: "문서").contains { $0.id == "card:\(cards[0])" })
        XCTAssertTrue(try search.read("card:\(cards[1])").isEmpty)
        XCTAssertFalse(try search.read("card:\(cards[0])").isEmpty)
    }
}
