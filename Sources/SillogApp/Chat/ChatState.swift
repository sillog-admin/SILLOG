import AppKit
import Combine
import Foundation
import SillogCore

@MainActor
final class ChatState: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var conversationPreviews: [String: String] = [:]
    @Published var current = ChatConversation() {
        didSet {
            if current.id != oldValue.id || current.projectID != oldValue.projectID {
                library.showAttachments(conversationID: current.id, projectID: current.projectID)
            }
        }
    }
    @Published var messages: [ConversationMessage] = []
    @Published var skills: [ChatSkill] = []
    @Published private(set) var pinnedSkillIDs: [String] = []
    var pinnedSkills: [ChatSkill] { pinnedSkillIDs.compactMap { id in skills.first { $0.id == id } } }
    @Published var automations: [ChatAutomation] = []
    @Published var draft = ""
    @Published var draftConnectors: [String] = []
    @Published var error: String?
    @Published var openArtifactID: String?
    @Published var activeMessage: ConversationMessage?
    /// 범위 단추의 고를 거리: 이 대화에서 볼 수 있는 분야·업무
    @Published var focusChoices = ChatFocusChoices()
    /// 늘어나면 입력칸으로 커서를 옮긴다 (범위를 고르면 바로 쓸 수 있게)
    @Published var inputFocusRequest = 0
    let projects: ProjectState
    let library: LibraryState
    private let db: SillogDatabase
    private let store: ChatStore
    private let makeClient: () -> ChatBackend
    private var runTask: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var titleTask: Task<Void, Never>?
    // shortcut: in memory only, lost on quit; persist if users ask for it.
    private var drafts: [String: String] = [:]
    private var pendingText = ""
    private var textFlush: Task<Void, Never>?
    var running: Bool { activeMessage != nil }

    /// Args: db는 앱 DB, makeClient는 현재 설정으로 모델 연결을 생성한다.
    /// Returns: 저장된 대화와 스킬을 불러온 채팅 상태.
    /// Raises: 없음. 초기화 오류는 화면에 표시한다.
    init(db: SillogDatabase, makeClient: @escaping () -> ChatBackend, makeProjectClient: @escaping () -> any LLMClient) {
        self.db = db; self.store = ChatStore(db); self.makeClient = makeClient
        projects = ProjectState(db: db, makeClient: makeProjectClient)
        library = LibraryState(db: db)
        library.onChange = { [weak self] in self?.projects.reload() }
        library.showAttachments(conversationID: current.id, projectID: current.projectID)
        projects.onChange = { [weak self] in
            guard let self else { return }
            do {
                try self.reload()
                if let saved = self.conversations.first(where: { $0.id == self.current.id }) { self.current.projectID = saved.projectID }
                else if !self.projects.projects.contains(where: { $0.id == self.current.projectID }) { self.current.projectID = nil }
            } catch { self.error = error.localizedDescription }
        }
        do {
            try store.recoverInterruptedRuns()
            skills = try store.skills()
            pinnedSkillIDs = try store.pinnedSkillIDs()
            try reload()                                  // 처음엔 최근 대화가 아니라 새 대화(홈)로 시작
        } catch { self.error = error.localizedDescription }
        refreshFocusChoices()
        // shortcut: crash still loses unflushed text, checkpoint in flushText if crashes matter.
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushText()
                if let message = self.activeMessage { try? self.store.save(message) }
            }
        }
    }

    /// Args: 없음.
    /// Returns: 없음. 범위 단추가 보여 줄 분야·업무를 다시 읽는다 (지금 대화의 프로젝트 범위 안에서).
    /// Raises: 없음. 읽기 오류면 고를 거리가 비어 모든 기록만 남는다.
    /// Args: focus는 고른 업무·분야(비면 모든 기록), movesCursor면 입력칸으로 커서를 옮긴다.
    /// Returns: 없음. 대화 범위를 바꾼다.
    /// Raises: 없음.
    func setFocus(_ focus: [ChatFocus], movesCursor: Bool = true) {
        current.scope.focus = focus
        current.scope.useActivity = true
        if movesCursor { inputFocusRequest += 1 }
    }

    /// Args: 없음.
    /// Returns: 없음. 내 기록을 쓰지 않는다 (웹·파일·보관함만).
    /// Raises: 없음.
    func useNoRecords() {
        current.scope.focus = []
        current.scope.useActivity = false
    }

    /// First questions for an empty chat: two fixed ones, then the two most recently worked tasks.
    var starterPrompts: [(prompt: String, focus: ChatFocus?)] {
        [(tr("오늘 한 일 정리해 줘"), nil), (tr("이번 주 업무 보고서 만들어 줘"), nil)]
            + focusChoices.tasks.prefix(2).map { (tr("\($0.focus.title) 진행 상황 정리해 줘"), $0.focus) }
    }

    func useStarter(_ prompt: String, focus: ChatFocus?) {
        draft = prompt
        if let focus { setFocus([focus]) } else { inputFocusRequest += 1 }
    }

    func refreshFocusChoices() {
        let fresh = (try? ContextSearch(db, projectID: current.projectID).focusChoices()) ?? ChatFocusChoices()
        if fresh != focusChoices { focusChoices = fresh }
    }

    /// 스킬을 추가하거나 같은 ID로 수정한다. 선택 상태는 사용자가 바꾼다.
    func saveSkill(id: String?, title: String, summary: String, instructions: String) throws {
        if let id {
            guard let index = skills.firstIndex(where: { $0.id == id }) else {
                throw ChatToolError.unavailable(tr("이 스킬이 이미 삭제됐어요."))
            }
            let updated = try store.updateSkill(skills[index], title: title, instructions: instructions, summary: summary)
            skills[index] = updated
        } else {
            skills.append(try store.addSkill(title: title, instructions: instructions, summary: summary))
        }
    }

    func deleteSkill(_ skill: ChatSkill) throws {
        try store.deleteSkill(skill)
        skills.removeAll { $0.id == skill.id }
        pinnedSkillIDs.removeAll { $0 == skill.id }
        if current.skillIDs.contains(skill.id) {
            current.skillIDs.removeAll { $0 == skill.id }
            saveScope()
        }
    }

    func selectSkill(_ id: String) {
        guard skills.contains(where: { $0.id == id }), !current.skillIDs.contains(id) else { return }
        current.skillIDs.append(id)
    }

    func togglePinnedSkill(_ id: String) {
        var ids = pinnedSkillIDs
        if ids.contains(id) { ids.removeAll { $0 == id } }
        else { ids.append(id) }
        do {
            try store.setPinnedSkills(ids)
            pinnedSkillIDs = ids
        } catch { self.error = error.localizedDescription }
    }

    func newConversation(projectID: String? = nil, focus: [ChatFocus] = []) {
        // Commits pending IME text into the old draft before the draft changes.
        _ = NSApp?.keyWindow?.makeFirstResponder(nil)
        draftConnectors = []
        openArtifactID = nil
        // Coming back to the chat tab also lands here, so an unsent home draft is kept.
        let kept = messages.isEmpty ? draft : (drafts.removeValue(forKey: "") ?? "")
        if !messages.isEmpty { stashDraft() }
        current = ChatConversation(); current.projectID = projectID; current.scope.focus = focus; messages = []; draft = kept; error = nil
        if !focus.isEmpty { refreshFocusChoices() }
        inputFocusRequest += 1
    }

    // The unsaved home chat gets a new id each time, so its draft sits under one fixed key.
    private func stashDraft() { drafts[messages.isEmpty ? "" : current.id] = draft.isEmpty ? nil : draft }

    /// Args: conversation은 선택한 대화이다.
    /// Returns: 없음. 저장된 메시지와 진행 중인 응답을 표시한다.
    /// Raises: 없음. 조회 오류는 화면에 표시한다.
    func select(_ conversation: ChatConversation) {
        guard conversation.id != current.id else { return }
        _ = NSApp?.keyWindow?.makeFirstResponder(nil)
        draftConnectors = []
        do {
            let loaded = try store.messages(conversation.id)
            stashDraft()
            current = conversation; messages = loaded; draft = drafts[conversation.id] ?? ""; error = nil; openArtifactID = nil
            inputFocusRequest += 1
            let available = Set(skills.map(\.id))
            current.skillIDs.removeAll { !available.contains($0) }
            if let activeMessage, activeMessage.conversationID == conversation.id { replaceVisible(activeMessage) }
        } catch { self.error = error.localizedDescription }
    }

    /// Args: conversation은 대상 대화, title은 사용자가 입력한 이름이다.
    /// Returns: 없음. 빈 이름은 저장하지 않는다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    func rename(_ conversation: ChatConversation, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try store.renameConversation(conversation.id, title: title)
            if current.id == conversation.id { current.title = title }
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Args: conversation은 사용자가 삭제를 확인한 대화이다.
    /// Returns: 없음. 응답 생성 중인 대화는 삭제하지 않는다.
    /// Raises: 없음. 삭제 오류는 화면에 표시한다.
    func delete(_ conversation: ChatConversation) {
        do {
            try deleteConversations([conversation.id])
        } catch { self.error = error.localizedDescription }
    }

    func deleteConversations(_ ids: Set<String>) throws {
        try checkEditable(ids)
        try store.deleteConversations(Array(ids))
        try reload()
        projects.reload()
        if ids.contains(current.id) {
            if let next = conversations.first { select(next) } else { newConversation() }
        }
    }

    func moveConversations(_ ids: Set<String>, to projectID: String?) throws {
        try checkEditable(ids)
        try ProjectStore(db).move(ids.map { "conversation:\($0)" }, to: projectID)
        try reload()
        projects.reload()
        if ids.contains(current.id) { current.projectID = projectID; refreshFocusChoices() }
    }

    private func checkEditable(_ ids: Set<String>) throws {
        if let activeMessage, ids.contains(activeMessage.conversationID) {
            throw ChatToolError.unavailable(tr("응답 중인 채팅은 완료 후 이동하거나 삭제할 수 있어요."))
        }
    }

    /// Args: 없음.
    /// Returns: 없음. 선택한 스킬·자료 범위를 저장한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    func saveScope() {
        guard conversations.contains(where: { $0.id == current.id }) else { return }
        do { try store.save(current); try reload(); projects.reload() } catch { self.error = error.localizedDescription }
    }

    /// Args: 없음.
    /// Returns: 없음. 사용자가 선택한 파일·폴더를 대화에 연결한다.
    /// Raises: 없음. 파일 내용은 이 단계에서 읽지 않는다.
    func connectFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = tr("이 대화에서 읽을 파일 또는 저장소 폴더를 선택하세요. 필요한 내용은 설정된 LLM에 전송됩니다.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !current.scope.paths.contains(url.path) { current.scope.paths.append(url.path) }
        saveScope()
    }

    func uploadFiles(projectWide: Bool = false) {
        do {
            try store.save(current); try reload()
            let projectID = projectWide ? current.projectID : nil
            library.importFiles(projectID: projectID, conversationID: projectID == nil ? current.id : nil)
        } catch { self.error = error.localizedDescription }
    }

    /// Args: urls are files and folders dropped or pasted into the chat.
    /// Returns: 없음. 폴더는 읽을 경로로 연결하고, 파일은 보관함에 복사해 이 대화에 붙인다.
    /// Raises: 없음. 오류는 error에 남긴다.
    func attach(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if !folders.isEmpty {
            for url in folders where !current.scope.paths.contains(url.path) { current.scope.paths.append(url.path) }
            saveScope()
        }
        let files = urls.filter { !folders.contains($0) }
        guard !files.isEmpty else { return }
        do {
            try store.save(current); try reload()
            library.importFiles(files, conversationID: current.id)
        } catch { self.error = error.localizedDescription }
    }

    func attachLibraryItem(_ item: ChatLibraryItem, projectWide: Bool = false) {
        do {
            try store.save(current); try reload()
            if projectWide, let id = current.projectID { library.attach(item, projectID: id) }
            else { library.attach(item, conversationID: current.id) }
        } catch { self.error = error.localizedDescription }
    }

    /// Args: 없음.
    /// Returns: 없음. 현재 입력을 저장하고 응답 생성을 시작한다.
    /// Raises: 없음. 실행 오류는 해당 응답과 화면에 남긴다.
    @discardableResult
    func send() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let activeMessage {
            if activeMessage.conversationID != current.id { error = tr("다른 대화의 응답이 끝나면 보낼 수 있어요") }
            return false
        }
        guard !library.busy else { error = tr("첨부 파일을 넣는 중이에요. 끝나면 보내 주세요."); return false }
        guard begin(text, conversation: current, automationID: nil, draftConnectors: draftConnectors) else { return false }
        draft = ""
        drafts[current.id] = nil
        draftConnectors = []
        inputFocusRequest += 1     // the home input and the conversation input are different views
        return true
    }

    /// Messages an edit of `message` or a regenerate of its answer would replace, from its question to the end.
    func replacedMessages(from message: ConversationMessage) -> [ConversationMessage] {
        ConversationMessage.replaced(from: message, in: messages)
    }

    /// Args: message is the question to resend with `text`, or an answer to regenerate when text is nil.
    /// Returns: 시작했으면 true. 그 질문부터 뒤의 메시지는 새 질문을 저장할 때 같이 지운다. 시작하지 못하면 아무것도 지우지 않는다.
    /// Raises: 없음. 시작하지 못한 이유는 error에 남긴다.
    @discardableResult func resend(from message: ConversationMessage, text: String? = nil) -> Bool {
        let replaced = replacedMessages(from: message)
        guard let question = replaced.first, question.role == "user" else { return false }
        guard !running else { error = tr("응답이 끝난 뒤에 다시 보내 주세요."); return false }
        guard !library.busy else { error = tr("첨부 파일을 넣는 중이에요. 끝나면 보내 주세요."); return false }
        let request = (text ?? question.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return false }
        // Only a regenerate keeps the old answer; an edited question makes it answer something else.
        let earlier = text == nil && replaced.count > 1 && replaced[1].role == "assistant" ? replaced[1].versions : nil
        return begin(request, conversation: current, automationID: nil, replacing: replaced, earlierAnswers: earlier)
    }

    /// Asks for the rest of a stopped answer; ChatRunner keeps the partial text in the history.
    // shortcut: adds a visible follow-up turn instead of extending the stopped answer, merge them if users want one answer.
    @discardableResult func continueAnswer() -> Bool {
        guard !running else { error = tr("응답이 끝난 뒤에 다시 보내 주세요."); return false }
        guard !library.busy else { error = tr("첨부 파일을 넣는 중이에요. 끝나면 보내 주세요."); return false }
        return begin(tr("앞 답변에 이어서 계속 써 줘"), conversation: current, automationID: nil)
    }

    /// Copies the conversation as Markdown with sources, or saves it to a file the user picks.
    func exportMarkdown(_ conversation: ChatConversation, toFile: Bool) {
        do {
            let title = ChatConversation.display(conversation.title)
            let text = ConversationMessage.markdown(title: title, messages: try store.messages(conversation.id))
            guard toFile else { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".md"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    /// 고정한 대화, 고정 시각 내림차순.
    var pinnedConversations: [ChatConversation] {
        conversations.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? 0) > ($1.pinnedAt ?? 0) }
    }

    /// 고정 아닌 대화, 최신순.
    var recentConversations: [ChatConversation] {
        conversations.filter { $0.pinnedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 고정 또는 해제한다. 실패하면 error에 남긴다.
    func togglePin(_ conversation: ChatConversation) {
        let pin = conversation.pinnedAt == nil
        do {
            try store.setPinned(conversation.id, pinned: pin)
            if current.id == conversation.id { current.pinnedAt = pin ? Date().timeIntervalSince1970 : nil }
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    /// 제목과 본문에서 찾는다. 빈 글이면 [].
    /// DB 조회는 메인 스레드 밖에서 돈다.
    func search(_ query: String) async -> [ChatSearchHit] {
        let store = store
        do { return try await Task.detached { try store.searchConversations(query) }.value }
        catch { self.error = error.localizedDescription; return [] }
    }

    /// Args: 없음.
    /// Returns: 없음. 실행 중인 모델·하위 작업에 취소를 전달한다.
    /// Raises: 없음.
    func cancel() { runTask?.cancel() }

    /// Args: message는 예약안을 포함한 답변이다.
    /// Returns: 없음. 사용자의 명시적 승인으로 예약을 등록한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    func approve(_ message: ConversationMessage) {
        guard let proposal = message.automation, message.approvedAutomationID == nil else { return }
        do {
            var job = ChatAutomation(proposal: proposal, conversation: current)
            job.scope.libraryIDs = try library.store.sourceIDs(conversationID: current.id)
            var updated = message; updated.approvedAutomationID = job.id
            try store.approve(job, message: updated)
            replaceVisible(updated); try reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Args: job은 사용자가 활성 상태를 변경한 예약이다.
    /// Returns: 없음. 다시 켜면 현재 시각부터 새 간격을 적용한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    func toggle(_ job: ChatAutomation) {
        var updated = job; updated.enabled.toggle()
        if updated.enabled { updated.nextRun = Date().timeIntervalSince1970 + Double(updated.intervalHours) * 3600 }
        do { try store.save(updated); try reload() } catch { self.error = error.localizedDescription }
    }

    /// Args: job은 삭제할 예약이다.
    /// Returns: 없음. 예약만 삭제하고 이미 생성된 대화는 보존한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    func deleteAutomation(_ job: ChatAutomation) {
        do {
            try store.deleteAutomation(job.id)
            for index in messages.indices where messages[index].approvedAutomationID == job.id {
                messages[index].approvedAutomationID = nil
            }
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Args: 없음.
    /// Returns: 없음. 앱 실행 중 예약을 확인하는 작업을 시작한다.
    /// Raises: 없음. 로그인·앱 종료 시 stop으로 중단한다.
    func startScheduler() {
        guard scheduler == nil else { return }
        library.collectExisting()
        titleTask = Task { [weak self] in
            guard let self else { return }
            await self.updateOldTitles()
        }
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDueAutomation()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
            }
        }
    }

    /// Args: 없음.
    /// Returns: 없음. 예약 확인과 진행 중인 요청을 중단한다.
    /// Raises: 없음.
    func stop() { scheduler?.cancel(); scheduler = nil; titleTask?.cancel(); titleTask = nil; projects.stop(); cancel() }

    /// Args: text는 요청, conversation은 실행 범위, automationID가 있으면 승인된 예약 실행이다.
    /// Returns: 요청을 저장하고 시작했으면 true.
    /// Raises: 없음. 시작 실패는 화면에 표시한다.
    @discardableResult private func begin(_ text: String, conversation: ChatConversation, automationID: String?, draftConnectors: [String] = [], replacing: [ConversationMessage] = [], earlierAnswers: [ConversationMessage]? = nil) -> Bool {
        guard !running else { return false }
        do {
            var conversation = conversation
            // 고른 범위 중 사라진 것이 있으면 넓혀서 보내지 않는다. 업무가 합쳐진 경우엔 저장된 대화에 남는 업무가 적혀 있다 (TaskMerger)
            if !conversation.scope.focus.isEmpty {
                var focus = conversation.scope.focus
                if try focus.contains(where: { try !ContextSearch.exists($0, in: db) }),
                   let saved = try store.conversations().first(where: { $0.id == conversation.id })?.scope.focus, saved != focus, !saved.isEmpty,
                   try saved.allSatisfy({ try ContextSearch.exists($0, in: db) }) {
                    focus = saved
                }
                let gone = try focus.filter { try !ContextSearch.exists($0, in: db) }
                if !gone.isEmpty {
                    let names = gone.map { "'\($0.title)'" }.joined(separator: ", ")
                    if automationID != nil { error = tr("\(names) 범위를 찾을 수 없어 예약을 실행하지 못했어요."); return false }
                    let kept = focus.filter { !gone.contains($0) }
                    if current.id == conversation.id { current.scope.focus = kept }
                    error = tr("\(names) 범위를 찾을 수 없어 ") + (kept.isEmpty ? tr("모든 기록으로 바꿨어요") : tr("빼고 남은 범위로 바꿨어요")) + tr(". 다시 보내 주세요.")
                    return false
                }
                conversation.scope.focus = focus
                if current.id == conversation.id { current.scope.focus = focus }
            }
            var scope = try ProjectStore(db).scope(for: conversation)
            for connector in draftConnectors {
                if connector == "github" { scope.useGitHub = true }
                else if !scope.connectors.contains(connector) { scope.connectors.append(connector) }
            }
            conversation.projectID = scope.projectID
            let replacedIDs = Set(replacing.map(\.id))
            let previous = try store.messages(conversation.id).filter { !replacedIDs.contains($0.id) }
            let remoteConnectors = ConnectorAuth.remoteIDs()
            // Retried on later turns too, so a stopped or failed first answer still gets a title.
            let needsTitle = automationID == nil && conversation.title == ChatConversation.defaultTitle
            conversation.updatedAt = Date().timeIntervalSince1970
            let user = ConversationMessage(conversationID: conversation.id, role: "user", text: text)
            let backend = makeClient()
            var answer = ConversationMessage(conversationID: conversation.id, role: "assistant", text: "", status: "running")
            answer.model = backend.modelName; answer.previous = earlierAnswers
            let searchKey: String, searchModel: String
            if case .model(let client as OpenAICompatClient) = backend,
               client.baseURL.host == "api.openai.com", scope.useWeb {
                searchKey = client.apiKey ?? ""; searchModel = client.model
            } else { searchKey = ""; searchModel = "" }
            try store.startTurn(conversation: conversation, user: user, answer: answer, replacing: replacing)
            if automationID != nil {
                let existing = Set(try library.store.items().map(\.id))
                for id in conversation.scope.libraryIDs where existing.contains(id) { try library.store.attach(id, conversationID: conversation.id) }
                scope.libraryIDs = try library.store.sourceIDs(conversationID: conversation.id, projectID: conversation.projectID)
            }
            let tools = ChatTools(db: db, scope: scope,
                                  searchKey: searchKey, searchModel: searchModel,
                                  connectorToken: { id in
                                      if id == "github" { return (try? await ConnectorAuth.accessToken(id)) ?? "" }
                                      return try await ConnectorAuth.accessToken(id)
                                  }, connectorResource: ConnectorAuth.resource,
                                  remoteConnectors: remoteConnectors)
            let runner = ChatRunner(backend: backend, tools: tools)
            let selectedCatalog = skills
            activeMessage = answer; error = nil; library.chatImportError = nil
            // The turn is saved; a list refresh failure must not leave it running without a task.
            do { try reload() } catch { self.error = error.localizedDescription }
            if current.id == conversation.id { current = conversation; messages = previous + [user, answer] }
            if !replacing.isEmpty { library.reload() }    // startTurn unlinked the replaced answers' artifacts
            runTask = Task { [weak self] in
                guard let self else { return }
                var succeeded = false
                do {
                    let project = self.projects.projects.first(where: { $0.id == conversation.projectID })
                    let result = try await runner.run(history: previous + [user], skillIDs: conversation.skillIDs, skillCatalog: selectedCatalog, scheduled: automationID != nil, project: project, memory: conversation.memory) { [weak self] event in
                        await self?.receive(event)
                    }
                    self.flushText()
                    try Task.checkCancellation()
                    self.activeMessage?.text = result.text
                    self.activeMessage?.sources = result.sources
                    self.activeMessage?.artifacts = result.artifacts
                    self.activeMessage?.automation = result.automation
                    self.activeMessage?.status = "complete"
                    succeeded = true
                    if result.memory != conversation.memory { self.remember(result.memory, in: conversation.id) }
                } catch {
                    self.flushText()
                    let cancelled = Task.isCancelled || error is CancellationError
                    self.activeMessage?.status = cancelled ? "cancelled" : "failed"
                    if !cancelled {
                        let description = error.localizedDescription
                        self.activeMessage?.text += tr("\n\n응답을 완료하지 못했습니다: \(description)")
                    }
                }
                if let message = self.activeMessage {
                    self.replaceVisible(message)
                    do { try self.store.save(message) } catch { self.error = tr("응답 저장 실패: \(error.localizedDescription)"); succeeded = false }
                    if succeeded { self.library.collect(message) }
                }
                if let automationID, var job = self.automations.first(where: { $0.id == automationID }) {
                    job.lastStatus = succeeded ? tr("완료") : tr("실패 또는 중단 — 다음 예약에 실행")
                    do { try self.store.save(job) } catch { self.error = error.localizedDescription }
                }
                self.activeMessage = nil; self.runTask = nil
                do { try self.reload() } catch { self.error = error.localizedDescription }
                if needsTitle, !Task.isCancelled {
                    do {
                        let title = try await backend.conversationTitle(for: previous.first { $0.role == "user" }?.text ?? text)
                        self.applyTitle(title, to: conversation.id, replacing: ChatConversation.defaultTitle)
                    } catch { AppLog.write("chat title failed: \(error.localizedDescription)") }
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Stores the summary of older messages on the conversation as it is now, so a rename or scope change made meanwhile is kept.
    private func remember(_ memory: ChatMemory?, in conversationID: String) {
        guard var stored = (current.id == conversationID ? current : conversations.first { $0.id == conversationID }) else { return }
        stored.memory = memory
        do { try store.save(stored) } catch { AppLog.write("chat memory save failed: \(error)") }
        if current.id == conversationID { current.memory = memory }
    }

    /// Args: event는 실제 모델·도구 실행에서 발생한 이벤트이다.
    /// Returns: 없음. 현재 응답을 갱신하고 단계 변경 시 저장한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    private func receive(_ event: ChatRunEvent) {
        if case .text(let text) = event {
            pendingText += text
            // shortcut: fixed 40ms batches so each token doesn't redraw the whole chat; tune if streaming looks choppy.
            if textFlush == nil {
                textFlush = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
                    self?.flushText()
                }
            }
            return
        }
        flushText()
        guard var message = activeMessage else { return }
        var checkpoint = true
        switch event {
        case .textReset: message.text = ""   // saving here keeps a crash from leaving the last step's preamble as the answer
        case .text(let text): message.text += text; checkpoint = false
        case .step(let text): message.trace = (message.trace ?? []) + [ChatStep(title: text, status: .done)]
        case .stepStarted(let step): message.trace = (message.trace ?? []) + [step]
        case .stepFinished(let id, let result, let failed):
            if let index = message.trace?.firstIndex(where: { $0.id == id }) {
                message.trace?[index].result = result
                message.trace?[index].status = failed ? .failed : .done
                message.trace?[index].endedAt = Date().timeIntervalSince1970
            }
        case .source(let source):
            message.sources.removeAll { $0.id == source.id }; message.sources.append(source)
        case .artifact(let artifact):
            message.artifacts.append(artifact)
            if message.conversationID == current.id { openArtifactID = artifact.id }
        case .automation(let proposal): message.automation = proposal
        }
        activeMessage = message; replaceVisible(message)
        if checkpoint {
            do { try store.save(message) } catch { self.error = tr("진행 기록 저장 실패: \(error.localizedDescription)") }
        }
    }

    /// Publishes streamed text held back by receive, before any other change so the order stays the same.
    private func flushText() {
        textFlush?.cancel(); textFlush = nil
        guard !pendingText.isEmpty else { return }
        defer { pendingText = "" }
        guard var message = activeMessage else { return }
        message.text += pendingText
        activeMessage = message; replaceVisible(message)
    }

    /// Args: message는 갱신된 응답이다.
    /// Returns: 없음. 선택된 대화에 속한 경우에만 화면을 바꾼다.
    /// Raises: 없음.
    private func replaceVisible(_ message: ConversationMessage) {
        guard current.id == message.conversationID else { return }
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
    }

    /// Args: 없음.
    /// Returns: 없음. 대화·예약 목록을 저장소와 맞춘다.
    /// Raises: DB·디코딩 오류.
    private func reload() throws {
        conversations = try store.conversations(); conversationPreviews = try store.conversationPreviews()
        automations = try store.automations()
    }

    /// Args: title은 생성된 제목, id는 대상 대화, oldTitle은 덮어써도 되는 자동 제목이다.
    /// Returns: 없음. 사용자가 직접 변경한 제목은 유지한다.
    /// Raises: 없음. 저장 오류는 화면에 표시한다.
    private func applyTitle(_ title: String, to id: String, replacing oldTitle: String) {
        guard conversations.first(where: { $0.id == id })?.title == oldTitle else { return }
        do {
            try store.renameConversation(id, title: title)
            if current.id == id { current.title = title }
            try reload()
        } catch { self.error = error.localizedDescription }
    }

    /// Args: 없음.
    /// Returns: 없음. 첫 요청을 잘라 만든 기존 제목만 모델로 다시 작성한다.
    /// Raises: 없음. 실패한 제목은 그대로 둔다.
    private func updateOldTitles() async {
        for conversation in conversations {
            if Task.isCancelled { return }
            do {
                guard let first = try store.firstMessage(conversation.id), first.role == "user" else { continue }
                let oldTitle = String(first.text.prefix(48))
                guard conversation.title == oldTitle else { continue }
                let title = try await makeClient().conversationTitle(for: first.text)
                applyTitle(title, to: conversation.id, replacing: oldTitle)
            } catch { return }
        }
    }

    /// Args: 없음.
    /// Returns: 없음. 기한이 지난 예약 하나를 실행하며 누락 횟수는 재생하지 않는다.
    /// Raises: 없음. 등록·실행 실패는 예약 상태에 표시한다.
    private func runDueAutomation() {
        guard !running else { return }
        let now = Date().timeIntervalSince1970
        guard var job = automations.filter({ $0.enabled && $0.nextRun <= now }).min(by: { $0.nextRun < $1.nextRun }) else { return }
        var conversation = ChatConversation()
        conversation.title = tr("예약 · \(job.title)"); conversation.scope = job.scope; conversation.skillIDs = job.skillIDs
        conversation.projectID = job.scope.projectID
        job.nextRun = now + Double(job.intervalHours) * 3600
        job.lastStatus = tr("실행 중"); job.lastConversationID = conversation.id
        do {
            try store.save(job); try reload()
            if !begin(job.prompt, conversation: conversation, automationID: job.id) {
                job.lastStatus = tr("시작 실패 — 설정을 확인하세요"); try store.save(job); try reload()
            }
        } catch { self.error = error.localizedDescription }
    }
}
