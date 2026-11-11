import SwiftUI
import SillogCore

/// 창 맨 왼쪽 세로 막대: 그래프, 채팅, 기록 자료, 캘린더, 설정이 한 줄로, 계정 동그라미가 맨 아래. 탭마다 아이콘 아래 작은 글자
struct NavRail: View {
    static let width: CGFloat = 72
    @EnvironmentObject private var state: AppState
    @ObservedObject private var calendar = CalendarService.shared

    /// lucide 줄 아이콘 경로: share-2, message-circle, archive, calendar, settings
    private func icon(_ tab: MainWindow.Tab) -> String {
        switch tab {
        case .graph: RailIcon.graph
        case .chat: RailIcon.chat
        case .records: RailIcon.records
        case .calendar: RailIcon.calendar
        case .settings: RailIcon.settings
        case .connectors: RailIcon.connectors
        }
    }

    /// 숫자 대신 점: 정리할 파일 제안, 등록할 일정 제안
    private func hasDot(_ tab: MainWindow.Tab) -> Bool {
        (tab == .records && state.pendingFileSuggestions > 0) || (tab == .calendar && !calendar.suggestions.isEmpty)
    }

    private func railTab(_ tab: MainWindow.Tab) -> some View {
        let on = state.selectedTab == tab
        return Button {
            if tab == .chat, state.selectedTab != .chat { state.chat?.newConversation() }   // 다른 탭에서 채팅으로 오면 홈(새 대화)
            state.selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                SVGIcon(d: icon(tab))
                    .stroke(Brand.tabText, style: StrokeStyle(lineWidth: on ? 1.8 : 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                Text(tab.rawValue).font(Brand.suit(10, on ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(on ? Brand.ink : Brand.tabText)
            .frame(width: 60, height: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color(hex: 0xF7F5F2) : .clear))   // 고른 탭 알약, 아이콘 줄보다 한 단계 밝게
            .hoverHighlight(cornerRadius: 12, active: !on)
            .overlay(alignment: .topTrailing) {
                if hasDot(tab) { Circle().fill(Brand.sky).frame(width: 7, height: 7).offset(x: -17, y: 10) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(MainWindow.Tab.visible()) { railTab($0) }   // 설정도 다른 탭과 한 줄에 (맨 아래로 내리지 않는다)
            Spacer(minLength: 0)
            AccountDot().padding(.top, 8)
        }
        .padding(.top, 10).padding(.bottom, 14).padding(.horizontal, 6)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(hex: 0xEFECE9))                    // 창 머리와 같은 톤. 구획선 없이 바탕 톤 차이로만 나눈다
    }
}

/// 아이콘 줄 맨 아래 계정 동그라미: 로그인한 이메일 앞 두 글자. 누르면 계정 상자(AccountPopover)
private struct AccountDot: View {
    @EnvironmentObject private var state: AppState
    @State private var open = false
    private var email: String? { if case .loggedIn(let email, _, _) = state.codexStatus { return email }; return nil }
    var body: some View {
        let initials = String((email ?? "?").prefix(2)).uppercased()
        Button { open.toggle() } label: {
            Text(initials).font(Brand.suit(11, .semibold)).foregroundStyle(Brand.badgeText)
                .frame(width: 32, height: 32).background(Circle().fill(Brand.badgeFill))
                .frame(width: 36, height: 36).contentShape(Circle())
        }
        .buttonStyle(.plain).railLabel(email ?? "계정").accessibilityLabel("계정 \(email ?? "")")
        .popover(isPresented: $open, arrowEdge: .trailing) { AccountPopover().environmentObject(state) }
    }
}

/// 계정 동그라미 이름표: 커서를 대면 오른쪽에 이메일이 바로 뜬다 (기본 도움말은 늦게 떠서). 탭은 글자가 보여 이름표가 없다
private struct RailLabel: ViewModifier {
    let text: String
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .onHover { hover = $0 }
            .overlay(alignment: .leading) {
                if hover {
                    Text(text).font(Brand.suit(11, .medium)).foregroundStyle(Brand.ink).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.pillFill))
                        .offset(x: 58).allowsHitTesting(false)       // 동그라미 36 + 줄 가장자리 18 + 간격 4
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hover)
    }
}
private extension View { func railLabel(_ text: String) -> some View { modifier(RailLabel(text: text)) } }

/// 창 머리 왼쪽 (Figma 851:354): 빈칸과 SILLOG 글자, 가는 구분선, 연결 알약, 정리 알약
private struct TitleBarBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            if let mark = Brand.wordmark {
                Image(nsImage: mark).resizable().scaledToFit().frame(height: 13).accessibilityLabel("SILLOG")
            } else {
                Text("SILLOG").font(Brand.suit(13, .semibold)).foregroundStyle(Brand.ink)
            }
            Rectangle().fill(Brand.line).frame(width: 1, height: 14)
            TitleConnection()
            TitleRefresh()
        }
        .padding(.leading, 6)
    }
}

/// 연결 알약 (Figma 923:2819): [로고 이름 | 모델 ●]. ChatGPT 구독이면 OpenAI 로고와 요금제, OpenAI 호환 서버면 주소로 Claude API 를 가리고 그 밖은 링크와 API.
/// 점은 연결됨 초록, 아니면 회색
private struct TitleConnection: View {
    @EnvironmentObject private var state: AppState
    private var compat: Bool { state.settings.chatUsesAPI }
    private var host: String { URL(string: state.settings.chatEndpoint.url)?.host?.lowercased() ?? "" }
    private var plan: String? { if case .loggedIn(_, let plan, _) = state.codexStatus, let plan, !plan.isEmpty { return plan }; return nil }
    private var label: String {
        if !compat { return plan.map { "ChatGPT \($0.prefix(1).uppercased() + $0.dropFirst())" } ?? "ChatGPT" }
        if host.contains("anthropic") { return "Claude API" }
        return "API"
    }
    private var connected: Bool {
        if compat { return !state.settings.chatBaseURL.isEmpty }
        if case .loggedIn = state.codexStatus { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 6) {
            logo.frame(width: 13, height: 13)
            Text(label).font(Brand.suit(12, .medium)).foregroundStyle(Color(hex: 0x4A3E37))
            Rectangle().fill(Color(hex: 0xCFC8C1)).frame(width: 1, height: 10)
            Text(Self.modelTitle(state.settings.chatModelName)).font(Brand.suit(11.5)).foregroundStyle(Color(hex: 0x7A716B)).lineLimit(1)
            Circle().fill(connected ? Brand.connected : Brand.sub).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).frame(height: 24)
        .background(Capsule().fill(Brand.pillFill))
        .help(connected ? "연결됨" : "연결되지 않음")
    }

    @ViewBuilder private var logo: some View {
        if !compat, let mark = Brand.openAIMark {
            Image(nsImage: mark).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Color(hex: 0x4A3E37))
        } else if compat, host.contains("anthropic") {
            SVGIcon(d: Brand.claudePath).fill(Color(hex: 0xD97757))
        } else {
            SVGIcon(d: RailIcon.link).stroke(Brand.tabText, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    /// 모델 이름을 읽기 좋게: gpt-6-luna → GPT-6 Luna, claude-opus-5-5 → Claude Opus 5.5
    static func modelTitle(_ id: String) -> String {
        var out = [String]()
        for part in id.split(separator: "-").map(String.init) {
            let isNum = part.first?.isNumber == true
            if isNum, let last = out.last, last.hasPrefix("GPT") || last.last?.isNumber == true {
                out[out.count - 1] = last + (last == "GPT" ? "-" : ".") + part
            } else if part.lowercased() == "gpt" { out.append("GPT") }
            else { out.append(part.prefix(1).uppercased() + part.dropFirst()) }
        }
        return out.joined(separator: " ")
    }
}

/// 창 머리 오른쪽 위: 녹음 단추. 메뉴 막대 아이콘이 노치 뒤로 가려져도 창에서 녹음할 수 있다
struct TitleBarControls: View {
    var body: some View {
        RecordingTitleControl()
            .padding(.trailing, 14)                               // 아래 본문 오른쪽 끝과 맞춘다
    }
}

/// 녹음 단추 안의 막대 여섯 개 소리 모양 아이콘 (붉은 점 대신)
private struct WaveformIcon: View {
    private static let heights: [CGFloat] = [5, 9, 13, 8, 11, 5]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.heights.indices, id: \.self) { Capsule().frame(width: 1.5, height: Self.heights[$0]) }
        }
        .frame(width: 15, height: 15)
    }
}

/// 창 머리 알약 단추 모양: 주 단추(녹음)는 갈색 바탕에 흰 글자, 높이 32. 보조 단추(정리)는 연한 바탕에 갈색 글자, 높이 24. 테두리 없음.
/// 단추 안의 내용만 바뀌고 알약은 그대로다. 커서를 올리면 바탕색이 한 단계 바뀐다
private struct TitlePill<Content: View>: View {
    var primary = false
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .font(primary ? Brand.suit(12, .bold) : Brand.suit(12))
            .foregroundStyle(primary ? .white : Brand.tabText)
            .lineLimit(1).fixedSize()                              // 옆 문구에 밀려 두 줄로 꺾이지 않게
            .padding(.horizontal, primary ? 30 : 10).frame(height: primary ? 32 : 24)
            .background(Capsule().fill(primary ? (hover ? Brand.accentDark : Brand.accent) : hover ? Brand.pillFill.opacity(0.7) : Brand.pillFill))
            .contentShape(Capsule())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// 창 머리의 녹음: 메뉴 막대 녹음 줄과 같은 상태를 보인다. 평소 [● 녹음 시작], 녹음 중 [● 녹음 끝내기 12:31], 받아쓰는 중에는 알약 왼쪽에 "받아쓰는 중 37%".
/// 새 녹음은 로그인을 마친 뒤에만, 끝내기는 언제나
private struct RecordingTitleControl: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if let problem = state.recordingProblem { problemButton(problem) }
            if let active = state.activeRecording {
                Button { Task { await state.stopRecording() } } label: {
                    TitlePill(primary: true) {
                        HStack(spacing: 7) {
                            WaveformIcon()
                            Text("녹음 끝내기")
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(RecordingText.clock(context.date.timeIntervalSince1970 - active.startedAt)).monospacedDigit()
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("녹음을 끝내고 이 Mac 안에서 받아씁니다")
            } else if state.phase == .ready {
                if let work = state.recordingWork {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(work.menuText).font(Brand.suit(11)).foregroundStyle(Brand.tabText).lineLimit(1).truncationMode(.tail)
                    }
                    .layoutPriority(-1)                               // 칸이 모자라면 단추 대신 이 문구가 줄어든다
                }
                Button { Task { await state.startRecording() } } label: {
                    TitlePill(primary: true) {
                        HStack(spacing: 9) {
                            WaveformIcon()
                            Text("녹음 시작")
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("마이크로 녹음하고, 끝내면 이 Mac 안에서 받아씁니다")
            }
        }
    }

    /// 권한·받아쓰기 설정이 꺼져 있으면: 넓으면 문구, 좁으면 아이콘. 누르면 고칠 시스템 설정을 연다
    private func problemButton(_ problem: RecordingProblem) -> some View {
        Button { problem.openSettings() } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    Text(problem.text).font(Brand.suit(11)).lineLimit(1)
                }
                Image(systemName: "exclamationmark.circle").font(.system(size: 12))
            }
            .foregroundStyle(Brand.tabText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(problem.text)
    }
}

/// 창 머리의 지금 정리: [↻ 14개 지금 정리] (굵은 대기 수와 보통 글자). 정리하는 동안에는 기호가 돌고, 끝나면 체크나 X 가 잠깐 보인다
private struct TitleRefresh: View {
    @EnvironmentObject private var state: AppState
    @State private var spin = false
    var body: some View {
        Button { Task { await state.runBatch(force: true) } } label: {
            TitlePill {
                HStack(spacing: 6) {
                    icon.frame(width: 13, height: 13)
                    if state.batchRunning { Text("정리하는 중") }
                    else {
                        if state.pendingCount > 0 { Text("\(state.pendingCount)개").font(Brand.suit(12, .bold)).foregroundStyle(Color(hex: 0x4A3E37)) }
                        Text("지금 정리").foregroundStyle(Color(hex: 0x6E6862))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: state.batchResult)
            }
        }
        .buttonStyle(.plain)
        .disabled(state.batchRunning)
        .help("아직 정리되지 않은 활동을 지금 바로 그래프에 반영합니다")
        .onChange(of: state.batchRunning) { _, on in spin = on }
        .onAppear { spin = state.batchRunning }
    }

    /// 정리하는 동안은 같은 기호가 돌고, 끝나면 파란 체크(성공)나 X(실패)로 잠깐 바뀐다
    @ViewBuilder private var icon: some View {
        if state.batchRunning {
            SVGIcon(d: RailIcon.refresh).stroke(Brand.tabText, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(spin ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spin)
        } else if state.batchResult == true {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13, weight: .bold)).symbolRenderingMode(.palette).foregroundStyle(.white, Color(hex: 0x4A86C5)).transition(.scale.combined(with: .opacity))
        } else if state.batchResult == false {
            Image(systemName: "xmark.circle.fill").font(.system(size: 13, weight: .bold)).symbolRenderingMode(.palette).foregroundStyle(.white, Color(hex: 0xC0573F)).transition(.scale.combined(with: .opacity))
        } else {
            SVGIcon(d: RailIcon.refresh).stroke(Brand.tabText, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 업무 패널(업무 드로어): 그래프 탭에서 아이콘 줄 오른쪽에 열려 있는 업무 목록. 업무를 누르면 상세가 오른쪽으로 펼쳐지며 그래프를 덮지 않고 밀어낸다(그래프 폭이 줄어든다).
/// ×나 Esc 로 접는다. 업무 상세는 이 드로어 하나다: 그래프에서 업무를 눌러도(AppState.openTaskDetail) 같은 드로어가 그 업무로 열린다. 다른 탭으로 가면 접힌다
struct TasksPanel: View {
    static let listWidth: CGFloat = 277                         // 업무 목록 폭 (구분선 없이 바탕 톤으로 나눈다)
    static let maxDetail: CGFloat = 460
    static let minDetail: CGFloat = 340
    static let contentKeeps: CGFloat = 480                      // 드로어를 열어도 본문(그래프, 채팅)에 남기는 폭

    /// 상세 폭: 넓은 창에서는 460, 좁으면 본문에 480을 남기고 줄인다. 340 아래로는 안 줄인다. available = 창 폭 - 아이콘 줄 - 업무 목록
    static func detailWidth(available: CGFloat) -> CGFloat {
        max(minDetail, min(maxDetail, available - contentKeeps))
    }

    @EnvironmentObject private var state: AppState
    /// 펼쳤을 때 상세 폭 (창 폭에 맞춰 MainWindow 가 정한다)
    var detailWidth: CGFloat = TasksPanel.maxDetail

    private var expanded: Bool { state.taskDetailOpen }

    var body: some View {
        TasksView(selectedTask: state.selectedTaskId, showsDetail: expanded, onSelect: { state.openTaskDetail(id: $0) })   // 접히면 상세를 아예 안 그린다 (가려진 상세가 본문 클릭을 가로채지 않게)
            .frame(width: expanded ? Self.listWidth + detailWidth : Self.listWidth, alignment: .leading)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if expanded {
                    Button { state.taskDetailOpen = false } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.tabText)
                            .frame(width: 26, height: 26).background(Circle().fill(Color.black.opacity(0.05))).contentShape(Circle())
                    }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("업무 상세 닫기 (Esc)")
                    .padding(10)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.22), value: expanded)
    }
}

/// 정리 탭: 파일 제안과 처리한 지난 기록.
struct RecordsView: View {
    /// 파일(대기 중인 제안) · 지난 기록(처리한 제안)
    enum Section: String, CaseIterable, Identifiable {
        case files = "파일", history = "지난 기록"
        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TextTabs(selection: $state.recordsSection) { $0 == .files ? state.pendingFileSuggestions : 0 }
            Group {
                switch state.recordsSection {
                case .files: FilesView()
                case .history: FileHistoryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 창 바탕: 불투명한 종이색. 창 뒤 바탕화면이 비치는 유리와 흐림은 10/28 걷어냈다
private struct WindowGlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(Brand.paper.ignoresSafeArea()).background(FrameMonitorHook())
    }
}

/// 창이 붙으면 개발용 프레임 측정을 시작한다 (숨은 설정 frameLog)
private struct FrameMonitorHook: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let content = window?.contentView { FrameMonitor.shared.start(on: content) }
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ nsView: View, context: Context) {}
}

/// macOS 15부터 창 제목 글자를 숨긴다 (창 머리에는 왼쪽 브랜드, 연결, 지금 정리와 오른쪽 녹음 단추만)
private struct HideWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content }
    }
}

struct MainWindow: View {
    enum Tab: String, CaseIterable, Identifiable {
        case graph = "그래프", chat = "채팅", records = "정리", connectors = "커넥터", settings = "설정", calendar = "캘린더"   // 업무는 그래프 옆 패널(TasksPanel), 파일·보관함·활동 로그는 기록 자료 안 구역
        var id: String { rawValue }

        /// 캘린더는 켜져 있을 때만 아이콘 줄에 보인다.
        static func visible(calendar: Bool = AppFeatures.calendarOn) -> [Tab] {
            allCases.filter { calendar || $0 != .calendar }
        }
    }

    @EnvironmentObject private var state: AppState
    /// SILLOG_TAB=chat|records|files|history|library|calendar|settings|activity 로 시작 탭을 고를 수 있다 (개발·스크린샷용).
    static let initialTab: Tab = {
        switch SillogEnv.value("TAB") {
        case "settings", "ai", "activity": return .settings
        case "chat", "results", "library": return .chat
        case "connectors", "plugins", "skills": return .connectors
        case "records", "files", "history": return .records
        case "calendar": return AppFeatures.calendarOn ? .calendar : .graph
        default: return .graph                                   // 권한·로그인 안내는 온보딩이 맡는다
        }
    }()
    /// SILLOG_TAB=history 면 정리의 지난 기록으로 시작한다
    static let initialRecordsSection: RecordsView.Section = {
        switch SillogEnv.value("TAB") {
        case "history": return .history
        default: return .files
        }
    }()
    /// SILLOG_TAB=activity 면 설정의 활동 로그로 시작한다
    static let initialSettingsSection: SettingsView.Section = SillogEnv.value("TAB") == "activity" ? .activity : (SillogEnv.value("TAB") == "ai" ? .ai : .general)

    private var ready: Bool { state.startupError == nil && state.bootstrapped && state.phase == .ready }
    /// 기기 코드 로그인이 꺼진 계정: 탭 대신 OUT-W1 카드
    private var loginBlocked: Bool { state.loginBlocked && state.phase == .login }
    /// 시작 실패·불러오는 중·로그인 오류가 아니면 탭이 보이고, 온보딩은 그 위에 시트로 뜬다
    private var showsTabs: Bool { state.startupError == nil && state.bootstrapped && !loginBlocked }
    /// 온보딩 시트가 떠 있으면 시트 뒤 탭은 눌리지도(Return 같은 키보드 단축키 포함) 읽히지도 않는다
    private var sheetShown: Bool { showsTabs && state.onboardingStep != nil }

    var body: some View {
        // 왼쪽부터 아이콘 줄, 업무 드로어(목록, 펼치면 상세), 본문. 상세가 펼쳐지면 본문을 덮지 않고 오른쪽으로 밀어 본문 폭이 줄어든다
        GeometryReader { geo in
            let available = geo.size.width - (showsTabs ? NavRail.width : 0) - TasksPanel.listWidth
            let corner: CGFloat = 12                            // 본문 영역 왼쪽 위 모서리 반지름 (Figma GR-01)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if ready && state.selectedTab == .graph { TasksPanel(detailWidth: TasksPanel.detailWidth(available: available)) }   // 업무 목록은 그래프 옆에만 (채팅·기록 자료·설정은 본문만)
                    Group {
                        if let error = state.startupError {
                            BrandStartupErrorView(message: error)
                        } else if !state.bootstrapped {
                            BrandLoadingView()
                        } else if loginBlocked {
                            LoginBlockedView()
                        } else {
                            switch state.selectedTab {
                            case .graph: GraphWebView(version: state.graphVersion).ignoresSafeArea(edges: .bottom)   // 웹 페이지의 빈 곳으로 창 바탕 유리가 보인다
                            case .chat: if let chat = state.chat {
                                ChatView(chat: chat, library: chat.library, modelName: state.settings.chatModelName,
                                         openSettings: { state.settingsSection = .ai; state.selectedTab = .settings },   // 모델 메뉴의 설정 → AI 연결
                                         pendingRecords: state.pendingCount, tidyNow: { Task { await state.runBatch(force: true) } })
                            }
                            case .records: RecordsView()
                            case .calendar: CalendarView()
                            case .settings: SettingsView()
                            case .connectors: CustomizeView()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Brand.paper, ignoresSafeAreaEdges: [])   // 비치는 곳은 예전처럼 창 바탕색 (모서리 바깥만 아래 색이 보이게)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: showsTabs ? corner : 0, style: .circular))   // 모든 탭 공통: 본문 영역(창 머리 아래, 아이콘 줄 오른쪽) 왼쪽 위만 둥글게
                .background(alignment: .topLeading) { Color(hex: 0xEFECE9).frame(width: corner, height: corner) }   // 모서리 바깥은 창 머리, 아이콘 줄과 같은 색
                .padding(.leading, showsTabs ? NavRail.width : 0)    // 아이콘 줄 자리
                if showsTabs { NavRail() }                          // 맨 위: 이름표가 업무 목록 위로 나오게
            }
        }
        .onChange(of: state.selectedTab) { _, _ in state.taskDetailOpen = false }   // 탭을 바꾸면 드로어를 접는다 (채팅 탭에는 업무 패널이 없다)
        .disabled(sheetShown)
        .accessibilityHidden(sheetShown)
        .overlay {
            if showsTabs, let step = state.onboardingStep { OnboardingOverlay(step: step) }
        }
        .frame(minWidth: 1064, minHeight: 560)                  // 아이콘 줄 72 + 업무 목록 277 + 채팅 최소 700(대화 목록 200 + 본문 500) + 여유 15
        .sheet(item: $state.resumeRequest) { request in ResumeSheet(request: request).environmentObject(state) }
        .toolbar {
            if showsTabs {                                       // 왼쪽 브랜드, 연결, 지금 정리, 오른쪽 녹음
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { TitleBarBrand() }.sharedBackgroundVisibility(.hidden)
                    ToolbarSpacer(.flexible)
                    ToolbarItem { TitleBarControls() }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { TitleBarBrand() }
                    ToolbarItem { Spacer() }                     // macOS 15 는 항목을 왼쪽부터 놓는다(primaryAction 도 왼쪽). 빈 칸으로 오른쪽 끝에 민다
                    ToolbarItem { TitleBarControls() }
                }
            }
        }
        .toolbarBackground(Color(hex: 0xEFECE9), for: .windowToolbar)
        .modifier(HideWindowTitle())
        .modifier(WindowGlassBackground())
        .modifier(EraseDialog())                                // 지우기 확인 창 (그래프 우클릭, 업무·노드 상세의 지우기)
        .sheet(isPresented: $state.reviewSheetOpen) { ReviewSheet().environmentObject(state) }   // 정리 제안 (하루 한 번)
        .task { await state.bootstrap() }
        .onChange(of: state.phase) { old, phase in
            // 온보딩을 막 끝냈을 때만 그래프 탭으로. 앱 시작 시의 login → ready 전환은 탭을 건드리지 않는다.
            if phase == .ready { state.refresh() }
            if phase == .ready, old == .permissions { state.selectedTab = .graph }
        }
        .onAppear { state.refresh() }
    }
}
