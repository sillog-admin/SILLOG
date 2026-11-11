import AppKit
import SwiftUI
import SillogCollectors
import SillogCore

private let logFill = ChatPalette.soft   // 선택 분절, 원문 상자 바탕 (채팅 탭과 같은 옅은 회색)

/// 원시 데이터(관측 행)와 LLM 이 받고 돌려준 것을 그대로 들여다보는 화면.
/// 수집 기록과 정리 기록을 시간 순서 하나로 합친 표: 위에 아직 보내지 않은(대기) 기록, 그 아래에 정리마다 묶음 줄과 그 정리에 들어간 기록.
/// 기록 줄을 누르면 원문 시트, 정리 머리 줄을 누르면 보낸 내용과 받은 응답 시트가 열린다.
struct ActivityLogView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedObservation: Int64?
    @State private var selectedBatch: Int64?
    @State private var loaded = false
    @State private var expanded: Set<Int64> = []            // 펼친 묶음 (정리 id, 대기는 pendingKey)
    @State private var pending: [Observation] = []          // 아직 정리에 보내지 않은 기록
    @State private var grouped: [Int64: [Observation]] = [:]   // 정리 id 별 기록
    @State private var observationRows: [ObservationRow] = []
    @State private var batchRows: [BatchRow] = []
    @State private var showTitle = false                    // 창 제목이 한 줄이라도 있으면 열을 보인다
    @State private var showLink = false                     // 주소나 문서 경로가 한 줄이라도 있으면 열을 보인다

    /// 예전 두 구역 화면의 호출부(스냅샷, 테스트)가 쓰던 값. 지금은 구역이 하나라 화면에는 영향이 없다
    enum Section { case collected, batches }
    private let receivedFirst: Bool

    private static let pendingKey: Int64 = -1
    private static let previewCount = 5

    init(section: Section = .collected, showReceived: Bool = false) {
        receivedFirst = showReceived
    }

    private struct ObservationRow: Identifiable {
        let id: Int64
        let observation: Observation
    }

    private struct BatchRow: Identifiable {
        let id: Int64
        let batch: BatchRecord
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func hm(_ ts: Double) -> String { clock.string(from: Date(timeIntervalSince1970: ts)) }

    private func rebuildRows() {
        observationRows = state.recent.compactMap { observation in observation.id.map { ObservationRow(id: $0, observation: observation) } }
        batchRows = state.batches.compactMap { batch in batch.id.map { BatchRow(id: $0, batch: batch) } }
        pending = state.recent.filter { $0.batchId == nil }
        grouped = Dictionary(grouping: state.recent.filter { $0.batchId != nil }) { $0.batchId ?? 0 }
        showTitle = state.recent.contains { !($0.windowTitle ?? "").isEmpty }
        showLink = state.recent.contains { !($0.url ?? $0.docPath ?? "").isEmpty }
        loaded = true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                stateView(icon: nil, title: nil, message: "기록을 불러오는 중이에요")
            } else if pending.isEmpty, batchRows.isEmpty {
                stateView(icon: "list.bullet", title: "아직 수집한 기록이 없어요",
                          message: "앱을 오가며 작업하면 수집한 기록과 AI가 정리한 결과가 시간 순서로 여기에 쌓여요.")
            } else {
                if !state.status.accessibility { accessibilityNotice }
                timeline
            }
            Text("비공개 창의 URL과 비밀번호 입력칸은 기록하지 않아요.")
                .font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.vertical, 10)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .onAppear(perform: rebuildRows)
        .onChange(of: state.recent) { _, _ in rebuildRows() }
        .onChange(of: state.batches) { _, _ in rebuildRows() }
        .sheet(isPresented: Binding(get: { selectedObservation != nil }, set: { if !$0 { selectedObservation = nil } })) {
            if let row = observationRows.first(where: { $0.id == selectedObservation }) {
                ObservationDetail(observation: row.observation, onClose: { selectedObservation = nil })
            }
        }
        .sheet(isPresented: Binding(get: { selectedBatch != nil }, set: { if !$0 { selectedBatch = nil } })) {
            if let row = batchRows.first(where: { $0.id == selectedBatch }) {
                batchSheet(row.batch)
            }
        }
    }

    // MARK: 표

    /// 열 너비: 시각, 앱, 계기는 고정, 창 제목과 주소는 남는 폭을 나눠 쓴다
    private static let timeWidth: CGFloat = 64
    private static let appWidth: CGFloat = 150
    private static let triggerWidth: CGFloat = 72

    /// 엑셀처럼 칸이 나뉜 표: 맨 위 열 머리는 고정, 정리마다 하늘색 묶음 줄 아래에 그 정리에 들어간 기록.
    /// List(AppKit 표)로 그린다: ScrollView 에서는 스크롤할 때마다 짧게 멈칫했다 (10/29 프레임 측정: 1초에 10번 안팎 20ms)
    private var timeline: some View {
        VStack(spacing: 0) {
            columnHeader                                         // 열 머리는 List 밖 위에 고정 (List 의 고정 머리는 기본 바탕이 깔린다)
            List {
                pendingBlock.logRow()
                ForEach(batchRows) { row in batchBlock(row.batch).logRow() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .overlay(Rectangle().strokeBorder(Brand.line))
        .padding(.top, 16)
    }

    /// 손쉬운 사용이 꺼져 있으면 창 제목·주소가 남지 않는다는 안내 (누르면 설정의 일반). 화면 기록이 있으면 글자는 OCR 로만 읽는다
    private var accessibilityNotice: some View {
        Button { state.openGeneralSettings() } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Self.failColor)
                Text(state.status.screenRecording
                     ? "\(Permissions.accessibilityName) 권한이 꺼져 있어 창 제목과 주소 없이 기록되고 있어요. 화면 글자는 스크린샷에서 OCR로 읽고, 브라우저는 찍지 않아요."
                     : "\(Permissions.accessibilityName) 권한이 꺼져 있어 창 제목과 주소 없이 앱 이름만 기록되고 있어요.").foregroundStyle(Brand.text)
                Text("권한 켜기").foregroundStyle(Brand.ink).underline()
            }
            .font(Brand.suit(11)).padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 앱 열 폭: 창 제목, 주소 열이 없으면 남는 폭을 다 쓴다
    private var appWidth: CGFloat? { showTitle || showLink ? Self.appWidth : nil }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            cell(width: Self.timeWidth) { headText("시각") }
            cell(width: appWidth) { headText("앱") }
            if showTitle { cell(width: nil) { headText("창 제목") } }
            if showLink { cell(width: nil) { headText("주소, 문서") } }
            cell(width: Self.triggerWidth, last: true) { headText("계기") }
        }
        .frame(height: 30)
        .background(logFill)
        .overlay(alignment: .bottom) { hairline }
    }

    private func headText(_ title: String) -> some View {
        Text(title).font(Brand.suit(11, .semibold)).foregroundStyle(Brand.gray)
    }

    /// 표 칸 하나: 고정 폭(width) 또는 남는 폭, 오른쪽에 세로 선
    private func cell<V: View>(width: CGFloat?, last: Bool = false, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: width, maxWidth: width ?? .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { if !last { Rectangle().fill(Brand.line).frame(width: 1) } }
    }

    /// 묶음 줄: 표 폭 전체를 쓰는 하늘색 줄 (대기, 정리 #n)
    private func groupRow<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(cornerRadius: 0)
            .background(Brand.sky.opacity(0.16))
            .overlay(alignment: .bottom) { hairline }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text).font(Brand.suit(11, .semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.1)))
    }

    /// 대기: 아직 정리에 보내지 않은 기록
    private var pendingBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupRow {
                HStack(spacing: 10) {
                    pill("대기", color: Brand.gray)
                    Text("아직 보내지 않은 기록 \(pending.count)개").font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                }
            }
            if !pending.isEmpty { observationList(pending, key: Self.pendingKey) }
        }
    }

    /// 정리 하나: 묶음 줄(누르면 상세 시트)과 그 정리에 들어간 기록
    private func batchBlock(_ batch: BatchRecord) -> some View {
        let items = grouped[batch.id ?? 0] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            batchHeader(batch)
            if !items.isEmpty { observationList(items, key: batch.id ?? 0) }
        }
    }

    private func batchHeader(_ batch: BatchRecord) -> some View {
        let ok = batch.status == "ok"
        return Button { selectedBatch = batch.id } label: {
            groupRow {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        pill(ok ? "성공" : "실패", color: ok ? Self.okColor : Self.failColor)
                        Text(verbatim: "정리 #\(batch.id ?? 0)").font(Brand.suit(12, .semibold)).foregroundStyle(Brand.ink)
                        Text(Self.hm(batch.startedAt)).font(Brand.jost(12)).foregroundStyle(Brand.gray)
                        Text("기록 \(batch.rowCount)개, \(batch.model ?? "-"), 토큰 \(batch.promptTokens.formatted()) + \(batch.completionTokens.formatted())")
                            .font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1)
                        Spacer(minLength: 12)
                        Text("자세히").font(Brand.suit(11)).foregroundStyle(Brand.tabText)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Brand.gray)
                    }
                    if let error = batch.error, !ok {
                        Text(AppState.friendlyModelError(error)).font(Brand.suit(11)).foregroundStyle(Self.failColor).lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 기록 줄 목록: 처음 몇 개만 보이고 나머지는 "더 보기" 줄로 펼친다
    private func observationList(_ items: [Observation], key: Int64) -> some View {
        let open = expanded.contains(key)
        let shown = open ? items : Array(items.prefix(Self.previewCount))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown, id: \.id) { observationRow($0) }
            if items.count > Self.previewCount {
                Button {
                    if open { expanded.remove(key) } else { expanded.insert(key) }
                } label: {
                    Text(open ? "접기" : "기록 \(items.count - Self.previewCount)개 더 보기")
                        .font(Brand.suit(11)).foregroundStyle(Brand.gray)
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .overlay(alignment: .bottom) { hairline }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 0)
            }
        }
    }

    private func observationRow(_ o: Observation) -> some View {
        Button { selectedObservation = o.id } label: {
            HStack(spacing: 0) {
                cell(width: Self.timeWidth) { Text(Self.hm(o.ts)).font(Brand.jost(12)).foregroundStyle(Brand.gray) }
                cell(width: appWidth) { Text(o.appName).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink) }
                if showTitle { cell(width: nil) { Text(o.windowTitle ?? "").font(Brand.suit(12)).foregroundStyle(Brand.tabText).truncationMode(.tail) } }
                if showLink { cell(width: nil) { Text(o.url ?? o.docPath ?? "").font(Brand.suit(11)).foregroundStyle(Brand.gray).truncationMode(.middle) } }
                cell(width: Self.triggerWidth, last: true) { Text(Self.triggerName(o.trigger)).font(Brand.suit(11)).foregroundStyle(Brand.gray) }
            }
            .frame(height: 30)
            .overlay(alignment: .bottom) { hairline }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 0)
    }

    private var hairline: some View { Rectangle().fill(Brand.line).frame(height: 1) }

    /// 정리 상세 시트: 보낸 내용과 받은 응답
    private func batchSheet(_ batch: BatchRecord) -> some View {
        VStack(spacing: 0) {
            BatchDetail(batch: batch, maxHeight: 490, showReceived: receivedFirst).padding(20)
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack {
                Spacer()
                Button("닫기") { selectedBatch = nil }.buttonStyle(BrandButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 32).frame(height: 62).background(logFill)
        }
        .frame(width: 760, height: 600)
        .background(Color.white)
    }

    static let okColor = Brand.blue   // 대기=회색, 성공=하늘, 실패=빨강
    static let failColor = Color(hex: 0xC0473B)

    // MARK: 빈 상태, 불러오는 중

    private func stateView(icon: String?, title: String?, message: String) -> some View {
        VStack(spacing: 0) {
            if let icon {
                Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(Brand.sub)
            } else {
                ProgressView().controlSize(.regular)
            }
            if let title {
                Text(title).font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink).padding(.top, 16)
            }
            Text(message).font(Brand.suit(14)).foregroundStyle(Brand.gray).padding(.top, title == nil ? 14 : 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    static func triggerName(_ trigger: String) -> String {
        switch trigger {
        case "app_activate": return "앱 전환"
        case "window_change": return "창 변경"
        case "periodic": return "유지"
        case "demo": return "데모"
        default: return trigger
        }
    }
}

// MARK: 수집 기록 원문 시트

/// 관측 행 하나: 모든 필드, 화면 텍스트 전문, 스크린샷.
struct ObservationDetail: View {
    @EnvironmentObject private var state: AppState
    let observation: Observation
    var onClose: () -> Void = {}
    @State private var text: String?
    @State private var image: NSImage?
    @State private var imageLoading = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("수집 기록 원문").font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink)
                    Text("관측 행 #\(observation.id ?? 0)").font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 10)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .regular)).foregroundStyle(Brand.tabText)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 22)
            Rectangle().fill(Brand.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    field("시각", Self.time.string(from: Date(timeIntervalSince1970: observation.ts)))
                    field("계기", ActivityLogView.triggerName(observation.trigger), medium: true)
                    field("앱", "\(observation.appName)  (\(observation.appBundle))")
                    if let title = observation.windowTitle { field("창 제목", title) }
                    if let url = observation.url { field("URL", url) }
                    if let path = observation.docPath { field("문서", path) }
                    field("정리", observation.batchId.map { "배치 #\($0)" } ?? "아직 정리 안 됨")

                    Group {
                        if let text {
                            TextBlock(title: "화면 텍스트 (\(text.count.formatted())자)", text: text, height: 200)
                        } else {
                            Text("화면 텍스트 없음").font(Brand.suit(12)).foregroundStyle(Brand.gray)
                        }
                    }
                    .padding(.top, 16)

                    if let path = observation.screenshotPath {
                        HStack(spacing: 14) {
                            Text("스크린샷").font(Brand.suit(12)).foregroundStyle(Brand.gray)
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .buttonStyle(.plain).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                        }
                        .padding(.top, 16)
                        Group {
                            if let image {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else if imageLoading {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity).frame(height: 110)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(logFill))
                            } else {
                                Text("파일이 없어요 (보관 기간이 지나 지워졌을 수 있어요)").font(Brand.suit(12)).foregroundStyle(Brand.gray)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 8).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Rectangle().fill(Brand.line).frame(height: 1)
            HStack {
                let pinned = state.isDayPinned(observation.ts)
                Button { state.toggleDayPin(observation.ts) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 11))
                        Text(pinned ? "이 날 원문 보존 중" : "이 날 원문 보존")
                    }
                }
                .buttonStyle(BrandButtonStyle())
                .help("이 날의 화면 텍스트와 활동 기록을 보관 기간이 지나도 지우지 않아요")
                Spacer()
                Button("닫기", action: onClose).buttonStyle(BrandButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 32).frame(height: 62).background(logFill)
        }
        .frame(width: 720, height: 600)
        .background(Color.white)
        .onChange(of: observation.id, initial: true) { _, _ in
            let started = Date()
            text = observation.textId.flatMap { state.observationText($0) }        // DB 읽기 1ms 미만: 바로, 깜빡임 없이
            Self.logIfSlow("관측 행 #\(observation.id ?? 0) 텍스트 읽기", since: started)
            image = nil
            guard let path = observation.screenshotPath else { imageLoading = false; return }
            imageLoading = true
            let id = observation.id
            Task.detached(priority: .userInitiated) {                              // JPEG 디코드는 메인 스레드 밖에서, 표시 크기로 축소
                let decodeStarted = Date()
                let thumbnail = Self.thumbnail(path: path, maxPixels: 1000)
                Self.logIfSlow("관측 행 #\(id ?? 0) 스크린샷 썸네일", since: decodeStarted)
                await MainActor.run {
                    guard id == observation.id else { return }
                    image = thumbnail
                    imageLoading = false
                }
            }
        }
    }

    /// 100ms 넘게 걸린 로딩만 app.log 에 남긴다 (느리다는 보고가 오면 원인을 바로 볼 수 있게).
    nonisolated static func logIfSlow(_ what: String, since started: Date) {
        let ms = Date().timeIntervalSince(started) * 1000
        if ms > 100 { AppLog.write("느림: \(what) \(Int(ms))ms") }
    }

    /// 원본을 통째로 디코드하지 않고 표시 크기의 썸네일만 만든다.
    nonisolated static func thumbnail(path: String, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCache: false]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func field(_ name: String, _ value: String, medium: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(name).font(Brand.suit(12)).foregroundStyle(Brand.gray).frame(width: 120, alignment: .leading)
            Text(value).font(Brand.suit(12, medium ? .medium : .regular)).foregroundStyle(Brand.ink)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

// MARK: 정리 기록 상세 (LLM 교환 판)

/// 배치 하나: LLM 이 받은 것, 돌려준 것, 반영한 것, 원본 응답. 큰 열은 선택했을 때만 읽는다.
/// 높이는 maxHeight 안에서 내용에 맞추고, 넘치면(펼친 시스템 프롬프트 등) 머리는 두고 아래만 카드 안에서 스크롤한다.
struct BatchDetail: View {
    @EnvironmentObject private var state: AppState
    let batch: BatchRecord
    var maxHeight: CGFloat = .infinity
    @State private var full: BatchRecord?
    @State private var showReceived: Bool
    @State private var showSystem = false
    @State private var showRaw = false
    @State private var headerHeight: CGFloat = 120
    @State private var patchText: String?
    @State private var appliedText: String?

    init(batch: BatchRecord, maxHeight: CGFloat = .infinity, showReceived: Bool = false) {
        self.batch = batch
        self.maxHeight = maxHeight
        _showReceived = State(initialValue: showReceived)
    }

    /// 글 상자 높이: 접힌 상태에서 카드가 스크롤 없이 들어가게 (상자 제목·여백·펼침 줄 몫 92)
    private var boxHeight: CGFloat { min(300, max(120, maxHeight - headerHeight - 1 - 92)) }

    private struct HeaderHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text("정리 #\(batch.id ?? 0)").font(Brand.suit(16, .bold)).foregroundStyle(Brand.ink)
                        let ok = batch.status == "ok"
                        Text(ok ? "성공" : "실패").font(Brand.suit(11, .semibold))
                            .foregroundStyle(ok ? ActivityLogView.okColor : ActivityLogView.failColor)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Capsule().fill((ok ? ActivityLogView.okColor : ActivityLogView.failColor).opacity(0.1)))
                    }
                    Text("\(Self.time.string(from: Date(timeIntervalSince1970: batch.startedAt))), \(batch.model ?? "-"), 행 \(batch.rowCount)개, 토큰 \(batch.promptTokens.formatted()) + \(batch.completionTokens.formatted())")
                        .font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.top, 10)
                    if let error = batch.error { summaryLine("오류", AppState.friendlyModelError(error)) }
                    if let stats = batch.stats { summaryLine("반영 결과", ApplyStats.summary(json: stats) ?? stats) }
                }
                Spacer(minLength: 16)
                viewToggle
            }
            .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
            .background(GeometryReader { g in Color.clear.preference(key: HeaderHeight.self, value: g.size.height) })
            Rectangle().fill(Brand.line).frame(height: 1)

            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
        .frame(maxHeight: maxHeight)
        .onPreferenceChange(HeaderHeight.self) { if $0 > 0 { headerHeight = $0 } }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: batch.id, initial: true) { _, _ in
            let started = Date()
            full = batch.id.flatMap { state.batchDetail($0) }
            patchText = full?.llmPatch.map(Self.pretty)
            appliedText = full?.appliedPatch.flatMap { $0 == full?.llmPatch ? nil : Self.pretty($0) }
            ObservationDetail.logIfSlow("정리 #\(batch.id ?? 0) 상세 읽기", since: started)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let full {
                if showReceived { received(full) } else { sent(full) }
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(name).font(Brand.suit(12)).foregroundStyle(Brand.gray)
            Text(value).font(Brand.suit(12)).foregroundStyle(Brand.ink).textSelection(.enabled)
        }
        .padding(.top, 6)
    }

    /// 보낸 내용, 받은 응답 전환 (Figma 보기 전환)
    private var viewToggle: some View {
        HStack(spacing: 0) {
            toggleItem("보낸 내용", on: !showReceived) { showReceived = false }
            toggleItem("받은 응답", on: showReceived) { showReceived = true }
        }
        .padding(2)
    }

    private func toggleItem(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Brand.suit(12, on ? .medium : .regular)).foregroundStyle(on ? Brand.ink : Brand.gray)
                .frame(width: 88, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? logFill : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func sent(_ full: BatchRecord) -> some View {
        if let user = full.userPrompt {
            TextBlock(title: "LLM이 받은 것 (이 배치의 활동 행)", text: user, height: boxHeight)
            disclosure("시스템 프롬프트 (고정 지시문)", isOn: $showSystem) {
                ReadOnlyTextView(text: full.systemPrompt ?? OntologyPrompt.system).frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 6).fill(logFill))
            }
        } else {
            Text("이 배치는 프롬프트를 저장하기 전에 실행됐어요").font(Brand.suit(12)).foregroundStyle(Brand.gray)
        }
    }

    @ViewBuilder private func received(_ full: BatchRecord) -> some View {
        if full.llmPatch == nil, full.rawResponse == nil {
            Text("받은 응답이 없어요").font(Brand.suit(12)).foregroundStyle(Brand.gray)
        }
        // 돌려준 것과 반영한 것을 나란히 (Figma LG-W4). 반영한 것이 돌려준 것과 같으면 하나만
        if patchText != nil || appliedText != nil {
            HStack(alignment: .top, spacing: 16) {
                if let patchText { TextBlock(title: "LLM이 돌려준 것 (구조화 결과)", text: patchText, height: boxHeight, monospaced: true) }
                if let appliedText { TextBlock(title: "짧은 구간을 다듬은 뒤 반영한 것", text: appliedText, height: boxHeight, monospaced: true) }
            }
        }
        if let raw = full.rawResponse {
            disclosure("원본 응답 (\(raw.count.formatted())자)", isOn: $showRaw) {
                ReadOnlyTextView(text: raw, monospaced: true).frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 6).fill(logFill))
            }
        }
    }

    /// 한 줄 JSON 은 줄을 나눠 보여 준다 (좁은 상자에서도 읽히게, 상자 높이도 줄 수로 정해진다). JSON 이 아니면 그대로
    static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: out, encoding: .utf8) else { return text }
        return string
    }

    /// 펼침 줄: 화살표와 Medium 12 제목, 펼치면 아래에 상자
    private func disclosure<Content: View>(_ title: String, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { isOn.wrappedValue.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOn.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium))
                    Text(title).font(Brand.suit(12, .medium))
                }
                .foregroundStyle(Brand.ink).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOn.wrappedValue { content() }
        }
    }
}

private extension View {
    /// 활동 로그 표의 List 줄: 칸과 선을 직접 그리므로 양옆 여백(List 가 띄우는 10)·구분선·바탕을 없앤다
    func logRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: -10, bottom: 0, trailing: -10))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
