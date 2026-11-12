import SwiftUI
import QuickLookThumbnailing
import SillogCore

/// 보관함 종류별 화면과 홈 (Figma LB-25, LB-04, LB-06, LB-16, LB-17, LB-18). 수치는 모두 앱 데이터로 계산한다.
enum LibraryLook {
    static let recording = Color(hex: 0x6E5A4D)
    static let upload = Color(hex: 0xA38E7F)
    static let generated = Color(hex: 0xC4B5A8)
    static let note = Color(hex: 0xE1D8D0)
    static let noContent = Color(hex: 0xB8ABA0)
    static let failed = Color(hex: 0xB5503F)
    /// 막대와 범례에 나오는 순서
    static let order = ["recording", "upload", "generated", "note"]

    static func color(_ kind: String) -> Color {
        switch kind {
        case "recording": recording
        case "upload": upload
        case "generated": generated
        default: note
        }
    }
    static func name(_ kind: String) -> String {
        switch kind {
        case "recording": tr("녹음")
        case "upload": tr("업로드")
        case "generated": tr("생성한 결과물")
        default: tr("저장한 답변")
        }
    }
    static func when(_ time: Double) -> String { RecordingText.date(time, tr("M월 d일 HH:mm"), timeZone: .current) }
    static func day(_ time: Double) -> String { RecordingText.date(time, tr("M월 d일"), timeZone: .current) }
    static func ext(_ item: ChatLibraryItem) -> String { URL(fileURLWithPath: item.filename).pathExtension.lowercased() }
    /// 형식 열에 쓰는 이름
    static func format(_ ext: String) -> String {
        switch ext {
        case "pdf": "PDF"
        case "doc", "docx": tr("Word 문서")
        case "html", "htm": tr("HTML 문서")
        case "md", "markdown": tr("Markdown 문서")
        case "txt": tr("텍스트")
        case "ppt", "pptx": "PowerPoint"
        case "xls", "xlsx": "Excel"
        case "hwp", "hwpx": tr("한글 문서")
        case "png", "jpg", "jpeg", "gif", "heic": tr("이미지")
        case "": tr("파일")
        default: ext.uppercased()
        }
    }
    static func count(_ n: Int) -> String { "\(n.formatted())" }
}

extension LibraryEntry {
    var kind: String {
        switch self {
        case .item(let item): item.kind
        case .recording: "recording"
        }
    }
    var title: String {
        switch self {
        case .item(let item): item.title
        case .recording(let recording): recording.displayTitle
        }
    }
}

extension Recording {
    /// 목록과 막대에 쓰는 받아쓰기 상태
    var libraryStatus: (text: String, color: Color) {
        switch status {
        case .recording: (tr("녹음 중"), Brand.gray)
        case .transcribing: (tr("받아쓰는 중"), Brand.gray)
        case .failed: (tr("실패"), LibraryLook.failed)
        case .ready: hasTranscript ? (tr("완료"), Brand.tabText) : (tr("내용 없음"), Brand.gray)
        }
    }
}

struct LibraryActions {
    var open: (LibraryEntry) -> Void
    var export: (ChatLibraryItem) -> Void
    var delete: (ChatLibraryItem) -> Void
    let rename: (ChatLibraryItem) -> Void
    let url: (ChatLibraryItem) -> URL
    let modified: (LibraryEntry) -> Double
    let projectCount: (ChatLibraryItem) -> Int
}

/// 저장한 답변의 첫 줄과 글자 수.
struct LibraryTextInfo {
    var first = ""
    var count = 0

    static func read(_ url: URL) -> LibraryTextInfo {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        return from(raw)
    }

    static func from(_ raw: String) -> LibraryTextInfo {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? plainText(raw) : raw
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#>*- \t")) }.first { !$0.isEmpty } ?? ""
        return .init(first: line, count: text.count)
    }

    /// HTML 결과물: 머리(head, style, script)와 태그를 걷어 낸 본문 글. 카드 미리보기에 <!doctype html> 이 보이지 않게
    private static func plainText(_ html: String) -> String {
        var s = html
        for pattern in ["(?is)<head.*?</head>", "(?is)<style.*?</style>", "(?is)<script.*?</script>", "(?i)<br\\s*/?>|</(p|div|h[1-6]|li|tr)>", "(?s)<[^>]+>"] {
            s = s.replacingOccurrences(of: pattern, with: pattern.hasPrefix("(?i)<br") ? "\n" : " ", options: .regularExpression)
        }
        return s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// 머리: 종류 이름과 개수(16), 한 줄 요약(11)
private struct KindHeader: View {
    let title: String
    let summary: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink)
            Text(summary).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 목록 줄: 누르면 열고, 보관한 자료는 오른쪽 클릭 메뉴로 내보내거나 지운다
private struct KindRow<Content: View>: View {
    let entry: LibraryEntry
    let actions: LibraryActions
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        Button { actions.open(entry) } label: {
            content.padding(.vertical, spacing).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
            .contextMenu {
                if case .item(let item) = entry {
                    Button(tr("제목 바꾸기")) { actions.rename(item) }
                    Button(tr("파일 내보내기")) { actions.export(item) }
                    Button(tr("결과물에서 삭제"), role: .destructive) { actions.delete(item) }
                }
            }
    }
}

/// 열 제목 줄 (10, 회색) 과 아래 선
private struct ColumnHeads: View {
    let heads: [(String, CGFloat)]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28, height: 1)
                ForEach(heads.indices, id: \.self) { i in
                    Text(heads[i].0).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                        .frame(width: heads[i].1 > 0 ? heads[i].1 : nil, alignment: .leading)
                        .frame(maxWidth: heads[i].1 > 0 ? nil : .infinity, alignment: .leading)
                }
            }.padding(.top, 30).padding(.bottom, 8)
            Rectangle().fill(Brand.line).frame(height: 1)
        }
    }
}

private func cell(_ text: String, _ width: CGFloat, gray: Bool = false) -> some View {
    Text(text).font(Brand.font(.caption)).foregroundStyle(gray ? Brand.gray : Brand.tabText).lineLimit(1)
        .frame(width: width > 0 ? width : nil, alignment: .leading).frame(maxWidth: width > 0 ? nil : .infinity, alignment: .leading)
}

private func lead(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Brand.tabText).frame(width: 28, alignment: .leading)
}

private func title(_ text: String, _ width: CGFloat) -> some View {
    Text(text).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText).lineLimit(1)
        .frame(width: width, alignment: .leading)
}

/// LB-04: 전체, 종류 색 표시와 추가한 때 열, 최근순
struct LibraryAllList: View {
    let entries: [LibraryEntry]
    let actions: LibraryActions
    var body: some View {
        let counts = LibraryLook.order.map { kind in (kind, entries.filter { $0.kind == kind }.count) }
        VStack(spacing: 0) {
            KindHeader(title: tr("전체 \(entries.count)개"),
                       summary: counts.filter { $0.1 > 0 }.map { "\(LibraryLook.name($0.0)) \($0.1)" }.joined(separator: "     "))
            ColumnHeads(heads: [(tr("제목"), 248), (tr("종류"), 112), (tr("수정일"), 0)])
            ForEach(entries) { entry in
                KindRow(entry: entry, actions: actions) {
                    HStack(spacing: 0) {
                        entryThumbnail(entry, actions: actions)
                        title(entry.title, 248)
                        HStack(spacing: 6) {
                            Circle().fill(LibraryLook.color(entry.kind)).frame(width: 6, height: 6)
                            Text(LibraryLook.name(entry.kind)).font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
                        }.frame(width: 112, alignment: .leading)
                        cell(LibraryLook.when(actions.modified(entry)), 0, gray: true)
                    }
                }
            }
        }
    }
}

/// LB-06: 제목, 녹음한 때, 길이와 비례 막대, 받아쓰기 상태 (실패는 붉게)
struct LibraryRecordingList: View {
    let recordings: [Recording]
    let actions: LibraryActions
    var body: some View {
        let longest = max(recordings.map(\.duration).max() ?? 0, 1)
        let total = recordings.reduce(0) { $0 + $1.duration }
        let ready = recordings.filter { $0.status == .ready && $0.hasTranscript }.count
        let empty = recordings.filter { $0.status == .ready && !$0.hasTranscript }.count
        let failed = recordings.filter { $0.status == .failed }.count
        VStack(spacing: 0) {
            KindHeader(title: tr("녹음 \(recordings.count)개"),
                       summary: tr("총 길이 \(RecordingText.duration(total))     받아쓰기 완료 \(ready)     내용 없음 \(empty)     실패 \(failed)"))
            ColumnHeads(heads: [(tr("제목"), 220), (tr("녹음한 때"), 112), (tr("길이"), 116), (tr("받아쓰기"), 0)])
            ForEach(recordings) { recording in
                let status = recording.libraryStatus
                KindRow(entry: .recording(recording), actions: actions) {
                    HStack(spacing: 0) {
                        lead("waveform")
                        title(recording.displayTitle, 220)
                        cell(LibraryLook.when(recording.startedAt), 112, gray: true)
                        HStack(spacing: 8) {
                            Text(RecordingText.duration(recording.duration)).font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
                                .frame(width: 64, alignment: .leading)
                            if recording.duration > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(LibraryLook.recording)
                                    .frame(width: max(4, 42 * recording.duration / longest), height: 4)
                            }
                        }.frame(width: 116, alignment: .leading)
                        Text(status.text).font(Brand.font(.caption, recording.status == .failed ? .medium : .regular)).foregroundStyle(status.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// LB-16: 이름, 형식, 올린 때, 연결한 프로젝트
struct LibraryUploadList: View {
    let items: [ChatLibraryItem]
    let actions: LibraryActions
    var body: some View {
        VStack(spacing: 0) {
            KindHeader(title: tr("업로드 \(items.count)개"), summary: tr("내가 올린 파일의 복사본이에요"))
            ColumnHeads(heads: [(tr("이름"), 228), (tr("형식"), 88), (tr("수정일"), 114), (tr("연결한 프로젝트"), 0)])
            ForEach(items) { item in
                let projects = actions.projectCount(item)
                KindRow(entry: .item(item), actions: actions, spacing: 16) {
                    HStack(spacing: 0) {
                        entryThumbnail(.item(item), actions: actions)
                        title(item.title, 228)
                        cell(LibraryLook.format(LibraryLook.ext(item)), 88)
                        cell(LibraryLook.when(actions.modified(.item(item))), 114, gray: true)
                        cell(projects > 0 ? tr("프로젝트 \(projects)개") : tr("연결 없음"), 0)
                    }
                }
            }
            Text(tr("올린 파일은 연결한 대화와 프로젝트에서 답변 근거로 써요.")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18)
        }
    }
}

/// LB-17: 문서 모양 미리보기 그림 2열 카드, 형식과 날짜
struct LibraryGeneratedGrid: View {
    let items: [ChatLibraryItem]
    let actions: LibraryActions

    private var formatText: String {
        var formats: [String: Int] = [:]
        for item in items { formats[LibraryLook.ext(item).uppercased(), default: 0] += 1 }
        return formats.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { tr("\($0.key.isEmpty ? tr("파일") : $0.key) \($0.value)개") }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KindHeader(title: tr("생성한 결과물 \(items.count)개"), summary: tr("채팅에서 만든 결과물이에요     형식은 \(formatText)"))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], alignment: .leading, spacing: 28) {
                ForEach(items) { item in
                    Button { actions.open(.item(item)) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            LibraryThumbnail(url: actions.url(item), size: CGSize(width: 228, height: 146))
                                .frame(maxWidth: .infinity).background(Brand.paper)
                            Text(item.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText).lineLimit(1).padding(.top, 14)
                            Text("\(LibraryLook.format(LibraryLook.ext(item)))     \(LibraryLook.when(actions.modified(.item(item))))")
                                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.top, 6)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .contextMenu {
                            Button(tr("제목 바꾸기")) { actions.rename(item) }
                            Button(tr("파일 내보내기")) { actions.export(item) }
                            Button(tr("결과물에서 삭제"), role: .destructive) { actions.delete(item) }
                        }
                }
            }.padding(.top, 26)
        }
    }
}

private func entryThumbnail(_ entry: LibraryEntry, actions: LibraryActions) -> some View {
    Group {
        switch entry {
        case .item(let item):
            LibraryThumbnail(url: actions.url(item), size: CGSize(width: 26, height: 28))
        case .recording: lead("waveform")
        }
    }.frame(width: 28).padding(.trailing, 6)
}

private struct LibraryThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    private var symbol: String {
        switch url.pathExtension.lowercased() {
        case "png", "jpeg", "jpg", "heic", "gif", "svg", "webp": "photo"
        case "pdf": "doc.richtext"
        case "csv", "xls", "xlsx", "tsv": "tablecells"
        case "ppt", "pptx", "key": "rectangle.on.rectangle"
        case "mp4", "mov", "webm": "film"
        case "m4a", "mp3", "wav": "waveform"
        case "html", "htm", "json": "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz": "archivebox"
        default: "doc.text"
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: symbol).font(.system(size: min(size.width / 2, 26))).foregroundStyle(Brand.gray) }
            }.frame(width: size.width, height: size.height)
            if image != nil {
                Image(systemName: symbol).font(.system(size: size.width > 40 ? 11 : 7))
                    .foregroundStyle(Brand.ink).padding(size.width > 40 ? 5 : 2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
                image = representation.nsImage
            }
        }
    }
}

/// LB-18: 제목, 첫 줄, 날짜, 글자 수, 연결 프로젝트
struct LibraryNoteList: View {
    let items: [ChatLibraryItem]
    let actions: LibraryActions
    let infos: [String: LibraryTextInfo]
    var body: some View {
        LazyVStack(spacing: 0) {
            KindHeader(title: tr("저장한 답변 \(items.count)개"), summary: tr("채팅 답변을 저장해 둔 글이에요")).padding(.bottom, 18)
            ForEach(items) { item in
                let projects = actions.projectCount(item)
                let info = infos[item.id]
                KindRow(entry: .item(item), actions: actions, spacing: 18) {
                    VStack(spacing: 8) {
                        HStack {
                            entryThumbnail(.item(item), actions: actions)
                            Text(item.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText).lineLimit(1)
                            Spacer(minLength: 16)
                            Text(LibraryLook.when(actions.modified(.item(item)))).font(Brand.font(.caption)).foregroundStyle(Brand.tabText)
                        }
                        HStack {
                            Text(info?.first ?? "").font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                            Spacer(minLength: 16)
                            Text("\(info.map { tr("\($0.count.formatted())자") } ?? "")     \(projects > 0 ? tr("프로젝트 \(projects)개") : tr("연결 없음"))")
                                .font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
        }
    }
}

/// LB-25, LB-26: 보관함 홈. 분야별 누적 면적 차트와 범례, 종류별 개수, 6개월 잔디 달력, 최근 추가 5건
struct LibraryHome: View {
    let items: [ChatLibraryItem]
    let recordings: [Recording]
    var tasks: [TaskSummary] = []
    /// 보관 자료 id -> 연결 대화의 초점. 없으면 "분야 없음"
    var itemFocuses: [String: [ChatFocus]] = [:]
    let actions: LibraryActions
    @State private var period = Period.all

    enum Period: String, CaseIterable {
        case week = "7일", month = "30일", year = "1년", all = "전체"
        var days: Int? { switch self { case .week: 7; case .month: 30; case .year: 365; case .all: nil } }
    }

    private struct Row { let kind: String; let date: Double; let field: String }

    private var entries: [LibraryEntry] {
        (items.map { LibraryEntry.item($0) } + recordings.map { LibraryEntry.recording($0) }).sorted { $0.date > $1.date }
    }

    /// 항목 하나의 분야: 녹음은 업무의 분야, 보관 자료는 연결 대화의 첫 초점 (업무면 그 업무의 분야, 분야면 그 이름). 못 찾으면 "분야 없음"
    private func rows(_ all: [LibraryEntry]) -> [Row] {
        let none = TasksView.noField
        let byID = Dictionary(tasks.map { ($0.id, $0.field) }, uniquingKeysWith: { a, _ in a })
        let byKey = Dictionary(tasks.map { ($0.key, $0.field) }, uniquingKeysWith: { a, _ in a })
        return all.map { entry in
            var field = none
            switch entry {
            case .recording(let r): if let id = r.taskId, let f = byID[id] ?? nil { field = f }
            case .item(let item):
                if let focus = itemFocuses[item.id]?.first {
                    if focus.kind == .theme { field = focus.title } else if let f = byKey[focus.key] ?? nil { field = f }
                }
            }
            return Row(kind: entry.kind, date: entry.date, field: field)
        }
    }

    /// 업무가 있는 분야는 0개여도 범례에 나온다. "분야 없음" 은 항목이 있을 때만
    private func fieldList(_ rows: [Row]) -> [TasksView.FieldStat] {
        var counts: [String: Int] = [:]
        for task in tasks { counts[task.field ?? TasksView.noField, default: 0] += 0 }
        for row in rows { counts[row.field, default: 0] += 1 }
        return TasksView.fieldStats(counts: counts.filter { $0.key != TasksView.noField || $0.value > 0 })
    }

    var body: some View {
        let all = entries
        let rows = rows(all)
        let fields = fieldList(rows)
        VStack(alignment: .leading, spacing: 0) {
            banner(all, rows, fields)
            legend(fields, total: all.count).padding(.top, 5)
            Rectangle().fill(Brand.line).frame(height: 1).padding(.top, 10)
            HStack(alignment: .top, spacing: 50) {
                VStack(alignment: .leading, spacing: 0) {
                    kindCounts(all)
                    calendar(all).padding(.top, 23)
                }.frame(maxWidth: .infinity, alignment: .leading)
                recent(all).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.top, 19)
        }
    }

    // MARK: 위 카드와 차트

    private func banner(_ all: [LibraryEntry], _ rows: [Row], _ fields: [TasksView.FieldStat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(hex: 0xF7F5F2))
                AreaChart(rows: rows.map { ($0.date, $0.field) }, fields: fields, period: period.days).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("보관함 전체")).font(Brand.font(.tag)).foregroundStyle(Brand.gray)
                    Text(tr("\(all.count.formatted())개")).font(Brand.font(.screenTitle)).foregroundStyle(Brand.ink).padding(.top, 2)
                    if let last = all.first {
                        Text(tr("마지막으로 쌓인 때  \(LibraryLook.when(last.date))")).font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.top, 4)
                    }
                }.padding(.leading, 18).padding(.top, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 2) {
                    ForEach(Period.allCases, id: \.self) { p in
                        Button { period = p } label: {
                            Text(L10n.tr(key: p.rawValue)).font(Brand.font(.caption)).foregroundStyle(period == p ? Color(hex: 0x3D2F27) : Brand.gray)
                                .padding(.horizontal, 11).frame(height: 21)
                                .background(Capsule().fill(period == p ? Color(hex: 0xEAE3DC) : .clear))
                                .overlay(Capsule().stroke(period == p ? Color(hex: 0xCCBEB3) : .clear, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(.trailing, 14).padding(.top, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }.frame(height: 150)
            AreaAxis(dates: rows.map(\.date), period: period.days).padding(.top, 3)
        }
    }

    /// 색 점, 분야 이름, 개수, 퍼센트. 한 줄에 6개씩, 더 많으면 다음 줄
    private func legend(_ fields: [TasksView.FieldStat], total: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .topLeading), count: 6), alignment: .leading, spacing: 12) {
            ForEach(fields) { f in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(f.color).frame(width: 8, height: 8)
                        Text(f.title).font(Brand.font(.caption)).foregroundStyle(Brand.tabText).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(f.count.formatted()).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink)
                        Text(tr("개")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        Text("\(total > 0 ? Int((Double(f.count) / Double(total) * 100).rounded()) : 0)%").font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.leading, 4)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 아래 왼쪽

    private func kindCounts(_ all: [LibraryEntry]) -> some View {
        let counts = Dictionary(grouping: all, by: \.kind).mapValues(\.count)
        let ready = recordings.filter { $0.status == .ready && $0.hasTranscript }.count
        let empty = recordings.filter { $0.status == .ready && !$0.hasTranscript }.count
        let failed = recordings.filter { $0.status == .failed }.count
        return VStack(alignment: .leading, spacing: 0) {
            Text(tr("종류별 개수")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
            HStack(alignment: .top, spacing: 0) {
                ForEach(LibraryLook.order, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LibraryLook.name(kind)).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text((counts[kind] ?? 0).formatted()).font(Brand.font(.sectionTitle)).foregroundStyle(Brand.ink)
                            Text(tr("개")).font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                        }
                    }.frame(width: 92, alignment: .leading)
                }
            }.padding(.top, 8)
            if !recordings.isEmpty {
                Text(tr("녹음 총 길이 \(RecordingText.duration(recordings.reduce(0) { $0 + $1.duration })), 받아쓰기 완료 \(ready), 내용 없음 \(empty), 실패 \(failed)"))
                    .font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.top, 12)
            }
        }
    }

    /// 최근 6개월 잔디: 한 줄이 월~일, 한 칸이 하루. 오늘 칸에 테두리
    private func calendar(_ all: [LibraryEntry]) -> some View {
        let cal = Calendar(identifier: .gregorian)
        var mondayFirst = cal; mondayFirst.firstWeekday = 2
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .month, value: -6, to: today)!
        let start = mondayFirst.dateInterval(of: .weekOfYear, for: from)!.start
        let weeks = (cal.dateComponents([.day], from: start, to: today).day! / 7) + 1
        var perDay: [Date: Int] = [:]
        for entry in all { perDay[cal.startOfDay(for: Date(timeIntervalSince1970: entry.date)), default: 0] += 1 }
        let peak = max(perDay.values.max() ?? 0, 1)
        func day(_ week: Int, _ row: Int) -> Date { cal.date(byAdding: .day, value: week * 7 + row, to: start)! }
        func shade(_ n: Int) -> Color {
            if n == 0 { return Color(hex: 0xF2EEEA) }
            let r = Double(n) / Double(peak)
            return r <= 0.25 ? LibraryLook.note : r <= 0.5 ? LibraryLook.generated : r <= 0.75 ? LibraryLook.upload : LibraryLook.recording
        }
        let months: [(Int, String)] = (1..<weeks).compactMap { w in
            let d = day(w, 0)
            return cal.component(.day, from: d) <= 7 && cal.component(.day, from: day(w - 1, 0)) > 7 ? (w, tr("\(cal.component(.month, from: d))월")) : nil
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("최근 6개월 추가")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText)
                Spacer()
                HStack(spacing: 2) {
                    Text(tr("적음")).font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.trailing, 4)
                    ForEach([Color(hex: 0xF2EEEA), LibraryLook.note, LibraryLook.generated, LibraryLook.upload, LibraryLook.recording].indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill([Color(hex: 0xF2EEEA), LibraryLook.note, LibraryLook.generated, LibraryLook.upload, LibraryLook.recording][i]).frame(width: 9, height: 9)
                    }
                    Text(tr("많음")).font(Brand.font(.tag)).foregroundStyle(Brand.gray).padding(.leading, 4)
                }
            }
            ZStack(alignment: .topLeading) {
                ForEach(months, id: \.0) { m in
                    Text(m.1).font(Brand.font(.tag)).foregroundStyle(Brand.gray).fixedSize().offset(x: 19 + CGFloat(m.0) * 13, y: 0)
                }
                ForEach([0, 2, 4], id: \.self) { row in
                    Text([tr("월"), "", tr("수"), "", tr("금")][row]).font(Brand.font(.tag)).foregroundStyle(Brand.gray).offset(x: 0, y: 14 + CGFloat(row) * 13)
                }
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<weeks, id: \.self) { w in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { r in
                                let d = day(w, r)
                                if d <= today {
                                    RoundedRectangle(cornerRadius: 2).fill(shade(perDay[d] ?? 0)).frame(width: 11, height: 11)
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(d == today ? LibraryLook.recording : .clear, lineWidth: 1))
                                } else { Color.clear.frame(width: 11, height: 11) }
                            }
                        }
                    }
                }.offset(x: 19, y: 14)
            }.frame(height: 14 + 89, alignment: .topLeading).padding(.top, 8)
        }
    }

    // MARK: 아래 오른쪽

    private func recent(_ all: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("최근 추가")).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText).padding(.bottom, 11)
            ForEach(Array(all.prefix(5))) { entry in
                KindRow(entry: entry, actions: actions, spacing: 7.5) {   // 행 피치 48pt (Figma)
                    VStack(alignment: .leading, spacing: 4.5) {
                        Text(entry.title).font(Brand.font(.body, .medium)).foregroundStyle(Brand.tabText).lineLimit(1)
                        Text(subtitle(entry)).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(1)
                    }
                }
            }
        }
    }

    private func subtitle(_ entry: LibraryEntry) -> String {
        var text = "\(LibraryLook.name(entry.kind))  \(LibraryLook.when(entry.date))"
        if case .recording(let recording) = entry { text += "  \(RecordingText.duration(recording.duration))" }
        return text
    }
}

/// 차트 시간 범위: 기간 단추 값(일)이 없으면 가장 오래된 항목부터 지금까지
private func chartRange(_ dates: [Double], _ period: Int?) -> (Double, Double) {
    let end = Date().timeIntervalSince1970
    let start = period.map { end - Double($0) * 86_400 } ?? min(dates.min() ?? end, end - 86_400)
    return (start, end)
}

/// 분야별로 쌓인 누적 면적. 아래부터 분야 순서대로 쌓고, 점 사이는 가로로 눕는 곡선이라 계단이 부드럽다
private struct AreaChart: View {
    let rows: [(Double, String)]
    let fields: [TasksView.FieldStat]
    let period: Int?
    private let steps = 60

    var body: some View {
        GeometryReader { geo in
            let (start, end) = chartRange(rows.map(\.0), period)
            let names = fields.map(\.name)
            // cumulative[k][i]: 분야 0...k 를 합친, i번째 시각까지의 누적 개수
            let cumulative: [[Double]] = names.indices.map { k in
                (0...steps).map { i in
                    let t = start + (end - start) * Double(i) / Double(steps)
                    return Double(rows.filter { $0.0 <= t && (names.firstIndex(of: $0.1) ?? names.count) <= k }.count)
                }
            }
            let peak = max(cumulative.last?.last ?? 0, 1)
            let top: CGFloat = 46, h = geo.size.height - top
            ZStack(alignment: .topLeading) {
                ForEach(names.indices.reversed(), id: \.self) { k in
                    let color = fields[k].color
                    area(cumulative[k], peak: peak, top: top, h: h, width: geo.size.width)
                        .fill(LinearGradient(colors: [color.opacity(0.78), color], startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    private func area(_ values: [Double], peak: Double, top: CGFloat, h: CGFloat, width: CGFloat) -> Path {
        let dx = width / CGFloat(values.count - 1)
        let pts = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * dx, y: top + h * (1 - CGFloat($0.element / peak))) }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: top + h))
        path.addLine(to: pts[0])
        for i in 1..<pts.count {
            let mid = (pts[i - 1].x + pts[i].x) / 2
            path.addCurve(to: pts[i], control1: CGPoint(x: mid, y: pts[i - 1].y), control2: CGPoint(x: mid, y: pts[i].y))
        }
        path.addLine(to: CGPoint(x: width, y: top + h))
        path.closeSubpath()
        return path
    }
}

/// 차트 아래 날짜 축: 45일 이하는 날짜 5개, 그보다 길면 두 달마다 월 이름과 오른쪽 끝에 오늘
private struct AreaAxis: View {
    let dates: [Double]
    let period: Int?

    var body: some View {
        GeometryReader { geo in
            let (start, end) = chartRange(dates, period)
            let cal = Calendar.current
            let startDate = Date(timeIntervalSince1970: start), endDate = Date(timeIntervalSince1970: end)
            let labels: [(Double, String, UnitPoint)] = {
                let f = DateFormatter(); f.dateFormat = "M/d"
                if end - start <= 45 * 86_400 {
                    return (0...4).map { i in
                        let t = start + (end - start) * Double(i) / 4
                        return (Double(i) / 4, f.string(from: Date(timeIntervalSince1970: t)), i == 0 ? .leading : i == 4 ? .trailing : .center)
                    }
                }
                var list: [(Double, String, UnitPoint)] = [(0, tr("\(cal.component(.month, from: startDate))월"), .leading)]
                var d = cal.date(from: cal.dateComponents([.year, .month], from: startDate))!
                while true {
                    d = cal.date(byAdding: .month, value: 2, to: d)!
                    let frac = (d.timeIntervalSince1970 - start) / (end - start)
                    if frac >= 0.9 { break }
                    list.append((frac, tr("\(cal.component(.month, from: d))월"), .center))
                }
                list.append((1, tr("\(cal.component(.month, from: endDate))월 \(cal.component(.day, from: endDate))일"), .trailing))
                return list
            }()
            ZStack(alignment: .topLeading) {
                ForEach(labels.indices, id: \.self) { i in
                    let l = labels[i]
                    // 폭 0 자리를 날짜 위치에 두고 글씨를 왼쪽 맞춤, 가운데, 오른쪽 맞춤으로 걸친다
                    Color.clear.frame(width: 0, height: 14)
                        .overlay(alignment: l.2 == .leading ? .leading : l.2 == .trailing ? .trailing : .center) {
                            Text(l.1).font(Brand.font(.tag)).foregroundStyle(Brand.gray).fixedSize()
                        }
                        .offset(x: geo.size.width * l.0)
                }
            }
        }.frame(height: 14)
    }
}
