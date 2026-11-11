import AppKit
import ServiceManagement
import SwiftUI
import SillogCollectors
import SillogCore

/// Settings tab: text tabs on top (general, AI connection, activity log) and one page under them.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @State private var launchAtLogin = false
    @State private var launchStatusLoaded = false
    @State private var launchError: String?
    @State private var applyTask: Task<Void, Never>?
    @State private var editingExcluded = false

    enum Section: String, CaseIterable, Identifiable {
        case general = "일반"
        case ai = "AI 연결"
        case activity = "활동 로그"                       // 무엇을 기록하고 언제 정리했는지 (수집 설정 가까이)
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextTabs(selection: $state.settingsSection, selectedFill: Color(hex: 0xEFECE9))
            if state.settingsSection == .activity {
                ActivityLogView().frame(maxWidth: .infinity, maxHeight: .infinity)   // 자기 표와 스크롤이 있다
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, 34)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.white)
            }
        }
        // Typing a key or URL should not rebuild every client per keystroke.
        .onChange(of: state.settings) { _, _ in
            applyTask?.cancel()
            applyTask = Task { try? await Task.sleep(nanoseconds: 400_000_000); guard !Task.isCancelled else { return }; applyTask = nil; state.applySettings() }
        }
        .onDisappear { if applyTask != nil { applyTask?.cancel(); applyTask = nil; state.applySettings() } }
        .onChange(of: state.settings.llmProvider) { _, _ in state.updateCodexModelProviders() }
        .onChange(of: state.settings.chatProvider) { _, _ in state.updateCodexModelProviders() }
        .onChange(of: state.settings.judgeProvider) { _, _ in state.updateCodexModelProviders() }
        .onChange(of: state.settings.judgeGPTProvider) { _, _ in state.updateCodexModelProviders() }
        .onAppear { if !state.isPreview { state.refreshCodexStatus() } }
        .task {
            // 로그인 항목 상태 조회는 수 초 걸릴 수 있는 동기 XPC 호출이라 메인 스레드 밖에서 읽는다.
            let enabled = await Task.detached(priority: .utility) { SMAppService.mainApp.status == .enabled }.value
            launchAtLogin = enabled
            try? await Task.sleep(nanoseconds: 100_000_000)
            launchStatusLoaded = true
        }
    }

    @ViewBuilder private var content: some View {
        switch state.settingsSection {
        case .general: general
        case .ai: aiConnection
        case .activity: EmptyView()                      // 위에서 따로 그린다
        }
    }

    // MARK: 일반

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("기본 설정")); basics
            SectionLabel(tr("권한")); permissions
            SectionLabel(tr("기록할 내용")); collection
            SectionLabel(tr("업무 정리")); organizing
            StorageSettingsView()
        }
        .sheet(isPresented: $editingExcluded) {
            SettingSheet(tr("기록하지 않을 앱")) { ExcludedAppsView() }.environmentObject(state)
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingTiles(columns: 3) {
                SettingTile(tr("언어")) {
                    BrandMenu(selection: Binding(get: { state.settings.language.rawValue },
                                                 set: { state.settings.language = AppLanguage(rawValue: $0) ?? .ko }),
                              options: [("ko", "한국어"), ("en", "English")], width: 120)
                }
                .help(tr("화면과 AI가 만드는 업무 이름·요약에 써요. 이미 만든 기록은 그대로예요."))
                SettingTile(tr("로그인 시 실행")) {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(BrandSwitchStyle())
                        .disabled(!launchStatusLoaded)
                        .onChange(of: launchAtLogin) { _, enabled in if launchStatusLoaded { setLaunchAtLogin(enabled) } }
                }
                .help(tr("Mac에 로그인하면 메뉴 막대에서 시작해요."))
                SettingTile(tr("Dock 아이콘")) {
                    Toggle("", isOn: $state.settings.showDockIcon).toggleStyle(BrandSwitchStyle())
                }
                .help(tr("끄면 메뉴 막대에만 보여요."))
            }
            if let launchError {
                Text(launchError).font(Brand.suit(11)).foregroundStyle(Brand.text).padding(.vertical, 12)
            }
        }
    }

    /// One line when everything is granted; the full tiles only while something is off.
    @ViewBuilder private var permissions: some View {
        let granted = [state.status.accessibility, state.status.screenRecording, !state.notificationsDenied]
            + (AppFeatures.calendarOn ? [calendar.granted] : [])
        if granted.allSatisfy({ $0 }) {
            let names = [Permissions.accessibilityName, tr("화면 기록"), tr("알림")] + (AppFeatures.calendarOn ? [tr("캘린더")] : [])
            SettingTile(names.joined(separator: " · "), icon: "checkmark.shield") {
                Label(tr("모두 허용됨"), systemImage: "checkmark.circle.fill")
                    .font(Brand.suit(11, .semibold)).foregroundStyle(ActivityLogView.okColor)
            }
        } else {
            permissionTiles
        }
    }

    private var permissionTiles: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
            permissionTile(Permissions.accessibilityName, icon: "hand.raised",
                           detail: accessibilityDetail,
                           granted: state.status.accessibility) {
                _ = Permissions.accessibility(prompt: true)
                Permissions.openSettings(.accessibility)
            }
            permissionTile(tr("화면 기록"), icon: "camera.viewfinder",
                           detail: screenRecordingDetail,
                           granted: state.status.screenRecording) {
                Permissions.requestScreenRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Permissions.openSettings(.screenRecording) }
            }
            permissionTile(tr("알림"), icon: "bell", detail: tr("파일 정리 제안을 알려요. 꺼져 있어도 파일 구역에서 볼 수 있어요."), granted: !state.notificationsDenied) {
                SuggestionNotifier.openSystemSettings()
            }
            if AppFeatures.calendarOn {
                permissionTile(tr("캘린더"), icon: "calendar",
                               detail: calendar.granted ? tr("오늘 일정을 보여 줘요. 등록할 캘린더: \(calendar.target.map { "\($0.title) · \($0.account)" } ?? CalendarService.calendarName) (캘린더 탭에서 바꿔요)") : tr("꺼져 있어 오늘 일정을 못 보여 주고 일정을 등록하지 못해요."),
                               granted: calendar.granted) {
                    Task { await calendar.requestAccess() }
                }
            }
            }
            InfoLine(tr("화면 기록은 허용한 뒤 앱을 다시 실행해 주세요."))
        }
    }

    /// 두 권한의 조합마다 실제로 남는 것을 적는다
    private var accessibilityDetail: String {
        if state.status.accessibility { return tr("창 제목, 주소, 문서 경로, 화면 텍스트를 읽어요.") }
        return state.status.screenRecording ? tr("꺼져 있어 창 제목·주소·문서 경로는 남지 않아요. 화면 글자는 스크린샷에서 OCR로 읽어요.")
                                            : tr("꺼져 있어 지금은 앱 이름만 기록하고 있어요.")
    }

    private var screenRecordingDetail: String {
        guard state.status.screenRecording else { return tr("꺼져 있어 스크린샷과 화면 카드를 만들지 못해요.") }
        return state.status.accessibility ? tr("스크린샷을 남기고, 글자를 읽을 수 없는 화면은 OCR로 읽어요.")
                                          : tr("맨 앞 창을 찍고 글자를 OCR로 읽어요. 비공개 창을 가릴 수 없어 브라우저는 찍지 않아요.")
    }

    /// 권한 하나를 한눈에: 이름, 허용 상태(아이콘과 글), 하는 일 또는 꺼졌을 때 못 하는 일, 허용 단추
    private func permissionTile(_ title: String, icon: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        let color = granted ? ActivityLogView.okColor : ActivityLogView.failColor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Brand.ink).frame(width: 18)
                Text(title).font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                Spacer(minLength: 4)
                Label(granted ? tr("허용됨") : tr("꺼짐"), systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(Brand.suit(11, .semibold)).foregroundStyle(color)
            }
            Text(detail).font(Brand.suit(11)).foregroundStyle(Brand.tabText).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            Spacer(minLength: 12)
            if !granted { Button(tr("허용하기"), action: request).buttonStyle(BrandButtonStyle()) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(granted ? Brand.paper : ActivityLogView.failColor.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(granted ? Brand.line : ActivityLogView.failColor.opacity(0.25)))
    }

    private var collection: some View {
        SettingTiles {
            SettingTile(tr("화면 텍스트"), detail: tr("보고 있는 창의 글자"), icon: "textformat") {
                Toggle("", isOn: $state.settings.captureText).toggleStyle(BrandSwitchStyle())
            }
            SettingTile(tr("다운로드한 파일"), detail: tr("파일 이름과 받은 주소"), icon: "arrow.down.circle") {
                Toggle("", isOn: $state.settings.watchDownloads).toggleStyle(BrandSwitchStyle())
            }
            SettingTile(tr("스크린샷"), detail: tr("맨 앞 창 이미지"), icon: "camera") {
                Toggle("", isOn: $state.settings.captureScreenshots).toggleStyle(BrandSwitchStyle())
            }
            SettingTile(tr("AI 코딩 도구 대화"), detail: tr("Claude Code, Codex에 쓴 메시지"), icon: "terminal") {
                Toggle("", isOn: $state.settings.readChatLogs).toggleStyle(BrandSwitchStyle())
            }
            SettingTile(tr("화면 요약"), detail: tr("AI가 스크린샷을 한두 줄로 정리"), icon: "text.below.photo") {
                Toggle("", isOn: $state.settings.screenCards).toggleStyle(BrandSwitchStyle())
                    .disabled(!state.settings.captureScreenshots)
            }
            .help(tr("스크린샷이 켜져 있어야 해요."))
            SettingTile(tr("기록하지 않을 앱"), detail: tr("\(state.settings.excludedBundles.count)개 앱은 사용 시간만 남겨요"), icon: "eye.slash") {
                Button(tr("편집")) { editingExcluded = true }.buttonStyle(BrandButtonStyle(kind: .primary))
            }
        }
    }

    private var organizing: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingTiles {
                SettingTile(tr("자동 업무 분류"), detail: tr("5분마다 AI가 기록을 업무로 나눠요"), icon: "clock.arrow.circlepath") {
                    Toggle("", isOn: $state.settings.batchEnabled).toggleStyle(BrandSwitchStyle())
                }
                SettingTile(tr("비슷한 업무 합치기"),
                            detail: state.reviewProposals.isEmpty ? tr("하루 한 번 찾아서 물어봐요") : tr("대기 중인 제안 \(state.reviewProposals.count)개"),
                            icon: "arrow.triangle.merge") {
                    if state.reviewRunning { ProgressView().controlSize(.small) }
                    if !state.reviewProposals.isEmpty { Button(tr("제안 보기")) { state.reviewSheetOpen = true }.buttonStyle(BrandButtonStyle()) }
                    Button(state.reviewRunning ? tr("찾는 중…") : tr("지금 찾기")) { Task { await state.runReview(); if !state.reviewProposals.isEmpty { state.reviewSheetOpen = true } } }
                        .buttonStyle(BrandButtonStyle(kind: .primary)).disabled(state.reviewRunning)
                }
            }
            InfoLine(tr("자동 분류를 꺼도 ‘지금 정리’를 누르면 기록이 전송돼요."))
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = tr("자동 실행을 바꾸지 못했어요. build/SILLOG.app으로 실행했는지 확인해 주세요. (\(error.localizedDescription))")
        }
    }

    // MARK: AI 연결

    private var aiConnection: some View { ConnectionSection() }
}

// MARK: AI 연결 한 구역 (Figma ST-03, 08, 09, 10, 27, 37)

/// 알약 하나. 고른 것은 바탕 #EAE3DC에 1pt 테두리 #CCBEB3와 글자 #3D2F27 medium, 안 고른 것은 바탕 #F3F1EF와 글자 #4A4541.
/// 진한 갈색 채움 알약은 쓰지 않는다. 테두리는 선 대신 채움 두 겹(바깥 테두리색, 안쪽 바탕색)으로 그린다: 같은 모양이고 화면 캡처 때 끝이 지저분해지지 않는다.
private struct SettingPill<Content: View>: View {
    let on: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .font(Brand.suit(11, on ? .medium : .regular))
                .foregroundStyle(on ? Color(hex: 0x3D2F27) : Brand.tabText)
                .padding(.horizontal, 14).frame(height: 28)
                .background {
                    ZStack {
                        Capsule().fill(on ? Color(hex: 0xCCBEB3) : Color(hex: 0xF3F1EF))
                        if on { Capsule().inset(by: 1).fill(Brand.badgeFill) }
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

/// Jev 로고 (Resources/Brand/jev.png). Brand 의 그림 불러오기와 같은 방식이고, 그림을 못 찾으면 아무것도 그리지 않는다
private struct SettingJevLogo: View {
    let size: CGFloat
    private static let image: NSImage? = {
        let url = BundledResources.url(forResource: "jev", withExtension: "png", subdirectory: "Brand", main: .main) { .module }
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size).clipShape(Circle())
        }
    }
}

/// 연결 확인 결과: 확인 중은 회색, 성공은 초록 체크, 실패는 빨간 오류 표시.
private struct SettingCheckStatus: View {
    let result: CheckResult?
    let action: () -> Void

    private var testing: Bool { result == .checking }

    var body: some View {
        HStack(spacing: 14) {
            if let result {
                HStack(spacing: 6) {
                    if !testing { Image(systemName: result.isOK ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 13)) }
                    Text(result.message).font(Brand.suit(11)).lineLimit(3).multilineTextAlignment(.trailing).textSelection(.enabled)
                }.foregroundStyle(testing ? Brand.gray : result.isOK ? Color(hex: 0x2D8053) : Color(hex: 0xC9452E))
            } else {
                Text(tr("확인 전")).font(Brand.suit(11)).foregroundStyle(Brand.gray)
            }
            if testing { ProgressView().controlSize(.small) }
            Button(action: action) { Text(tr("연결 확인")).font(Brand.suit(12, .medium)) }   // Figma 단추 글자는 12
                .buttonStyle(BrandButtonStyle(kind: .primary)).disabled(testing)
        }
    }
}

private struct ModelDropdown: View {
    @Binding var selection: String
    let models: [(String, String)]
    var directEntry = false

    private var choices: [(String, String)] {
        guard !selection.isEmpty, !models.contains(where: { $0.0 == selection }) else { return models }
        return [(selection, tr("\(selection) (목록에 없음)"))] + models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !models.isEmpty { BrandMenu(selection: $selection, options: choices, width: 260) }
            if models.isEmpty || directEntry {
                BrandInput(text: $selection, placeholder: tr("모델 이름 직접 입력"), width: 260, height: 34)
            }
        }
    }
}

/// AI settings: the four connections as tiles, then which connection and model each role uses.
private struct ConnectionSection: View {
    @EnvironmentObject private var state: AppState
    @State private var apiModels: [String] = []
    @State private var judgeAPIModels: [String] = []
    @State private var choiceChecks: [AppSettings.JudgeChoice: CheckResult] = [:]
    @State private var panel: Panel?
    @FocusState private var focusedKey: AppSettings.JudgeChoice?

    /// The connection whose address or key fields are open under the tiles.
    private enum Panel { case api, jev, decisions }

    /// Organize and chat share one API server; writing its address or key also writes the chat copy.
    private func shared(_ main: WritableKeyPath<AppSettings, String>, _ chat: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(get: { state.settings[keyPath: main] },
                set: { state.settings[keyPath: main] = $0; state.settings[keyPath: chat] = $0 })
    }

    private var judgeChoice: Binding<String> {
        Binding(get: { state.settings.judgeChoice.rawValue },
                set: { state.settings.judgeChoice = AppSettings.JudgeChoice(rawValue: $0) ?? .codex })
    }

    private func chatUses(_ provider: String) -> Bool { state.settings.effectiveChatProvider == provider }

    /// One status per connection: its own check, then the chat check when chat also runs on it.
    private func check(_ provider: String) -> CheckResult? {
        guard let main = state.connectionChecks[provider] else { return nil }
        if main == .checking || (chatUses(provider) && state.chatTesting) { return .checking }
        if main.isOK, chatUses(provider), let chat = state.chatTestResult, !chat.isOK { return chat }
        return main
    }

    private func runCheck(_ provider: String) {
        Task {
            await state.testConnection(provider)
            if chatUses(provider) { await state.testChatLLM() }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("연결"))
            SettingTiles {
                codexTile
                connectionTile(tr("API 서버"), detail: tr("OpenAI 호환 서버"), ready: false, open: .api, closed: tr("설정"))
                connectionTile("Jev", detail: tr("판단 모델 전용"), ready: !state.settings.jevAPIKey.isEmpty, open: .jev, closed: tr("키 입력"))
                connectionTile("OpenAI Decisions", detail: tr("판단 모델 전용"), ready: !state.settings.decisionsAPIKey.isEmpty, open: .decisions, closed: tr("키 입력"))
            }
            codexExtras
            switch panel {
            case .api: SettingCard { apiRows }
            case .jev: choiceKeyRow(.jev)
            case .decisions: choiceKeyRow(.decisions)
            case nil: EmptyView()
            }
            SectionLabel(tr("모델"))
            VStack(spacing: 8) { organizeRow; chatRow; judgeRow }
            Text(tr("기록은 Mac에 저장되고, 정리와 채팅을 쓸 때 창 제목, 주소, 화면 텍스트 일부, 질문, 새 파일 정보가 연결한 AI 계정으로 전송돼요. 연결 확인은 개인 자료 없이 시험 호출만 하고, 모델 사용량이 소량 발생해요."))
                .font(Brand.suit(11)).foregroundStyle(Brand.gray).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4).padding(.top, 14)
        }
        .onAppear(perform: splitChat)
        .onChange(of: state.settings.jevAPIKey) { _, _ in choiceChecks[.jev] = nil }
        .onChange(of: state.settings.decisionsAPIKey) { _, _ in choiceChecks[.decisions] = nil }
        // Picking a connection that still needs an address or key opens its fields.
        .onChange(of: state.settings.judgeChoice) { _, choice in
            if choice == .api { panel = .api }
            if choice == .jev, state.settings.jevAPIKey.isEmpty { panel = .jev }
            if choice == .decisions, state.settings.decisionsAPIKey.isEmpty { panel = .decisions }
        }
        .onChange(of: [state.settings.llmProvider, state.settings.chatProvider]) { _, used in if used.contains("openai") { panel = .api } }
        .task(id: [state.settings.llmProvider, state.settings.chatProvider, state.settings.judgeChoice.rawValue, state.settings.llmBaseURL, state.settings.llmAPIKey]) {
            let s = state.settings
            let used = s.llmProvider == "openai" || s.chatProvider == "openai" || s.judgeChoice == .api
            apiModels = await availableAPIModels(enabled: used, address: s.llmBaseURL, key: s.llmAPIKey)
        }
        .task(id: [state.settings.judgeChoice.rawValue, state.settings.judgeBaseURL, state.settings.judgeAPIKey]) {
            let settings = state.settings
            judgeAPIModels = await availableAPIModels(enabled: settings.judgeChoice == .customAPI, address: settings.judgeBaseURL, key: settings.judgeAPIKey)
        }
    }

    private func splitChat() {
        var s = state.settings
        s.splitChatFromOrganize()
        if s != state.settings { state.settings = s }
    }

    // MARK: 줄 틀

    /// 키가 큰 줄(Jev 키): 제목은 왼쪽 위 slot 높이 칸 안에 가운데, 조작 요소는 오른쪽 column 폭 칸 안에 오른쪽 맞춤.
    private func tallRow<Content: View>(_ title: String, sub: String? = nil, slot: CGFloat = 28, top: CGFloat = 20, bottom: CGFloat = 11,
                                        column: CGFloat? = 460, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: -3) {
                Text(title).font(Brand.suit(13)).foregroundStyle(Brand.ink).frame(height: slot)
                if let sub { Text(sub).font(Brand.suit(11)).foregroundStyle(Brand.gray).frame(height: 13).offset(y: 1) }
            }
            Spacer(minLength: 16)
            if let column { content().frame(width: column, alignment: .trailing) } else { content() }
        }
        .padding(.top, top).padding(.bottom, bottom)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }

    /// "키 받기 ↗": 키를 만드는 사이트를 연다
    private func keyLink(_ site: URL, help: String) -> some View {
        Button { NSWorkspace.shared.open(site) } label: {
            HStack(spacing: 3) { Text(tr("키 받기")); Image(systemName: "arrow.up.right").font(.system(size: 8)) }
        }.buttonStyle(BrandButtonStyle()).help(help).fixedSize()
    }

    private func okLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").font(Brand.suit(11, .semibold)).foregroundStyle(ActivityLogView.okColor)
    }

    // MARK: 연결

    /// ChatGPT subscription: plan and remaining usage when logged in, a login button otherwise.
    @ViewBuilder private var codexTile: some View {
        switch state.codexStatus {
        case .loggedIn(let email, let plan, _):
            let windows = [state.codexUsage?.primary, state.codexUsage?.secondary].compactMap { $0 }
            let parts = [plan] + windows.map { tr("\($0.label) \(Int($0.remainingPercent.rounded()))% 남음") }
            SettingTile(tr("ChatGPT 구독"), detail: parts.compactMap { $0 }.joined(separator: " · ")) {
                switch check("codex") {
                case .checking: ProgressView().controlSize(.small)
                case .failed: Label(tr("확인 실패"), systemImage: "xmark.circle.fill").font(Brand.suit(11, .semibold)).foregroundStyle(ActivityLogView.failColor)
                default: okLabel(tr("연결됨"))
                }
                Menu {
                    Button(tr("연결 확인")) { runCheck("codex") }
                    if state.codexModelsLoading { Button(tr("모델 검사 중단")) { state.cancelCodexModelLoading() } }
                    else { Button(tr("모델 다시 확인")) { Task { await state.loadCodexModels(force: true) } } }
                    Button(tr("사용량 자세히 보기")) { NSWorkspace.shared.open(CodexResponsesClient.usagePage) }
                    Divider()
                    Button(tr("로그아웃")) { state.logoutCodex() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(Brand.tabText).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(tr("더 보기"))
            }
            .help(email ?? "")
        case .loggedOut:
            SettingTile(tr("ChatGPT 구독"), detail: tr("로그인하면 정리와 채팅을 쓸 수 있어요")) {
                if state.deviceCode == nil {
                    Button(tr("ChatGPT 로그인")) { state.startCodexLogin() }.buttonStyle(BrandButtonStyle(kind: .primary))
                }
            }
        }
    }

    /// A connection that needs an address or key: the button opens its fields under the tiles.
    private func connectionTile(_ title: String, detail: String, ready: Bool, open target: Panel, closed: String) -> some View {
        SettingTile(title, detail: detail) {
            if ready { okLabel(tr("키 있음")) }
            Button(panel == target ? tr("닫기") : closed) { panel = panel == target ? nil : target }
                .buttonStyle(BrandButtonStyle(kind: .primary))
        }
    }

    @ViewBuilder private var apiRows: some View {
        SettingRow(tr("API 서버 주소"), detail: tr("OpenAI 호환 서버 주소예요."), top: 16, bottom: 7) {
            BrandInput(text: shared(\.llmBaseURL, \.chatBaseURL), placeholder: "http://localhost:5010/v1", width: 460)
        }
        SettingRow(tr("API 서버 키"), detail: tr("없으면 비워 둬요."), top: 16, bottom: 7) {
            BrandInput(text: shared(\.llmAPIKey, \.chatAPIKey), placeholder: "", width: 460, secure: true)
        }
        SettingRow(tr("API 서버 연결"), top: 16, bottom: 7) { SettingCheckStatus(result: check("openai"), action: { runCheck("openai") }) }
    }

    /// Under the tiles: device code, the last check's full message, errors.
    @ViewBuilder private var codexExtras: some View {
        if case .loggedOut = state.codexStatus, let code = state.deviceCode { deviceCodeRows(code) }
        if case .loggedIn = state.codexStatus, let modelsError = state.codexModelsError { resultLine(modelsError) }
        if case .loggedIn = state.codexStatus, let result = check("codex"), result != .checking { resultLine(result.message) }
        if let message = state.codexMessage { resultLine(message) }
    }

    private func deviceCodeRows(_ code: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("열린 브라우저에 이 코드를 입력해 주세요")).font(Brand.suit(12, .medium)).foregroundStyle(Brand.text)
                .padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("기기 코드")).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                Text(code.userCode).font(Brand.jost(28)).tracking(1.4).foregroundStyle(Brand.ink).textSelection(.enabled)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
            HStack(spacing: 10) {
                Button(tr("코드 복사")) { state.copyDeviceCode() }.buttonStyle(BrandButtonStyle())
                Button(tr("브라우저 다시 열기")) { NSWorkspace.shared.open(code.verificationURL) }.buttonStyle(BrandButtonStyle())
                Button(tr("취소")) { state.cancelCodexLogin() }.buttonStyle(BrandButtonStyle())
                ProgressView().controlSize(.small)
            }
            .padding(.top, 14)
            Text(tr("코드는 복사돼 있어요. 브라우저에 붙여 넣으세요.")).font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(.top, 10).padding(.bottom, 14)
        }
    }

    private func resultLine(_ text: String) -> some View {
        Text(text).font(Brand.suit(11)).foregroundStyle(Brand.text).textSelection(.enabled).padding(.horizontal, 4).padding(.top, 10)
    }

    // MARK: 모델

    private static let connections = [("codex", tr("ChatGPT 구독")), ("openai", tr("API 서버"))]

    /// One role: what it does on the left, its connection and then its model on the right.
    private func modelRow<Content: View>(_ title: String, _ detail: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        SettingTile(title, detail: detail) { HStack(alignment: .top, spacing: 8) { content() } }
    }

    private var organizeRow: some View {
        modelRow(tr("정리 모델"), tr("업무에 이름과 요약을 붙여요")) {
            BrandMenu(selection: $state.settings.llmProvider, options: Self.connections, width: 150)
            modelList(state.settings.llmProvider, codex: $state.settings.codexModel, openAI: $state.settings.llmModel, codexModels: state.codexModels)
        }
    }

    private var chatRow: some View {
        modelRow(tr("채팅 모델"), tr("채팅에서 질문에 답해요")) {
            BrandMenu(selection: $state.settings.chatProvider, options: Self.connections, width: 150)
            modelList(state.settings.chatProvider, codex: $state.settings.chatCodexModel, openAI: $state.settings.chatModel,
                      codexModels: state.chatCodexModels.isEmpty ? state.codexModels : state.chatCodexModels)
        }
    }

    private var judgeRow: some View {
        modelRow(tr("판단 모델"), tr("기록이 어느 업무인지 골라요")) {
            BrandMenu(selection: judgeChoice, options: [("codex", tr("ChatGPT 구독")), ("api", tr("API 서버")), ("customAPI", tr("다른 API 서버")),
                                                         ("jev", "Jev"), ("decisions", "OpenAI Decisions")], width: 150)
            switch state.settings.judgeChoice {
            case .codex: codexModelField($state.settings.judgeCodexModel, state.codexModels)
            case .api: ModelDropdown(selection: $state.settings.judgeAPIModel, models: apiModels.map { ($0, $0) }, directEntry: true)
            case .customAPI:
                VStack(alignment: .leading, spacing: 8) {
                    BrandInput(text: $state.settings.judgeBaseURL, placeholder: tr("판단 API 주소"), width: 260)
                    BrandInput(text: $state.settings.judgeAPIKey, placeholder: tr("판단 API 키"), width: 260, secure: true)
                    ModelDropdown(selection: $state.settings.judgeAPIModel, models: judgeAPIModels.map { ($0, $0) }, directEntry: true)
                }
            case .jev, .decisions: EmptyView()
            }
        }
    }

    private func availableAPIModels(enabled: Bool, address: String, key: String) async -> [String] {
        guard enabled, !state.isPreview,
              let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return [] }
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            return try await OpenAICompatClient(baseURL: url, model: "", apiKey: key).availableModels()
        } catch { return [] }
    }

    private func choiceKey(_ kind: AppSettings.JudgeChoice) -> Binding<String> {
        kind == .jev ? $state.settings.jevAPIKey : $state.settings.decisionsAPIKey
    }

    /// Key row for a choice-only judge: key link, key field, and a check once a key is in.
    private func choiceKeyRow(_ kind: AppSettings.JudgeChoice) -> some View {
        let jev = kind == .jev
        return tallRow(jev ? tr("Jev API 키") : tr("OpenAI API 키"), sub: jev ? nil : tr("OpenAI Decisions에 써요"), slot: 36, top: 16, bottom: 7, column: nil) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    keyLink(jev ? AppSettings.jevSite : AppSettings.openAIKeySite, help: jev ? tr("Jev 사이트에서 키를 만들어요") : tr("OpenAI 사이트에서 키를 만들어요"))
                    HStack(spacing: 8) {
                        if jev { SettingJevLogo(size: 16) }
                        SecureField("", text: choiceKey(kind), prompt: Text(jev ? tr("Jev 사이트에서 받은 키를 붙여 넣어요") : tr("OpenAI에서 받은 키를 붙여 넣어요")).foregroundStyle(Color(hex: 0x9E9994)))
                            .textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
                            .focused($focusedKey, equals: kind)
                    }
                    .settingField()
                    .frame(width: 460)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedKey = kind }
                }
                if !choiceKey(kind).wrappedValue.isEmpty {
                    SettingCheckStatus(result: choiceChecks[kind], action: { checkChoice(kind) })
                }
            }
        }
    }

    /// Sends one small question with no personal data. A result for a key that has since changed is dropped.
    private func checkChoice(_ kind: AppSettings.JudgeChoice) {
        let key = choiceKey(kind).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        choiceChecks[kind] = .checking
        Task {
            var result = CheckResult.ok(tr("연결됨"))
            do {
                if kind == .jev { try await JevClient(endpoint: JevEndpoint(url: JevEndpoint.typesafeURL, model: JevEndpoint.defaultModel, key: key)).verify() }
                else { try await DecisionsClient(key: key).verify() }
            } catch { result = .failed(error.localizedDescription) }
            choiceChecks[kind] = choiceKey(kind).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) == key ? result : nil
        }
    }

    /// Model menu for a role on the given connection.
    @ViewBuilder private func modelList(_ provider: String, codex: Binding<String>, openAI: Binding<String>, codexModels: [CodexModel]) -> some View {
        switch provider {
        case "openai": ModelDropdown(selection: openAI, models: apiModels.map { ($0, $0) }, directEntry: true)
        default: codexModelField(codex, codexModels)
        }
    }

    /// ChatGPT 모델을 불러오는 동안에는 현재 상태를 안내한다.
    @ViewBuilder private func codexModelField(_ selection: Binding<String>, _ models: [CodexModel]) -> some View {
        if state.codexModelsLoading {
            HStack(spacing: 8) {
                Text(tr("불러오는 중…")).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                ProgressView().controlSize(.mini)
            }.frame(width: 260, height: 36)
        } else {
            ModelDropdown(selection: selection, models: models.map { ($0.slug, $0.displayName) })
        }
    }
}

// MARK: 설정 전용 부품 (공용 부품으로 옮기면 좋음)

/// 설정 묶음: 바탕 상자 없이 줄과 선만 (미니멀)
struct SettingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
    }
}

/// 설정 한 줄: 왼쪽 아이콘(있으면)과 제목, 오른쪽 조작 요소, 아래 구분선 (설명은 말풍선으로만)
/// top, bottom: 위아래 여백. 기본 10, AI 연결 탭은 Figma 대로 위 16, 아래 7(구분선 1pt 포함)
struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String?
    var icon: String? = nil                      // SF 기호 이름, 또는 앱 아이콘 같은 이미지(iconImage)
    var iconImage: NSImage? = nil
    var top: CGFloat = 10
    var bottom: CGFloat = 10
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, detail: String? = nil, icon: String? = nil, iconImage: NSImage? = nil,
         top: CGFloat = 10, bottom: CGFloat = 10, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.detail = detail; self.icon = icon; self.iconImage = iconImage
        self.top = top; self.bottom = bottom; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 16) {
            if let iconImage {
                Image(nsImage: iconImage).resizable().frame(width: 18, height: 18)
            } else if let icon {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Brand.tabText).frame(width: 18)
            }
            // Figma 설정 줄에는 설명이 없다: 회색 설명 글은 그리지 않고 마우스를 올리면 말풍선으로만 보인다
            Text(title).font(Brand.suit(13)).foregroundStyle(Brand.ink)
                .help(detail ?? "")
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.top, top).padding(.bottom, bottom)
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
    }
}

/// 묶음 위 구역 제목: 작은 회색 글씨. 기본은 위 26, 좌우 4, 아래 8. AI 연결 탭은 왼쪽 선에 맞추려 좌우 0, 고정 높이 12로 쓴다
struct SectionLabel: View {
    let text: String
    var top: CGFloat = 26
    var inset: CGFloat = 4
    var bottom: CGFloat = 8
    var height: CGFloat? = nil
    init(_ text: String, top: CGFloat = 26, inset: CGFloat = 4, bottom: CGFloat = 8, height: CGFloat? = nil) {
        self.text = text; self.top = top; self.inset = inset; self.bottom = bottom; self.height = height
    }
    var body: some View {
        Text(text).font(Brand.suit(11, .medium)).foregroundStyle(Brand.gray)
            .frame(height: height).padding(.horizontal, inset).padding(.top, top).padding(.bottom, bottom)
    }
}

/// 회색 안내 줄
struct InfoLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.horizontal, 4).padding(.vertical, 10)
    }
}

/// 회색 안내 글 (Codex 필요 안내)
struct NoteBox: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.suit(11)).foregroundStyle(Brand.gray).padding(.vertical, 6)
    }
}

/// 회색 상태 배지 (허용 안 됨, 예정)
struct GrayBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Brand.suit(10, .medium)).foregroundStyle(Brand.gray)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Brand.paper))
    }
}

/// On/off switch in the brand brown, so it does not read as the check mark used for status.
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Color(hex: 0x86756B) : Color(hex: 0xD6D1CC))
                .frame(width: 36, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(.white).padding(2) }
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? tr("켜짐") : tr("꺼짐"))
    }
}

/// One setting on a bordered tile: icon, title over a one-line description, control on the right.
struct SettingTile<Trailing: View>: View {
    let title: String
    let detail: String?
    let icon: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, detail: String? = nil, icon: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.detail = detail; self.icon = icon; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon { Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Brand.tabText).frame(width: 20) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Brand.suit(13)).foregroundStyle(Brand.ink)
                if let detail { Text(detail).font(Brand.suit(11)).foregroundStyle(Brand.gray).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.line))
    }
}

/// Tiles in equal columns.
struct SettingTiles<Content: View>: View {
    var columns = 2
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8, content: content)
    }
}

/// Sheet for a setting's longer list: title, close, scrolling content.
struct SettingSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(Brand.suit(16, .bold)).foregroundStyle(Brand.ink)
                Spacer()
                Button(tr("닫기")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(BrandButtonStyle(kind: .primary))
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            Rectangle().fill(Brand.line).frame(height: 1)
            ScrollView {
                content().padding(.horizontal, 28).padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 560)
        .background(.white)
    }
}

extension View {
    /// 설정의 입력칸과 고르기 칸: 밑줄 대신 연한 바탕 칸 (Figma ST-03). 안쪽 여백 좌우 12, 둥글기 8, 기본 높이 36.
    /// 밑줄은 아래 줄 구분선과 겹쳐 두 줄로 보였다
    func settingField(height: CGFloat = 36) -> some View {
        padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF5F2EE)))
    }
}

/// 연결 방식, 모델 선택 상자: 연한 바탕 칸에 고른 값과 아래 화살표
struct BrandMenu: View {
    @Binding var selection: String
    let options: [(String, String)]
    let width: CGFloat

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { selection = option.0 }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == selection }?.1 ?? selection).font(Brand.suit(12)).foregroundStyle(Brand.text).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(Brand.tabText)
            }
            .settingField()
            .frame(width: width)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// 한 줄 입력칸: 연한 바탕 칸 어디를 눌러도 글자 입력이 시작된다
struct BrandInput: View {
    @Binding var text: String
    let placeholder: String
    let width: CGFloat
    var secure = false
    var height: CGFloat = 36
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(Brand.sub))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Brand.sub))
            }
        }
        .textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
        .focused($focused)
        .settingField(height: height)
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
