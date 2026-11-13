import SwiftUI
import SillogCore

/// 대화 머리(제목 아래, 모델 칩 옆)의 범위 표시: 지금 채팅이 보는 기록 (모든 기록 · 고른 업무·분야 · 기록 안 씀). 누르면 분야 칩 + 업무 목록으로 바꾼다
struct ChatFocusButton: View {
    @ObservedObject var chat: ChatState
    @State private var picking = false

    var body: some View {
        let scope = chat.current.scope
        Button { picking = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "diamond").font(.system(size: 10))
                Text(Self.label(scope, choices: chat.focusChoices)).font(Brand.font(.caption)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(Brand.tabText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(scope.focus.isEmpty ? tr("답변에 쓸 내 기록의 범위 바꾸기") : tr("범위: ") + scope.focus.map(\.title).joined(separator: ", "))
        .popover(isPresented: $picking, arrowEdge: .bottom) { ChatFocusPicker(chat: chat) }
    }

    /// 단추 글자: 모든 기록 / Flask 웹앱 개발 / 학업 · 업무 6 / Flask 웹앱 개발 외 2 / 기록 안 씀
    static func label(_ scope: ChatScope, choices: ChatFocusChoices) -> String {
        guard scope.useActivity else { return tr("기록 안 씀") }
        guard let first = scope.focus.first else { return tr("모든 기록") }
        guard scope.focus.count == 1, first.kind == .theme else { return summary(scope.focus) }
        if let count = choices.themes.first(where: { $0.focus.key == first.key })?.taskCount { return tr("\(short(L10n.tr(key: first.title))) · 업무 \(count)") }
        return tr("\(short(L10n.tr(key: first.title))) 분야")
    }

    /// 고른 것을 짧게: 하나면 그 이름, 여럿이면 '첫 이름 외 n' (대화 목록·입력칸 안내도 같은 말)
    static func summary(_ focus: [ChatFocus]) -> String {
        guard let first = focus.first else { return "" }
        return focus.count == 1 ? short(first.title) : tr("\(short(first.title)) 외 \(focus.count - 1)")
    }

    /// 긴 업무 이름은 열여덟 자에서 줄인다 (단추·입력칸 안내가 한 줄에 들어가게)
    static func short(_ title: String) -> String {
        title.count > 18 ? String(title.prefix(17)) + "…" : title
    }
}

/// 범위 고르기 창 (◎ 단추): 분야 칩 + 업무 목록. 닫히면 입력칸으로 커서를 옮긴다
struct ChatFocusPicker: View {
    @ObservedObject var chat: ChatState

    var body: some View {
        ChatFocusTree(chat: chat, movesCursor: false, maxHeight: 400)
            .padding(.vertical, 8)
            .frame(width: 438)
            .onDisappear { chat.inputFocusRequest += 1 }
    }
}

/// 범위 목록 (Figma CH-03, CH-04, CH-40): 검색 칸, 모든 기록, 분야 칩 한 줄, 업무 평평한 목록(체크 칸 + 분야 색 점), 기록 안 씀.
/// 칩은 보이는 목록만 거르고 고른 범위는 바꾸지 않는다. 범위는 업무 체크로 고른다. 아무것도 안 고르면 모든 기록
struct ChatFocusTree: View {
    @ObservedObject var chat: ChatState
    /// 고를 때마다 입력칸으로 커서를 옮길지 (첫 화면은 옮기고, 고르기 창은 닫힐 때 옮긴다)
    var movesCursor: Bool
    var maxHeight: CGFloat
    @State private var query = ""
    @State private var fieldFilter: Set<String> = []

    var body: some View {
        let scope = chat.current.scope
        let selection = scope.useActivity ? scope.focus : []
        let needle = query.trimmingCharacters(in: .whitespaces)
        let tasks = chat.focusChoices.tasks
        let fields = Self.fields(chat.focusChoices)
        let filter = fieldFilter.intersection(fields.map(\.name))                  // 그 분야 업무가 없어졌으면 무시
        let colors = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.color) })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.gray)
                TextField(tr("업무·분야 검색"), text: $query).textFieldStyle(.plain).font(Brand.font(.body))
            }
            .padding(.horizontal, 14).frame(height: 32)
            Rectangle().fill(Brand.line).frame(height: 1).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if needle.isEmpty {
                        row(title: tr("모든 기록"), detail: tr("기본"), mark: scope.useActivity && scope.focus.isEmpty ? .check : .none) {
                            chat.setFocus([], movesCursor: movesCursor)
                        }
                    }
                    if !fields.isEmpty {
                        ChatChipFlow(spacing: 6) {
                            ForEach(fields) { field in chip(field, on: filter.contains(field.name)) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    ForEach(Self.visible(tasks, filter: filter, query: needle), id: \.focus.key) { task in
                        let on = Self.isOn(task, tasks: tasks, selection: selection)
                        Button { chat.setFocus(Self.toggle(task, tasks: tasks, selection: selection), movesCursor: movesCursor) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13))
                                    .foregroundStyle(on ? Brand.accentDark : Brand.gray)
                                Circle().fill(colors[task.field ?? TasksView.noField] ?? Brand.sub).frame(width: 7, height: 7)
                                Text(task.focus.title).font(Brand.font(.body)).foregroundStyle(Brand.ink).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 31).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverHighlight(cornerRadius: 5)
                        .accessibilityLabel(task.focus.title).accessibilityAddTraits(on ? .isSelected : [])
                    }
                    if needle.isEmpty {
                        Rectangle().fill(Brand.line).frame(height: 1).padding(.vertical, 6).padding(.horizontal, 6)
                        row(title: tr("기록 안 씀"), detail: tr("웹·파일·보관함만"), mark: scope.useActivity ? .none : .check) {
                            chat.useNoRecords()
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.top, 6)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 분야 칩: 색 점 + 이름. 누르면 목록만 그 분야로 좁히고(여러 개), 다시 누르면 풀린다
    private func chip(_ field: TasksView.FieldStat, on: Bool) -> some View {
        Button {
            if fieldFilter.contains(field.name) { fieldFilter.remove(field.name) } else { fieldFilter.insert(field.name) }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(field.color).frame(width: 7, height: 7)
                Text(field.title).font(Brand.font(.caption, on ? .medium : .regular)).lineLimit(1)
            }
            .foregroundStyle(on ? Brand.chipSelectedText : Brand.tabText)
            .padding(.horizontal, 9).frame(height: 24)
            .background(on ? Brand.chipSelectedFill : Brand.chipFill, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Brand.chipSelectedBorder : Brand.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("\(field.title) 분야")).accessibilityAddTraits(on ? .isSelected : [])
    }

    private enum Mark { case none, check }

    /// 모든 기록, 기록 안 씀: 고른 줄 앞에만 ✓ (자리는 늘 비워 둔다)
    private func row(title: String, detail: String, mark: Mark, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink)
                    .frame(width: 13).opacity(mark == .check ? 1 : 0)
                Text(title).font(Brand.font(.body)).foregroundStyle(Brand.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 31).contentShape(Rectangle())
        }
        .buttonStyle(.plain).hoverHighlight(cornerRadius: 5)
        .accessibilityLabel(title).accessibilityAddTraits(mark == .check ? .isSelected : [])
    }

    // MARK: 고르기 규칙 (화면 없이 시험한다)

    /// 같은 업무·분야인지 (이름은 바뀌었을 수 있어 종류와 key 로 본다)
    static func same(_ a: ChatFocus, _ b: ChatFocus) -> Bool { a.kind == b.kind && a.key == b.key }

    /// 분야 칩: 업무 탭 분야 막대와 같은 이름, 색, 순서 (업무 목록을 그쪽 계산에 그대로 넣는다)
    static func fields(_ choices: ChatFocusChoices) -> [TasksView.FieldStat] {
        TasksView.fieldStats(choices.tasks.map {
            TaskSummary(id: 0, key: $0.focus.key, title: $0.focus.title, taskType: nil, activeSeconds: 0, lastActive: 0, sessionCount: 1, theme: $0.theme, field: $0.field)
        })
    }

    /// 보이는 업무: 칩을 눌렀으면 그 분야들만, 검색어가 있으면 업무 이름이나 분야 이름이 맞는 것만. 받은 순서(최근에 일한 순) 그대로
    static func visible(_ tasks: [ChatFocusChoices.TaskItem], filter: Set<String>, query: String) -> [ChatFocusChoices.TaskItem] {
        tasks.filter { task in
            (filter.isEmpty || filter.contains(task.field ?? TasksView.noField))
                && (query.isEmpty || task.focus.title.localizedCaseInsensitiveContains(query) || (task.field ?? "").localizedCaseInsensitiveContains(query) || L10n.tr(key: task.field ?? "").localizedCaseInsensitiveContains(query))
        }
    }

    /// 업무가 골라졌는지. 예전 대화에 저장된 분야 범위가 이 업무의 분야면 골라진 것으로 본다
    static func isOn(_ task: ChatFocusChoices.TaskItem, tasks: [ChatFocusChoices.TaskItem], selection: [ChatFocus]) -> Bool {
        selection.contains { same($0, task.focus) } || coveringTheme(task, selection) != nil
    }

    /// 업무 체크: 넣고 빼기. 예전 분야 범위가 덮고 있던 업무면 분야 범위를 그 분야 업무들로 풀어서 이 업무만 뺀다
    static func toggle(_ task: ChatFocusChoices.TaskItem, tasks: [ChatFocusChoices.TaskItem], selection: [ChatFocus]) -> [ChatFocus] {
        if let theme = coveringTheme(task, selection) {
            return selection.filter { !same($0, theme) } + tasks.filter { $0.themeKey == theme.key && $0.focus.key != task.focus.key }.map(\.focus)
        }
        if selection.contains(where: { same($0, task.focus) }) { return selection.filter { !same($0, task.focus) } }
        return selection + [task.focus]
    }

    private static func coveringTheme(_ task: ChatFocusChoices.TaskItem, _ selection: [ChatFocus]) -> ChatFocus? {
        guard let key = task.themeKey else { return nil }
        return selection.first { $0.kind == .theme && $0.key == key }
    }
}
