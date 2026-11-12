import SwiftUI
import SillogCore

/// 채팅 탭 왼쪽 대화 목록 (Figma CH-02, 29, 30). 폭 261, 오른쪽 선은 바깥에서 그린다.
struct ChatSidebar: View {
    @ObservedObject var chat: ChatState
    @ObservedObject var projects: ProjectState
    @Binding var pane: ChatPane
    var isSearching: Bool
    var onSearch: () -> Void
    var onSchedules: () -> Void
    var onCollapse: () -> Void
    var onRename: (ChatConversation) -> Void
    var onDelete: (ChatConversation) -> Void

    @State private var pinnedOpen = true
    @State private var recentOpen = true
    @State private var projectsOpen = true
    @State private var collapsedProjects: Set<String> = []
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmDelete = false
    @State private var selectionError: String?
    @State private var hoverSection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(spacing: 2) {
                navRow(tr("새 대화"), "plus", selected: pane == .chat && chat.messages.isEmpty && !isSearching, help: tr("새 대화 (⌘N)")) {
                    chat.newConversation(); pane = .chat
                }
                navRow(tr("검색"), "magnifyingglass", selected: isSearching, help: tr("검색 (⌘K)"), action: onSearch)
                navRow(tr("프로젝트"), "folder", selected: isProjectPane) { pane = .projects }
                navRow(tr("결과물"), "square.on.square", selected: pane == .results) { pane = .results }
                navRow(tr("예약 작업"), "clock", selected: false, trailing: "\(chat.automations.count)", action: onSchedules)
            }
            .padding(.leading, 12).padding(.trailing, 12).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !chat.pinnedConversations.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            sectionHeader(tr("고정됨"), open: $pinnedOpen)
                            if pinnedOpen { ForEach(chat.pinnedConversations) { conversationRow($0) } }
                        }.onHover { hoverSection = $0 ? "pinned" : (hoverSection == "pinned" ? nil : hoverSection) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(tr("프로젝트"), open: $projectsOpen)
                        if projectsOpen {
                            ForEach(projects.projects) { project in projectRow(project) }
                            if projects.projects.isEmpty {
                                Text(tr("아직 프로젝트가 없어요")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                    }.onHover { hoverSection = $0 ? tr("프로젝트") : nil }
                    VStack(alignment: .leading, spacing: 0) {
                        sectionHeader(tr("최근 항목"), open: $recentOpen)
                        if recentOpen {
                            ForEach(selecting ? chat.conversations : chat.recentConversations) { conversationRow($0) }
                        }
                    }.onHover { hoverSection = $0 ? "recent" : (hoverSection == "recent" ? nil : hoverSection) }
                }.padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 16)
            }
            if selecting { selectionActions }
        }
        .frame(width: ChatPalette.sidebarWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.paper)
        .alert(tr("채팅 \(selected.count)개를 삭제할까요?"), isPresented: $confirmDelete) {
            Button(tr("취소"), role: .cancel) { }
            Button(tr("삭제"), role: .destructive) {
                performSelectionAction { try chat.deleteConversations(selected) }
            }
        } message: {
            Text(tr("선택한 채팅의 메시지와 결과물이 삭제됩니다. 되돌릴 수 없습니다."))
        }
        .onChange(of: chat.conversations.map(\.id)) { _, ids in selected.formIntersection(ids) }
    }

    private var isProjectPane: Bool {
        switch pane { case .projects, .project: return true; default: return false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onCollapse) {
                Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(Brand.tabText)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).help(tr("목록 접기")).accessibilityLabel(tr("목록 접기"))
            Text(tr("채팅")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
            Button {
                selecting.toggle(); selected = []; selectionError = nil
            } label: {
                Image(systemName: selecting ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: 15)).foregroundStyle(Brand.tabText).frame(width: 28, height: 24)
            }.buttonStyle(.plain).help(selecting ? tr("선택 취소") : tr("채팅 선택"))
                .accessibilityLabel(selecting ? tr("선택 취소") : tr("채팅 선택"))
        }.padding(.horizontal, 14).padding(.top, 14).frame(height: 56, alignment: .topLeading)
    }

    private func navRow(_ title: String, _ icon: String, selected: Bool, trailing: String? = nil, help: String = "",
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 16)
                Text(title).font(Brand.font(.rowTitle, selected ? .medium : .regular))
                Spacer(minLength: 0)
                if let trailing { Text(trailing).font(Brand.font(.caption)).foregroundStyle(Brand.gray) }
            }
            .foregroundStyle(Brand.ink)
            .padding(.leading, 10).padding(.trailing, 12).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? ChatPalette.navSelected : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).hoverHighlight(cornerRadius: 7).help(help)
    }

    private func sectionHeader(_ title: String, open: Binding<Bool>) -> some View {
        // 삼각형은 커서가 구역 안에 있을 때, 접힌 구역은 항상 보인다 (CH-76, 77)
        let key = title == tr("고정됨") ? "pinned" : title == tr("최근 항목") ? "recent" : title
        return Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Text(title).font(Brand.font(.body))
                Image(systemName: "triangle.fill").font(.system(size: 5)).rotationEffect(.degrees(open.wrappedValue ? 180 : 90))
                    .opacity(hoverSection == key || !open.wrappedValue ? 1 : 0)
            }
            .foregroundStyle(Brand.gray).padding(.leading, 10).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func conversationRow(_ item: ChatConversation) -> some View {
        if selecting {
            Button {
                if !selected.insert(item.id).inserted { selected.remove(item.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(item.id) ? Brand.accent : Brand.gray)
                    HoverScrollingText(text: ChatConversation.display(item.title))
                    Spacer(minLength: 0)
                }.font(Brand.font(.body)).foregroundStyle(Brand.tabText)
                    .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).hoverHighlight(cornerRadius: 5)
                .accessibilityLabel("\(selected.contains(item.id) ? tr("선택 해제") : tr("선택")): \(item.title)")
                .disabled(chat.activeMessage?.conversationID == item.id)
        } else {
            ConversationRow(item: item, isCurrent: pane == .chat && chat.current.id == item.id,
                        isBusy: chat.activeMessage?.conversationID == item.id,
                        open: { chat.select(item); pane = .chat },
                        context: { menu(item) }, pop: { close in popMenu(item, close) })
            .padding(.vertical, 1)
        }
    }

    private func projectRow(_ project: ChatProject) -> some View {
        let open = !collapsedProjects.contains(project.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if !collapsedProjects.insert(project.id).inserted { collapsedProjects.remove(project.id) }
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 20, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(project.title) \(open ? tr("접기") : tr("펼치기"))")
                Button {
                    chat.newConversation(projectID: project.id); pane = .project(project.id)
                } label: {
                    Label(project.title, systemImage: "folder").font(Brand.font(.body)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.foregroundStyle(Brand.tabText).hoverHighlight(cornerRadius: 5)
            if open {
                ForEach(chat.conversations.filter { $0.projectID == project.id }) { item in
                    conversationRow(item).padding(.leading, 22)
                }
            }
        }
    }

    private var selectionActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("\(selected.count)개 선택")).font(Brand.font(.body, .medium))
                Spacer()
                Button(tr("전체 선택")) {
                    selected = Set(chat.conversations.filter { $0.id != chat.activeMessage?.conversationID }.map(\.id))
                }.buttonStyle(.plain).font(Brand.font(.caption))
                Button(tr("완료")) { selecting = false; selected = []; selectionError = nil }
                    .buttonStyle(.plain).font(Brand.font(.caption))
            }
            HStack {
                Menu {
                    ForEach(projects.projects) { project in
                        Button(project.title) { performSelectionAction { try chat.moveConversations(selected, to: project.id) } }
                    }
                    Divider()
                    Button(tr("일반 채팅으로 이동")) { performSelectionAction { try chat.moveConversations(selected, to: nil) } }
                } label: { Label(tr("이동"), systemImage: "folder") }
                Button { confirmDelete = true } label: { Label(tr("삭제"), systemImage: "trash") }
                    .foregroundStyle(PopRow.red)
            }.disabled(selected.isEmpty)
            if let selectionError { Text(selectionError).font(Brand.font(.caption)).foregroundStyle(.red) }
        }.foregroundStyle(Brand.tabText).padding(12)
            .overlay(alignment: .top) { Rectangle().fill(Brand.line).frame(height: 1) }
    }

    private func performSelectionAction(_ action: () throws -> Void) {
        do {
            try action(); selected = []; selecting = false; selectionError = nil
        } catch { selectionError = error.localizedDescription }
    }

    /// 오른쪽 클릭 메뉴
    @ViewBuilder private func menu(_ item: ChatConversation) -> some View {
        let busy = chat.activeMessage?.conversationID == item.id
        Button { chat.togglePin(item) } label: {
            item.pinnedAt != nil ? Label(tr("고정 해제"), systemImage: "pin.slash") : Label(tr("고정"), systemImage: "pin")
        }
        Button { onRename(item) } label: { Label(tr("이름 바꾸기"), systemImage: "pencil") }
        ProjectMoveMenu(projects: chat.projects, itemID: "conversation:\(item.id)").disabled(busy)
        Button { chat.exportMarkdown(item, toFile: false) } label: { Label(tr("전체 복사"), systemImage: "doc.on.doc") }
        Button { chat.exportMarkdown(item, toFile: true) } label: { Label(tr("Markdown으로 내보내기"), systemImage: "square.and.arrow.up") }
        Divider()
        Button(role: .destructive) { onDelete(item) } label: { Label(tr("삭제"), systemImage: "trash") }.disabled(busy)
    }

    /// ⋯ 메뉴 (CH-29, 47, 48): 아이콘이 있고 삭제는 빨강
    private func popMenu(_ item: ChatConversation, _ close: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            PopRow(icon: item.pinnedAt != nil ? "pin.slash" : "pin", title: item.pinnedAt != nil ? tr("고정 해제") : tr("고정")) { close(); chat.togglePin(item) }
            PopRow(icon: "pencil", title: tr("이름 바꾸기")) { close(); onRename(item) }
            MoveRow(projects: chat.projects, itemID: "conversation:\(item.id)", close: close)
            PopRow(icon: "doc.on.doc", title: tr("전체 복사")) { close(); chat.exportMarkdown(item, toFile: false) }
            PopRow(icon: "square.and.arrow.up", title: tr("Markdown으로 내보내기")) { close(); chat.exportMarkdown(item, toFile: true) }
            Divider().padding(.vertical, 2)
            PopRow(icon: "trash", title: tr("삭제"), color: PopRow.red) { close(); onDelete(item) }
        }.padding(6).frame(width: 190)
    }
}

/// 팝업 메뉴 한 줄: 높이 28, 둥글기 6, 커서를 올리면 rowHover
struct PopRow: View {
    static let red = Color(hex: 0xD0392B)
    let icon: String?
    let title: String
    var color: Color = Brand.text
    var chevron = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 12)).frame(width: 14) }
                Text(title).font(Brand.font(.body)).lineLimit(1)
                Spacer(minLength: 6)
                if chevron { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray) }
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity)
            .background(hover ? ChatPalette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// 프로젝트로 옮기기 › : 오른쪽에 프로젝트 목록 팝업
private struct MoveRow: View {
    @ObservedObject var projects: ProjectState
    let itemID: String
    let close: () -> Void
    @State private var show = false
    private var currentID: String? { projects.items.first(where: { $0.id == itemID })?.projectID }

    var body: some View {
        PopRow(icon: "folder", title: tr("프로젝트로 옮기기"), chevron: true) { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .trailing) {
                VStack(spacing: 2) {
                    ForEach(projects.projects) { project in
                        PopRow(icon: nil, title: project.title, color: project.id == currentID ? Brand.gray : Brand.text) {
                            show = false; close(); projects.move(itemID, to: project.id)
                        }.disabled(project.id == currentID)
                    }
                    if !projects.projects.isEmpty { Divider().padding(.vertical, 2) }
                    PopRow(icon: nil, title: tr("일반 채팅으로 옮기기"), color: currentID == nil ? Brand.gray : Brand.text) {
                        show = false; close(); projects.move(itemID, to: nil)
                    }.disabled(currentID == nil)
                }.padding(6).frame(width: 190)
            }
    }
}

private struct ConversationRow<Context: View, Pop: View>: View {
    let item: ChatConversation
    let isCurrent: Bool
    let isBusy: Bool
    let open: () -> Void
    @ViewBuilder var context: () -> Context
    @ViewBuilder var pop: (@escaping () -> Void) -> Pop
    @State private var hovering = false
    @State private var menuOpen = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HoverScrollingText(text: ChatConversation.display(item.title), rowHovered: hovering)
                    .font(Brand.font(.rowTitle, isCurrent ? .medium : .regular)).foregroundStyle(isCurrent ? Brand.ink : Brand.tabText)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isBusy {
                // CH-14: 응답이 도는 대화는 메뉴 자리에 스피너 (메뉴는 오른쪽 클릭으로)
                ProgressView().controlSize(.small).frame(width: 28, height: 32)
            } else {
                Button { menuOpen.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Brand.tabText)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(tr("대화 메뉴"))
                    .opacity(hovering || menuOpen ? 1 : 0)
                    .popover(isPresented: $menuOpen, arrowEdge: .bottom) { pop { menuOpen = false } }
            }
        }
        .frame(height: 32)
        // Same fill as the selected menu row above, so the open chat reads as selected.
        .background(RoundedRectangle(cornerRadius: 7).fill(isCurrent ? ChatPalette.navSelected : hovering || menuOpen ? ChatPalette.rowHover : .clear))
        .onHover { hovering = $0 }
        .contextMenu { context() }
    }
}
