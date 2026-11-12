import AppKit
import SwiftUI
import SillogCore

/// 기록 자료의 파일 구역: 맨 위 파일 제안 설정 한 줄과 대기 중인 정리 제안. 처리한 제안은 지난 기록 탭(FileHistoryView).
/// 스크롤하면 커서 아래로 카드가 지나가며 마우스 올림 상태가 잇달아 바뀐다. 그 상태는 PendingSection 안에만 두고
/// 바뀌어도 크기가 변하지 않게 한다: 바뀔 때마다 화면 전체를 다시 재면 스크롤이 끊긴다 (10/27 실 앱 관찰)
struct FilesView: View {
    @EnvironmentObject private var state: AppState

    fileprivate static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private var pending: [FileSuggestion] { state.fileSuggestions.filter { $0.status == "pending" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = state.fileError { errorBanner(error) }
            FileSuggestSettings().padding(.horizontal, 34).padding(.top, 6)
            if pending.isEmpty {
                emptyState
            } else {
                if state.notificationsDenied { notificationRow.padding(.horizontal, 34) }
                PendingSection(pending: pending, state: state, fields: state.fileFields(for: pending))
                    .padding(.horizontal, 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(.white)
        .onAppear { state.refreshFileSuggestions() }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Text(tr("정리할 파일이 없어요")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
            Text(tr("다운로드 폴더에 새 파일이 생기면 어디에 둘지 제안해요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(Brand.ink)
            Text(error).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
            Spacer()
            Button(tr("닫기")) { state.fileError = nil }.buttonStyle(.plain).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 34).frame(height: 52).frame(maxWidth: .infinity)
        .background(ChatPalette.soft)
    }

    /// 알림 권한이 꺼져 있으면: 누르면 설정의 일반(권한 칸)
    private var notificationRow: some View {
        Button { state.openGeneralSettings() } label: {
            HStack(spacing: 4) {
                Text(tr("알림이 꺼져 있어요. 설정의 일반에서 켤 수 있어요."))
                Image(systemName: "arrow.up.right").font(.system(size: 9))
            }
            .font(Brand.font(.caption)).foregroundStyle(Brand.gray)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    fileprivate static func source(_ suggestion: FileSuggestion) -> String {
        (((suggestion.path as NSString).deletingLastPathComponent) as NSString).lastPathComponent
    }

    fileprivate static func short(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// 기록 자료 > 지난 기록: 정리 제안을 어떻게 처리했는지(옮김·무시·되돌림·직접 처리). 20개씩 쪽으로 넘기고, 옮긴 파일은 되돌린다
struct FileHistoryView: View {
    @EnvironmentObject private var state: AppState

    private var rows: [FileSuggestion] { state.fileSuggestions.filter { $0.status != "pending" } }
    /// 전체 개수 (미리보기처럼 DB 없이 줄만 넣었으면 그 줄 수)
    private var total: Int { max(state.fileHistoryTotal, rows.count) }
    private var pages: Int { (total + AppState.fileHistoryPageSize - 1) / AppState.fileHistoryPageSize }

    var body: some View {
        Group {
            if rows.isEmpty {
                VStack(spacing: 0) {
                    Text(tr("아직 지난 기록이 없어요")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                    Text(tr("정리 제안을 옮기거나 무시하면 여기에 남아요.")).font(Brand.font(.body)).foregroundStyle(Brand.gray).padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(title: tr("지난 기록"), count: total).padding(.horizontal, 34)
                    legend.padding(.horizontal, 34).padding(.bottom, 10)
                    HistoryRow.header(oldestFirst: state.fileHistoryOldestFirst, toggleOrder: state.toggleFileHistoryOrder)
                        .padding(.horizontal, 34)
                    HistoryList(rows: rows, page: state.fileHistoryPage, state: state, fields: state.fileFields(for: rows))
                    if pages > 1 {
                        PageNumbers(current: state.fileHistoryPage, pages: pages) { state.showFileHistoryPage($0) }
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
            }
        }
        .background(.white)
        .onAppear { state.refreshFileSuggestions() }
    }

    private var legend: some View {
        let all = state.fileHistoryLegend.reduce(0) { $0 + $1.count }
        return HStack(spacing: 6) {
            legendChip(tr("전체"), color: nil, count: all, on: state.fileHistoryField == nil) { state.filterFileHistory(nil) }
            ForEach(state.fileHistoryLegend) { item in
                legendChip(item.name.isEmpty ? tr("분야 없음") : L10n.tr(key: item.name), color: item.name.isEmpty ? nil : item.color,
                           count: item.count, on: state.fileHistoryField == item.name) { state.filterFileHistory(item.name) }
            }
            Spacer(minLength: 0)
        }
    }

    private func legendChip(_ title: String, color: Color?, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(title).font(Brand.font(.body, on ? .semibold : .regular)).foregroundStyle(on ? Brand.ink : Brand.tabText)
                Text("\(count)").font(Brand.jost(11)).foregroundStyle(Brand.gray)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(on ? (color ?? Brand.ink).opacity(0.14) : Color(hex: 0xF3F1EF)))
            .overlay(Capsule().strokeBorder(on ? (color ?? Brand.ink).opacity(0.5) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 구역 제목: 이름과 개수
private struct SectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
            if let count { Text("\(count)").font(Brand.jost(12)).foregroundStyle(Brand.gray) }
            Spacer()
        }
        .padding(.top, 24).padding(.bottom, 16)
    }
}

/// 대기 중인 제안: 왼쪽에 옮겨질 곳 나무(고정), 오른쪽에 제안 카드(스크롤). 카드만 스크롤해 스크롤할 때 나무까지 다시 재지 않는다 (10/29 사용자 결정).
/// 커서를 댄 제안(hovered)은 이 안에서만 바뀌어 파일 화면 전체를 다시 그리지 않는다.
/// 마우스 올림 상태가 있는 이 구역에는 equatable 을 걸지 않는다: 걸면 카드를 옮겨 다닐 때 나무가 안 바뀌었다 (10/29). state 는 단추 동작에만 쓴다
private struct PendingSection: View {
    let pending: [FileSuggestion]
    let state: AppState
    let fields: [Int64: FileField]
    @State private var hovered: FileSuggestion.ID?          // 커서를 댄 제안: 왼쪽 나무에서 그 가지를 진하게
    @State private var marked: FileSuggestion.ID?
    /// 왼쪽 나무 폭
    static let treeWidth: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: tr("대기 중인 제안"), count: pending.count)
            HStack(alignment: .top, spacing: 28) {
                ScrollViewReader { proxy in
                    ScrollView { tree.padding(.bottom, 28) }    // scrolls on its own so card scrolling never re-lays out the tree
                        .onChange(of: marked) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                        }
                }
                .frame(width: Self.treeWidth)
                List {                                              // 카드 목록: AppKit 표가 스크롤을 맡는다 (지난 기록과 같은 까닭, 10/29 측정)
                    ForEach(pending) { suggestion in
                        PendingCard(suggestion: suggestion, source: FilesView.source(suggestion), folder: FilesView.short(suggestion.suggestedFolder),
                                    field: suggestion.id.flatMap { fields[$0] }, marked: marked == suggestion.id,
                                    mark: { marked = marked == suggestion.id ? nil : suggestion.id },
                                    accept: { state.acceptSuggestion(suggestion) }, choose: { state.chooseFolderAndMove(suggestion) },
                                    ignore: { state.ignoreSuggestion(suggestion) }, reveal: { state.revealSuggestionFile(suggestion) })
                            .equatable()
                            .onHover { h in hovered = h ? suggestion.id : (hovered == suggestion.id ? nil : hovered) }
                            .listRowInsets(EdgeInsets(top: 0, leading: -10, bottom: 0, trailing: -10))   // List 가 양옆에 띄우는 10 을 없앤다
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// 나무 그림용 묶음: 원래 폴더 → 옮길 폴더 → 파일 (제안이 나온 순서 유지)
    private var groups: [(source: String, folders: [(path: String, files: [FileSuggestion])])] {
        var groups: [(source: String, folders: [(path: String, files: [FileSuggestion])])] = []
        for suggestion in pending {
            let src = FilesView.source(suggestion)
            let i = groups.firstIndex { $0.source == src } ?? { groups.append((src, [])); return groups.count - 1 }()
            if let j = groups[i].folders.firstIndex(where: { $0.path == suggestion.suggestedFolder }) {
                groups[i].folders[j].files.append(suggestion)
            } else {
                groups[i].folders.append((suggestion.suggestedFolder, [suggestion]))
            }
        }
        return groups
    }

    /// 옮겨질 곳: 원래 폴더에서 옮길 폴더로 가지가 뻗고, 그 아래에 파일. 같은 폴더로 가는 파일은 한 가지에 묶인다
    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("옮겨질 곳")).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.gray).padding(.bottom, 6)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Brand.ink).frame(width: 12)
                    Text(group.source).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                    Text("\(group.folders.reduce(0) { $0 + $1.files.count })").font(Brand.jost(11)).foregroundStyle(Brand.gray)
                }
                .frame(height: 28)
                ForEach(Array(group.folders.enumerated()), id: \.offset) { index, folder in
                    let lastFolder = index == group.folders.count - 1
                    let on = folder.files.contains { $0.id == hovered }
                    let folderMarked = folder.files.contains { $0.id == marked }
                    let shown = FilesView.short(folder.path)
                    HStack(spacing: 0) {
                        TreeElbow(last: lastFolder).stroke(folderMarked ? Brand.blue : Brand.line, lineWidth: folderMarked ? 1.5 : 1).frame(width: 20)
                        HStack(spacing: 7) {
                            Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.blue)
                            BoldOnHover(text: (shown as NSString).lastPathComponent, size: 13, on: on || folderMarked)
                                .foregroundStyle(folderMarked ? Brand.blue : Brand.ink).lineLimit(1)
                            Text((shown as NSString).deletingLastPathComponent + "/").font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                                .lineLimit(1).truncationMode(.head)
                        }
                        .padding(.horizontal, 6).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Brand.blue.opacity(folderMarked ? 0.18 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.blue.opacity(folderMarked ? 0.55 : 0), lineWidth: 1.2))
                        .padding(.leading, 2)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 30)
                    .help(shown)
                    ForEach(folder.files) { file in
                        let fileMarked = file.id == marked
                        let fileOn = file.id == hovered || fileMarked
                        HStack(spacing: 0) {
                            if lastFolder { Color.clear.frame(width: 20) }       // 위 가지가 이어지면 세로 줄기만
                            else { Rectangle().fill(Brand.line).frame(width: 1).padding(.leading, 6).frame(width: 20, alignment: .leading) }
                            TreeElbow(last: file.id == folder.files.last?.id).stroke(fileMarked ? Brand.blue : Brand.line, lineWidth: fileMarked ? 1.5 : 1)
                                .frame(width: 20).padding(.leading, 7.5)
                            HStack(spacing: 6) {
                                Image(systemName: fileMarked ? "doc.fill" : "doc").font(.system(size: 11)).foregroundStyle(fileMarked ? Brand.blue : Brand.gray)
                                BoldOnHover(text: file.fileName, size: 12, on: fileOn)
                                    .foregroundStyle(fileMarked ? Brand.blue : fileOn ? Brand.ink : Brand.tabText).lineLimit(1).truncationMode(.middle)
                            }
                            .padding(.horizontal, 6).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 6).fill(fileMarked ? Brand.blue.opacity(0.18) : Color.black.opacity(fileOn ? 0.05 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.blue.opacity(fileMarked ? 0.55 : 0), lineWidth: 1.2))
                            .overlay { if fileMarked { MarkPulse() } }
                            .padding(.leading, 2)
                            Spacer(minLength: 0)
                            if fileMarked { MarkBuddy().padding(.trailing, 4) }
                        }
                        .frame(height: 28)
                        .contentShape(Rectangle())
                        .id(file.id)
                        .onHover { h in hovered = h ? file.id : (hovered == file.id ? nil : hovered) }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.paper))
        .padding(.top, 18)
        .animation(.easeOut(duration: 0.2), value: marked)
    }

}

private struct MarkPulse: View {
    @State private var spread = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.blue, lineWidth: 2)
            .scaleEffect(spread ? 1.12 : 1)
            .opacity(spread ? 0 : 0.8)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { spread = true; return }
                withAnimation(.easeOut(duration: 0.7).repeatCount(2, autoreverses: false)) { spread = true }
            }
    }
}

private struct MarkBuddy: View {
    @State private var shown = false
    @State private var hops = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GazingMark(size: 22, smiling: true)
            .scaleEffect(shown ? 1 : 0.2, anchor: .bottom)
            .opacity(shown ? 1 : 0)
            .keyframeAnimator(initialValue: CGFloat(0), trigger: hops) { view, y in view.offset(y: y) } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(-7, duration: 0.18); SpringKeyframe(0, duration: 0.2)
                    SpringKeyframe(-4, duration: 0.16); SpringKeyframe(0, duration: 0.2)
                }
            }
            .onAppear {
                if reduceMotion { shown = true; return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { shown = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { hops += 1 }
            }
            .help(tr("여기로 옮겨져요"))
    }
}

/// 커서를 대면 굵어지는 글자: 보통·굵은 글자를 겹쳐 두고 보이기만 바꾼다. 굵기를 바꾸면 글자 폭이 달라져 나무와 옆 카드까지 다시 재게 된다
private struct BoldOnHover: View {
    let text: String
    let size: CGFloat
    let on: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Text(text).font(Brand.suit(size, .regular)).opacity(on ? 0 : 1)
            Text(text).font(Brand.suit(size, .semibold)).opacity(on ? 1 : 0)
        }
    }
}

/// 지난 기록 줄 목록 (한 쪽 20줄). SwiftUI ScrollView 는 스크롤할 때마다 상태 갱신 → 창 레이아웃 → 다시 그리기가 돌고
/// 글자·아이콘마다 생기는 NSView 를 AppKit 이 매 프레임 훑어 끊겼다 (10/29 실 앱 관찰). List 는 AppKit 표(NSTableView)가 스크롤을 맡고 보이는 줄만 만든다
struct HistoryList: View {
    let rows: [FileSuggestion]
    /// 쪽이 바뀌면 맨 위로
    let page: Int
    let state: AppState
    let fields: [Int64: FileField]

    static let rowHeight: CGFloat = 46

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(rows) { suggestion in
                    HistoryRow(suggestion: suggestion, field: suggestion.id.flatMap { fields[$0] }, undo: { state.undoSuggestion(suggestion) })
                        .hoverHighlight(cornerRadius: 6)
                        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))   // List 가 양옆에 10 을 더 띄운다: 위 열 머리(34)와 칸을 맞춘다
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(suggestion.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .onChange(of: page) { if let first = rows.first?.id { proxy.scrollTo(first, anchor: .top) } }
        }
    }
}

/// Shared by history rows and pending cards so the two stay identical.
private struct FieldPill: View {
    let field: FileField?

    var body: some View {
        if let field {
            HStack(spacing: 5) {
                Circle().fill(field.color).frame(width: 7, height: 7)
                Text(field.title).font(Brand.font(.caption)).lineLimit(1).foregroundStyle(Brand.ink)
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(field.color.opacity(0.16)))
        } else {
            Text(tr("분야 없음")).font(Brand.font(.caption)).lineLimit(1).foregroundStyle(Brand.gray)
        }
    }
}

/// 지난 기록 한 줄: 파일 · 폴더 · 처리 결과 · 시간 · 되돌리기
private struct HistoryRow: View {
    let suggestion: FileSuggestion
    let field: FileField?
    let undo: () -> Void

    static func header(oldestFirst: Bool, toggleOrder: @escaping () -> Void) -> some View {
        cells(Text(tr("파일")), AnyView(Text(tr("분야"))), Text(tr("폴더")), Text(tr("처리 결과")),
              AnyView(Button(action: toggleOrder) {
                  HStack(spacing: 4) {
                      Text(oldestFirst ? tr("시간, 오래된순") : tr("시간, 최신순"))
                      Image(systemName: oldestFirst ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .medium))
                  }.contentShape(Rectangle())
              }.buttonStyle(.plain).help(tr("눌러서 순서 바꾸기"))),
              AnyView(EmptyView()), header: true)
    }

    var body: some View {
        let folder = FilesView.short(suggestion.status == "moved"
            ? (suggestion.movedTo.map { ($0 as NSString).deletingLastPathComponent } ?? suggestion.suggestedFolder) : suggestion.suggestedFolder)
        return Self.cells(Text(suggestion.fileName), AnyView(fieldCell), Text(folder), Text(Self.label(suggestion.status)),
                          AnyView(Text(FilesView.time.string(from: Date(timeIntervalSince1970: suggestion.ts)))),
                          AnyView(undoButton), header: false, failed: suggestion.status == "rejected")
    }

    private var fieldCell: some View { FieldPill(field: field) }

    @ViewBuilder private var undoButton: some View {
        if suggestion.status == "moved" {
            Button(action: undo) {
                HStack(spacing: 5) { Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold)); Text(tr("되돌리기")) }
            }
            .buttonStyle(BrandButtonStyle(kind: .primary)).controlSize(.small)
        }
    }

    private static func cells(_ file: Text, _ field: AnyView, _ folder: Text, _ result: Text, _ time: AnyView, _ action: AnyView,
                              header: Bool, failed: Bool = false) -> some View {
        HStack(spacing: 0) {
            file.lineLimit(1).truncationMode(.middle).padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
            field.padding(.leading, 12).frame(width: 130, alignment: .leading)
            folder.lineLimit(1).truncationMode(.middle).padding(.leading, 12).frame(width: 256, alignment: .leading)
            result.foregroundStyle(failed ? Color(hex: 0x934C3B) : (header ? Brand.gray : Brand.tabText)).padding(.leading, 12).frame(width: 139, alignment: .leading)
            time.foregroundStyle(Brand.gray).padding(.leading, 12).frame(width: 190, alignment: .leading)
            Color.clear.frame(width: 140).overlay(alignment: .leading) { action.padding(.leading, 12) }   // 단추가 없는 머리·줄도 이 칸 자리를 차지해야 칸이 맞는다
        }
        .font(Brand.font(header ? .tag : .caption)).foregroundStyle(header ? Brand.gray : Brand.tabText)
        .frame(height: header ? 38 : HistoryList.rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }

    private static func label(_ status: String) -> String {
        switch status {
        case "moved": return tr("옮김")
        case "ignored": return tr("무시")
        case "undone": return tr("되돌림")
        case "rejected": return tr("거절")
        case "gone": return tr("직접 처리")
        default: return status
        }
    }
}

/// Sits on a paper panel so it reads as settings, apart from the pending list below.
private struct FileSuggestSettings: View {
    @EnvironmentObject private var state: AppState

    private var roots: [String] { state.settings.folderRoots }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("새 파일의 정리 위치 제안")).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                    Text(tr("새 파일에 어울리는 폴더 한 곳을 추천해요. 승인한 파일만 옮겨요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $state.settings.suggestFolders).toggleStyle(BrandSwitchStyle())
            }
            tree.padding(.top, 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.paper))
        .padding(.bottom, 8)
    }

    /// 뿌리 "정리 대상 폴더" 아래로 폴더마다 가지가 뻗고, 맨 끝 가지가 "폴더 추가"
    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Brand.ink).frame(width: 12)
                Text(tr("정리 대상 폴더")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.ink)
                Text("\(roots.count)").font(Brand.jost(11)).foregroundStyle(Brand.gray)
            }
            .frame(height: 28)
            ForEach(roots, id: \.self) { root in
                FolderBranch(root: root, last: false) { state.settings.folderRoots.removeAll { $0 == root } }
            }
            HStack(spacing: 0) {
                TreeElbow(last: true).stroke(Brand.line, lineWidth: 1).frame(width: 20)
                Button { addRoot() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .medium)).frame(width: 12)
                        Text(tr("폴더 추가")).font(Brand.font(.body))
                    }
                    .foregroundStyle(Brand.tabText).padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                    .hoverHighlight(cornerRadius: 6)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .frame(height: 30)
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            let path = url.path
            let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            if !state.settings.folderRoots.contains(shown) { state.settings.folderRoots.append(shown) }
        }
    }
}

/// 대기 중인 제안 카드 하나. 내용(제안·원래 폴더·옮길 폴더)이 같으면 다시 그리지 않는다:
/// 파일 화면은 바뀐 값이 있을 때마다, 마우스를 올릴 때마다 다시 그려진다 (10/25 측정: 카드 6장 다시 그리기 5ms → 3ms 남짓)
private struct PendingCard: View, Equatable {
    let suggestion: FileSuggestion
    let source: String
    let folder: String
    let field: FileField?
    let marked: Bool
    let mark: () -> Void
    let accept: () -> Void
    let choose: () -> Void
    let ignore: () -> Void
    let reveal: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.suggestion == rhs.suggestion && lhs.source == rhs.source && lhs.folder == rhs.folder && lhs.field == rhs.field && lhs.marked == rhs.marked
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.text").font(.system(size: 20, weight: .light)).foregroundStyle(Brand.ink).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(suggestion.fileName).font(Brand.font(.sectionTitle, .semibold)).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(FilesView.time.string(from: Date(timeIntervalSince1970: suggestion.ts))).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                }
                if let reason = suggestion.reason, !reason.isEmpty {
                    Text(reason).font(Brand.font(.body)).foregroundStyle(Brand.tabText).lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
                HStack(spacing: 8) {
                    Text(source).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Brand.ink)
                    Text(folder).font(Brand.font(.caption, .medium)).foregroundStyle(Brand.ink)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 8)
                    FieldPill(field: field)
                }
                .padding(.top, 14)
                HStack(spacing: 4) {
                    Button(action: accept) {
                        HStack(spacing: 4) { Text(tr("옮기기")); Image(systemName: "arrow.right").font(.system(size: 10)) }
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    Button(tr("다른 폴더 고르기"), action: choose).buttonStyle(BrandButtonStyle())
                    Button(tr("무시"), action: ignore).buttonStyle(BrandButtonStyle())
                    Spacer(minLength: 0)
                    Button(action: mark) {
                        Text(marked ? tr("표시 끄기") : tr("위치 표시")).font(Brand.font(.body, .medium))
                        .foregroundStyle(marked ? .white : Brand.blue)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(marked ? Brand.blue : Brand.blue.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tr("왼쪽 옮겨질 곳에서 이 파일 자리를 보여 줘요"))
                    Button(tr("Finder에서 보기"), action: reveal).buttonStyle(BrandButtonStyle())
                }
                .padding(.top, 12)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, marked ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.blue.opacity(marked ? 0.07 : 0)))
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
        .animation(.easeOut(duration: 0.2), value: marked)
    }
}

/// 나무 가지 선: 왼쪽 세로 줄기(x=6, 뿌리 아이콘 가운데)와 줄기에서 오른쪽으로 꺾이는 짧은 가로선. 마지막 가지는 줄기를 가운데에서 끊어 └ 모양
private struct TreeElbow: Shape {
    let last: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 6.5, midY = rect.midY.rounded() + 0.5
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: last ? midY : rect.maxY))
        path.move(to: CGPoint(x: x, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}

/// 정리 대상 폴더 한 가지: 폴더 이름은 진하게, 위 경로는 옅게, 삭제 단추는 커서를 대면 진해진다
private struct FolderBranch: View {
    let root: String
    let last: Bool
    let onRemove: () -> Void
    @State private var hover = false

    private var name: String { (root as NSString).lastPathComponent }
    private var parent: String {
        let dir = (root as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    var body: some View {
        HStack(spacing: 0) {
            TreeElbow(last: last).stroke(Brand.line, lineWidth: 1).frame(width: 20)
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Brand.blue)
                Text(name).font(Brand.font(.rowTitle)).foregroundStyle(Brand.ink)
                if !parent.isEmpty { Text(parent).font(Brand.font(.caption)).foregroundStyle(Brand.gray) }
                Spacer(minLength: 8)
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(hover ? Brand.ink : Brand.tabText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(hover ? Brand.line : Color(hex: 0xEDEAE7)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(tr("\(root) 폴더 삭제"))
            }
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 26)
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .hoverHighlight(cornerRadius: 6)
        }
        .frame(height: 30)
    }
}
