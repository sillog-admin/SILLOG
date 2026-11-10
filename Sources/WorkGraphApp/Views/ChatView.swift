import SwiftUI
import WorkGraphCore

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
    @State private var artifact: ChatArtifact?
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

    /// 목록(261, 고정 폭) + 1pt 선 + 본문. 목록을 접으면(CH-30) 본문만 남는다.
    private var layout: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ChatSidebar(chat: chat, projects: chat.projects, pane: $pane, isSearching: showSearch,
                            onSearch: { showSearch = true },
                            onSchedules: { showSchedules = true },
                            onCollapse: { sidebarVisible = false },
                            onRename: { item in editingConversation = item; conversationName = item.title; showRename = true },
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
                                onOpen: { item in chat.select(item); pane = .chat; showSearch = false },
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
        .sheet(item: $artifact) { ArtifactPreview(artifact: $0) }
        .sheet(item: $source) { ChatSourceSheet(source: $0) }
        .sheet(item: $pendingAutomation) { message in automationApproval(message) }
        .sheet(isPresented: $showSchedules) { ChatSchedulesView(chat: chat) }
        .sheet(item: $previewItem) { LibraryPreview(library: library, item: $0) }
    }

    var body: some View {
        sheets
        .onAppear { if state.showsChatResultsOnOpen { pane = .results } }
        .alert("이름 바꾸기", isPresented: $showRename) {
            TextField("대화 이름", text: $conversationName)
            Button("취소", role: .cancel) {}
            Button("저장") {
                if let item = editingConversation { chat.rename(item, title: conversationName) }
            }.disabled(conversationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("대화를 삭제할까요?", isPresented: $showDelete) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) {
                if let item = deletingConversation { chat.delete(item) }
            }
        } message: {
            Text("‘\(deletingConversation?.title ?? "")’의 메시지와 결과물이 삭제되며 복구할 수 없습니다. 원본 자료와 등록된 예약 작업은 유지됩니다.")
        }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme ?? "") ? .systemAction : .discarded
        })
        .onChange(of: chat.current.scope) { old, new in if old != new { chat.saveScope() } }
        .onChange(of: chat.current.skillIDs) { old, new in if old != new { chat.saveScope() } }
    }

    private var mainContent: some View {
        Group {
            switch pane {
            case .chat:
                chatContent
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
                LibraryView(library: library, initialKind: "", title: "결과물")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if !chat.messages.isEmpty || !sidebarVisible { header }
            if let active = chat.activeMessage, active.conversationID != chat.current.id {
                // CH-14: 본문 600 열 안, 머리에서 떨어진 47 높이 띠, 아래 줄 하나, '이동'은 글자 링크
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("다른 대화에서 작업 중").font(Brand.suit(11)).foregroundStyle(Brand.tabText)
                    Button {
                        if let item = chat.conversations.first(where: { $0.id == active.conversationID }) { chat.select(item) }
                    } label: { Text("이동").font(Brand.suit(11, .medium)).foregroundStyle(Brand.ink) }
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
            if let error = chat.error {
                // CH-17: 입력칸과 같은 600 열, 위아래 줄, 입력칸 위 8 간격
                Label(error, systemImage: "exclamationmark.circle")
                    .font(Brand.suit(11)).foregroundStyle(Brand.ink).textSelection(.enabled)
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
                     pendingRecords: pendingRecords, tidyNow: tidyNow, onOpenConnectors: { state.selectedTab = .connectors })
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
                Text("쌓아 온 기록으로 다음 일을 시작해요")
                    .font(Brand.suit(24)).tracking(-0.48).foregroundStyle(Brand.ink).lineLimit(1)
                    .frame(maxWidth: .infinity)
                ChatComposer(chat: chat, library: library, modelName: modelName, openSettings: openSettings,
                             pendingRecords: pendingRecords, tidyNow: tidyNow, onOpenConnectors: { state.selectedTab = .connectors },
                             showsNotice: false)
                    .overlay(alignment: .topTrailing) {             // Figma 1591:18788: 입력칸 오른쪽 위에 올라앉은 심볼
                        GazingMark(size: 72, smiling: !chat.draft.isEmpty).offset(x: -24, y: -63).allowsHitTesting(false)
                    }
                    .padding(.top, 28)
                if !results.isEmpty {
                    HStack {
                        Text("최근 결과물").font(Brand.suit(12)).foregroundStyle(Brand.tabText).padding(.leading, 4)
                        Spacer()
                        Button { pane = .results } label: {
                            Text("모두 보기").font(Brand.suit(12)).foregroundStyle(Brand.tabText).contentShape(Rectangle())
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
            Text("질문과 조회한 자료는 연결한 AI로 전송돼요. 웹 검색과 커넥터는 허용한 범위만 사용해요.")
                .font(Brand.suit(9)).foregroundStyle(Brand.gray).lineLimit(1).padding(.bottom, 14)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 본문 머리(CH-02): 제목 하나, 밑줄 없음. 목록을 접었을 때(CH-30)만 목록 펼치기와 새 대화 아이콘이 제목 왼쪽에 붙는다.
    private var header: some View {
        HStack(spacing: 8) {
            if !sidebarVisible {
                // CH-30: 아이콘 중심 35, 64, 제목 시작 87 (아이콘 28 폭, 간격 1)
                HStack(spacing: 1) {
                    ChatIconButton(systemName: "sidebar.left", help: "대화 목록 표시 전환") { sidebarVisible = true }
                    ChatIconButton(systemName: "square.and.pencil", help: "새 대화") { chat.newConversation(); pane = .chat }
                }
            }
            if !chat.messages.isEmpty {
                HoverScrollingText(text: chat.current.title).font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink)
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
                                    withAnimation(.easeInOut(duration: 0.25)) {
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
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        if hovering { hoveredQuestionID = turn.id }
                                        else if hoveredQuestionID == turn.id { hoveredQuestionID = nil }
                                    }
                                }
                                .accessibilityLabel("질문 \(index + 1): \(turn.question.text)")
                            }
                            if let index = turns.firstIndex(where: { $0.id == hoveredQuestionID }) {
                                turnPreview(turns[index])
                                    .offset(x: 48, y: min(max(18 + CGFloat(index) * step - 24, 8),
                                                          max(8, geometry.size.height - 160)))
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(.easeOut(duration: 0.18), value: hoveredQuestionID)
                    }
                    .frame(width: 44)
                    .zIndex(1)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(chat.messages) { message in
                            messageView(message)
                                .id(message.id)
                                .background {
                                    if message.role == "user" {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: QuestionPositionKey.self,
                                                value: [message.id: geometry.frame(in: .named("chatTranscript")).minY])
                                        }
                                    }
                                }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: ChatPalette.columnWidth).frame(maxWidth: .infinity).padding(.horizontal, 32).padding(.vertical, 24)
                }
                .coordinateSpace(name: "chatTranscript")
                .defaultScrollAnchor(.bottom)
                .onPreferenceChange(QuestionPositionKey.self) { positions in
                    let ordered = positions.sorted { $0.value < $1.value }
                    selectedQuestionID = ordered.last(where: { $0.value <= 100 })?.key ?? ordered.first?.key
                }
                .onChange(of: chat.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.current.id) { _, _ in
                    selectedQuestionID = nil
                    hoveredQuestionID = nil
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .overlay(alignment: .bottomTrailing) {
                    if chat.running {
                        Button { proxy.scrollTo("bottom", anchor: .bottom) } label: {
                            Image(systemName: "arrow.down").font(.system(size: 11)).foregroundStyle(Brand.tabText).frame(width: 30, height: 30).background(.white, in: Circle()).overlay(Circle().strokeBorder(Brand.line))
                        }.buttonStyle(.plain).help("최근 응답으로").padding(16)
                    }
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
            Text(turn.question.text).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).lineLimit(2)
            Rectangle().fill(Brand.line).frame(height: 1)
            if let answer = turn.answer, !answer.text.isEmpty {
                Text(answer.text).font(Brand.suit(12)).foregroundStyle(Brand.gray).lineLimit(3)
            } else {
                Text(turn.answer?.status == "running" ? "답변 작성 중…" : "답변 없음")
                    .font(Brand.suit(12)).foregroundStyle(Brand.gray)
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
        if message.role == "user" {
            // 내 질문: 오른쪽 말풍선 (이름표 없이)
            Text(message.text).font(Brand.suit(12)).foregroundStyle(Brand.text).lineSpacing(5).textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 560, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            // 답변: 아바타 없이 본문 그대로
            VStack(alignment: .leading, spacing: 12) {
                let picked = chat.skills.filter { chat.current.skillIDs.contains($0.id) }
                if !picked.isEmpty { HStack(spacing: 4) { ForEach(picked, id: \.id) { BrandBadge($0.title) } } }
                if message.status == "running" || !message.steps.isEmpty {
                    DisclosureGroup(isExpanded: Binding(
                        get: { message.status == "running" ? !collapsedSteps.contains(message.id) : expandedSteps.contains(message.id) },
                        set: { open in
                            if message.status == "running" {
                                if open { collapsedSteps.remove(message.id) } else { collapsedSteps.insert(message.id) }
                            } else if open { expandedSteps.insert(message.id) } else { expandedSteps.remove(message.id) }
                        })) {
                        ForEach(Array(message.steps.enumerated()), id: \.offset) { _, step in
                            Text(step).font(Brand.suit(10)).foregroundStyle(Brand.gray).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if message.status == "running" { ProgressView().controlSize(.small) }
                            Text(message.steps.last ?? "답변을 준비하고 있습니다").font(Brand.suit(11))
                        }
                    }.foregroundStyle(Brand.gray)
                }
                if message.status == "failed" {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("응답을 완료하지 못했습니다", systemImage: "exclamationmark.circle").font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                        Text(message.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(Brand.suit(12)).foregroundStyle(Brand.tabText).textSelection(.enabled)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                } else if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ChatMessageText(text: message.text, sources: message.sources) { source = $0 }
                }
                ForEach(message.artifacts) { item in
                    Button { artifact = item } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "doc.text").font(.system(size: 22, weight: .light)).foregroundStyle(Brand.ink)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                                Text("\(item.format.uppercased()) 결과물, 미리보기").font(Brand.suit(10)).foregroundStyle(Brand.gray)
                            }
                            Spacer(minLength: 24); Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(Brand.ink)
                        }.padding(.horizontal, 16).frame(width: 360, height: 68, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if let proposal = message.automation {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                            Text("\(proposal.intervalHours)시간마다, 앱 실행 중").font(Brand.suit(10)).foregroundStyle(Brand.gray)
                        }
                        Spacer()
                        Button(message.approvedAutomationID == nil ? "예약안 확인" : "등록됨") { pendingAutomation = message }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(message.approvedAutomationID != nil || message.status != "complete")
                    }.padding(14).background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                }
                if message.status != "running" {
                    HStack(spacing: 16) {
                        if !message.sources.isEmpty {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    if expandedSources.contains(message.id) { expandedSources.remove(message.id) } else { expandedSources.insert(message.id) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("출처 \(message.sources.count)개")
                                    Image(systemName: expandedSources.contains(message.id) ? "chevron.down" : "chevron.right").font(.system(size: 8))
                                }.foregroundStyle(Brand.gray)
                            }
                        }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 13))
                        }.help("답변 복사")
                        if ["cancelled", "interrupted"].contains(message.status) {
                            HStack(spacing: 4) {
                                Image(systemName: "record.circle").font(.system(size: 11))
                                Text("중단됨").font(Brand.suit(11))
                            }.foregroundStyle(Brand.tabText)
                        }
                        if message.status == "failed" {
                            Button("요청 다시 입력") {
                                if let index = chat.messages.firstIndex(where: { $0.id == message.id }),
                                   let request = chat.messages[..<index].last(where: { $0.role == "user" }) { chat.draft = request.text }
                            }.font(Brand.suit(10))
                        }
                    }.buttonStyle(.plain).foregroundStyle(Brand.gray).font(Brand.suit(11))
                }
                if expandedSources.contains(message.id) {
                    // 본문의 [1] 번호와 맞도록 순서, 번호를 그대로 둔다
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, item in
                            Button { source = item } label: {
                                HStack(spacing: 10) {
                                    Text("\(index + 1)").font(Brand.jost(10)).foregroundStyle(Brand.gray).frame(width: 14, alignment: .trailing)
                                    Text(item.title).font(Brand.suit(11)).foregroundStyle(Brand.tabText).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
                                }.frame(height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(item.title)
                            .overlay(alignment: .top) { if index > 0 { Rectangle().fill(Brand.line).frame(height: 1) } }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Args: message는 승인할 예약안을 포함한 답변이다.
    /// Returns: 요청 내용과 권한 범위를 확인하는 승인 화면.
    /// Raises: 없음.
    private func automationApproval(_ message: ConversationMessage) -> some View {
        let scope = chat.current.scope
        let connectors = (scope.connectors + (scope.useGitHub ? ["GitHub"] : [])).joined(separator: ", ")
        return ChatDialogFrame(title: "예약 작업 등록", width: 600, height: 520, onClose: { pendingAutomation = nil }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proposal = message.automation {
                        Text(proposal.title).font(Brand.suit(16)).foregroundStyle(Brand.tabText)
                        Text(proposal.prompt).font(Brand.suit(13)).foregroundStyle(Brand.tabText).lineSpacing(6).textSelection(.enabled)
                        Text("\(proposal.intervalHours)시간마다 현재 자료 범위로 실행해요. LLM과 외부 API 사용량이 발생할 수 있어요.")
                            .font(Brand.suit(12)).foregroundStyle(Brand.gray)
                        VStack(alignment: .leading, spacing: 8) {
                            ChatInfoRow(label: "기록 범위", value: ChatFocusButton.label(scope, choices: chat.focusChoices))
                            ChatInfoRow(label: "웹 검색", value: scope.useWeb ? "허용" : "미허용")
                            ChatInfoRow(label: "커넥터", value: connectors.isEmpty ? "없음" : connectors)
                            if !scope.paths.isEmpty { ChatInfoRow(label: "연결한 파일", value: scope.paths.joined(separator: "\n")) }
                            ForEach(library.sources(conversationID: chat.current.id, projectID: chat.current.projectID)) { ChatInfoRow(label: "보관 자료", value: $0.title) }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                        Label("원본 파일 변경, 명령 실행, 메시지 발송은 하지 않아요. 앱 종료나 절전 중에는 실행되지 않아요.", systemImage: "info.circle")
                            .font(Brand.suit(12)).foregroundStyle(Brand.gray)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 27).padding(.vertical, 24)
            }
        } footer: {
            Spacer()
            Button("취소") { pendingAutomation = nil }.buttonStyle(ChatDialogButtonStyle())
            Button("등록") { chat.approve(message); pendingAutomation = nil }.buttonStyle(ChatDialogButtonStyle(primary: true))
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
        Text(text).font(Brand.suit(10, .medium)).foregroundStyle(Brand.gray)
            .padding(.horizontal, 5).frame(height: 20)
            .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Brand.line))
    }
}

/// 머리글 오른쪽의 28pt 아이콘 버튼
struct ChatIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 13)).foregroundStyle(Brand.tabText)
                .frame(width: 28, height: 28)
                .background(hovering && enabled ? ChatPalette.soft : .clear, in: RoundedRectangle(cornerRadius: 5))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(help).accessibilityLabel(help)
    }
}

/// 대화 상자 하단 버튼: 높이 38, primary는 주색 바탕
struct ChatDialogButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.suit(12, .medium))
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
    var width: CGFloat = 600
    var height: CGFloat? = nil
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Brand.suit(22)).tracking(-0.77).foregroundStyle(Brand.ink).lineLimit(1).padding(.trailing, 30)
                if let detail { Text(detail).font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 9) }
            }.padding(.horizontal, 27).padding(.top, 25).padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChatPalette.soft)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
                .overlay(alignment: .topTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Brand.tabText).frame(width: 28, height: 28).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("닫기").accessibilityLabel("닫기").padding(.top, 19).padding(.trailing, 16)
                }
            content().frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            HStack(spacing: 10) { footer() }
                .padding(.horizontal, 24).frame(height: 73)
                .background(ChatPalette.soft)
                .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }.frame(width: width, height: height)
    }
}

private struct ChatInfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(Brand.suit(11)).foregroundStyle(Brand.gray).frame(width: 72, alignment: .leading)
            Text(value).font(Brand.suit(12)).foregroundStyle(Brand.tabText).textSelection(.enabled)
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

private struct ChatSourceSheet: View {
    let source: ChatSource
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ChatDialogFrame(title: source.title, width: 600, height: 400, onClose: { dismiss() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !source.location.isEmpty {
                        Text(source.location).font(Brand.suit(11)).foregroundStyle(Brand.gray).textSelection(.enabled)
                    }
                    Text(source.excerpt).font(Brand.suit(13)).foregroundStyle(Brand.tabText).lineSpacing(6).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 27).padding(.vertical, 24)
            }
        } footer: {
            Spacer()
            if let url = URL(string: source.location), ["https", "http"].contains(url.scheme ?? "") {
                Link(destination: url) { HStack(spacing: 6) { Text("원문 열기"); Image(systemName: "arrow.up.right").font(.system(size: 11)) } }
                    .buttonStyle(ChatDialogButtonStyle())
            } else if source.location.hasPrefix("/") {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.location)]) } label: {
                    HStack(spacing: 6) { Text("Finder에서 보기"); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                }.buttonStyle(ChatDialogButtonStyle())
            }
            Button("닫기") { dismiss() }.buttonStyle(ChatDialogButtonStyle())
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
        ChatDialogFrame(title: "예약 작업",
                        detail: "앱이 켜져 있을 때만 실행돼요. 지난 실행은 한 번만 처리해요.",
                        width: chat.automations.isEmpty ? 600 : 760, height: 505, onClose: { dismiss() }) {
            if chat.automations.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.tabText)
                        Text("등록된 예약이 없어요").font(Brand.suit(17, .medium)).foregroundStyle(Brand.ink).padding(.top, 16)
                        Text("채팅에서 반복할 일을 요청하고 예약안을 승인해 주세요.").font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button { dismiss() } label: {
                        HStack(spacing: 8) { Text("채팅에서 예약안 만들기"); Image(systemName: "arrow.up.right").font(.system(size: 11)) }
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
                                            Text(job.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                                            Text("\(job.intervalHours)시간마다, \(job.lastStatus)")
                                                .font(Brand.suit(10)).foregroundStyle(Brand.gray).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    ChatIconButton(systemName: job.enabled ? "pause.fill" : "play.fill", help: job.enabled ? "일시 중지" : "다시 시작") { chat.toggle(job) }
                                    ChatIconButton(systemName: "trash", help: "예약 삭제") { deletingJob = job; confirmDelete = true }
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
                                    Text(job.title).font(Brand.suit(16)).foregroundStyle(Brand.ink)
                                    ChatTag(text: job.enabled ? "실행 대기" : "일시 중지됨")
                                }
                                Text("요청 내용").font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 4)
                                Text(job.prompt).font(Brand.suit(13)).foregroundStyle(Brand.tabText).lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 4)
                                ChatInfoRow(label: "실행 간격", value: "\(job.intervalHours)시간마다")
                                ChatInfoRow(label: "기록 범위", value: ChatFocusButton.label(job.scope, choices: chat.focusChoices))
                                ChatInfoRow(label: "웹 검색", value: job.scope.useWeb ? "사용" : "사용 안 함")
                                ChatInfoRow(label: "커넥터", value: (job.scope.connectors + (job.scope.useGitHub ? ["GitHub"] : [])).joined(separator: ", "))
                                if !job.scope.paths.isEmpty { ChatInfoRow(label: "연결한 파일", value: job.scope.paths.joined(separator: "\n")) }
                                ForEach(chat.library.items.filter { job.scope.libraryIDs.contains($0.id) }) { ChatInfoRow(label: "보관 자료", value: $0.title) }
                                ChatInfoRow(label: "최근 상태", value: job.lastStatus)
                                if job.enabled { ChatInfoRow(label: "다음 실행", value: Date(timeIntervalSince1970: job.nextRun).formatted()) }
                                if let id = job.lastConversationID, let conversation = chat.conversations.first(where: { $0.id == id }) {
                                    Button("최근 실행 보기") { chat.select(conversation); dismiss() }.buttonStyle(ChatDialogButtonStyle()).padding(.top, 6)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button("닫기") { dismiss() }.buttonStyle(.plain).font(Brand.suit(12, .medium)).foregroundStyle(Brand.tabText)   // CH-10: 테두리 없는 글자 단추
        }
        .alert("예약 작업 삭제", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) { deletingJob = nil }
            Button("삭제", role: .destructive) {
                if let deletingJob {
                    chat.deleteAutomation(deletingJob)
                    if selectedID == deletingJob.id { selectedID = nil }
                }
                deletingJob = nil
            }
        } message: { Text("예약을 삭제합니다. 이미 생성된 대화는 그대로 남습니다.") }
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
