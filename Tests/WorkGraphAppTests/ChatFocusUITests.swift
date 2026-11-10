import AppKit
import SwiftUI
import XCTest
@testable import WorkGraphApp
@testable import WorkGraphCore

/// 채팅 범위: 채팅 탭은 업무 목록 없이, 분야→업무 나무로 여러 개 고르는 범위(첫 화면과 입력창 위 단추)와 업무 드로어의 '이 업무로 묻기'
@MainActor
final class ChatFocusUITests: XCTestCase {
    private let flask = TaskSummary(id: 1, key: "flask", title: "Flask 웹앱 개발", taskType: nil, activeSeconds: 9600, lastActive: 300, sessionCount: 3, theme: "프로젝트")
    private let flaskFocus = ChatFocus(kind: .task, key: "flask", title: "Flask 웹앱 개발")
    private let statsFocus = ChatFocus(kind: .task, key: "stats", title: "통계학 수업")

    private func chatState(_ database: WGDatabase) -> ChatState {
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)   // 그리기만 하고 부르지 않는다
        return ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
    }

    /// 채팅 탭을 연 창의 글자. AppState 에는 DB 를 안 줘서(정리 대기 수를 DB 가 덮어쓰지 않게) 채팅만 DB 를 쓴다
    private func text(seed: (WGDatabase) throws -> Void = { _ in }, _ configure: (AppState) -> Void) throws -> String {
        let database = try WGDatabase.inMemory()
        try seed(database)
        let state = AppState(preview: { s in
            s.phase = .ready; s.selectedTab = .chat; s.taskList = [flask]
            s.chat = chatState(database)
            configure(s)
        })
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return OnboardingOverlayTests.recognizedText(host).filter { !$0.isWhitespace }
    }

    func testTheChatTabHasNoTaskList() throws {
        let text = try text { _ in }
        XCTAssertFalse(text.contains("Flask웹앱개발"), "채팅 탭에서는 왼쪽 업무 목록이 안 보인다: \(text)")
    }

    func testTheScopeLabelSaysWhatTheChatLooksAt() {
        let study = ChatFocus(kind: .theme, key: "학업", title: "학업")
        var scope = ChatScope()
        XCTAssertEqual(ChatFocusButton.label(scope, choices: .init()), "모든 기록")
        scope.focus = [flaskFocus]
        XCTAssertEqual(ChatFocusButton.label(scope, choices: .init()), "Flask 웹앱 개발")
        scope.focus = [study]
        XCTAssertEqual(ChatFocusButton.label(scope, choices: .init()), "학업 분야")
        XCTAssertEqual(ChatFocusButton.label(scope, choices: ChatFocusChoices(themes: [.init(focus: study, taskCount: 6)])), "학업 · 업무 6")
        scope.focus = [flaskFocus, statsFocus]
        XCTAssertEqual(ChatFocusButton.label(scope, choices: .init()), "Flask 웹앱 개발 외 1", "여럿이면 첫 이름 외 n")
        scope.useActivity = false
        XCTAssertEqual(ChatFocusButton.label(scope, choices: .init()), "기록 안 씀")
    }

    // 범위는 첫 화면 나무에서 고르고 입력창 윗줄에는 없다. 대화를 시작하면 머리(제목 아래)에 고른 범위가 작게 보이고, 누르면 같은 나무로 바꾼다
    func testTheScopeLivesInTheHeaderNotAboveTheInput() throws {
        let fresh = try text { _ in }                                                     // 업무가 없는 새 대화: 나무도 머리 표시도 없다
        XCTAssertFalse(fresh.contains("모든기록"), "입력창 윗줄에 범위 단추가 없다: \(fresh)")
        let started = try text(seed: { db in
            var conversation = ChatConversation(); conversation.title = "보고서 정리"
            conversation.scope.focus = [ChatFocus(kind: .theme, key: "학업", title: "학업")]
            try ChatStore(db).startTurn(conversation: conversation, user: ConversationMessage(conversationID: conversation.id, role: "user", text: "이번 주 정리"),
                                        answer: ConversationMessage(conversationID: conversation.id, role: "assistant", text: "정리했어요"))
        }) { _ in }
        XCTAssertTrue(started.contains("학업분야"), "시작한 대화는 머리에 고른 범위 (목록 줄은 '학업'만): \(started)")
    }

    func testAFocusedChatPointsOutRecordsWaitingToBeTidied() throws {
        let focused = try text { s in s.pendingCount = 12; s.chat?.current.scope.focus = [flaskFocus] }
        XCTAssertTrue(focused.contains("정리전최근기록12건"), "정리 전 기록은 아직 업무가 없어 범위에서 빠진다는 안내: \(focused)")
        let all = try text { s in s.pendingCount = 12 }
        XCTAssertFalse(all.contains("정리전최근기록"), "모든 기록일 때는 안내가 없다: \(all)")
    }

    func testTheConversationListShowsEachChatsFocus() throws {
        let text = try text(seed: { db in
            var conversation = ChatConversation(); conversation.title = "배포 논의"; conversation.scope.focus = [flaskFocus]
            try ChatStore(db).startTurn(conversation: conversation, user: ConversationMessage(conversationID: conversation.id, role: "user", text: "배포 계획"),
                                        answer: ConversationMessage(conversationID: conversation.id, role: "assistant", text: "정리했어요"))
        }) { s in s.chat?.newConversation() }                                     // 지금 대화는 새 대화(모든 기록): 업무 이름은 목록 줄에서만
        XCTAssertTrue(text.contains("배포논의"), text)
        XCTAssertTrue(text.contains("Flask웹앱개발"), "대화 제목 아래에 그 대화의 범위: \(text)")
    }

    func testAskingAboutATaskOpensAChatFocusedOnIt() throws {
        let database = try WGDatabase.inMemory()
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .graph; s.taskList = [flask]; s.chat = chatState(database) })
        state.selectedTaskId = 1; state.taskDetailOpen = true
        state.askAbout(task: flask)
        XCTAssertEqual(state.selectedTab, .chat)
        XCTAssertFalse(state.taskDetailOpen, "드로어는 닫고 채팅으로")
        XCTAssertEqual(state.chat?.current.scope.focus, [flaskFocus])
        XCTAssertEqual(state.chat?.messages.count, 0, "새 대화")
    }

    func testAskingAboutAFieldFocusesOnTheTheme() throws {
        let database = try WGDatabase.inMemory()
        try database.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "stats", subtype: nil, title: "통계학 수업", props: [:], at: 1)
            try ThemeGraph.attach(taskId: task, to: "학업", tx, now: 1)
        }
        let state = AppState(preview: { s in s.phase = .ready; s.chat = chatState(database) }, database: database)
        state.askAbout(theme: "학업")
        XCTAssertEqual(state.chat?.current.scope.focus, [ChatFocus(kind: .theme, key: "학업", title: "학업")])
        XCTAssertEqual(state.selectedTab, .chat)
    }

    /// 업무 둘(세션 있음): Flask(개발 분야), 통계학(학업 분야)
    private func seedTasks(_ db: WGDatabase) throws {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            for (index, (key, title, theme)) in [("flask", "Flask 웹앱 개발", "개발"), ("stats", "통계학 수업", "학업")].enumerated() {
                let task = try tx.upsertNode(label: NodeLabel.task, key: key, subtype: nil, title: title, props: ["last_active": .number(Double(100 - index))], at: 1)
                try ThemeGraph.attach(taskId: task, to: theme, tx, now: 1)
                let session = try tx.upsertNode(label: NodeLabel.session, key: "\(key)-s", subtype: nil, title: title, props: [:], at: 1)
                try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1)
            }
        }
    }

    // 새 대화 첫 화면에서 바로: 분야 칩 아래 업무 목록, 체크로 여러 개
    func testANewChatOffersFieldsAndTasksAsATree() throws {
        let text = try text(seed: seedTasks) { _ in }
        for part in ["무엇에대해이야기할까요", "모든기록", "개발", "Flask웹앱개발", "학업", "통계학수업", "기록안씀"] {
            XCTAssertTrue(text.contains(part), "\(part): \(text)")
        }
    }

    private func item(_ key: String, _ title: String, field: String?, themeKey: String? = nil) -> ChatFocusChoices.TaskItem {
        .init(focus: ChatFocus(kind: .task, key: key, title: title), theme: themeKey, themeKey: themeKey, field: field)
    }

    func testTaskChecksAddAndRemoveOneByOne() {
        let a = item("a", "A", field: "학습"), b = item("b", "B", field: "학습")
        XCTAssertEqual(ChatFocusTree.toggle(a, tasks: [a, b], selection: []), [a.focus])
        XCTAssertEqual(ChatFocusTree.toggle(b, tasks: [a, b], selection: [a.focus]), [a.focus, b.focus], "여러 개")
        XCTAssertEqual(ChatFocusTree.toggle(a, tasks: [a, b], selection: [a.focus]), [])
    }

    func testAStoredThemeFocusStillWorks() {
        let a = item("a", "A", field: "학업", themeKey: "학업"), b = item("b", "B", field: "학업", themeKey: "학업")
        let theme = ChatFocus(kind: .theme, key: "학업", title: "학업")
        XCTAssertTrue(ChatFocusTree.isOn(b, tasks: [a, b], selection: [theme]), "분야 범위는 안의 업무가 체크로 보인다")
        XCTAssertEqual(ChatFocusTree.toggle(a, tasks: [a, b], selection: [theme]), [b.focus], "하나를 빼면 나머지 업무로 풀린다")
    }

    func testChipsOnlyFilterTheList() {
        let a = item("a", "통계학 수업", field: "학습"), b = item("b", "Flask 앱", field: "산출물작성"), c = item("c", "메모", field: nil)
        XCTAssertEqual(ChatFocusTree.visible([a, b, c], filter: [], query: "").count, 3, "처음엔 전부")
        XCTAssertEqual(ChatFocusTree.visible([a, b, c], filter: ["학습", "산출물작성"], query: "").map(\.focus.key), ["a", "b"], "여러 칩")
        XCTAssertEqual(ChatFocusTree.visible([a, b, c], filter: [], query: "통계").map(\.focus.key), ["a"])
        XCTAssertEqual(ChatFocusTree.visible([a, b, c], filter: ["산출물작성"], query: "통계").count, 0, "칩과 검색은 함께 걸린다")
        XCTAssertEqual(ChatFocusTree.fields(.init(tasks: [a, b, c])).map(\.name), ["학습", "산출물작성", "분야 없음"])
    }

    func testPickingAStartChoiceFocusesTheChatAndTheInput() throws {
        let chat = chatState(try WGDatabase.inMemory())
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .chat; s.chat = chat })
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(window.firstResponder is ChatTextView, "처음엔 입력칸에 커서가 없다")
        chat.setFocus([flaskFocus])
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(chat.current.scope.focus, [flaskFocus])
        XCTAssertTrue(chat.current.scope.useActivity)
        XCTAssertTrue(window.firstResponder is ChatTextView, "고르면 바로 쓸 수 있게 입력칸으로: \(String(describing: window.firstResponder))")
    }

    func testThePlaceholderNamesTheChosenScope() throws {
        let text = try text { s in s.chat?.current.scope.focus = [flaskFocus] }
        XCTAssertTrue(text.contains("Flask웹앱개발에대해물어보세요"), text)
    }

    func testSidebarShowsProjectsAndTheirConversations() throws {
        let text = try text(seed: { db in
            let store = ProjectStore(db)
            let project = ChatProject(title: "졸업 프로젝트", goal: "")
            try store.save(project)
            var conversation = ChatConversation(); conversation.title = "졸업 논의"
            try ChatStore(db).startTurn(conversation: conversation, user: ConversationMessage(conversationID: conversation.id, role: "user", text: "일정"),
                                        answer: ConversationMessage(conversationID: conversation.id, role: "assistant", text: "정리했어요"))
            try store.move("conversation:\(conversation.id)", to: project.id)
        }) { s in s.chat?.newConversation() }
        XCTAssertTrue(text.contains("졸업논의"), "프로젝트에 있던 대화도 대화 목록에: \(text)")
        XCTAssertTrue(text.contains("졸업프로젝트"), text)
        XCTAssertFalse(text.contains("제안"), "프로젝트 제안도 없다: \(text)")
    }

    func testStartingTheChatDoesNotAskForProjectSuggestions() throws {
        let chat = chatState(try WGDatabase.inMemory())
        chat.startScheduler()
        XCTAssertFalse(chat.projects.checking, "프로젝트 자동 제안(모델 호출)은 돌리지 않는다")
        chat.stop()
    }

    func testBulkActionsUpdateCurrentProjectAndProtectRunningChat() throws {
        let db = try WGDatabase.inMemory(), store = ChatStore(db)
        var first = ChatConversation(); first.title = "첫 대화"
        var second = ChatConversation(); second.title = "둘째 대화"
        for conversation in [first, second] {
            try store.save(conversation)
        }
        let project = ChatProject(title: "검토", goal: "공동 검토")
        try ProjectStore(db).save(project)
        let chat = chatState(db)
        chat.select(first)
        let ids: Set<String> = [first.id, second.id]
        try chat.moveConversations(ids, to: project.id)
        XCTAssertEqual(chat.current.projectID, project.id)
        XCTAssertEqual(chat.conversations.filter { $0.projectID == project.id }.count, 2)
        chat.activeMessage = ConversationMessage(conversationID: first.id, role: "assistant", text: "")
        XCTAssertThrowsError(try chat.deleteConversations(ids))
        XCTAssertThrowsError(try chat.moveConversations(ids, to: nil))
        XCTAssertEqual(try store.conversations().count, 2)
        chat.activeMessage = nil
        try chat.deleteConversations(ids)
        XCTAssertTrue(chat.conversations.isEmpty)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(ids.contains(chat.current.id))
    }

    func testTaskRowsHaveNoProjectLabel() throws {
        let text = try text(seed: { db in
            try seedTasks(db)
            let store = ProjectStore(db)
            let project = ChatProject(title: "졸업 과제", goal: "")
            try store.save(project)
            try store.move("task:1", to: project.id)
        }) { s in s.selectedTab = .graph }
        XCTAssertTrue(text.contains("Flask웹앱개발"), text)
        XCTAssertFalse(text.contains("졸업과제"), "업무 줄에 프로젝트 이름이 없다: \(text)")
    }

    func testTheLibraryHasNoProjectFilter() throws {
        let text = try text { s in s.selectedTab = .chat; s.showsChatResultsOnOpen = true }
        XCTAssertTrue(text.contains("전체종류"), text)
        XCTAssertFalse(text.contains("전체프로젝트"), "보관함에 프로젝트 걸러보기가 없다: \(text)")
    }

    func testSendingWithAVanishedFocusSaysSoAndFallsBackToAllRecords() throws {
        let chat = chatState(try WGDatabase.inMemory())
        chat.current.scope.focus = [ChatFocus(kind: .task, key: "gone", title: "사라진 업무")]
        chat.draft = "요약해 줘"
        chat.send()
        XCTAssertFalse(chat.running, "좁힌 범위를 잃은 채로 보내지 않는다")
        XCTAssertEqual(chat.current.scope.focus, [], "범위는 모든 기록으로")
        XCTAssertEqual(chat.draft, "요약해 줘", "쓴 글은 남긴다")
        XCTAssertTrue(chat.error?.contains("사라진 업무") == true, chat.error ?? "")
    }
}
