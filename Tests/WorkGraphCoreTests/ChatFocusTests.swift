import GRDB
import XCTest
@testable import WorkGraphCore

/// 채팅 초점: 업무·분야를 (여러 개) 고르면 그 기록만 찾는다 (다른 업무와 정리 전 기록은 빠진다)
final class ChatFocusTests: XCTestCase {
    private struct Seed {
        var flask: Int64, stats: Int64, algebra: Int64
        var observation: [String: Int64]
    }

    /// 업무 셋: Flask(프로젝트 분야, 세션 3), 통계학·선형대수(학업 분야). 업무마다 '보고서' 화면 기록 하나, 업무 없는(정리 전) 기록 하나
    private func seed(_ db: WGDatabase) throws -> Seed {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            func task(_ key: String, _ title: String, seconds: Double, last: Double, theme: String, sessions: Int) throws -> Int64 {
                let id = try tx.upsertNode(label: NodeLabel.task, key: key, subtype: nil, title: title,
                                           props: ["active_seconds": .number(seconds), "last_active": .number(last)], at: 1)
                try ThemeGraph.attach(taskId: id, to: theme, tx, now: 1)
                for index in 0..<sessions {
                    let session = try tx.upsertNode(label: NodeLabel.session, key: "\(key)-s\(index)", subtype: nil, title: "\(title) 작업",
                                                    props: ["start": .number(Double(index))], at: 1)
                    try tx.upsertEdge(src: session, dst: id, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1)
                }
                return id
            }
            let flask = try task("flask", "Flask 웹앱 개발", seconds: 9600, last: 300, theme: "프로젝트", sessions: 3)
            let stats = try task("stats", "통계학 수업", seconds: 3000, last: 200, theme: "학업", sessions: 1)
            let algebra = try task("algebra", "선형대수 과제", seconds: 1200, last: 100, theme: "학업", sessions: 1)
            var observation: [String: Int64] = [:]
            for (name, id) in [("flask", Optional(flask)), ("stats", stats), ("algebra", algebra), ("none", nil)] {
                try conn.execute(sql: "INSERT INTO observations(ts, trigger_kind, app_bundle, app_name, window_title, task_id) VALUES (10, 'test', 'test', 'test', ?, ?)",
                                 arguments: ["\(name) 보고서", id])
                observation[name] = conn.lastInsertedRowID
            }
            return Seed(flask: flask, stats: stats, algebra: algebra, observation: observation)
        }
    }

    private func conversation(_ db: WGDatabase, focus: [ChatFocus]) throws -> ChatConversation {
        var conversation = ChatConversation(); conversation.title = "배포 논의"; conversation.scope.focus = focus
        var user = ConversationMessage(conversationID: conversation.id, role: "user", text: "배포 계획 정리"); user.createdAt = 10
        var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "배포 계획은 이렇습니다"); answer.createdAt = 11
        try ChatStore(db).startTurn(conversation: conversation, user: user, answer: answer)
        return conversation
    }

    private let flask = ChatFocus(kind: .task, key: "flask", title: "Flask 웹앱 개발")
    private let study = ChatFocus(kind: .theme, key: "학업", title: "학업")
    private let algebra = ChatFocus(kind: .task, key: "algebra", title: "선형대수 과제")

    func testATaskFocusFindsOnlyThatTasksRecords() throws {
        let db = try WGDatabase.inMemory(), seed = try seed(db)
        let search = ContextSearch(db, focus: [flask])
        let found = Set(try search.search(query: "보고서").map(\.id))
        XCTAssertTrue(found.contains("observation:\(seed.observation["flask"]!)"), "\(found)")
        for other in ["stats", "algebra", "none"] {
            XCTAssertFalse(found.contains("observation:\(seed.observation[other]!)"), "\(other) 기록은 빠져야 한다 (none 은 정리 전 기록): \(found)")
        }
        XCTAssertTrue(try search.read("observation:\(seed.observation["stats"]!)").isEmpty, "다른 업무 원문은 이어 읽기로도 못 본다")
        XCTAssertTrue(try search.read("node:\(seed.stats)").isEmpty)
        XCTAssertFalse(try search.read("node:\(seed.flask)").isEmpty)
        var scope = ChatScope(); scope.focus = [flask]
        XCTAssertEqual(Set(try ChatTools(db: db, scope: scope).search.search(query: "보고서").map(\.id)), found, "채팅 도구도 같은 초점으로 찾는다")
    }

    func testSeveralFocusesAreSearchedTogether() throws {
        let db = try WGDatabase.inMemory(), seed = try seed(db)
        let found = Set(try ContextSearch(db, focus: [flask, algebra]).search(query: "보고서").map(\.id))
        for name in ["flask", "algebra"] { XCTAssertTrue(found.contains("observation:\(seed.observation[name]!)"), "\(name): \(found)") }
        for name in ["stats", "none"] { XCTAssertFalse(found.contains("observation:\(seed.observation[name]!)"), "\(name): \(found)") }
    }

    func testAThemeFocusCoversEveryTaskInTheTheme() throws {
        let db = try WGDatabase.inMemory(), seed = try seed(db)
        let found = Set(try ContextSearch(db, focus: [study]).search(query: "보고서").map(\.id))
        XCTAssertTrue(found.contains("observation:\(seed.observation["stats"]!)"), "\(found)")
        XCTAssertTrue(found.contains("observation:\(seed.observation["algebra"]!)"), "\(found)")
        XCTAssertFalse(found.contains("observation:\(seed.observation["flask"]!)"), "\(found)")
        XCTAssertFalse(found.contains("observation:\(seed.observation["none"]!)"), "\(found)")
    }

    func testAFocusedChatRecallsOnlyConversationsSharingAFocus() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let shared = try conversation(db, focus: [flask, study]), unfocused = try conversation(db, focus: []), elsewhere = try conversation(db, focus: [algebra])
        let search = ContextSearch(db, focus: [flask])
        let messages = try search.search(query: "배포 계획").map(\.id).filter { $0.hasPrefix("message:") }
        let sharedIDs = Set(try ChatStore(db).messages(shared.id).map { "message:\($0.id)" })
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.allSatisfy { sharedIDs.contains($0) }, "고른 업무·분야가 하나라도 겹치는 대화만: \(messages)")
        XCTAssertFalse(try search.read("conversation:\(shared.id)").isEmpty)
        XCTAssertTrue(try search.read("conversation:\(unfocused.id)").isEmpty)
        XCTAssertTrue(try search.read("conversation:\(elsewhere.id)").isEmpty)
    }

    func testChoicesListThemesAndTasksByRecentWork() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let choices = try ContextSearch(db).focusChoices()
        XCTAssertEqual(choices.tasks.map(\.focus.title), ["Flask 웹앱 개발", "통계학 수업", "선형대수 과제"])
        XCTAssertEqual(choices.tasks.first?.theme, "프로젝트")
        XCTAssertEqual(choices.tasks.map(\.themeKey), ["프로젝트", "학업", "학업"], "나무로 묶을 분야 key")
        XCTAssertEqual(choices.themes.map(\.focus), [ChatFocus(kind: .theme, key: "프로젝트", title: "프로젝트"), ChatFocus(kind: .theme, key: "학업", title: "학업")],
                       "최근에 일한 분야 먼저")
        XCTAssertEqual(choices.themes.map(\.taskCount), [1, 2])
    }

    func testChoicesFollowAPrivateProject() throws {
        let db = try WGDatabase.inMemory(), seed = try seed(db), store = ProjectStore(db)
        var project = ChatProject(title: "졸업", goal: ""); project.memoryMode = .projectOnly
        try store.save(project)
        try store.move("task:\(seed.flask)", to: project.id)
        XCTAssertFalse(try ContextSearch(db).focusChoices().tasks.contains { $0.focus.key == "flask" }, "전용 프로젝트 밖에서는 그 업무를 고를 수 없다")
        XCTAssertEqual(try ContextSearch(db, projectID: project.id).focusChoices().tasks.map(\.focus.key), ["flask"])
    }

    func testMergingATaskCarriesTheFocusAlong() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let stats = ChatFocus(kind: .task, key: "stats", title: "통계학 수업")
        let chat = try conversation(db, focus: [algebra, flask]), both = try conversation(db, focus: [algebra, stats])
        var source = ChatConversation(); source.scope.focus = [algebra]
        try ChatStore(db).save(ChatAutomation(proposal: .init(title: "주간 정리", prompt: "정리해 줘", intervalHours: 24), conversation: source))
        _ = try db.writer.write { try TaskMerger.merge(.init(keep: "stats", merge: ["algebra"]), conn: $0, now: 20) }
        let conversations = try ChatStore(db).conversations()
        XCTAssertEqual(conversations.first { $0.id == chat.id }?.scope.focus, [stats, flask], "대화 범위의 그 업무만 남는 업무로 바뀐다")
        XCTAssertEqual(conversations.first { $0.id == both.id }?.scope.focus, [stats], "합친 뒤 겹친 업무는 하나로")
        XCTAssertEqual(try ChatStore(db).automations().first?.scope.focus, [stats], "예약도")
        XCTAssertTrue(try ContextSearch.exists(stats, in: db))
        XCTAssertFalse(try ContextSearch.exists(algebra, in: db), "합쳐져 사라진 업무")
    }

    func testTheScopeRemembersTheFocusAndReadsOldPayloads() throws {
        var scope = ChatScope(); scope.focus = [study, flask]
        XCTAssertEqual(try JSONDecoder().decode(ChatScope.self, from: JSONEncoder().encode(scope)).focus, scope.focus)
        XCTAssertEqual(try JSONDecoder().decode(ChatScope.self, from: Data(#"{"paths":[],"useActivity":true}"#.utf8)).focus, [], "초점 이전에 저장한 대화")
        let single = #"{"useActivity":true,"focus":{"kind":"task","key":"flask","title":"Flask 웹앱 개발"}}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatScope.self, from: Data(single.utf8)).focus, [flask], "하나만 고르던 때의 대화도 읽는다")
    }

    func testTheOutlineTellsWhatTheFocusCovers() throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        let task = try XCTUnwrap(try ContextSearch(db, focus: [flask]).focusOutline())
        for part in ["selected: 업무 Flask 웹앱 개발", "- Flask 웹앱 개발", "약 2시간 40분", "세션 3개"] {
            XCTAssertTrue(task.contains(part), "\(part): \(task)")
        }
        let theme = try XCTUnwrap(try ContextSearch(db, focus: [study]).focusOutline())
        for part in ["selected: 분야 학업", "- 통계학 수업", "- 선형대수 과제"] {
            XCTAssertTrue(theme.contains(part), "\(part): \(theme)")
        }
        XCTAssertFalse(theme.contains("Flask"), theme)
        let both = try XCTUnwrap(try ContextSearch(db, focus: [study, flask]).focusOutline())
        XCTAssertTrue(both.contains("selected: 분야 학업, 업무 Flask 웹앱 개발"), both)
        XCTAssertTrue(both.contains("- Flask 웹앱 개발") && both.contains("- 통계학 수업"), both)
        XCTAssertNil(try ContextSearch(db).focusOutline(), "초점이 없으면 블록도 없다")
    }

    func testThePromptHasAFocusBlockOnlyWhenChosen() throws {
        var prompt = ChatSystemPrompt(template: try ChatSystemPrompt.template(), scope: ChatScope(), chatModel: "gpt-test", scheduled: false)
        prompt.focus = "selected: 업무 Flask 웹앱 개발"
        XCTAssertTrue(prompt.render(role: nil).contains("<focus>\nselected: 업무 Flask 웹앱 개발\n</focus>"))
        XCTAssertFalse(prompt.render(role: "review").contains("<focus>\n"), "하위 에이전트는 위임받은 문장만 본다")
        prompt.focus = nil
        XCTAssertFalse(prompt.render(role: nil).contains("<focus>\n"))
    }

    // 프로젝트 화면이 빠졌으니 지침도 없는 화면(제안, 프로젝트 +, 프로젝트 자료로 저장)을 가리키지 않는다
    func testThePromptNoLongerPointsToProjectScreens() throws {
        let template = try ChatSystemPrompt.template()
        for gone in ["프로젝트 자료로 저장", "the + next to 프로젝트", "제안 lists suggested projects"] {
            XCTAssertFalse(template.contains(gone), gone)
        }
    }

    func testTheRunnerTellsTheModelTheFocus() async throws {
        let db = try WGDatabase.inMemory(); _ = try seed(db)
        var scope = ChatScope(); scope.focus = [flask]
        let model = FocusCapturingModel()
        _ = try await ChatRunner(client: model, tools: ChatTools(db: db, scope: scope))
            .run(history: [ConversationMessage(conversationID: "c", role: "user", text: "요약해 줘")], skillIDs: []) { _ in }
        let system = await model.systems.first ?? ""
        XCTAssertTrue(system.contains("<focus>\nselected: 업무 Flask 웹앱 개발"), system.suffix(1200).description)
    }
}

private actor FocusCapturingModel: ChatModelClient {
    nonisolated var modelName: String { "focus-test" }
    var systems: [String] = []
    func respond(system: String, messages: [ChatModelMessage], tools: [ToolSpec], onText: @escaping @Sendable (String) async -> Void) async throws -> ChatModelReply {
        systems.append(system)
        return .init(text: "요약입니다")
    }
}
