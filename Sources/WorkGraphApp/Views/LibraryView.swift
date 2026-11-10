import SwiftUI
import Quartz
import WorkGraphCore

/// 시트 머리: 제목(22), 설명(12), 닫기 버튼. 유리 판 바탕에 아래 구분선 (Figma 자료 연결 시트)
struct LibrarySheetHeader: View {
    let title: String
    var detail: String? = nil
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Brand.suit(22)).tracking(-0.77).foregroundStyle(Brand.ink)
                if let detail { Text(detail).font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 6) }
            }
            Spacer(minLength: 12)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Brand.tabText)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("닫기")
        }
        .padding(.horizontal, 27).padding(.top, 25).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandGlass()
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }
}

/// 자료 한 줄에 쓰는 작은 아이콘 칸
private struct LibraryTile: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Brand.ink)
            .frame(width: 30, height: 30)
    }
}

/// 보관함 목록 한 줄: 보관한 자료 또는 녹음
enum LibraryEntry: Identifiable {
    case item(ChatLibraryItem)
    case recording(Recording)

    var id: String {
        switch self {
        case .item(let item): "item:\(item.id)"
        case .recording(let recording): "recording:\(recording.id ?? 0)"
        }
    }

    var date: Double {
        switch self {
        case .item(let item): item.createdAt
        case .recording(let recording): recording.startedAt
        }
    }
}

struct LibraryView: View {
    @ObservedObject var library: LibraryState
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var kind: String       // home 은 홈 화면, 빈 글은 전체
    @State private var infos: [String: LibraryTextInfo] = [:]
    @State private var preview: ChatLibraryItem?
    @State private var deleting: ChatLibraryItem?
    @State private var recordingPreview: Recording?
    @State private var sort: Sort = .modified
    @State private var editing: ChatLibraryItem?
    @State private var editTitle = ""
    var title: String?

    enum Sort: String, CaseIterable {
        case title = "제목", kind = "종류", modified = "수정일"
    }

    init(library: LibraryState, initialKind: String = "home", title: String? = nil) {
        self.library = library
        self.title = title
        _kind = State(initialValue: initialKind)
    }

    private var filtered: [ChatLibraryItem] {
        library.items.filter { item in
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)) && (listKind.isEmpty || item.kind == listKind)
        }
    }

    /// 목록에 쓰는 종류: 홈은 전체와 같다
    private var listKind: String { kind == "home" ? "" : kind }

    /// 보관한 자료와 녹음을 날짜순으로
    private var entries: [LibraryEntry] {
        let items: [LibraryEntry] = listKind == "recording" ? [] : filtered.map { LibraryEntry.item($0) }
        let showRecordings = listKind.isEmpty || listKind == "recording"
        let recordings: [LibraryEntry] = showRecordings
            ? state.recordings.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }.map { LibraryEntry.recording($0) }
            : []
        let dated = (items + recordings).map { ($0, modified($0)) }
        return dated.sorted { left, right in
            switch sort {
            case .title:
                let order = left.0.title.localizedStandardCompare(right.0.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .kind:
                let order = LibraryLook.name(left.0.kind).localizedStandardCompare(LibraryLook.name(right.0.kind))
                if order != .orderedSame { return order == .orderedAscending }
            case .modified: break
            }
            return left.1 == right.1 ? left.0.id < right.0.id : left.1 > right.1
        }.map { $0.0 }
    }

    private func modified(_ entry: LibraryEntry) -> Double {
        switch entry {
        case .item(let item): library.store.modifiedAt(for: item)
        case .recording(let recording): recording.readyAt ?? recording.endedAt ?? recording.startedAt
        }
    }

    private var emptyTitle: String {
        if kind == "recording" { return state.recordings.isEmpty ? "녹음이 없습니다" : "검색 결과가 없습니다" }
        return library.items.isEmpty && state.recordings.isEmpty ? "보관한 자료가 없습니다" : "검색 결과가 없습니다"
    }
    var body: some View {
        HStack(spacing: 0) {
            if title == nil {
                sidebar
                Rectangle().fill(Brand.hairline).frame(width: 1)
            }
            content
        }
        .sheet(item: $preview) { LibraryPreview(library: library, item: $0) }
        .sheet(item: $recordingPreview) { RecordingDetailView(recording: $0).environmentObject(state) }
        .onAppear { state.refreshRecordings() }
        .onChange(of: query) { _, text in if kind == "home", !text.isEmpty { kind = "" } }
        .task(id: library.items.map(\.id)) {
            var found: [String: LibraryTextInfo] = [:]
            for item in library.items where item.kind == "note" { found[item.id] = LibraryTextInfo.read(library.store.url(for: item)) }
            infos = found
        }
        .alert("제목 바꾸기", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("제목", text: $editTitle)
            Button("취소", role: .cancel) { editing = nil }
            Button("저장") { if let editing { library.rename(editing, title: editTitle) }; editing = nil }
                .disabled(editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("자료를 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("취소", role: .cancel) { deleting = nil }
            Button("삭제", role: .destructive) { if let deleting { library.delete(deleting) }; deleting = nil }
        } message: { Text("결과물의 복사본과 모든 대화 연결이 삭제됩니다. 업로드한 원본 파일과 기존 채팅 답변은 남습니다.") }
    }

    /// 유리 사이드바: 파일 올리기 버튼, 종류 필터 (보관함 이름은 위쪽 글자 탭이 보인다)
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { library.importFiles() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 12))
                    Text("파일 업로드").font(Brand.suit(12, .medium))
                    if library.busy { ProgressView().controlSize(.mini) }
                }.foregroundStyle(Brand.tabText).frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.5)))
                    .hoverHighlight(cornerRadius: 6)
            }.buttonStyle(.plain).disabled(library.busy).padding(.top, 18)
            Eyebrow("종류").padding(.top, 26).padding(.leading, 12)
            VStack(spacing: 2) {
                filterRow("홈", kind == "home") { kind = "home" }
                filterRow("전체 종류", kind.isEmpty) { kind = "" }
                filterRow("업로드", kind == "upload") { kind = "upload" }
                filterRow("생성한 결과물", kind == "generated") { kind = "generated" }
                filterRow("저장한 답변", kind == "note") { kind = "note" }
                filterRow("녹음", kind == "recording") { kind = "recording" }
            }.padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 249).frame(maxHeight: .infinity)
        .brandGlass()
    }

    private func filterRow(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.suit(11, on ? .medium : .regular)).foregroundStyle(on ? Brand.ink : Brand.tabText).lineLimit(1)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .glassPill(on, cornerRadius: 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    Text(title).font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink)
                    Spacer()
                    Button { library.importFiles() } label: { Label("파일 업로드", systemImage: "plus") }
                        .buttonStyle(BrandButtonStyle()).disabled(library.busy)
                }.padding(.horizontal, 28).padding(.top, 22)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Brand.gray)
                TextField("자료 이름 검색", text: $query).textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
            }.brandField().padding(.horizontal, 34).padding(.top, 16)
                .help("업로드한 파일, 생성한 결과물, 저장한 답변과 녹음을 모아 둬요. 프로젝트나 대화에 연결한 자료만 답변에 써요.")
            if title != nil { sortAndFilter }
            if let error = library.error {
                Text(error).font(Brand.suit(12)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 34).padding(.top, 10)
            }
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: kind == "recording" ? "waveform" : "tray").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.sub)
                    Text(emptyTitle).font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink)
                    Text(kind == "recording" ? "메뉴 막대에서 녹음 시작을 누르면 받아쓴 글이 여기에 모여요." : "파일을 업로드하거나 채팅에서 결과물을 만들어보세요.")
                        .font(Brand.suit(12)).foregroundStyle(Brand.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { kindContent.padding(.horizontal, 34).padding(.top, 20).padding(.bottom, 24) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
    }

    private var sortAndFilter: some View {
        HStack(spacing: 12) {
            Picker("종류", selection: $kind) {
                Text("홈").tag("home")
                Text("전체 종류").tag("")
                ForEach(LibraryLook.order, id: \.self) { Text(LibraryLook.name($0)).tag($0) }
            }
            Picker("정렬", selection: $sort) {
                ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.onChange(of: sort) { _, _ in if kind == "home" { kind = "" } }
            Spacer()
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 34).padding(.top, 12)
    }

    private var actions: LibraryActions {
        LibraryActions(
            open: { entry in
                switch entry {
                case .item(let item): preview = item
                case .recording(let recording): recordingPreview = recording
                }
            },
            export: { library.export($0) }, delete: { deleting = $0 },
            rename: { editing = $0; editTitle = $0.title },
            url: { library.store.url(for: $0) }, modified: { modified($0) },
            projectCount: { library.projectIDs($0).count })
    }

    @ViewBuilder private var kindContent: some View {
        let recs = entries.compactMap { entry -> Recording? in if case .recording(let r) = entry { r } else { nil } }
        let mine = entries.compactMap { entry -> ChatLibraryItem? in if case .item(let i) = entry { i } else { nil } }
        switch kind {
        case "home": LibraryHome(items: library.items, recordings: state.recordings, tasks: state.taskList, itemFocuses: library.itemFocuses, actions: actions)
        case "recording": LibraryRecordingList(recordings: recs, actions: actions)
        case "upload": LibraryUploadList(items: mine, actions: actions)
        case "generated": LibraryGeneratedGrid(items: mine, actions: actions)
        case "note": LibraryNoteList(items: mine, actions: actions, infos: infos)
        default: LibraryAllList(entries: entries, actions: actions)
        }
    }
}

struct LibraryPreview: View {
    @ObservedObject var library: LibraryState
    let item: ChatLibraryItem
    @Environment(\.dismiss) private var dismiss
    private var artifact: ChatArtifact? {
        let ext = URL(fileURLWithPath: item.filename).pathExtension.lowercased()
        guard item.kind != "upload" || ["html", "htm"].contains(ext),
              let text = try? String(contentsOf: library.store.url(for: item), encoding: .utf8) else { return nil }
        return .init(title: item.title, format: ext == "md" ? "markdown" : ext == "htm" ? "html" : ext, content: text)
    }
    var body: some View {
        Group {
        if let artifact {
            ArtifactPreview(artifact: artifact)
        } else {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(item.title).font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink).lineLimit(1); Spacer()
                Button("파일 내보내기") { library.export(item) }.buttonStyle(BrandButtonStyle())
                Button("닫기") { dismiss() }.buttonStyle(BrandButtonStyle())
            }.padding(.horizontal, 24).frame(height: 56)
            Rectangle().fill(Brand.line).frame(height: 1)
            LibraryQuickLook(url: library.store.url(for: item))
            if !item.extractionNote.isEmpty { Text(item.extractionNote).font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(12) }
        }.frame(width: 800, height: 600).background(.white)
        }
        }
    }
}

private struct LibraryQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true; view.previewItem = url as NSURL; return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

struct LibraryPicker: View {
    @ObservedObject var library: LibraryState
    var onSelect: (ChatLibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            LibrarySheetHeader(title: "보관함에서 선택", detail: "연결한 자료만 답변에 사용해요.") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Brand.gray)
                TextField("자료 이름 검색", text: $query).textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
            }.padding(.horizontal, 12).frame(height: 36)
                .background(ChatPalette.field, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 27).padding(.top, 16)
            ScrollView {
                LazyVStack(spacing: 0) {
                    let items = library.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                    ForEach(items) { item in
                        Button { onSelect(item); dismiss() } label: {
                            HStack(spacing: 12) {
                                LibraryTile(symbol: "doc.text")
                                Text(item.title).font(Brand.suit(12)).foregroundStyle(Brand.tabText).lineLimit(1)
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Brand.gray)
                            }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if items.isEmpty { Text(library.items.isEmpty ? "보관한 자료가 없습니다" : "검색 결과가 없습니다").font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(28) }
                }.padding(.horizontal, 27).padding(.top, 4)
            }
            HStack {
                Spacer()
                Button("완료") { dismiss() }.buttonStyle(BrandButtonStyle(kind: .primary))
            }.padding(.horizontal, 24).frame(height: 63)
                .brandGlass()
                .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
        }.frame(width: 600, height: 480).background(.white)
    }
}

struct ProjectSourcesView: View {
    @ObservedObject var library: LibraryState
    @ObservedObject var projects: ProjectState
    var project: ChatProject
    @State private var picker = false
    @State private var preview: ChatLibraryItem?
    @Binding var kind: String
    @Binding var newestFirst: Bool
    @State private var hoveredSource: String?

    private var sources: [ChatLibraryItem] {
        library.sources(projectID: project.id).filter { kind.isEmpty || $0.kind == kind }
            .sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
    }
    private var paths: [String] { kind.isEmpty || kind == "folder" ? project.paths : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Menu {
                Button("파일 업로드") { library.importFiles(projectID: project.id) }.disabled(library.busy)
                Button("보관함에서 선택") { picker = true }
                Divider()
                Button("이 컴퓨터에서 폴더 연결") { projects.connectFiles(project) }
            } label: {
                Label("소스 추가", systemImage: "plus").font(Brand.suit(12, .medium))
                    .foregroundStyle(Brand.tabText).padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .disabled(library.busy).accessibilityLabel("소스 추가")
            Rectangle().fill(Brand.line).frame(height: 1)
            if library.busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("소스를 추가하고 있어요").font(Brand.suit(12)).foregroundStyle(Brand.gray) }
                    .padding(16)
            }
            ForEach(sources) { item in sourceRow(item) }
            ForEach(paths, id: \.self) { path in folderRow(path) }
            if sources.isEmpty && paths.isEmpty && !library.busy {
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind.isEmpty ? "프로젝트에 소스를 추가해보세요" : "이 종류의 소스가 없습니다")
                        .font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink)
                    Text("파일을 올리거나 보관함의 자료, 컴퓨터의 폴더를 연결할 수 있습니다.")
                        .font(Brand.suit(12)).foregroundStyle(Brand.gray)
                }.padding(.horizontal, 16).padding(.vertical, 28)
            }
            if let error = library.error { Text(error).foregroundStyle(.red).font(Brand.suit(12)).padding(16) }
        }
        .sheet(isPresented: $picker) { LibraryPicker(library: library) { library.attach($0, projectID: project.id) } }
        .sheet(item: $preview) { LibraryPreview(library: library, item: $0) }
    }

    private func sourceRow(_ item: ChatLibraryItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { preview = item } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.kind == "note" ? "text.bubble" : "doc.text").font(.system(size: 14))
                            .foregroundStyle(Brand.ink).frame(width: 36, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.tabText).lineLimit(1)
                            Text(item.kind == "note" ? "저장한 답변" : item.kind == "generated" ? "생성한 파일" : "업로드")
                                .font(Brand.suit(10)).foregroundStyle(Brand.gray)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 12).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(ChatDateText.day(item.createdAt)).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                Menu {
                    Button("파일 내보내기") { library.export(item) }
                    Button("프로젝트에서 제거") { library.detach(item, projectID: project.id) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Brand.gray).frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hoveredSource == item.id ? 1 : 0).accessibilityLabel("\(item.title) 소스 메뉴")
            }.padding(.horizontal, 16)
                .background(hoveredSource == item.id ? Brand.paper : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hoveredSource = $0 ? item.id : nil }
                .contextMenu {
                    Button("파일 내보내기") { library.export(item) }
                    Button("프로젝트에서 제거") { library.detach(item, projectID: project.id) }
                }
            Rectangle().fill(Brand.line).frame(height: 1)
        }
    }

    private func folderRow(_ path: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(Brand.ink)
                    .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(Brand.suit(12, .medium)).foregroundStyle(Brand.tabText).lineLimit(1)
                    Text("원본 연결, 파일을 복사하지 않고 참고합니다").font(Brand.suit(10)).foregroundStyle(Brand.gray)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("Finder에서 보기") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                    Button("프로젝트에서 제거") { projects.disconnect(path, from: project) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(Brand.gray).frame(width: 24, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(hoveredSource == path ? 1 : 0).accessibilityLabel("폴더 소스 메뉴")
            }.padding(.horizontal, 16).padding(.vertical, 12).help(path)
                .background(hoveredSource == path ? Brand.paper : .clear, in: RoundedRectangle(cornerRadius: 8))
                .onHover { hoveredSource = $0 ? path : nil }
                .contextMenu { Button("프로젝트에서 제거") { projects.disconnect(path, from: project) } }
            Rectangle().fill(Brand.line).frame(height: 1)
        }
    }
}
