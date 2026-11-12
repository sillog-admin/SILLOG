import SwiftUI
import SillogCore

struct ProjectMoveMenu: View {
    @ObservedObject var projects: ProjectState
    var itemID: String
    private var currentProjectID: String? { projects.items.first(where: { $0.id == itemID })?.projectID }

    var body: some View {
        Menu {
            ForEach(projects.projects) { project in
                Button(project.title) { projects.move(itemID, to: project.id) }
                    .disabled(project.id == currentProjectID)
            }
            Divider()
            Button(itemID.hasPrefix("task:") ? tr("프로젝트에서 빼기") : tr("일반 채팅으로 옮기기")) {
                projects.move(itemID, to: nil)
            }.disabled(currentProjectID == nil)
        } label: { Label(tr("프로젝트로 옮기기"), systemImage: "folder") }
    }
}

struct ProjectAssignmentLabel: View {
    @ObservedObject var projects: ProjectState
    var itemID: String

    var body: some View {
        if let id = projects.items.first(where: { $0.id == itemID })?.projectID,
           let project = projects.projects.first(where: { $0.id == id }) {
            Label(project.title, systemImage: "folder").font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
        }
    }
}

struct ProjectOverview<Composer: View>: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var projects: ProjectState
    @ObservedObject var chat: ChatState
    var project: ChatProject
    var onConversation: (ChatConversation) -> Void
    var composer: Composer
    @State private var tab = tr("채팅")
    @State private var sourceKind = ""
    @State private var newestFirst = true
    @State private var hoveredConversation: String?
    @State private var name = ""
    @State private var showRename = false
    @State private var showDelete = false
    @State private var showSettings = false
    @State private var tasksOpen = false

    private var conversations: [ChatConversation] { chat.conversations.filter { $0.projectID == project.id } }
    private var tasks: [ProjectItem] { projects.items.filter { $0.projectID == project.id && $0.isTask } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 14) {
                    Image(systemName: "folder").font(.system(size: 22, weight: .regular)).foregroundStyle(Brand.ink)
                    Text(project.title).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink).lineLimit(2)
                    Spacer(minLength: 12)
                    Menu {
                        Button(tr("프로젝트 설정")) { showSettings = true }.disabled(chat.running)
                        Button(tr("이름 바꾸기")) { name = project.title; showRename = true }
                        Divider()
                        Button(tr("프로젝트 삭제"), role: .destructive) { showDelete = true }.disabled(chat.running)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(Brand.tabText)
                            .frame(width: 30, height: 30)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(tr("프로젝트 메뉴")).accessibilityLabel(tr("프로젝트 메뉴"))
                }
                composer
                HStack(spacing: 8) {
                    ForEach([tr("채팅"), tr("소스")], id: \.self) { value in
                        Button { tab = value } label: {
                            Text(value).font(Brand.font(.body, tab == value ? .medium : .regular))
                                .foregroundStyle(tab == value ? Brand.chipSelectedText : Brand.tabText)
                                .padding(.horizontal, 16).frame(height: 32)
                                .background(tab == value ? Brand.chipSelectedFill : Brand.chipFill, in: Capsule())
                                .overlay { if tab == value { Capsule().strokeBorder(Brand.chipSelectedBorder, lineWidth: 1) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                    }
                    Spacer()
                    if tab == tr("소스") {
                        Menu(newestFirst ? tr("최신순") : tr("오래된순")) {
                            Button(tr("최신순")) { newestFirst = true }
                            Button(tr("오래된순")) { newestFirst = false }
                        }.menuStyle(.borderlessButton).fixedSize().font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        Menu(sourceKindTitle) {
                            Button(tr("전체")) { sourceKind = "" }
                            Button(tr("업로드")) { sourceKind = "upload" }
                            Button(tr("생성한 파일")) { sourceKind = "generated" }
                            Button(tr("저장한 답변")) { sourceKind = "note" }
                            Button(tr("폴더 연결")) { sourceKind = "folder" }
                        }.menuStyle(.borderlessButton).fixedSize().font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.leading, 12)
                    }
                }.padding(.top, 4)
                if tab == tr("채팅") { conversationList }
                else { ProjectSourcesView(library: chat.library, projects: projects, project: project, kind: $sourceKind, newestFirst: $newestFirst) }
                if let error = projects.error { Text(error).font(Brand.font(.body)).foregroundStyle(.red).textSelection(.enabled) }
                if let error = chat.error { Text(error).font(Brand.font(.body)).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(maxWidth: ChatPalette.columnWidth, alignment: .leading)
                .padding(.horizontal, 34).padding(.top, 40).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }.background(.white)
        .sheet(isPresented: $showSettings) { ProjectEditor(projects: projects, project: project) { _ in } }
        .alert(tr("프로젝트 이름 바꾸기"), isPresented: $showRename) {
            TextField(tr("프로젝트 이름"), text: $name)
            Button(tr("취소"), role: .cancel) {}
            Button(tr("저장")) { projects.rename(project, title: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(tr("프로젝트를 삭제할까요?"), isPresented: $showDelete) {
            Button(tr("취소"), role: .cancel) {}
            Button(tr("삭제"), role: .destructive) { projects.delete(project) }
        } message: { Text(tr("업무·대화·파일은 남으며, 프로젝트로 묶인 상태만 해제됩니다.")) }
    }

    private var sourceKindTitle: String {
        switch sourceKind {
        case "upload": return tr("업로드")
        case "generated": return tr("생성한 파일")
        case "note": return tr("저장한 답변")
        case "folder": return tr("폴더 연결")
        default: return tr("전체")
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if conversations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("첫 채팅을 시작해보세요")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                    Text(tr("위 입력창에서 질문하면 이 프로젝트에 새 채팅이 만들어집니다."))
                        .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                }.padding(.vertical, 32).padding(.horizontal, 16)
            }
            ForEach(conversations) { conversation in
                HStack(spacing: 12) {
                    Button { onConversation(conversation) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HoverScrollingText(text: conversation.title, rowHovered: hoveredConversation == conversation.id)
                                .font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
                            let preview = chat.conversationPreviews[conversation.id, default: ""]
                            if !preview.isEmpty {
                                Text(preview.replacingOccurrences(of: "\n", with: " "))
                                    .font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 17)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text(ChatDateText.day(conversation.updatedAt))
                        .font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                    Menu {
                        ProjectMoveMenu(projects: projects, itemID: "conversation:\(conversation.id)")
                            .disabled(chat.activeMessage?.conversationID == conversation.id)
                    } label: { Image(systemName: "ellipsis").foregroundStyle(Brand.gray).frame(width: 24, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .opacity(hoveredConversation == conversation.id ? 1 : 0)
                        .accessibilityLabel(tr("\(conversation.title) 채팅 메뉴"))
                }.padding(.horizontal, 16)
                    .background(hoveredConversation == conversation.id ? Brand.paper : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .onHover { hoveredConversation = $0 ? conversation.id : nil }
                    .contextMenu {
                        ProjectMoveMenu(projects: projects, itemID: "conversation:\(conversation.id)")
                            .disabled(chat.activeMessage?.conversationID == conversation.id)
                    }
                Rectangle().fill(ChatPalette.cardLine).frame(height: 1)
            }
            if !tasks.isEmpty {
                // CH-51: '연결된 업무 N' 글자 뒤에 꺾쇠, 기본 접힘
                Button { withAnimation(.easeOut(duration: 0.15)) { tasksOpen.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text(tr("연결된 업무 \(tasks.count)")).font(Brand.font(.body))
                        Image(systemName: tasksOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .medium))
                    }.foregroundStyle(Brand.gray).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 28)
                if tasksOpen {
                    ForEach(tasks) { item in
                        HStack(spacing: 12) {
                            Label(item.title, systemImage: "checklist").font(Brand.font(.body)).foregroundStyle(Brand.tabText)
                            Spacer()
                            if let id = Int64(item.id.dropFirst(5)) {
                                Button(tr("다시 열기")) { state.prepareResume(taskId: id) }.buttonStyle(.plain).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.tabText)
                            }
                            Menu { ProjectMoveMenu(projects: projects, itemID: item.id) } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }.padding(.vertical, 9).padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

struct ProjectEditor: View {
    @ObservedObject var projects: ProjectState
    let project: ChatProject?
    var onSave: (ChatProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var goal: String
    @State private var instructions: String
    @State private var memoryMode: ProjectMemoryMode
    @State private var paths: [String] = []
    @State private var showDetails: Bool
    @State private var showMemory = false

    init(projects: ProjectState, project: ChatProject? = nil, onSave: @escaping (ChatProject) -> Void) {
        self.projects = projects; self.project = project; self.onSave = onSave
        _title = State(initialValue: project?.title ?? ""); _goal = State(initialValue: project?.goal ?? "")
        _instructions = State(initialValue: project?.instructions ?? ""); _memoryMode = State(initialValue: project?.memoryMode ?? .allRecords)
        _showDetails = State(initialValue: project != nil)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibrarySheetHeader(title: project == nil ? tr("프로젝트 만들기") : tr("프로젝트 설정")) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tr("프로젝트 이름")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(Brand.gray)
                            TextField(tr("프로젝트 이름을 입력하세요"), text: $title).textFieldStyle(.plain).font(Brand.font(.body)).foregroundStyle(Brand.text)
                        }.padding(.horizontal, 2).frame(height: 36)
                            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }     // CH-54: 바탕 없이 밑줄
                    }
                    if project == nil {
                        folderSelection
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle").font(.system(size: 14)).padding(.top, 1)
                            Text(tr("채팅, 파일, 공통 지침을 한곳에 모아두세요. 프로젝트의 모든 채팅에서 함께 활용할 수 있습니다."))
                                .font(Brand.font(.body)).lineSpacing(3)
                        }.foregroundStyle(Brand.gray)
                        Button { showDetails.toggle() } label: {
                            HStack { Text(tr("목표와 지침 (선택)")); Spacer(); Image(systemName: showDetails ? "chevron.up" : "chevron.down") }
                                .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                        }.buttonStyle(.plain)
                    }
                    if showDetails { details }
                }.padding(.horizontal, 27).padding(.vertical, 24)
            }.frame(height: project != nil ? 340 : showDetails ? 420 : 330).scrollIndicators(.hidden).background(.white)
            if let error = projects.error { Text(error).foregroundStyle(.red).font(Brand.font(.body)).padding(.horizontal, 27).padding(.bottom, 8).background(.white) }
            HStack(spacing: 8) {
                Button { showMemory.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(memoryMode == .allRecords ? tr("기본 메모리") : tr("프로젝트 전용 메모리"))
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                }.buttonStyle(ProjectPillStyle()).popover(isPresented: $showMemory) { memoryOptions }
                Spacer()
                Button(project == nil ? tr("프로젝트 만들기") : tr("저장")) { save() }
                    .buttonStyle(ProjectPillStyle(kind: .primary)).disabled(!canSave)
            }.padding(.horizontal, 24).frame(height: 63)
                .brandGlass()
                .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }.frame(width: 560).background(.white)
    }

    private var folderSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("소스 폴더")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
            VStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in
                    HStack {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder").lineLimit(1)
                        Spacer()
                        Button { paths.removeAll { $0 == path } } label: { Image(systemName: "xmark").font(.system(size: 11)) }.buttonStyle(.plain)
                    }.font(Brand.font(.body)).foregroundStyle(Brand.tabText).help(path)
                }
                if paths.isEmpty { Text(tr("이 컴퓨터에서 폴더 추가")).font(Brand.font(.body)).foregroundStyle(Brand.gray) }
                Button { chooseFolders() } label: {
                    Label(tr("추가"), systemImage: "folder.badge.plus")
                }.buttonStyle(ProjectPillStyle())
            }.padding(16).frame(maxWidth: .infinity, minHeight: 100)
                .background(RoundedRectangle(cornerRadius: 2).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Brand.line))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("목표")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
            TextField(tr("이 프로젝트에서 이루려는 목표"), text: $goal, axis: .vertical)
                .textFieldStyle(.plain).font(Brand.font(.body)).foregroundStyle(Brand.text).lineLimit(2...3).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(ChatPalette.field))
            Text(tr("공통 지침")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink).padding(.top, 8)
            Text(tr("답변 방식이나 작업 규칙을 적어주세요. 모든 프로젝트 채팅에 적용됩니다."))
                .font(Brand.font(.tag)).foregroundStyle(Brand.gray)
            TextEditor(text: $instructions).font(Brand.font(.body)).foregroundStyle(Brand.text).scrollContentBackground(.hidden)
                .padding(6).frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 8).fill(ChatPalette.field))
        }
    }

    private var memoryOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            memoryOption(.allRecords, title: tr("기본 메모리"), description: tr("이 프로젝트와 일반 채팅, 다른 프로젝트의 기록을 함께 참고합니다. 프로젝트 전용 기록은 제외됩니다."))
            memoryOption(.projectOnly, title: tr("프로젝트 전용 메모리"), description: tr("이 프로젝트의 기록만 참고합니다. 다른 채팅에서도 이 프로젝트의 기록을 읽을 수 없습니다."))
        }.padding(12).frame(width: 350)
    }

    private func memoryOption(_ mode: ProjectMemoryMode, title: String, description: String) -> some View {
        Button { memoryMode = mode; showMemory = false } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                    Text(description).font(Brand.font(.tag)).foregroundStyle(Brand.gray).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark").opacity(memoryMode == mode ? 1 : 0)
            }.padding(12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        paths = Array(Set(paths + panel.urls.map(\.path))).sorted()
    }

    private func save() {
        if let project {
            if projects.update(project, title: title, goal: goal, instructions: instructions, memoryMode: memoryMode) { dismiss() }
        } else if let created = projects.create(title: title, goal: goal, instructions: instructions, memoryMode: memoryMode, paths: paths) {
            onSave(created); dismiss()
        }
    }
}

struct ProjectProposalsSheet: View {
    @ObservedObject var projects: ProjectState
    @ObservedObject var chat: ChatState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibrarySheetHeader(title: tr("프로젝트 제안"),
                               detail: tr("관련 있는 업무와 채팅을 함께 묶어 제안합니다. 수락한 항목만 프로젝트에 들어갑니다.")) { dismiss() }
            VStack(alignment: .leading, spacing: 12) {
                if let error = projects.error { Text(error).font(Brand.font(.body)).foregroundStyle(.red).textSelection(.enabled) }
                if chat.running { Text(tr("채팅 응답이 끝나면 제안을 수락할 수 있습니다.")).font(Brand.font(.body)).foregroundStyle(Brand.gray) }
                if projects.proposals.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: projects.checking ? "sparkles" : "folder.badge.plus")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Brand.sub)
                        Text(projects.checking ? tr("함께 묶을 항목을 찾고 있어요") : tr("새로운 제안이 없어요"))
                            .font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                        Text(tr("같은 목표를 다루는 업무와 채팅이 쌓이면 알려드릴게요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.gray)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(projects.proposals) { proposal in
                                ProjectProposalCard(projects: projects, proposal: proposal, canAccept: !chat.running)
                            }
                        }
                    }
                }
            }.padding(.horizontal, 27).padding(.vertical, 20).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
            HStack(spacing: 8) {
                if projects.checking {
                    ProgressView().controlSize(.small)
                    Text(tr("새 항목 확인 중")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                }
                Spacer()
                Button(projects.checking ? tr("확인 중단") : tr("새 항목 확인")) {
                    if projects.checking { projects.stop() } else { projects.check() }
                }.buttonStyle(ProjectPillStyle())
            }.padding(.horizontal, 24).frame(height: 63)
                .brandGlass()
                .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }.frame(width: 600, height: projects.proposals.isEmpty ? 400 : 560)
            .background(.white)
    }
}

private struct ProjectProposalCard: View {
    @ObservedObject var projects: ProjectState
    var proposal: ProjectProposal
    var canAccept: Bool
    @State private var title: String

    init(projects: ProjectState, proposal: ProjectProposal, canAccept: Bool) {
        self.projects = projects; self.proposal = proposal; self.canAccept = canAccept
        _title = State(initialValue: proposal.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let projectID = proposal.projectID {
                Text(projects.projects.first(where: { $0.id == projectID })?.title ?? proposal.title).font(Brand.font(.rowTitle, .semibold)).foregroundStyle(Brand.ink)
            } else {
                TextField(tr("프로젝트 이름"), text: $title).textFieldStyle(.plain).font(Brand.font(.rowTitle, .semibold)).foregroundStyle(Brand.ink)     // CH-55
            }
            Text(proposal.goal).font(Brand.font(.body)).foregroundStyle(Brand.ink)
            DisclosureGroup(tr("업무·채팅 \(proposal.items.count)개 · 제안 상세 보기")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(proposal.reason).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                    ForEach(proposal.items) { item in
                        Label(item.title, systemImage: item.isTask ? "checklist" : "bubble.left")
                            .font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
                    }
                }.padding(.top, 8)
            }.font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
            HStack {
                Button(tr("제안 무시")) { projects.dismiss(proposal) }.buttonStyle(.plain).foregroundStyle(Brand.gray)
                Spacer()
                Button(proposal.projectID == nil ? tr("프로젝트 만들기") : tr("프로젝트에 추가")) { projects.accept(proposal, title: title) }
                    .buttonStyle(ProjectPillStyle(kind: .soft))
                    .disabled(!canAccept || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(Brand.font(.caption, .medium)).padding(.top, 4)
        }.padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatPalette.cardLine))
    }
}

/// CH-49, 50: 프로젝트 목록. 가운데 600 폭, 카드 2열
struct ProjectListView: View {
    @ObservedObject var projects: ProjectState
    @ObservedObject var chat: ChatState
    var onOpen: (ChatProject) -> Void
    @State private var showEditor = false
    @State private var showProposals = false
    @State private var hoveredProjectID: String?

    private var proposalCount: Int { projects.proposals.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("프로젝트")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
                HStack(spacing: 8) {
                    Button { showEditor = true } label: {
                        Label(tr("새 프로젝트 만들기"), systemImage: "plus")
                            .font(Brand.font(.body, .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Brand.accent, in: Capsule()).contentShape(Capsule())
                    }.buttonStyle(.plain)
                    Button { showProposals = true } label: {
                        Label(tr("프로젝트 제안"), systemImage: "sparkles")
                            .font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
                            .padding(.horizontal, 12).frame(height: 32)
                            .overlay(Capsule().strokeBorder(Brand.line)).contentShape(Capsule())
                    }.buttonStyle(.plain)
                }.padding(.top, 22)
                if !projects.proposals.isEmpty {
                    Text(tr("함께 묶을 만한 업무와 채팅이 \(proposalCount)건 있어요."))
                        .font(Brand.font(.body)).foregroundStyle(Brand.tabText).padding(.top, 16)
                }
                if projects.projects.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(Brand.gray).padding(.bottom, 4)
                        Text(tr("아직 프로젝트가 없어요")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                        Text(tr("채팅, 파일, 공통 지침을 한곳에 모아두세요.\n프로젝트의 모든 채팅에서 함께 활용할 수 있습니다."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.tabText).multilineTextAlignment(.center).lineSpacing(2)
                    }.frame(maxWidth: .infinity).padding(.top, 200)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                        ForEach(projects.projects) { project in
                            Button { onOpen(project) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(Brand.ink)
                                    Text(project.title).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink).lineLimit(1).padding(.top, 12)
                                    Text(project.goal).font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineSpacing(3).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 6)
                                    Spacer(minLength: 0)
                                    Text(tr("업데이트 \(ChatDateText.day(project.updatedAt))")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                                }.padding(15).frame(height: 140, alignment: .topLeading)
                                    .background(hoveredProjectID == project.id ? ChatPalette.rowHover : .white, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ChatPalette.cardLine, lineWidth: 1))
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .onHover { hoveredProjectID = $0 ? project.id : nil }
                        }
                    }.padding(.top, proposalsShown ? 22 : 38)
                }
            }.frame(width: ChatPalette.columnWidth, alignment: .leading)
                .padding(.top, 40).padding(.bottom, 40).frame(maxWidth: .infinity)
        }.background(.white)
        .sheet(isPresented: $showEditor) { ProjectEditor(projects: projects) { onOpen($0) } }
        .sheet(isPresented: $showProposals) { ProjectProposalsSheet(projects: projects, chat: chat) }
    }

    private var proposalsShown: Bool { !projects.proposals.isEmpty }
}

/// 프로젝트 시트 알약 단추(CH-54, 55). 보조: 흰 바탕 1pt 테두리 높이 30. 주: accent 바탕 흰 글자 높이 30.
/// 옅은 주: 고른 알약 색(chipSelected) 높이 28. 비활성은 0.38
private struct ProjectPillStyle: ButtonStyle {
    enum Kind { case secondary, primary, soft }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, kind: kind) }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(Brand.font(kind == .soft ? .caption : .body, .medium))
                .foregroundStyle(kind == .primary ? Color.white : kind == .soft ? Brand.chipSelectedText : Brand.ink)
                .padding(.horizontal, 14).frame(height: kind == .soft ? 28 : 30)
                .background(Capsule().fill(kind == .primary ? Brand.accent : kind == .soft ? Brand.chipSelectedFill : .white))
                .overlay(Capsule().strokeBorder(kind == .primary ? .clear : kind == .soft ? Brand.chipSelectedBorder : Brand.line))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
                .contentShape(Capsule())
        }
    }
}
