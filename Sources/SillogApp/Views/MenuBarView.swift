import AppKit
import SwiftUI
import SillogCore

/// 메뉴 막대 드롭다운 (Figma 859:1630 기본, 857:1189 녹음 중, 857:1242 받아쓰는 중, 859:1760 일부만 수집, 859:1791 일시정지, 859:1741 연결 안 됨).
/// 폭 560 의 두 칸: 왼쪽은 연결과 사용량, 오늘 숫자, 알림 줄. 오른쪽은 최근 업무와 녹음 줄. 아래에 [지금 정리] 와 작은 글씨 단추.
/// `.window` 스타일 MenuBarExtra 안에서 그려진다.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var mode: MenuBarMode {
        MenuBarModel.mode(phase: state.phase, startupFailed: state.startupError != nil, paused: state.status.paused,
                          running: state.status.running, accessibility: state.status.accessibility,
                          screenRecording: state.status.screenRecording)
    }

    var body: some View {
        Group {
            if mode == .notReady {
                MenuBarSignedOut(openMain: openMain)
            } else {
                MenuBarDashboard(mode: mode, openMain: openMain)
            }
        }
        .frame(width: 560)
        .background(MenuColor.card)
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 메뉴 전용 색 (Figma 메뉴 화면 값). 큰 면에는 거의 검정을 쓰지 않는다
private enum MenuColor {
    static let card = Color(hex: 0xFCFAF8)
    static let text = Color(hex: 0x2A201B)
    static let sub = Color(hex: 0x4A3E37)
    static let gray = Color(hex: 0x8C837C)
    static let primary = Color(hex: 0x8A7566)
    static let track = Color(hex: 0xECE7E2)
    static let line = Color(hex: 0xEAE5E0)
    static let row = Color(hex: 0xF4EFEB)
    static let chip = Color(hex: 0xEFE9E4)
    static let warnBg = Color(hex: 0xF6E9E4)
    static let warnText = Color(hex: 0xA0523A)
    static let green = Color(hex: 0x3F9B6E)
    static let amber = Color(hex: 0xE0A030)
    static let rec = Color(hex: 0xC0573F)
    static let idle = Color(hex: 0xA9A29B)
}

/// 머리: 왼쪽 앱 아이콘과 SILLOG 글자, 오른쪽 점과 상태 글씨
private struct MenuBarHeader: View {
    let status: String
    let dot: Color

    var body: some View {
        HStack(spacing: 8) {
            // 메뉴 막대 아이콘과 같은 검은 실루엣
            Image(nsImage: MenuBarLabel.icon(paused: false, recording: false)).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24).foregroundStyle(.black).accessibilityHidden(true)
            if let mark = Brand.wordmark {
                Image(nsImage: mark).resizable().scaledToFit().frame(height: 10).accessibilityLabel("SILLOG")
            } else {
                Text("SILLOG").font(Brand.suit(15, .semibold)).foregroundStyle(MenuColor.text)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(status).font(Brand.suit(11)).foregroundStyle(MenuColor.sub)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }
}

/// 얇은 가로선
private struct MenuLine: View {
    var body: some View { Rectangle().fill(MenuColor.line).frame(height: 1) }
}

/// 아래 줄의 작은 글씨 단추 (아이콘 + 글씨)
private struct MenuTextButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(Brand.suit(11.5))
            }
            .foregroundStyle(MenuColor.gray)
            .padding(.horizontal, 10).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 채운 주색 단추 (흰 굵은 글씨, 모서리 10)
private struct MenuFilledButton: View {
    let title: String
    var icon: String? = nil
    var height: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(Brand.suit(13, .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 10).fill(MenuColor.primary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: 연결 안 됨 (859:1741), 시작 전

/// 로그인 전, 권한 단계 전, 시작 실패: 안내 상자 하나와 [AI 연결하기], 아래에는 종료만
private struct MenuBarSignedOut: View {
    @EnvironmentObject private var state: AppState
    let openMain: () -> Void

    private var needsLogin: Bool { state.phase == .login && state.startupError == nil }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader(status: needsLogin ? tr("연결 안 됨") : tr("준비 전"), dot: MenuColor.idle)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: needsLogin ? "link" : "info.circle").font(.system(size: 13)).foregroundStyle(MenuColor.sub)
                    Text(needsLogin ? tr("기록을 정리하려면 AI를 연결해요")
                         : MenuBarModel.notReadyMessage(phase: state.phase, startupFailed: state.startupError != nil))
                        .font(Brand.suit(12.5, .medium)).foregroundStyle(MenuColor.text)
                }
                MenuFilledButton(title: needsLogin ? tr("AI 연결하기") : tr("시작하기"), height: 34, action: openMain)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(MenuColor.row))
            .padding(.horizontal, 18).padding(.bottom, 14)
            // 녹음은 로그인과 상관없이 따로 돈다: 켜져 있을 때만 끝내기 줄을 보인다 (시작 버튼은 없다)
            if state.activeRecording != nil {
                MenuBarRecordingRow(allowStart: false).padding(.horizontal, 18).padding(.bottom, 14)
            }
            MenuLine()
            HStack {
                Spacer()
                MenuTextButton(icon: "rectangle.portrait.and.arrow.right", title: tr("종료")) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 8).frame(height: 44)
        }
    }
}

// MARK: 기본, 녹음 중, 받아쓰는 중, 일부만 수집, 일시정지

private struct MenuBarDashboard: View {
    @EnvironmentObject private var state: AppState
    let mode: MenuBarMode
    let openMain: () -> Void

    /// 오른쪽 위 상태: 녹음 중이 가장 먼저, 그다음 일시정지, 권한 부족, 자리 비움, 기록 중
    private var statusInfo: (text: String, dot: Color) {
        if state.activeRecording != nil { return (tr("녹음 중"), MenuColor.rec) }
        switch mode {
        case .paused: return (tr("일시정지됨"), MenuColor.idle)
        case .permissionMissing: return (tr("일부만 수집"), MenuColor.amber)
        default:
            if state.status.idle { return (tr("자리 비움"), MenuColor.idle) }
            return state.status.running ? (tr("기록 중"), MenuColor.green) : (tr("시작하는 중"), MenuColor.idle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader(status: statusInfo.text, dot: statusInfo.dot)
            HStack(alignment: .top, spacing: 0) {
                leftColumn.frame(width: 280, alignment: .topLeading)
                Rectangle().fill(MenuColor.line).frame(width: 1).frame(maxHeight: .infinity).padding(.top, 2)
                rightColumn.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 232, alignment: .top)
            MenuLine()
            if AppFeatures.calendarOn {                                   // 캘린더를 꺼 두면 캘린더 줄도 없다
                MenuBarCalendar(openMain: openMain)
                MenuLine()
            }
            bottom
        }
    }

    // MARK: 왼쪽: 연결, 사용량, 오늘 숫자, 알림 줄

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            connectionPill
            if let usage = state.codexUsage, !state.settings.llmUsesAPI {
                usageBars(usage).padding(.top, 12)
            }
            Spacer(minLength: 14)
            HStack(alignment: .top, spacing: 0) {
                number(tr("오늘 기록"), state.todayCount).frame(width: 124, alignment: .leading)
                number(tr("정리 대기"), state.pendingCount)
                Spacer(minLength: 0)
            }
            VStack(spacing: 6) {
                if mode == .permissionMissing { permissionRow }
                if state.notificationsDenied { notificationRow }
                if state.pendingFileSuggestions > 0 { fileRow }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 연결 방식: 제공자 로고, 요금제 이름, 초록 점
    private var connectionPill: some View {
        let usesAPI = state.settings.llmUsesAPI
        var label = "ChatGPT"
        var connected = usesAPI
        if usesAPI { label = AppSettings.providerName(state.settings.llmProvider) }
        else if case .loggedIn(_, let plan, _) = state.codexStatus {
            connected = true
            if let plan, !plan.isEmpty { label = "ChatGPT \(plan.prefix(1).uppercased() + plan.dropFirst())" }
        }
        return HStack(spacing: 7) {
            if let mark = Brand.openAIMark {
                Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit().frame(width: 13, height: 13)
                    .foregroundStyle(MenuColor.sub)
            }
            Text(label).font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.sub)
            Circle().fill(connected ? MenuColor.green : MenuColor.idle).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(MenuColor.chip))
    }

    /// 짧은 창(5시간)과 긴 창(주간) 사용량 막대
    private func usageBars(_ usage: CodexUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([usage.primary, usage.secondary].compactMap { $0 }, id: \.windowSeconds) { window in
                usageBar(window)
            }
        }
    }

    private func usageBar(_ window: CodexUsage.Window) -> some View {
        let ratio = min(1, max(0, window.usedPercent / 100))
        let name = window.windowSeconds >= 48 * 3600 ? tr("주간") : window.label
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tr("\(name) 사용량")).font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.text)
                if let hint = Self.resetHint(window, now: Date()) {
                    Text(hint).font(Brand.suit(10)).foregroundStyle(MenuColor.gray).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(Int(window.usedPercent.rounded()))%").font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.text)
            }
            Capsule().fill(MenuColor.track).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(MenuColor.primary).frame(width: max(6, g.size.width * ratio)) }
                }
        }
    }

    /// "2시간 14분 뒤 초기화", 하루 넘게 남았으면 "목요일 초기화"
    static func resetHint(_ window: CodexUsage.Window, now: Date) -> String? {
        guard window.resetAt > 0 else { return nil }
        let reset = Date(timeIntervalSince1970: window.resetAt)
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return tr("곧 초기화") }
        if seconds < 24 * 3600 {
            let minutes = Int((seconds / 60).rounded(.up))
            if minutes < 60 { return tr("\(minutes)분 뒤 초기화") }
            return minutes % 60 == 0 ? tr("\(minutes / 60)시간 뒤 초기화") : tr("\(minutes / 60)시간 \(minutes % 60)분 뒤 초기화")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "EEEE"
        return tr("\(formatter.string(from: reset)) 초기화")
    }

    private func number(_ caption: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray)
            Text("\(max(0, value))").font(Brand.suit(30, .medium)).foregroundStyle(MenuColor.text)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    /// 손쉬운 사용이나 화면 기록이 꺼져 있으면: 누르면 설정의 일반(권한 칸)
    private var permissionRow: some View {
        alertRow(icon: "exclamationmark.circle", text: tr("권한이 빠져 있어 일부만 기록해요"), warm: true) {
            state.openGeneralSettings()
            openMain()
        }
    }

    /// 알림 권한이 꺼져 있으면: 누르면 설정의 일반(권한 칸)
    private var notificationRow: some View {
        alertRow(icon: "bell.slash", text: tr("알림 꺼짐"), warm: false) {
            state.openGeneralSettings()
            openMain()
        }
    }

    /// 파일 정리 제안이 있으면: 누르면 기록 자료의 파일 구역
    private var fileRow: some View {
        alertRow(icon: "doc", text: tr("파일 정리 제안"), warm: false, count: state.pendingFileSuggestions) {
            state.openFileSuggestions()
            openMain()
        }
    }

    private func alertRow(icon: String, text: String, warm: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(warm ? MenuColor.warnText : MenuColor.sub)
                Text(text).font(Brand.suit(11.5, warm ? .medium : .regular)).foregroundStyle(warm ? MenuColor.warnText : MenuColor.sub)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count { Text("\(count)").font(Brand.suit(11.5, .semibold)).foregroundStyle(MenuColor.text) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(warm ? MenuColor.warnText : MenuColor.gray)
            }
            .padding(.horizontal, 12).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(warm ? MenuColor.warnBg : MenuColor.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 오른쪽: 최근 업무, 녹음 줄

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("최근 업무")).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray).padding(.top, 2)
            if state.taskList.isEmpty {
                Text(tr("아직 정리된 업무가 없어요")).font(Brand.suit(12)).foregroundStyle(MenuColor.gray).padding(.top, 14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.taskList.prefix(3)) { task in recentTask(task) }
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 10)
            MenuBarRecordingRow(allowStart: true)
        }
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 최근 업무 한 줄. 누르면 다시 열기 (prepareResume 이 창을 연다)
    private func recentTask(_ task: TaskSummary) -> some View {
        Button { state.prepareResume(taskId: task.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text).lineLimit(1).truncationMode(.tail)
                    Text(Self.timeText(task.lastActive)).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(MenuColor.gray)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tr("\(task.title) 다시 열기"))
    }

    // MARK: 아래 줄

    /// [지금 정리] 와 일시정지(또는 다시 시작), 앱 열기, 종료
    private var bottom: some View {
        HStack(spacing: 0) {
            MenuFilledButton(title: state.batchRunning ? tr("정리하는 중…") : tr("지금 정리"), icon: "arrow.clockwise", height: 38) {
                Task { await state.runBatch(force: true) }
            }
            .frame(width: 190)
            .disabled(state.batchRunning)
            .opacity(state.batchRunning ? 0.6 : 1)
            Spacer(minLength: 12)
            MenuTextButton(icon: state.status.paused ? "play" : "pause", title: state.status.paused ? tr("다시 시작") : tr("일시정지")) { state.togglePause() }
            MenuTextButton(icon: "macwindow", title: tr("앱 열기")) { openMain() }
            MenuTextButton(icon: "rectangle.portrait.and.arrow.right", title: tr("종료")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16).frame(height: 62)
    }

    static func timeText(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let time = AppState.clock.string(from: date)
        if Calendar.current.isDateInToday(date) { return tr("오늘 \(time)") }
        let c = Calendar.current.dateComponents([.month, .day], from: date)
        return tr("\(c.month ?? 0)월 \(c.day ?? 0)일 \(time)")
    }
}

// MARK: 녹음 줄 (정상, 일시정지, 일부만 수집, 준비 전 공용)

/// 녹음 줄: 문제 안내 → 정리 단계(받아쓰는 중 37% 와 막대) → [녹음 시작] 또는 "녹음 중 12:42" [끝내기].
/// allowStart: 시작 버튼을 보일지. 준비 전에는 녹음 중일 때만 끝내기 줄을 두고 시작 버튼은 두지 않는다
private struct MenuBarRecordingRow: View {
    @EnvironmentObject private var state: AppState
    let allowStart: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowStart, let problem = state.recordingProblem { problemRow(problem) }
            if allowStart, let work = state.recordingWork { workRow(work) }
            if let active = state.activeRecording {
                activeRow(active)
            } else if allowStart {
                startRow
            }
        }
    }

    /// 녹음 시작: 파형 아이콘 (막대 6개, 빨간색 없음)
    private var startRow: some View {
        Button { Task { await state.startRecording() } } label: {
            HStack(spacing: 9) {
                Waveform()
                Text(tr("녹음 시작")).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text)
                Spacer()
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func activeRow(_ active: ActiveRecording) -> some View {
        HStack(spacing: 8) {
            Circle().fill(MenuColor.rec).frame(width: 8, height: 8)
            Text(tr("녹음 중")).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(RecordingText.clock(context.date.timeIntervalSince1970 - active.startedAt))
                    .font(Brand.suit(13)).foregroundStyle(MenuColor.gray).monospacedDigit()
            }
            Spacer(minLength: 8)
            Button { Task { await state.stopRecording() } } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5).strokeBorder(MenuColor.sub, lineWidth: 1.2).frame(width: 7, height: 7)
                    Text(tr("끝내기")).font(Brand.suit(11, .medium)).foregroundStyle(MenuColor.sub)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(MenuColor.chip))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 34)
    }

    /// 받아쓰는 중 37% 와 막대 / 녹음을 정리하는 중
    private func workRow(_ work: RecordingPipeline.Step) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                if case .transcribing(let progress) = work {
                    Text(tr("받아쓰는 중")).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%").font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.sub)
                } else {
                    Text(work.menuText).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text)
                    Spacer()
                }
            }
            if case .transcribing(let progress) = work {
                Capsule().fill(MenuColor.track).frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(MenuColor.primary).frame(width: max(6, g.size.width * min(1, max(0, progress)))) }
                    }
            }
        }
        // 접근성과 화면 읽기용으로 한 문장도 함께 둔다 ("받아쓰는 중 37%")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(work.menuText)
    }

    /// 권한이나 받아쓰기 설정이 꺼져 있으면: 누르면 고칠 시스템 설정을 연다
    private func problemRow(_ problem: RecordingProblem) -> some View {
        Button { problem.openSettings() } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(MenuColor.warnText)
                Text(problem.text).font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.warnText).lineLimit(2)
                Spacer(minLength: 4)
                if problem.settingsURL != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(MenuColor.warnText)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(MenuColor.warnBg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 파형 아이콘: 가는 막대 6개
private struct Waveform: View {
    private let heights: [CGFloat] = [5, 10, 14, 9, 12, 5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                Capsule().fill(MenuColor.sub).frame(width: 2, height: h)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

extension RecordingPipeline.Step {
    /// 메뉴 막대의 정리 단계 문구: "받아쓰는 중 37%", "녹음을 정리하는 중"
    var menuText: String {
        switch self {
        case .transcribing(let progress): tr("받아쓰는 중 \(Int((progress * 100).rounded()))%")
        case .naming: tr("녹음을 정리하는 중")
        }
    }
}

// MARK: 캘린더 줄 (Figma MB-06 접힘 1269:15772, MB-07 펼침 1269:16029)

/// [일시정지] 줄 위의 접고 펴는 한 줄: 캘린더 아이콘, "캘린더", 회색 요약, 오른쪽 끝 화살표.
/// 펼치면 왼쪽에 오늘 일정, 오른쪽에 기록에서 찾은 일정 제안 (최대 3개). 펼침 상태는 기억한다
private struct MenuBarCalendar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @AppStorage(MenuBarPanel.calendarExpandedKey) private var expanded = false
    let openMain: () -> Void

    private var summary: String {
        var parts: [String] = []
        if calendar.granted { parts.append(calendar.today.isEmpty ? tr("오늘 일정 없음") : tr("오늘 일정 \(calendar.today.count)개")) }
        if !calendar.suggestions.isEmpty { parts.append(tr("일정 제안 \(calendar.suggestions.count)")) }
        return parts.isEmpty ? (calendar.granted ? "" : tr("권한 필요")) : parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(MenuColor.sub)
                    Text(tr("캘린더")).font(Brand.suit(12.5, .medium)).foregroundStyle(MenuColor.text)
                    Text(summary).font(Brand.suit(11)).foregroundStyle(MenuColor.gray).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(MenuColor.gray)
                }
                .padding(.horizontal, 18).frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                HStack(alignment: .top, spacing: 0) {
                    todayColumn.frame(width: 280, alignment: .topLeading)
                    Rectangle().fill(MenuColor.line).frame(width: 1).frame(maxHeight: .infinity)
                    suggestionColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.bottom, 14)
            }
        }
        .onAppear { calendar.attach(state.db) }
    }

    private var todayColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.dateTitle(Date())).font(Brand.suit(13, .bold)).foregroundStyle(MenuColor.text)
            Text(tr("오늘")).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray).padding(.top, 8)
            if !calendar.granted {
                Text(tr("캘린더 권한을 켜면 오늘 일정이 보여요")).font(Brand.suit(12)).foregroundStyle(MenuColor.gray).padding(.top, 8)
                Button { Task { await calendar.requestAccess() } } label: {
                    Text(tr("허용하기")).font(Brand.suit(11.5, .medium)).foregroundStyle(MenuColor.primary)
                        .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if calendar.today.isEmpty {
                Text(tr("오늘 일정이 없어요")).font(Brand.suit(12)).foregroundStyle(MenuColor.gray).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(calendar.today.prefix(3)) { event in
                        HStack(spacing: 8) {
                            Text(event.time).font(Brand.suit(12, .medium)).foregroundStyle(MenuColor.gray).frame(width: 40, alignment: .leading)
                            Text(event.title).font(Brand.suit(13, .medium)).foregroundStyle(MenuColor.text).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    if calendar.today.count > 3 {
                        Text(tr("외 \(calendar.today.count - 3)")).font(Brand.suit(11)).foregroundStyle(MenuColor.gray)
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 10)
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) } label: {
                Text(tr("캘린더 앱 열기 ›")).font(Brand.suit(11.5)).foregroundStyle(MenuColor.gray).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.top, 2)
    }

    private var suggestionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("일정 제안 \(calendar.suggestions.count)")).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray)
            if calendar.suggestions.isEmpty {
                Text(tr("기록에서 찾은 일정이 없어요")).font(Brand.suit(12)).foregroundStyle(MenuColor.gray).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calendar.suggestions.prefix(3)) { suggestion in card(suggestion) }
                    if calendar.suggestions.count > 3 {
                        Text(tr("외 \(calendar.suggestions.count - 3)")).font(Brand.suit(11)).foregroundStyle(MenuColor.gray)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16).padding(.top, 2)
    }

    private func card(_ suggestion: EventSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title).font(Brand.suit(12.5, .medium)).foregroundStyle(MenuColor.text).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 8) {
                Text(CalendarService.dateText(suggestion)).font(Brand.suit(10.5)).foregroundStyle(MenuColor.gray).lineLimit(1)
                Spacer(minLength: 4)
                Button { Task { await calendar.register(suggestion) } } label: {
                    Text(tr("등록")).font(Brand.suit(11, .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 24).background(Capsule().fill(MenuColor.text)).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button { calendar.dismiss(suggestion) } label: {
                    Text(tr("무시")).font(Brand.suit(11)).foregroundStyle(MenuColor.gray).padding(.horizontal, 4).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MenuColor.row))
    }

    /// "11월 3일 화요일"
    static func dateTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = tr("M월 d일 EEEE")
        return f.string(from: date)
    }
}
