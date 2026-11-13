import SwiftUI
import SillogCore

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var chat: ChatState
    @ObservedObject var library: LibraryState
    var modelName = ""
    var openSettings: () -> Void = {}
    /// 아직 업무로 정리되지 않은 기록 수: 범위를 좁히면 이 기록은 빠진다고 알리고 지금 정리를 권한다
    var pendingRecords = 0
    var tidyNow: () -> Void = {}
    @State private var pane: ChatPane = .chat
    @State private var source: ChatSource?
    @State private var pendingAutomation: ConversationMessage?
    @State private var showSchedules = false
    @State private var showSearch = false
    /// 검색 창을 창 정중앙에서 끌어 옮긴 거리. 앱을 다시 켜도 기억한다.
    @AppStorage("chatSearchOffsetX") private var searchOffsetX = 0.0
    @AppStorage("chatSearchOffsetY") private var searchOffsetY = 0.0
    @GestureState private var searchDrag = CGSize.zero
    @State private var previewItem: ChatLibraryItem?
    @State private var sidebarVisible = true
    @State private var editingConversation: ChatConversation?
    @State private var deletingConversation: ChatConversation?
    @State private var conversationName = ""
    @State private var showRename = false
    @State private var showDelete = false
    @State private var selectedQuestionID: String?
    @State private var hoveredQuestionID: String?
    @State private var expandedSources: Set<String> = []
    @State private var expandedSteps: Set<String> = []     // 끝난 답변의 단계 목록: 기본 접힘
    @State private var collapsedSteps: Set<String> = []    // 실행 중 답변의 단계 목록: 기본 펼침(CH-15)
    @State private var editingMessageID: String?
    @State private var editText = ""
    @State private var hoveredMessageID: String?
    @State private var expandedQuestions: Set<String> = []
    @State private var pendingResend: PendingResend?
    @State private var copiedID: String?
    @State private var hoveredArtifactID: String?
    @State private var atBottom = true
    /// A search hit to land on once its conversation is on screen.
    @State private var pendingScrollID: String?
    @State private var highlightedMessageID: String?
    /// Which earlier answer a regenerated answer shows, by message id; missing means the latest.
    @State private var shownVersions: [String: Int] = [:]
    @FocusState private var focusedActions: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editFocused: Bool
    @State private var artifactExpanded = false

    private struct PendingResend: Identifiable {
        let message: ConversationMessage
        let text: String?
        let dropped: Int
        let model: String?
        var id: String { message.id }
    }

    /// 목록(261, 고정 폭) + 1pt 선 + 본문. 목록을 접으면(CH-30) 본문만 남는다.
    private var layout: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ChatSidebar(chat: chat, projects: chat.projects, pane: $pane, isSearching: showSearch,
                            onSearch: { showSearch = true },
                            onSchedules: { showSchedules = true },
                            onCollapse: { sidebarVisible = false },
                            onRename: { item in editingConversation = item; conversationName = ChatConversation.display(item.title); showRename = true },
                            onDelete: { item in deletingConversation = item; showDelete = true })
                    .frame(width: ChatPalette.sidebarWidth)
                Rectangle().fill(Brand.line).frame(width: 1)
            }
            mainContent
        }
        .overlay { if showSearch { searchOverlay } }
    }

    /// 창을 어둡게 하고 560 폭 검색 창을 창 정중앙에 띄운다(Figma CH-41). 끌면 그 자리를 기억하고, 창이 작아지면 창 안으로 당긴다.
    /// 글자를 쳐서 창 높이가 변해도 움직이지 않게 위쪽 끝을 고정한다.
    private var searchOverlay: some View {
        GeometryReader { geo in
            let panelH: CGFloat = 342, panelW: CGFloat = 560, headH: CGFloat = 52
            let home = CGPoint(x: (geo.size.width - NavRail.width - panelW) / 2, y: (geo.size.height - headH - panelH) / 2)
            let maxX = max(0, geo.size.width - panelW), maxY = max(0, geo.size.height - 48)
            let x = min(max(0, home.x + searchOffsetX + searchDrag.width), maxX)
            let y = min(max(0, home.y + searchOffsetY + searchDrag.height), maxY)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.08).contentShape(Rectangle()).onTapGesture { showSearch = false }
                ChatSearchPanel(chat: chat,
                                onOpen: { item, messageID in pendingScrollID = messageID; chat.select(item); pane = .chat; showSearch = false },
                                onClose: { showSearch = false })
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                        .updating($searchDrag) { value, drag, _ in drag = value.translation }
                        .onEnded { value in     // 창 밖으로 나간 만큼은 저장하지 않는다
                            searchOffsetX = min(max(0, home.x + searchOffsetX + value.translation.width), maxX) - home.x
                            searchOffsetY = min(max(0, home.y + searchOffsetY + value.translation.height), maxY) - home.y
                        })
                    .frame(width: panelW)
                    .offset(x: x, y: y)
                Button("") { showSearch = false }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    private var sheets: some View {
        layout
        .sheet(item: $source) { ChatSourceSheet(source: $0).environmentObject(state) }
        .sheet(item: $pendingAutomation) { message in automationApproval(message) }
        .sheet(isPresented: $showSchedules) { ChatSchedulesView(chat: chat) }
        .sheet(item: $previewItem) { LibraryPreview(library: library, item: $0) }
        .alert(tr("뒤의 대화를 지우고 다시 보낼까요?"), isPresented: Binding(get: { pendingResend != nil }, set: { if !$0 { pendingResend = nil } }), presenting: pendingResend) { pending in
            Button(tr("지우고 보내기"), role: .destructive) {
                if let model = pending.model { state.selectChatModel(model) }
                if chat.resend(from: pending.message, text: pending.text) { editingMessageID = nil }
            }
            Button(tr("취소"), role: .cancel) {}
        } message: { pending in
            Text(tr("이 질문 뒤에 있는 메시지 \(pending.dropped)개가 지워져요."))
        }
    }

    var body: some View {
        sheets
        .onAppear { if state.showsChatResultsOnOpen { pane = .results } }
        .alert(tr("이름 바꾸기"), isPresented: $showRename) {
            TextField(tr("대화 이름"), text: $conversationName)
            Button(tr("취소"), role: .cancel) {}
            Button(tr("저장")) {
                if let item = editingConversation { chat.rename(item, title: conversationName) }
            }.disabled(conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(tr("대화를 삭제할까요?"), isPresented: $showDelete) {
            Button(tr("취소"), role: .cancel) {}
            Button(tr("삭제"), role: .destructive) {
                if let item = deletingConversation { chat.delete(item) }
            }
        } message: {
            Text(tr("‘\(ChatConversation.display(deletingConversation?.title ?? ""))’의 메시지와 결과물이 삭제되며 복구할 수 없습니다. 원본 자료와 등록된 예약 작업은 유지됩니다."))
        }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme ?? "") ? .systemAction : .discarded
        })
        // The 1064pt minimum window leaves too little room for the conversation beside both the list and the panel, so they take turns.
        .onChange(of: chat.openArtifactID, initial: true) { old, new in
            if new != nil, pane == .chat, old == nil || old == new { sidebarVisible = false } else if new == nil, old != nil { sidebarVisible = true }
            // Switching versions keeps the size; closing starts the next panel at 480.
            if new == nil { artifactExpanded = false }
        }
        .onChange(of: chat.current.scope) { old, new in if old != new { chat.saveScope() } }
        .onChange(of: chat.current.skillIDs) { old, new in if old != new { chat.saveScope() } }
        .onChange(of: chat.current.id) { _, _ in editingMessageID = nil }
        .background {
            Group {
                Button("") { chat.newConversation(); pane = .chat }.keyboardShortcut("n").disabled(editingMessageID != nil)
                Button("") { showSearch = true }.keyboardShortcut("k")
                Button("") { chat.cancel() }.keyboardShortcut(".").disabled(!(pane == .chat && chat.activeMessage?.conversationID == chat.current.id))
                Button("") { sidebarVisible.toggle(); if sidebarVisible { chat.openArtifactID = nil } }.keyboardShortcut("\\")
                Button("") { copyLastAnswer() }.keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!chat.messages.contains { $0.role == "assistant" })
                // Search, inline edit and the source sheet have their own Esc.
                if openArtifact != nil, !showSearch, editingMessageID == nil, source == nil {
                    Button("") { chat.openArtifactID = nil }.keyboardShortcut(.cancelAction)
                }
            }.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private var mainContent: some View {
        Group {
            switch pane {
            case .chat:
                let open = openArtifact
                HStack(spacing: 0) {
                    if open == nil || !artifactExpanded {
                        chatContent
                        if open != nil { Rectangle().fill(Brand.line).frame(width: 1) }
                    }
                    if let open {
                        ArtifactPreview(artifact: open, versions: ChatArtifact.versions(of: open, in: chat.messages),
                                        onSelect: { chat.openArtifactID = $0.id }, onClose: { chat.openArtifactID = nil },
                                        onExpand: { artifactExpanded.toggle() }, expanded: artifactExpanded)
                            .id(open.id).frame(width: artifactExpanded ? nil : 480).frame(maxWidth: artifactExpanded ? .infinity : nil)
                    }
                }
            case .projects:
                ProjectListView(projects: chat.projects, chat: chat,
                                onOpen: { project in chat.newConversation(projectID: project.id); pane = .project(project.id) })
            case .project(let id):
                if let project = chat.projects.projects.first(where: { $0.id == id }) {
                    ProjectOverview(projects: chat.projects, chat: chat, project: project,
                                    onConversation: { chat.select($0); pane = .chat },
                                    composer: ChatComposer(chat: chat, library: library, modelName: modelName, openSettings: openSettings,
                                                           pendingRecords: pendingRecords, tidyNow: tidyNow,
                                                           onOpenConnectors: { state.selectedTab = .connectors },
                                                           onSent: { pane = .chat }, showsNotice: false))
                } else {
                    Color.white.onAppear { pane = .projects }     // 삭제된 프로젝트
                }
            case .results:
                LibraryView(library: library, initialKind: "", title: tr("결과물"))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
    }

    private var openArtifact: ChatArtifact? {
        chat.openArtifactID.flatMap { id in chat.messages.flatMap { $0.versions.flatMap(\.artifacts) }.first { $0.id == id } }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !chat.messages.isEmpty || !sidebarVisible { header }
            if let active = chat.activeMessage, active.conversationID != chat.current.id {
                // CH-14: 본문 600 열 안, 머리에서 떨어진 47 높이 띠, 아래 줄 하나, '이동'은 글자 링크
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let job = chat.automations.first(where: { $0.lastConversationID == active.conversationID && $0.lastStatus == "실행 중" }) {
                        Text(tr("예약 작업 ‘\(job.title)’ 실행 중")).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).lineLimit(1)
                    } else {
                        Text(tr("다른 대화에서 작업 중")).font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
                    }
                    Button {
                        if let item = chat.conversations.first(where: { $0.id == active.conversationID }) { chat.select(item) }
                    } label: { Text(tr("이동")).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.ink) }
                        .buttonStyle(.plain)
                    Button { chat.cancel() } label: { Text(tr("중단")).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.ink) }
                        .buttonStyle(.plain)
                    Spacer()
                }.padding(.horizontal, 28).frame(height: 47)
                    .background(ChatPalette.soft)
                    .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                    .frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity)
                    .padding(.horizontal, 32).padding(.top, 24).padding(.leading, showsQuestionMarks ? 44 : 0)
            }
            if chat.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
            if let error = chat.error ?? library.chatImportError {
                // CH-17: 입력칸과 같은 600 열, 위아래 줄, 입력칸 위 8 간격
                HStack(alignment: .top, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(Brand.font(.caption)).foregroundStyle(Brand.ink).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { chat.error = nil; library.chatImportError = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray)
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tr("닫기")).accessibilityLabel(tr("닫기"))
                }
                    .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatPalette.soft)
                    .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                    .frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity)
                    .padding(.horizontal, 32).padding(.top, 8)
                    .padding(.leading, showsQuestionMarks ? 44 : 0)
            }
            if !chat.messages.isEmpty { composer }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if chat.messages.isEmpty { ChatStartBackground() } else { Color.white } }
    }

    private var composer: some View {
        ChatComposer(chat: chat, library: library, modelName: modelName, openSettings: openSettings,
                     pendingRecords: pendingRecords, tidyNow: tidyNow, onOpenConnectors: { state.selectedTab = .connectors },
                     onEditLast: {
                         if !chat.running, let last = chat.messages.last(where: { $0.role == "user" }) { editText = last.text; editingMessageID = last.id }
                     })
            .frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity)     // 대화 본문과 같은 폭
            .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 14)
            .padding(.leading, showsQuestionMarks ? 44 : 0)     // 질문 눈금(44)만큼 밀린 대화 본문과 같은 열
            .background(.white)
    }

    /// 질문이 하나면 옮겨 갈 곳이 없어 눈금을 숨긴다.
    private var showsQuestionMarks: Bool { chat.messages.filter({ $0.role == "user" }).count > 1 }

    /// Args: 없음.
    /// Returns: 새 대화의 시작 화면(CH-01). 로고와 한 줄 인사, 입력칸, 최근 결과물 카드 3장.
    /// Raises: 없음.
    private var emptyState: some View {
        let results = library.results(limit: 3)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("쌓아 온 기록으로 다음 일을 시작해요"))
                    .font(Brand.font(.screenTitle)).tracking(-0.48).foregroundStyle(Brand.ink).lineLimit(1)
                    .frame(maxWidth: .infinity)
                ChatComposer(chat: chat, library: library, modelName: modelName, openSettings: openSettings,
                             pendingRecords: pendingRecords, tidyNow: tidyNow, onOpenConnectors: { state.selectedTab = .connectors },
                             showsNotice: false)
                    .background(alignment: .topTrailing) {             // Figma 1591:18788: 입력칸 오른쪽 위에 올라앉은 심볼
                        GazingMark(size: 104, smiling: !chat.draft.isEmpty).offset(x: -20, y: -68).allowsHitTesting(false)
                    }
                    .padding(.top, 28)
                // Hidden while typing, since a chip replaces the draft.
                ChatChipFlow(spacing: 8) {
                    ForEach(Array(chat.starterPrompts.enumerated()), id: \.offset) { _, starter in
                        StarterChip(text: starter.prompt) { chat.useStarter(starter.prompt, focus: starter.focus) }
                    }
                }.padding(.top, 12)
                .opacity(chat.draft.isEmpty ? 1 : 0).disabled(!chat.draft.isEmpty).accessibilityHidden(!chat.draft.isEmpty)
                .onAppear { chat.refreshFocusChoices() }
                if !results.isEmpty {
                    HStack {
                        Text(tr("최근 결과물")).font(Brand.font(.body)).foregroundStyle(Brand.tabText).padding(.leading, 4)
                        Spacer()
                        Button { pane = .results } label: {
                            Text(tr("모두 보기")).font(Brand.font(.body)).foregroundStyle(Brand.tabText).contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.trailing, 4)
                    }.padding(.top, 36)
                    HStack(spacing: 12) {
                        ForEach(results) { item in
                            ChatResultCard(library: library, item: item) { previewItem = $0 }
                        }
                    }.padding(.top, 12)
                }
            }.frame(width: ChatPalette.columnWidth)
            Spacer(minLength: 0)
            Text(tr("질문과 조회한 자료는 연결한 AI로 전송돼요. 웹 검색과 커넥터는 허용한 범위만 사용해요."))
                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1).padding(.bottom, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 본문 머리(CH-02): 제목 하나, 밑줄 없음. 목록을 접었을 때(CH-30)만 목록 펼치기와 새 대화 아이콘이 제목 왼쪽에 붙는다.
    private var header: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                // CH-30: 아이콘 중심 35, 64, 제목 시작 87 (아이콘 28 폭, 간격 1)
                HStack(spacing: 1) {
                    ChatIconButton(systemName: "sidebar.left", help: tr("대화 목록 표시 전환 (⌘\\)"), label: tr("대화 목록 표시 전환")) { sidebarVisible = true; chat.openArtifactID = nil }
                    ChatIconButton(systemName: "square.and.pencil", help: tr("새 대화 (⌘N)"), label: tr("새 대화")) { chat.newConversation(); pane = .chat }
                }
            }
            if !chat.messages.isEmpty {
                HoverScrollingText(text: ChatConversation.display(chat.current.title)).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                // The sidebar is hidden while an artifact is open, so its row menu is out of reach.
                Menu {
                    let item = chat.conversations.first { $0.id == chat.current.id } ?? chat.current
                    Button { editingConversation = item; conversationName = ChatConversation.display(item.title); showRename = true } label: {
                        Label(tr("이름 바꾸기"), systemImage: "pencil")
                    }
                    Button(role: .destructive) { deletingConversation = item; showDelete = true } label: { Label(tr("삭제"), systemImage: "trash") }
                        .disabled(chat.activeMessage?.conversationID == item.id)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.tabText)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(tr("대화 메뉴")).accessibilityLabel(tr("대화 메뉴"))
            }
            Spacer(minLength: 0)
        }.padding(.top, sidebarVisible ? 20.5 : 20)   // 목록 "채팅" 제목과 글자 바닥선을 맞춘다
            .padding(.leading, sidebarVisible ? 28 : 21).padding(.trailing, 28)
            .frame(height: 65, alignment: .topLeading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if showsQuestionMarks {
                    GeometryReader { geometry in
                        let turns = conversationTurns
                        let step = min(28, max(10, (geometry.size.height - 36) / CGFloat(turns.count)))
                        let activeID = selectedQuestionID ?? turns.last?.id
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                Button {
                                    selectedQuestionID = turn.id
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                                        proxy.scrollTo(turn.id, anchor: .top)
                                    }
                                } label: {
                                    Capsule()
                                        .fill(activeID == turn.id ? Brand.ink : Brand.gray.opacity(0.45))
                                        .frame(width: hoveredQuestionID == turn.id ? 29 : activeID == turn.id ? 24 : 13,
                                               height: hoveredQuestionID == turn.id || activeID == turn.id ? 3 : 2)
                                        .frame(width: 44, height: step)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .offset(y: 18 + CGFloat(index) * step)
                                .onHover { hovering in
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                        if hovering { hoveredQuestionID = turn.id }
                                        else if hoveredQuestionID == turn.id { hoveredQuestionID = nil }
                                    }
                                }
                                .accessibilityLabel(tr("질문 \(index + 1): \(String(turn.question.text.prefix(80)))"))
                            }
                            if let index = turns.firstIndex(where: { $0.id == hoveredQuestionID }) {
                                turnPreview(turns[index])
                                    .offset(x: 48, y: min(max(18 + CGFloat(index) * step - 24, 8),
                                                          max(8, geometry.size.height - 160)))
                                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hoveredQuestionID)
                    }
                    .frame(width: 44)
                    .zIndex(1)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(chat.messages) { message in
                            messageView(message)
                                .id(message.id)
                                .background {
                                    RoundedRectangle(cornerRadius: 8).fill(ChatPalette.rowHover).padding(-8)
                                        .opacity(highlightedMessageID == message.id ? 1 : 0)
                                }
                                .background {
                                    if message.role == "user" {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: QuestionPositionKey.self,
                                                value: [message.id: geometry.frame(in: .named("chatTranscript")).minY])
                                        }
                                    }
                                }
                                // A question sits farther from the previous answer than its own answer sits from it.
                                .padding(.top, message.role == "user" ? (chat.messages.first?.id == message.id ? 0 : 32) : 4)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { atBottom = true }.onDisappear { atBottom = false }
                    }.frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 24)
                }
                .coordinateSpace(name: "chatTranscript")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(QuestionPositionKey.self) { positions in
                    let ordered = positions.sorted { $0.value < $1.value }
                    selectedQuestionID = ordered.last(where: { $0.value <= 100 })?.key ?? ordered.first?.key
                }
                .onChange(of: chat.messages.count) { _, _ in if pendingScrollID == nil { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: chat.current.id) { _, _ in
                    selectedQuestionID = nil
                    hoveredQuestionID = nil
                    if pendingScrollID == nil { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: pendingScrollID, initial: true) { _, id in
                    guard let id else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))     // let the lazy rows of a newly opened chat lay out first
                        proxy.scrollTo(id, anchor: .top)
                        pendingScrollID = nil
                        highlightedMessageID = id
                        try? await Task.sleep(for: .seconds(1.5))
                        if highlightedMessageID == id { withAnimation(.easeOut(duration: 0.4)) { highlightedMessageID = nil } }
                    }
                }
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 20).allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [.white.opacity(0), .white], startPoint: .top, endPoint: .bottom).frame(height: 16).allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    Group { if !atBottom {
                        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                            Image(systemName: "arrow.down").font(.system(size: 11)).foregroundStyle(Brand.tabText).frame(width: 30, height: 30).background(.white, in: Circle()).overlay(Circle().strokeBorder(Brand.line))
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        }.buttonStyle(.plain).help(tr("최근 응답으로")).accessibilityLabel(tr("최근 응답으로")).padding(16)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                    } }
                    .animation(.easeOut(duration: 0.15), value: atBottom)
                }
            }
        }
    }

    /// Args: 없음.
    /// Returns: 각 사용자 질문과 그 뒤에 이어진 모델 답변을 묶은 탐색 항목.
    /// Raises: 없음.
    private var conversationTurns: [ConversationTurn] {
        var turns: [ConversationTurn] = []
        for message in chat.messages {
            if message.role == "user" {
                turns.append(ConversationTurn(question: message))
            } else if message.role == "assistant", !turns.isEmpty {
                turns[turns.count - 1].answer = message
            }
        }
        return turns
    }

    /// Args: turn은 미리 볼 질문과 답변이다.
    /// Returns: 탐색 눈금에 마우스를 올렸을 때 표시할 미리보기 카드.
    /// Raises: 없음.
    private func turnPreview(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question.text).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(2)
            Rectangle().fill(Brand.line).frame(height: 1)
            if let answer = turn.answer, !answer.text.isEmpty {
                Text(answer.text).font(Brand.font(.body)).foregroundStyle(Brand.gray).lineLimit(3)
            } else {
                Text(turn.answer?.status == "running" ? tr("답변 작성 중…") : tr("답변 없음"))
                    .font(Brand.font(.body)).foregroundStyle(Brand.gray)
            }
        }
        .frame(width: 300, alignment: .leading)
        .padding(14)
        .glassPanel(cornerRadius: 8)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    /// Args: message는 저장된 요청 또는 응답이다.
    /// Returns: 사용자 질문 또는 출처, 실행 상태를 포함한 답변.
    /// Raises: 없음.
    @ViewBuilder private func messageView(_ message: ConversationMessage) -> some View {
        if message.role == "user", editingMessageID == message.id {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $editText)
                    .font(Brand.font(.body)).foregroundStyle(Brand.text).scrollContentBackground(.hidden)
                    .focused($editFocused).onAppear { editFocused = true }
                    .frame(minHeight: 60, maxHeight: 240).fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line))
                HStack(spacing: 8) {
                    Button(tr("취소")) { editingMessageID = nil; chat.inputFocusRequest += 1 }.keyboardShortcut(.cancelAction)
                    Button(tr("보내기")) { requestResend(message, text: editText) }
                        .keyboardShortcut(.return, modifiers: .command).help(tr("보내기 (⌘↩)"))
                        .buttonStyle(BrandButtonStyle())
                        .disabled(chat.running || editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.font(Brand.font(.caption))
            }
            .frame(maxWidth: 480).frame(maxWidth: .infinity, alignment: .trailing)
        } else if message.role == "user" {
            // 내 질문: 오른쪽 말풍선 (이름표 없이). 올리면 복사·편집
            let expanded = expandedQuestions.contains(message.id)
            // shortcut: guesses "long" from lines and length instead of measuring the laid-out text.
            let long = message.text.count > 600 || message.text.split(separator: "\n", omittingEmptySubsequences: false).count > 12
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.text).font(Brand.font(.body)).foregroundStyle(Brand.text).lineSpacing(5).textSelection(.enabled)
                    .lineLimit(long && !expanded ? 12 : nil)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: 480, alignment: .trailing)
                if long {
                    Button(expanded ? tr("접기") : tr("더 보기")) {
                        if expanded { expandedQuestions.remove(message.id) } else { expandedQuestions.insert(message.id) }
                    }.buttonStyle(.plain).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                }
                let showsActions = hoveredMessageID == message.id || focusedActions == message.id
                HStack(spacing: 2) {
                    ChatIconButton(systemName: copiedID == message.id ? "checkmark" : "doc.on.doc", help: tr("질문 복사"), color: Brand.gray) { copy(message.text, id: message.id) }
                    ChatIconButton(systemName: "pencil", help: tr("질문 편집"), color: Brand.gray) { editText = message.text; editingMessageID = message.id }
                        .disabled(chat.running)
                }
                .focused($focusedActions, equals: message.id)
                .opacity(showsActions ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: showsActions)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredMessageID = message.id } else if hoveredMessageID == message.id { hoveredMessageID = nil }
            }
        } else {
            // 답변: 아바타 없이 본문 그대로
            let versions = message.versions
            let shownIndex = min(shownVersions[message.id] ?? versions.count - 1, versions.count - 1)
            let shown = versions[shownIndex]
            VStack(alignment: .leading, spacing: 12) {
                let picked = chat.skills.filter { chat.current.skillIDs.contains($0.id) }
                if !picked.isEmpty { HStack(spacing: 4) { ForEach(picked, id: \.id) { BrandBadge($0.title) } } }
                if shown.status == "running" || !shown.steps.isEmpty || !(shown.trace ?? []).isEmpty {
                    ChatWorkLog(message: shown, isExpanded: Binding(
                        get: { message.status == "running" ? !collapsedSteps.contains(message.id) : expandedSteps.contains(message.id) },
                        set: { open in
                            if message.status == "running" {
                                if open { collapsedSteps.remove(message.id) } else { collapsedSteps.insert(message.id) }
                            } else if open { expandedSteps.insert(message.id) } else { expandedSteps.remove(message.id) }
                        }))
                }
                if shown.status == "failed" {
                    let parts = Self.failureParts(shown.text)
                    if !parts.received.isEmpty {
                        ChatMessageText(text: parts.received, sources: shown.sources) { source = $0 }.equatable()
                    }
                    Label(parts.error, systemImage: "exclamationmark.circle")
                        .font(Brand.font(.body)).foregroundStyle(Brand.tabText).textSelection(.enabled)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                } else if !shown.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ChatMessageText(text: shown.text, sources: shown.sources) { source = $0 }.equatable()
                }
                ForEach(shown.artifacts) { item in
                    let version = (ChatArtifact.versions(of: item, in: chat.messages).firstIndex { $0.id == item.id } ?? 0) + 1
                    Button { chat.openArtifactID = item.id } label: {
                        HStack(spacing: 14) {
                            Image(systemName: Self.artifactIcon(item.format)).font(.system(size: 22, weight: .light)).foregroundStyle(Brand.ink)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(2).help(item.title)
                                Text(item.format.uppercased() + " · " + tr("버전 \(version)")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                            }
                            Spacer(minLength: 24); Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Brand.ink)
                        }.padding(.horizontal, 16).frame(maxWidth: 360, minHeight: 68, maxHeight: 68, alignment: .leading)
                            .background(hoveredArtifactID == item.id ? ChatPalette.rowHover : chat.openArtifactID == item.id ? Brand.chipSelectedFill : .white,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chat.openArtifactID == item.id ? Brand.chipSelectedBorder : Brand.line))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { hoveredArtifactID = item.id } else if hoveredArtifactID == item.id { hoveredArtifactID = nil }
                    }
                }
                if let proposal = message.automation {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                            Text(tr("\(proposal.intervalHours)시간마다, 앱 실행 중")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                        }
                        Spacer()
                        Button(message.approvedAutomationID == nil ? tr("예약안 확인") : tr("등록됨")) { pendingAutomation = message }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(message.approvedAutomationID != nil || message.status != "complete")
                    }.padding(14).background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                }
                if message.status != "running" {
                    let showsActions = hoveredMessageID == message.id || focusedActions == message.id || chat.messages.last?.id == message.id
                    HStack(spacing: 2) {
                        if shown.status == "failed" {
                            ChatPillButton(title: tr("다시 시도"), systemName: "arrow.clockwise") { requestResend(message) }.disabled(chat.running)
                            if ChatFailure.needsSettings(Self.failureParts(shown.text).error) {
                                ChatPillButton(title: tr("설정 열기"), systemName: "gearshape") { openSettings() }
                            }
                        }
                        if versions.count > 1 {
                            HStack(spacing: 2) {
                                versionButton("chevron.left", tr("이전 답변"), message: message, to: shownIndex - 1, count: versions.count)
                                Text("\(shownIndex + 1)/\(versions.count)").font(Brand.font(.caption)).foregroundStyle(Brand.tabText).monospacedDigit()
                                    .accessibilityLabel(tr("버전 \(shownIndex + 1)/\(versions.count)"))
                                versionButton("chevron.right", tr("다음 답변"), message: message, to: shownIndex + 1, count: versions.count)
                            }
                        }
                        if !shown.sources.isEmpty {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                                    if expandedSources.contains(message.id) { expandedSources.remove(message.id) } else { expandedSources.insert(message.id) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tr("출처 \(shown.sources.count)개"))
                                    Image(systemName: expandedSources.contains(message.id) ? "chevron.down" : "chevron.right").font(.system(size: 8))
                                }.foregroundStyle(Brand.gray)
                            }
                            .accessibilityValue(expandedSources.contains(message.id) ? tr("펼침") : tr("접힘"))
                        }
                        HStack(spacing: 2) {
                            ChatIconButton(systemName: copiedID == message.id ? "checkmark" : "doc.on.doc",
                                           help: chat.messages.last(where: { $0.role == "assistant" })?.id == message.id ? tr("답변 복사 (⌘⇧C)") : tr("답변 복사"), label: tr("답변 복사"), color: Brand.gray) {
                                copy(shown.markdown, id: message.id,
                                     html: ChatArtifactHTML.render(ChatArtifact(title: "", format: "markdown", content: shown.markdown)))
                            }
                            if shown.status != "failed" {
                                ChatIconButton(systemName: "arrow.clockwise", help: tr("다시 생성"), color: Brand.gray) { requestResend(message) }
                                    .disabled(chat.running)
                                regenerateModelMenu(message)
                            }
                            if let model = shown.model {
                                Text(TitleConnection.modelTitle(model)).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1).padding(.leading, 4)
                            }
                        }
                        .opacity(showsActions ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: showsActions)
                        if ["cancelled", "interrupted"].contains(shown.status) {
                            HStack(spacing: 4) {
                                Image(systemName: "record.circle").font(.system(size: 11))
                                Text(tr("중단됨")).font(Brand.font(.caption))
                            }.foregroundStyle(Brand.tabText).padding(.horizontal, 6)
                            if chat.messages.last?.id == message.id && shownIndex == versions.count - 1 {
                                ChatPillButton(title: tr("이어서 쓰기"), systemName: "arrow.right") { chat.continueAnswer() }.disabled(chat.running)
                            }
                        }
                    }.buttonStyle(.plain).foregroundStyle(Brand.gray).font(Brand.font(.caption))
                    .focused($focusedActions, equals: message.id)
                }
                if expandedSources.contains(message.id) {
                    // 본문의 [1] 번호와 맞도록 순서, 번호를 그대로 둔다
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.sources.enumerated()), id: \.element.id) { index, item in
                            Button { source = item } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)").font(Brand.jost(10)).foregroundStyle(Brand.gray).frame(width: 14, alignment: .trailing)
                                    Text(ChatRunner.displayTitle(item.title)).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
                                }.frame(height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(ChatRunner.displayTitle(item.title))
                            .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Brand.line).frame(height: 1) } }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            // Keep the answer a container, or accessibility folds it into the work-log toggle.
            .accessibilityElement(children: .contain)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { hoveredMessageID = message.id } else if hoveredMessageID == message.id { hoveredMessageID = nil }
            }
        }
    }

    /// Args: text is a failed answer's stored text.
    /// Returns: the part that arrived before the failure, and the appended error line.
    /// Raises: none.
    static func failureParts(_ text: String) -> (received: String, error: String) {
        // The error line was appended in whichever language was active when the run failed.
        let key = "\n\n응답을 완료하지 못했습니다: %@"
        for marker in [key, L10n.english[key] ?? key].map({ $0.replacingOccurrences(of: "%@", with: "") }) {
            if let range = text.range(of: marker, options: .backwards) {
                return (String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                        String(text[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func artifactIcon(_ format: String) -> String {
        switch format.lowercased() {
        case "docx": return "doc.text"
        case "pptx": return "rectangle.on.rectangle"
        case "xlsx", "csv": return "tablecells"
        case "html", "svg": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.plaintext"
        }
    }

    private func copyLastAnswer() {
        guard let message = chat.messages.last(where: { $0.role == "assistant" }) else { return }
        let versions = message.versions
        let shown = versions[min(shownVersions[message.id] ?? versions.count - 1, versions.count - 1)]
        copy(shown.markdown, id: message.id, html: ChatArtifactHTML.render(ChatArtifact(title: "", format: "markdown", content: shown.markdown)))
    }

    private func copy(_ text: String, id: String, html: String? = nil) {
        Self.write(text, html: html)
        AccessibilityNotification.Announcement(tr("복사됨")).post()
        copiedID = id
        Task { try? await Task.sleep(for: .seconds(1.5)); if copiedID == id { copiedID = nil } }
    }

    static func write(_ text: String, html: String? = nil, to board: NSPasteboard = .general) {
        board.clearContents(); board.setString(text, forType: .string)
        if let html { board.setString(html, forType: .html) }
    }

    private func versionButton(_ symbol: String, _ label: String, message: ConversationMessage, to index: Int, count: Int) -> some View {
        Button { shownVersions[message.id] = index } label: {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Brand.tabText).disabled(!(0..<count).contains(index))
            .help(label).accessibilityLabel(label)
    }

    /// Regenerates with another chat model; only a ChatGPT connection has a list to pick from.
    @ViewBuilder private func regenerateModelMenu(_ message: ConversationMessage) -> some View {
        let models = state.settings.effectiveChatProvider == "codex"
            ? ChatModelMenu.options(models: state.chatCodexModels, current: state.settings.effectiveChatCodexModel) : []
        if models.count > 1 {
            Menu {
                ForEach(models, id: \.slug) { option in
                    Button(option.title) { requestResend(message, model: option.slug) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8)).frame(width: 16, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(chat.running)
            .help(tr("다른 모델로 다시 생성")).accessibilityLabel(tr("다른 모델로 다시 생성"))
        }
    }

    /// Resends at once when only this turn is replaced; asks first when later turns would be deleted too.
    private func requestResend(_ message: ConversationMessage, text: String? = nil, model: String? = nil) {
        let replaced = chat.replacedMessages(from: message)
        let thisTurn = replaced.count > 1 && replaced[1].role == "assistant" ? 2 : 1
        let dropped = replaced.count - thisTurn
        if dropped > 0 { pendingResend = PendingResend(message: message, text: text, dropped: dropped, model: model); return }
        // The model switches only when the resend goes ahead, so a cancelled alert changes nothing.
        if let model { state.selectChatModel(model) }
        if chat.resend(from: message, text: text) { editingMessageID = nil }
    }

    /// Args: message는 승인할 예약안을 포함한 답변이다.
    /// Returns: 요청 내용과 권한 범위를 확인하는 승인 화면.
    /// Raises: 없음.
    private func automationApproval(_ message: ConversationMessage) -> some View {
        let scope = chat.current.scope
        let connectors = (scope.connectors + (scope.useGitHub ? ["GitHub"] : [])).joined(separator: ", ")
        return ChatDialogFrame(title: tr("예약 작업 등록"), width: 600, height: 520, onClose: { pendingAutomation = nil }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proposal = message.automation {
                        Text(proposal.title).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.tabText)
                        Text(proposal.prompt).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineSpacing(6).textSelection(.enabled)
                        Text(tr("\(proposal.intervalHours)시간마다 현재 자료 범위로 실행해요. LLM과 외부 API 사용량이 발생할 수 있어요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                        VStack(alignment: .leading, spacing: 8) {
                            ChatInfoRow(label: tr("기록 범위"), value: ChatFocusButton.label(scope, choices: chat.focusChoices))
                            ChatInfoRow(label: tr("웹 검색"), value: scope.useWeb ? tr("허용") : tr("미허용"))
                            ChatInfoRow(label: tr("커넥터"), value: connectors.isEmpty ? tr("없음") : connectors)
                            if !scope.paths.isEmpty { ChatInfoRow(label: tr("연결한 파일"), value: scope.paths.joined(separator: "\n")) }
                            ForEach(library.attached) { ChatInfoRow(label: tr("보관 자료"), value: $0.title) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                        Label(tr("원본 파일 변경, 명령 실행, 메시지 발송은 하지 않아요. 앱 종료나 절전 중에는 실행되지 않아요."), systemImage: "info.circle")
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 27).padding(.vertical, 24)
            }
        } footer: {
            Spacer()
            Button(tr("취소")) { pendingAutomation = nil }.buttonStyle(ChatDialogButtonStyle())
            Button(tr("등록")) { chat.approve(message); pendingAutomation = nil }.buttonStyle(ChatDialogButtonStyle(primary: true))
        }
    }
}

/// 채팅 화면 안에서 쓰는 보조 색
enum ChatPalette {
    static let soft = Brand.paper       // 말풍선, 칩, 대화 상자 머리글 바탕
    static let inputLine = Color(hex: 0xD8D2CD)  // 입력 상자 테두리
    static let columnWidth: CGFloat = 600        // 대화 본문, 입력칸, 시작 화면이 함께 쓰는 폭 (Figma 600)
    static let sidebarWidth: CGFloat = 261
    static let navSelected = Color(hex: 0xEAE5DF)   // 사이드바 메뉴 고른 줄 (둥글기 7)
    static let cardLine = Color(hex: 0xE9E7E5)      // 카드 테두리, 목록 줄 구분선
    static let rowHover = Color(hex: 0xF3EFEA)      // 검색 결과, 메뉴 줄 고름과 마우스 올림
    static let panelLine = Color(hex: 0xE6E1DB)     // 검색 창 테두리
    static let field = Color(hex: 0xF5F2EE)         // 한 줄 입력칸 바탕 (둥글기 8, 테두리 없음)
}

/// 작은 상태 태그: 일부, 예정, 일시 중지됨
struct ChatTag: View {
    let text: String
    var body: some View {
        Text(text).font(Brand.font(.tag, .medium)).foregroundStyle(Brand.gray)
            .padding(.horizontal, 5).frame(height: 20)
            .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
    }
}

/// 머리글 오른쪽의 28pt 아이콘 버튼
struct ChatIconButton: View {
    let systemName: String
    let help: String
    var label: String? = nil
    var color: Color = Brand.tabText
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13)).foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(hovering && enabled ? ChatPalette.soft : .clear, in: RoundedRectangle(cornerRadius: 5))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(help).accessibilityLabel(label ?? help)
    }
}

struct ChatPillButton: View {
    let title: String
    let systemName: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.ink)
                .padding(.horizontal, 10).frame(height: 24)
                .background(hovering && enabled ? ChatPalette.rowHover : .white, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.line))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

/// 대화 상자 하단 버튼: 높이 38, primary는 주색 바탕
struct ChatDialogButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.font(.body, .medium))
            .foregroundStyle(primary ? Color.white : Brand.tabText)
            .padding(.horizontal, 14).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Brand.accentDark : .white))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? Brand.accentDark : Brand.line))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// 대화 상자: 제목이 있는 머리글, 흰 본문, 하단 버튼 줄
struct ChatDialogFrame<Content: View, Footer: View>: View {
    let title: String
    var detail: String? = nil
    var width: CGFloat? = 600
    var height: CGFloat? = nil
    /// Smaller head and foot for the 480pt side panel.
    var compact = false
    var onExpand: (() -> Void)? = nil
    var expanded = false
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(compact ? Brand.font(.sectionTitle, .semibold) : Brand.font(.screenTitle)).tracking(compact ? 0 : -0.77)
                    .foregroundStyle(Brand.ink).lineLimit(1).padding(.trailing, onExpand == nil ? 30 : 60)
                if let detail { Text(detail).font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 9) }
            }.padding(.horizontal, 27).padding(.top, compact ? 14 : 25).padding(.bottom, compact ? 12 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatPalette.soft)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if let onExpand {
                            let label = expanded ? tr("원래 크기로") : tr("크게 보기")
                            Button(action: onExpand) {
                                Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12)).foregroundStyle(Brand.tabText).frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(label).accessibilityLabel(label)
                        }
                        Button(action: onClose) {
                            Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Brand.tabText).frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(tr("닫기")).accessibilityLabel(tr("닫기"))
                    }.padding(.top, compact ? 8 : 19).padding(.trailing, 16)
                }
            content().frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            HStack(spacing: compact ? 8 : 10) { footer() }
                .padding(.horizontal, compact ? 20 : 24).frame(height: compact ? 56 : 73)
                .background(ChatPalette.soft)
                .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }.frame(width: width, height: height)
    }
}

/// A suggested first question on the empty chat; it fills the input and does not send.
private struct StarterChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(text).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 28)
                .background(hovering ? ChatPalette.rowHover : .white, in: Capsule()).overlay(Capsule().strokeBorder(Brand.line))
                .contentShape(Capsule())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(text)
    }
}

private struct ChatInfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(Brand.font(.caption)).foregroundStyle(Brand.gray).frame(width: 72, alignment: .leading)
            Text(value).font(Brand.font(.body)).foregroundStyle(Brand.tabText).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct ConversationTurn: Identifiable {
    var question: ConversationMessage
    var answer: ConversationMessage?
    var id: String { question.id }
}

private struct QuestionPositionKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    /// Args: value는 누적된 질문 위치, nextValue는 다음 메시지의 위치이다.
    /// Returns: 없음. 질문별 위치를 누적한다.
    /// Raises: 없음.
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ChatSourceSheet: View {
    let source: ChatSource
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Task nodes are left out: opening one would leave the chat tab.
    static func opensNode(_ source: ChatSource) -> Bool {
        source.id.hasPrefix("node:") && URINormalizer.openableURL(forKey: source.location, home: NSHomeDirectory()) != nil
    }

    var body: some View {
        ChatDialogFrame(title: source.title, width: 600, height: 400, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !source.location.isEmpty {
                        Text(source.location).font(Brand.font(.caption)).foregroundStyle(Brand.gray).textSelection(.enabled)
                    }
                    Text(source.excerpt).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineSpacing(6).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 27).padding(.vertical, 24)
            }
        } footer: {
            Spacer()
            if let url = URL(string: source.location), ["https", "http"].contains(url.scheme ?? "") {
                Link(destination: url) { HStack(spacing: 6) { Text(tr("원문 열기")); Image(systemName: "arrow.up.right").font(.system(size: 11)) } }
                    .buttonStyle(ChatDialogButtonStyle())
            } else if source.location.hasPrefix("/") {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.location)]) } label: {
                    HStack(spacing: 6) { Text(tr("Finder에서 보기")); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                }.buttonStyle(ChatDialogButtonStyle())
            } else if Self.opensNode(source) {
                Button { state.openGraphItem(uri: source.location); dismiss() } label: {
                    HStack(spacing: 6) { Text(tr("원문 열기")); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                }.buttonStyle(ChatDialogButtonStyle())
            }
            Button(tr("닫기")) { dismiss() }.buttonStyle(ChatDialogButtonStyle())
        }
    }
}

private struct ChatSchedulesView: View {
    @ObservedObject var chat: ChatState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var deletingJob: ChatAutomation?
    @State private var confirmDelete = false

    private var selected: ChatAutomation? { chat.automations.first { $0.id == selectedID } ?? chat.automations.first }

    var body: some View {
        ChatDialogFrame(title: tr("예약 작업"),
                        detail: tr("앱이 켜져 있을 때만 실행돼요. 지난 실행은 한 번만 처리해요."),
                        width: chat.automations.isEmpty ? 600 : 760, height: 505, onClose: { dismiss() }) {
            if chat.automations.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.tabText)
                        Text(tr("등록된 예약이 없어요")).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink).padding(.top, 16)
                        Text(tr("채팅에서 반복할 일을 요청하고 예약안을 승인해 주세요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button { dismiss() } label: {
                        HStack(spacing: 8) { Text(tr("채팅에서 예약안 만들기")); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                    }.buttonStyle(ChatDialogButtonStyle()).padding(.bottom, 24)
                }.padding(.horizontal, 27)
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 5) {
                            ForEach(chat.automations) { job in
                                HStack(spacing: 2) {
                                    Button { selectedID = job.id } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(job.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                                            Text(tr("\(job.intervalHours)시간마다, \(L10n.tr(key: job.lastStatus))"))
                                                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    ChatIconButton(systemName: job.enabled ? "pause.fill" : "play.fill", help: job.enabled ? tr("일시 중지") : tr("다시 시작")) { chat.toggle(job) }
                                    ChatIconButton(systemName: "trash", help: tr("예약 삭제")) { deletingJob = job; confirmDelete = true }
                                }.padding(.leading, 12).padding(.trailing, 4).frame(height: 52)
                                    .background(selected?.id == job.id ? ChatPalette.soft : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected?.id == job.id ? Brand.line : .clear))
                            }
                        }.padding(12)
                    }.frame(width: 280)
                    Rectangle().fill(Brand.line).frame(width: 1)
                    if let job = selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Text(job.title).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink)
                                    ChatTag(text: job.enabled ? tr("실행 대기") : tr("일시 중지됨"))
                                }
                                Text(tr("요청 내용")).font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.top, 4)
                                Text(job.prompt).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
                                ChatInfoRow(label: tr("실행 간격"), value: tr("\(job.intervalHours)시간마다"))
                                ChatInfoRow(label: tr("기록 범위"), value: ChatFocusButton.label(job.scope, choices: chat.focusChoices))
                                ChatInfoRow(label: tr("웹 검색"), value: job.scope.useWeb ? tr("사용") : tr("사용 안 함"))
                                ChatInfoRow(label: tr("커넥터"), value: (job.scope.connectors + (job.scope.useGitHub ? ["GitHub"] : [])).joined(separator: ", "))
                                if !job.scope.paths.isEmpty { ChatInfoRow(label: tr("연결한 파일"), value: job.scope.paths.joined(separator: "\n")) }
                                ForEach(chat.library.items.filter { job.scope.libraryIDs.contains($0.id) }) { ChatInfoRow(label: tr("보관 자료"), value: $0.title) }
                                ChatInfoRow(label: tr("최근 상태"), value: L10n.tr(key: job.lastStatus))
                                if job.enabled { ChatInfoRow(label: tr("다음 실행"), value: Date(timeIntervalSince1970: job.nextRun).formatted()) }
                                if let id = job.lastConversationID, let conversation = chat.conversations.first(where: { $0.id == id }) {
                                    Button(tr("최근 실행 보기")) { chat.select(conversation); dismiss() }.buttonStyle(ChatDialogButtonStyle()).padding(.top, 6)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button(tr("닫기")) { dismiss() }.buttonStyle(.plain).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)   // CH-10
        }
        .alert(tr("예약 작업 삭제"), isPresented: $confirmDelete) {
            Button(tr("취소"), role: .cancel) { deletingJob = nil }
            Button(tr("삭제"), role: .destructive) {
                if let deletingJob {
                    chat.deleteAutomation(deletingJob)
                    if selectedID == deletingJob.id { selectedID = nil }
                }
                deletingJob = nil
            }
        } message: { Text(tr("예약을 삭제합니다. 이미 생성된 대화는 그대로 남습니다.")) }
    }
}

/// 새 대화 화면 바탕: 발표 표지(Figma 1231:39559)와 같은 옅은 회색 바탕에 그래프 분야 색 번짐 다섯 개.
/// 색과 불투명도는 표지 채움 그대로, 위치는 화면 전체에 고루 퍼지게 옮김. 위치와 반지름은 화면 폭, 높이에 대한 비율
struct ChatStartBackground: View {
    private struct Glow { let color: Color; let x, y, rx, ry, a0, a55: CGFloat }
    private static let glows: [Glow] = [
        Glow(color: Color(hex: 0x4A86C5), x: 0.04, y: 0.42, rx: 0.30, ry: 0.55, a0: 0.22, a55: 0.08),   // 파랑
        Glow(color: Color(hex: 0x8A4E7D), x: 0.96, y: 0.80, rx: 0.26, ry: 0.46, a0: 0.20, a55: 0.07),   // 보라
        Glow(color: Color(hex: 0x3D9B6B), x: 0.36, y: 1.02, rx: 0.26, ry: 0.38, a0: 0.18, a55: 0.06),   // 초록
        Glow(color: Color(hex: 0xE9B23F), x: 0.42, y: -0.02, rx: 0.24, ry: 0.30, a0: 0.22, a55: 0.08),  // 노랑
        Glow(color: Color(hex: 0xE0533D), x: 0.98, y: 0.10, rx: 0.22, ry: 0.36, a0: 0.18, a55: 0.06),   // 빨강
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(hex: 0xF7F8FA), Color(hex: 0xE6E9EE)], startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
                ForEach(Self.glows.indices, id: \.self) { i in
                    let g = Self.glows[i]
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: g.color.opacity(g.a0), location: 0),
                                                     .init(color: g.color.opacity(g.a55), location: 0.55),
                                                     .init(color: g.color.opacity(0), location: 1)],
                                             center: .center, startRadius: 0, endRadius: 100))
                        .frame(width: 200, height: 200)
                        .scaleEffect(x: g.rx * 2 * geo.size.width / 200, y: g.ry * 2 * geo.size.height / 200)
                        .position(x: g.x * geo.size.width, y: g.y * geo.size.height)
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}
