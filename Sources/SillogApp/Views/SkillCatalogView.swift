import SwiftUI
import AppKit
import SillogCore

/// 스킬의 검색, 상세 보기, 만들기, 수정과 삭제를 한 화면에서 제공한다.
struct SkillCatalogView: View {
    @ObservedObject var chat: ChatState
    var onStart: (String) -> Void

    @State private var query = ""
    @State private var selectedID: String?
    @State private var draft: SkillDraft?
    @State private var importing = false
    @State private var deleting: ChatSkill?
    @State private var error: String?

    private var selected: ChatSkill? { chat.skills.first { $0.id == selectedID } }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var shown: [ChatSkill] {
        guard !searchTerm.isEmpty else { return chat.skills }
        return chat.skills.filter { [$0.title, $0.summary, $0.displayTitle, $0.displaySummary].contains { $0.localizedCaseInsensitiveContains(searchTerm) } }
    }

    var body: some View {
        ZStack {
            catalog.accessibilityHidden(selected != nil).disabled(selected != nil)
            if let skill = selected {
                Color.black.opacity(0.18).onTapGesture { selectedID = nil }.accessibilityHidden(true)
                detail(skill)
            }
        }
        .background(.white)
        .modifier(SkillEditorPresentation(chat: chat, draft: $draft, importing: $importing))
        .alert(tr("스킬을 삭제할까요?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { skill in
            Button(tr("취소"), role: .cancel) {}
            Button(tr("삭제"), role: .destructive) {
                do { try chat.deleteSkill(skill) }
                catch { self.error = error.localizedDescription }
            }
        } message: { skill in
            Text(tr("‘\(skill.displayTitle)’이 스킬 목록과 채팅에서 빠져요."))
        }
        .alert(tr("스킬 관리"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(tr("확인"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var catalog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CatalogHeader(title: tr("스킬"), description: tr("채팅에서 쓸 작업 지침을 찾아보고 관리해요."), query: $query) {
                    EmptyView()
                }
                addActions
                if shown.isEmpty {
                    Text(searchTerm.isEmpty ? tr("새 스킬을 만들거나 스킬 파일을 가져와 보세요.") : tr("맞는 스킬이 없어요."))
                        .font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 6)
                } else if !searchTerm.isEmpty {
                    section(tr("검색 결과"), shown)
                } else {
                    let defaults = shown.filter { !$0.isCustom }
                    let added = shown.filter(\.isCustom)
                    if !defaults.isEmpty { section(tr("기본 스킬"), defaults) }
                    if !added.isEmpty { section(tr("내 스킬"), added) }
                }
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 26)
            .frame(maxWidth: 984, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var addActions: some View {
        HStack(spacing: 8) {
            Button { draft = SkillDraft() } label: {
                Label(tr("새 스킬 만들기"), systemImage: "plus")
                    .font(Brand.font(.body, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Brand.accent, in: Capsule()).contentShape(Capsule())
            }.buttonStyle(.plain)
            Button { importing = true } label: {
                Label(tr("스킬 파일 가져오기"), systemImage: "square.and.arrow.down")
                    .font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
                    .padding(.horizontal, 12).frame(height: 32)
                    .overlay(Capsule().strokeBorder(Brand.line)).contentShape(Capsule())
            }.buttonStyle(.plain)
        }
    }

    private func section(_ title: String, _ skills: [ChatSkill]) -> some View {
        CatalogSection(title: title) {
            ForEach(skills) { skill in
                CatalogRow(title: skill.displayTitle, subtitle: summary(skill), open: { selectedID = skill.id }) {
                    icon(skill, size: 34)
                } actions: {
                    moreMenu(skill)
                }
            }
        }
    }

    private func summary(_ skill: ChatSkill) -> String {
        skill.displaySummary.isEmpty ? tr("직접 추가한 스킬") : skill.displaySummary
    }

    private func icon(_ skill: ChatSkill, size: CGFloat) -> some View {
        Image(systemName: skill.icon).resizable().scaledToFit()
            .frame(width: size * 0.5, height: size * 0.5).foregroundStyle(Brand.tabText)
            .frame(width: size, height: size)
            .background(Brand.paper, in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(Brand.line))
    }

    private func moreMenu(_ skill: ChatSkill) -> some View {
        SkillActions(title: skill.displayTitle, start: { start(skill) }, edit: { edit(skill) }, copy: { copy(skill) }) {
            selectedID = nil
            deleting = skill
        }
    }

    private func edit(_ skill: ChatSkill) {
        do {
            let value = try SkillDraft(skill: skill)
            selectedID = nil
            draft = value
        } catch { self.error = error.localizedDescription }
    }

    private func copy(_ skill: ChatSkill) {
        do {
            let instructions = try skill.instructions()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(instructions, forType: .string)
        } catch { self.error = error.localizedDescription }
    }

    private func start(_ skill: ChatSkill) {
        selectedID = nil
        onStart(skill.id)
    }

    private func detail(_ skill: ChatSkill) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                icon(skill, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.displayTitle).font(Brand.font(.sectionTitle, .semibold)).foregroundStyle(Brand.ink)
                    Text(skill.isCustom ? tr("내 스킬") : tr("기본 스킬")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                }
                Spacer(minLength: 8)
                moreMenu(skill)
                ChatIconButton(systemName: "xmark", help: tr("닫기")) { selectedID = nil }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 18) {
                        Text(tr("설명")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.gray)
                        Text(summary(skill)).font(Brand.font(.body)).foregroundStyle(Brand.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(13).background(Brand.paper, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 8) {
                        Label(tr("지침"), systemImage: "doc.text").font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                        Text(verbatim: (try? skill.instructions()) ?? tr("스킬 지침을 읽지 못했어요."))
                            .font(Brand.font(.body)).foregroundStyle(Brand.tabText)
                            .textSelection(.enabled).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button { start(skill) } label: {
                    Text(tr("채팅에서 사용해 보기")).font(Brand.font(.body, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 15).frame(height: 32).background(Brand.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(24).frame(maxWidth: 620, maxHeight: 550)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .padding(24)
    }
}


private struct SkillActions: View {
    let title: String
    let start: () -> Void
    let edit: () -> Void
    let copy: () -> Void
    let delete: () -> Void
    @State private var open = false

    var body: some View {
        ChatIconButton(systemName: "ellipsis", help: tr("\(title) 작업")) { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(spacing: 2) {
                    PopRow(icon: "bubble.left", title: tr("채팅에서 사용해 보기")) { choose(start) }
                    PopRow(icon: "pencil", title: tr("수정")) { choose(edit) }
                    PopRow(icon: "doc.on.doc", title: tr("지침 복사")) { choose(copy) }
                    Divider()
                    PopRow(icon: "trash", title: tr("삭제"), color: PopRow.red) { choose(delete) }
                }.padding(6).frame(width: 176)
            }
    }

    private func choose(_ action: @escaping () -> Void) {
        open = false
        DispatchQueue.main.async { action() }
    }
}
