import SwiftUI
import SillogCore

/// Settings > storage: usage at a glance, the retention preset, clean up now. The breakdown and per-item days open in a sheet.
struct StorageSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("저장 공간"))
            summary
            SettingTiles {
                SettingTile(tr("보관 기간"), detail: tr("지나면 요약만 남겨요")) {
                    BrandMenu(selection: presetBinding, options: presetOptions, width: 230)
                }
                SettingTile(tr("오래된 기록 지우기"), detail: tr("지울 목록을 먼저 보여 줘요")) {
                    if state.consolidating { ProgressView().controlSize(.small) }
                    Button(state.consolidating ? tr("정리하는 중…") : tr("지금 지우기")) { Task { await state.prepareCleanup() } }
                        .buttonStyle(BrandButtonStyle(kind: .primary)).disabled(state.consolidating)
                }
            }
            .padding(.top, 8)
        }
        .onAppear { state.refreshStorage(); state.loadRetentionState() }
        .sheet(isPresented: $showingDetail) { SettingSheet(tr("저장 공간")) { StorageDetailView() }.environmentObject(state) }
        .sheet(item: $state.cleanupPreview) { preview in CleanupPreviewSheet(preview: preview).environmentObject(state) }
    }

    static let barColor = Brand.blue   // 켜짐 표시와 같은 파랑

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    /// Total, the two largest categories and the rest, as one line and one bar.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let usage = state.storageUsage {
                    Text(Self.size(usage.total)).font(Brand.jost(20)).foregroundStyle(Brand.ink)
                    Text(shares(usage).map { "\($0.title) \($0.percent)%" }.joined(separator: " · ")).font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1)
                } else {
                    Text(tr("사용량을 계산하고 있어요")).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                }
                Spacer(minLength: 8)
                Button(tr("자세히")) { showingDetail = true }.buttonStyle(BrandButtonStyle(kind: .primary))
                Button(tr("폴더 열기")) { state.revealDataFolder() }.buttonStyle(BrandButtonStyle(kind: .primary)).help(state.databasePath)
            }
            if let usage = state.storageUsage {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(Array(shares(usage).dropLast().enumerated()), id: \.offset) { index, share in
                            Rectangle().fill(Self.barColor.opacity(index == 0 ? 1 : 0.45)).frame(width: proxy.size.width * CGFloat(share.percent) / 100)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 8).background(Brand.line.opacity(0.7)).clipShape(Capsule())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.line))
    }

    /// The two largest categories, then everything else as the last entry.
    private func shares(_ usage: StorageUsage) -> [(title: String, percent: Int)] {
        let total = Double(max(usage.total, 1))
        let top = StorageUsage.Category.allCases.sorted { (usage.bytes[$0] ?? 0) > (usage.bytes[$1] ?? 0) }.prefix(2)
            .map { (title: $0.title, percent: Int((Double(usage.bytes[$0] ?? 0) / total * 100).rounded())) }
        return top + [(title: tr("그 밖"), percent: max(0, 100 - top.reduce(0) { $0 + $1.percent }))]
    }

    private var presetBinding: Binding<String> {
        Binding(get: { state.retention.preset?.rawValue ?? "custom" },
                set: { value in
                    guard let preset = RetentionPolicy.Preset(rawValue: value) else { return }
                    var policy = state.retention
                    policy.apply(preset)
                    state.updateRetention(policy)
                })
    }

    private var presetOptions: [(String, String)] {
        func days(_ value: Int?) -> String { value.map { tr("\($0)일") } ?? tr("무기한") }
        var options = RetentionPolicy.Preset.allCases.map { ($0.rawValue, tr("\($0.title), 화면 텍스트 \(days($0.screenTextDays))")) }
        if state.retention.preset == nil { options.append(("custom", tr("사용자 지정, 화면 텍스트 \(days(state.retention.screenTextDays))"))) }
        return options
    }
}

/// The storage sheet: usage by category, retention days per item, kept records.
struct StorageDetailView: View {
    @EnvironmentObject private var state: AppState
    @State private var advanced: Bool

    /// advanced: 항목별 보관일을 펼친 채로 시작 (스냅샷용)
    init(advanced: Bool = false) { _advanced = State(initialValue: advanced) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usage
            retention
            kept
        }
    }

    // MARK: 사용량

    private var usage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("사용량"))
            if let usage = state.storageUsage {
                VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(StorageSettingsView.size(usage.total)).font(.custom("Jost-ExtraLight", size: 38)).foregroundStyle(Brand.ink)
                    Text(tr("사용 중")).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                    Spacer()
                    Text(tr("기록 DB 최근 30일 하루 평균 +\(StorageSettingsView.size(usage.totalDailyGrowth))")).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                }
                .padding(.top, 12).padding(.bottom, 8)
                let total = max(usage.total, 1)
                ForEach(StorageUsage.Category.allCases.filter { (usage.bytes[$0] ?? 0) > 0 }.sorted { (usage.bytes[$0] ?? 0) > (usage.bytes[$1] ?? 0) }, id: \.self) { category in
                    let bytes = usage.bytes[category] ?? 0
                    let share = Double(bytes) / Double(total)
                    let percent = share >= 0.01 ? "\(Int((share * 100).rounded()))%" : tr("1% 미만")
                    HStack(spacing: 14) {
                        Text(category.title).font(Brand.suit(12)).foregroundStyle(Brand.text).frame(width: 190, alignment: .leading)
                        GeometryReader { proxy in                // 회색 바탕 = 전체, 파란 막대 = 이 항목의 몫
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.line.opacity(0.7))
                                Capsule().fill(StorageSettingsView.barColor).frame(width: max(4, proxy.size.width * share))
                            }
                            .frame(height: 8).frame(maxHeight: .infinity)
                        }
                        .frame(height: 16)
                        Text(percent).font(Brand.suit(11)).foregroundStyle(Brand.gray).frame(width: 52, alignment: .trailing)
                        Text(StorageSettingsView.size(bytes)).font(Brand.jost(12)).foregroundStyle(Brand.text).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .help(tr("\(category.title) \(StorageSettingsView.size(bytes)), 전체의 \(percent)"))
                }
                }
                .padding(.bottom, 6)
                InfoLine(usage.measuredWithDBStat ? tr("DB 안의 크기는 SQLite가 잰 실제 페이지예요.") : tr("DB 안의 크기는 내용 길이로 어림한 값이에요."))
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("사용량을 계산하고 있어요")).font(Brand.suit(12)).foregroundStyle(Brand.gray)
                }
                .padding(.vertical, 18)
            }
        }
    }

    // MARK: 보관

    private var retention: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("보관"))
            SettingCard {
            SettingRow(tr("스크린샷 보관 기간"), detail: tr("지난 스크린샷 파일만 지워요. 화면 카드와 기록은 아래 기간을 따라요.")) {
                daysField(Binding(get: { state.settings.retentionDays }, set: { state.settings.retentionDays = min(max($0, 1), 90) }), range: 1...90)
            }
            SettingRow(tr("요약 확인 뒤 기다리는 날"), detail: tr("주간 요약을 확인한 뒤 원문을 지우기까지 기다려요.")) {
                daysField(Binding(get: { state.retention.graceDays }, set: { days in update { $0.graceDays = days } }), range: RetentionPolicy.graceRange)
            }
            SettingRow(tr("요약 문장을 AI로 쓰기"), detail: tr("업무 요약과 자료 제목을 정리용 AI에 다시 보내요. 끄면 수치와 세션 요약만 남겨요.")) {
                Toggle("", isOn: Binding(get: { state.retention.narrateDigests }, set: { on in update { $0.narrateDigests = on } }))
                    .toggleStyle(BrandSwitchStyle())
            }
            }
            Button { withAnimation(.easeOut(duration: 0.15)) { advanced.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: advanced ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium))
                    Text(tr("항목별 보관일")).font(Brand.suit(12, .medium))
                }
                .foregroundStyle(Brand.tabText).padding(.horizontal, 4).padding(.vertical, 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if advanced {
                SettingCard { ForEach(RetentionPolicy.Item.allCases, id: \.self) { item in itemRow(item) } }
                InfoLine(tr("활동 기록은 화면 텍스트보다 먼저 지우지 않아요. 한쪽을 바꾸면 다른 쪽이 맞춰져요."))
            }
        }
    }

    private func itemRow(_ item: RetentionPolicy.Item) -> some View {
        SettingRow(item.title, detail: item.detail) {
            HStack(spacing: 12) {
                if let days = state.retention.days(item) {
                    daysField(Binding(get: { days }, set: { value in update { $0.setDays(item, value) } }), range: item.range)
                } else {
                    Text(tr("지우지 않음")).font(Brand.suit(11)).foregroundStyle(Brand.text).frame(width: 88 + 10 + 62, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Text(tr("무기한")).font(Brand.suit(11)).foregroundStyle(Brand.tabText)
                    Toggle("", isOn: Binding(get: { state.retention.days(item) == nil }, set: { forever in
                        update { $0.setDays(item, forever ? nil : RetentionPolicy.standard.days(item) ?? item.range.lowerBound) }
                    }))
                    .toggleStyle(BrandSwitchStyle())
                }
            }
        }
    }

    private func update(_ change: (inout RetentionPolicy) -> Void) {
        var policy = state.retention
        change(&policy)
        state.updateRetention(policy)
    }

    private func daysField(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                TextField("", value: value, format: .number.grouping(.never))
                    .textFieldStyle(.plain).font(Brand.suit(11)).foregroundStyle(Brand.text)
                    .frame(width: 40)
                Text(tr("일")).font(Brand.suit(11)).foregroundStyle(Brand.text).padding(.leading, 6)
            }
            .settingField()
            .frame(width: 88)
            Text(verbatim: tr("\(range.lowerBound)~\(range.upperBound)일")).font(Brand.suit(10)).foregroundStyle(Brand.gray)
                .lineLimit(1).fixedSize().frame(width: 62, alignment: .leading)
        }
    }

    // MARK: 지운 기록과 보존한 기록

    private var kept: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("오래된 기록 지우기"))
            InfoLine(lastRun)
            InfoLine(state.rawRecordsSince.map { tr("원문 기록은 \($0)부터 남아 있어요. 그 전은 요약과 사용 시간만 있어요.") }
                     ?? tr("아직 지운 원문이 없어요."))
            if !state.pruneConsented {
                NoteBox(tr("처음 정리할 때 지울 것을 보여 드리고 동의를 받아요. 동의 전에는 요약만 만들어요."))
            }
            if let notes = state.consolidationReport?.notes, !notes.isEmpty {
                Text(notes.joined(separator: "\n")).font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.top, 12)
            }
            SectionLabel(tr("보존한 기록"))
            if state.retentionPins.isEmpty {
                Text(tr("업무 화면의 '원문 보존'이나 활동 로그의 '이 날 원문 보존'으로 지우지 않을 기록을 고를 수 있어요."))
                    .font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.horizontal, 4).padding(.vertical, 6)
            } else {
                SettingCard {
                    ForEach(state.retentionPins) { pin in
                        SettingRow(pinTitle(pin)) {
                            Button(tr("보존 해제")) { state.removePin(pin) }.buttonStyle(BrandButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var lastRun: String {
        guard let report = state.consolidationReport else { return tr("하루 한 번, 자리를 비웠을 때 요약을 만들고 보관 기간이 지난 원문을 정리해요.") }
        let time = Date(timeIntervalSince1970: report.finishedAt ?? report.startedAt).formatted(date: .abbreviated, time: .shortened)
        return tr("마지막 정리 \(time), \(report.summary)")
    }

    private func pinTitle(_ pin: RetentionPin) -> String {
        switch pin.kind {
        case .task: return tr("업무, ") + (state.taskList.first { $0.key == pin.key }?.title ?? pin.key)
        case .period:
            let parts = pin.key.components(separatedBy: "..")
            return tr("기간, ") + (parts.count == 2 && parts[0] == parts[1] ? parts[0] : pin.key.replacingOccurrences(of: "..", with: " ~ "))
        }
    }
}

/// 지울 날·항목·회수량과 그 기간을 대신할 요약을 보여 준다. 첫 정리면 동의를 받는다
struct CleanupPreviewSheet: View {
    @EnvironmentObject private var state: AppState
    let preview: CleanupPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow(tr("정리"))
                    Text(preview.consentNeeded && !preview.plan.isEmpty ? tr("처음 정리하기 전에 확인해 주세요") : tr("정리 미리보기"))
                        .font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink).padding(.top, 8)
                }
                Spacer()
                Button { state.cleanupPreview = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Brand.gray)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 20)
            Rectangle().fill(Brand.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if preview.plan.isEmpty {
                        Text(tr("지금 지울 원문이 없어요. 요약은 최신으로 만들었어요.")).font(Brand.suit(13)).foregroundStyle(Brand.text)
                        ForEach(preview.plan.keptReasons, id: \.self) { Text($0).font(Brand.suit(12)).foregroundStyle(Brand.gray) }
                        if let reason = preview.plan.blockedReason { Text(reason).font(Brand.suit(12)).foregroundStyle(Brand.gray) }
                    } else {
                        Text(tr("\(preview.plan.firstDay ?? "") ~ \(preview.plan.lastDay ?? "") · \(preview.plan.days.count)일"))
                            .font(Brand.suit(15, .medium)).foregroundStyle(Brand.ink)
                        ForEach(preview.plan.counts.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) { entry in
                            HStack {
                                Text(entry.key.item.title).font(Brand.suit(12)).foregroundStyle(Brand.text)
                                Spacer()
                                Text(tr("\(entry.value.formatted())건")).font(Brand.jost(12)).foregroundStyle(Brand.tabText)
                            }
                        }
                        Text(tr("돌려받을 공간 약 \(StorageSettingsView.size(preview.plan.estimatedBytes))")).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink).padding(.top, 4)
                        ForEach(preview.plan.keptReasons, id: \.self) { Text($0).font(Brand.suit(11)).foregroundStyle(Brand.gray) }
                        if let reason = preview.plan.blockedReason {
                            Text(tr("그 뒤 기간은 아직이에요: \(reason)")).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                        }
                        if !preview.digests.isEmpty {
                            Text(tr("이 기간을 대신할 요약")).font(Brand.suit(12, .medium)).foregroundStyle(Brand.gray).padding(.top, 12)
                            ForEach(preview.digests) { digest in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(digest.title).font(Brand.suit(12, .medium)).foregroundStyle(Brand.ink)
                                    Text(digest.content.summary).font(Brand.suit(11)).foregroundStyle(Brand.tabText).lineLimit(3)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        if preview.consentNeeded {
                            NoteBox(tr("동의하면 앞으로 하루 한 번 보관 기간이 지난 원문을 자동으로 지워요. 지운 원문은 되돌릴 수 없어요."))
                                .padding(.top, 12)
                            Text(tr("업무별 사용 시간, 세션, 주간·월간 요약은 계속 남아요. 남기고 싶은 업무나 날은 보존 핀을 걸어 두세요."))
                                .font(Brand.suit(11)).foregroundStyle(Brand.gray)
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 420)

            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                if preview.plan.isEmpty {
                    Button(tr("닫기")) { state.cleanupPreview = nil }.keyboardShortcut(.cancelAction).buttonStyle(BrandButtonStyle(kind: .secondary))
                } else {
                    Button(tr("취소")) { state.cleanupPreview = nil }.keyboardShortcut(.cancelAction).buttonStyle(BrandButtonStyle(kind: .secondary))
                    Button(preview.consentNeeded ? tr("동의하고 정리") : tr("정리")) { Task { await state.confirmCleanup() } }
                        .keyboardShortcut(.defaultAction).buttonStyle(BrandButtonStyle(kind: .primary))
                }
            }
            .padding(.horizontal, 24).frame(height: 63)
            .background(Brand.paper)
        }
        .frame(width: 560)
        .background(.white)
    }
}
