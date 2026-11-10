import AppKit
import ServiceManagement
import SwiftUI
import WorkGraphCollectors
import WorkGraphCore

/// 설정 탭: 위쪽 글자 탭(일반, AI 연결, 활동 로그)과 그 아래 한 쪽. 일반은 권한, 수집, 개인정보와 저장 공간, 앱 실행을 한 쪽에 잇는다. Figma ST-01~06, ST-W1~W8.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @State private var launchAtLogin = false
    @State private var launchStatusLoaded = false
    @State private var launchError: String?

    enum Section: String, CaseIterable, Identifiable {
        case general = "일반"                            // 권한, 수집, 개인정보와 저장 공간, 앱 실행
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
                        .padding(.horizontal, state.settingsSection == .ai ? 64 : 34)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.white)
            }
        }
        .onChange(of: state.settings) { _, _ in state.applySettings() }
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

    /// 일반: 예전 권한, 수집, 개인정보와 저장 공간, 일반 네 구역을 한 쪽에 잇는다
    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("권한"); permissions
            SectionLabel("수집"); collection
            privacy
            SectionLabel("앱 실행"); appLaunch
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
            permissionTile(Permissions.accessibilityName, icon: "hand.raised",
                           detail: accessibilityDetail,
                           granted: state.status.accessibility) {
                _ = Permissions.accessibility(prompt: true)
                Permissions.openSettings(.accessibility)
            }
            permissionTile("화면 기록", icon: "camera.viewfinder",
                           detail: screenRecordingDetail,
                           granted: state.status.screenRecording) {
                Permissions.requestScreenRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Permissions.openSettings(.screenRecording) }
            }
            permissionTile("알림", icon: "bell", detail: "파일 정리 제안을 알려요. 꺼져 있어도 파일 구역에서 볼 수 있어요.", granted: !state.notificationsDenied) {
                SuggestionNotifier.openSystemSettings()
            }
            if AppFeatures.calendarOn {
                permissionTile("캘린더", icon: "calendar",
                               detail: calendar.granted ? "오늘 일정을 보여 줘요. 등록할 캘린더: \(calendar.target.map { "\($0.title) · \($0.account)" } ?? CalendarService.calendarName) (캘린더 탭에서 바꿔요)" : "꺼져 있어 오늘 일정을 못 보여 주고 일정을 등록하지 못해요.",
                               granted: calendar.granted) {
                    Task { await calendar.requestAccess() }
                }
            }
            }
            .padding(.top, 4)
            InfoLine("화면 기록은 허용한 뒤 앱을 다시 실행해 주세요.")
        }
    }

    /// 두 권한의 조합마다 실제로 남는 것을 적는다
    private var accessibilityDetail: String {
        if state.status.accessibility { return "창 제목, 주소, 문서 경로, 화면 텍스트를 읽어요." }
        return state.status.screenRecording ? "꺼져 있어 창 제목·주소·문서 경로는 남지 않아요. 화면 글자는 스크린샷에서 OCR로 읽어요."
                                            : "꺼져 있어 지금은 앱 이름만 기록하고 있어요."
    }

    private var screenRecordingDetail: String {
        guard state.status.screenRecording else { return "꺼져 있어 스크린샷과 화면 카드를 만들지 못해요." }
        return state.status.accessibility ? "스크린샷을 남기고, 글자를 읽을 수 없는 화면은 OCR로 읽어요."
                                          : "맨 앞 창을 찍고 글자를 OCR로 읽어요. 비공개 창을 가릴 수 없어 브라우저는 찍지 않아요."
    }

    /// 권한 하나를 한눈에: 이름, 허용 상태(아이콘과 글), 하는 일 또는 꺼졌을 때 못 하는 일, 허용 단추
    private func permissionTile(_ title: String, icon: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        let color = granted ? ActivityLogView.okColor : ActivityLogView.failColor
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Brand.ink).frame(width: 18)
                Text(title).font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                Spacer(minLength: 4)
                Label(granted ? "허용됨" : "꺼짐", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(Brand.suit(11, .semibold)).foregroundStyle(color)
            }
            Text(detail).font(Brand.suit(11)).foregroundStyle(Brand.tabText).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            Spacer(minLength: 12)
            if !granted { Button("허용하기", action: request).buttonStyle(BrandButtonStyle()) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(granted ? Brand.paper : ActivityLogView.failColor.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(granted ? Brand.line : ActivityLogView.failColor.opacity(0.25)))
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingCard {
            SettingRow("화면 텍스트 읽기", detail: "텍스트가 부족하면 OCR로 보충해요.") {
                Toggle("", isOn: $state.settings.captureText).toggleStyle(BrandSwitchStyle())
            }
            SettingRow("스크린샷 저장", detail: "활성 창만 저장해요. 끄면 화면 내용 기록도 꺼져요.") {
                Toggle("", isOn: $state.settings.captureScreenshots).toggleStyle(BrandSwitchStyle())
            }
            SettingRow("화면 내용 기록", detail: "대표 화면 이미지를 AI로 보내 화면 기억 카드를 만들어요.") {
                Toggle("", isOn: $state.settings.screenCards).toggleStyle(BrandSwitchStyle())
                    .disabled(!state.settings.captureScreenshots)
            }
            SettingRow("다운로드 폴더 새 파일 기록", detail: "다운로드 파일과 출처 URL을 기록해요.") {
                Toggle("", isOn: $state.settings.watchDownloads).toggleStyle(BrandSwitchStyle())
            }
            SettingRow("AI 코딩 도구 대화 읽기", detail: "Claude Code와 Codex CLI에 입력한 메시지를 읽어요.") {
                Toggle("", isOn: $state.settings.readChatLogs).toggleStyle(BrandSwitchStyle())
            }
            SettingRow("5분마다 자동으로 정리", detail: "쌓인 기록을 연결한 AI 계정으로 보내 업무를 정리해요.") {
                Toggle("", isOn: $state.settings.batchEnabled).toggleStyle(BrandSwitchStyle())
            }
            }
            InfoLine("자동 정리를 꺼도 ‘지금 정리’를 누르면 기록이 전송돼요.")
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExcludedAppsView()
            StorageSettingsView()
            SectionLabel("저장 위치")
            SettingCard {
                SettingRow("기록 폴더", detail: state.databasePath) {
                    Button("Finder에서 보기") { state.revealDataFolder() }.buttonStyle(BrandButtonStyle())
                }
            }
        }
    }

    private var appLaunch: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingCard {
            SettingRow("Dock 아이콘 표시", detail: "Dock에 SILLOG를 표시해요.") {
                Toggle("", isOn: $state.settings.showDockIcon).toggleStyle(BrandSwitchStyle())
            }
            SettingRow("로그인 시 자동 실행", detail: "Mac에 로그인하면 메뉴 막대에서 시작해요.") {
                Toggle("", isOn: $launchAtLogin).toggleStyle(BrandSwitchStyle())
                    .disabled(!launchStatusLoaded)
                    .onChange(of: launchAtLogin) { _, enabled in if launchStatusLoaded { setLaunchAtLogin(enabled) } }
            }
            }
            if let launchError {
                Text(launchError).font(Brand.suit(11)).foregroundStyle(Brand.text).padding(.vertical, 12)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "자동 실행을 바꾸지 못했어요. build/Sillog.app으로 실행했는지 확인해 주세요. (\(error.localizedDescription))"
        }
    }

    // MARK: AI 연결

    /// 연결 구역 하나: 채팅도 같은 연결 방식, 주소, 키를 쓴다. 저장 키는 그대로 두고, 값을 바꿀 때 채팅 쪽에도 같이 적는다.
    private func chatBinding(_ main: WritableKeyPath<AppSettings, String>, _ chat: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(get: { state.settings[keyPath: main] },
                set: { state.settings[keyPath: main] = $0; state.settings[keyPath: chat] = $0 })
    }

    /// '정리 모델과 같이' 고르기. 같이에서 따로로 바꾸는 순간에는 지금 쓰던 정리 모델을 채팅 모델 칸에 채워 채팅 모델이 갑자기 바뀌지 않게 한다.
    /// 채팅 연결 방식(chatProvider)은 늘 정리와 같게 맞춘다.
    private var chatSameBinding: Binding<Bool> {
        Binding(get: { state.settings.chatSameAsOrganize },
                set: { same in
                    if !same, state.settings.chatSameAsOrganize {
                        state.settings.chatCodexModel = state.settings.codexModel
                        state.settings.chatModel = state.settings.llmModel
                    }
                    state.settings.chatSameAsOrganize = same
                    state.settings.chatProvider = state.settings.llmProvider
                })
    }

    private var aiConnection: some View {
        ConnectionSection(
            provider: chatBinding(\.llmProvider, \.chatProvider),
            openAIModel: $state.settings.llmModel, chatOpenAIModel: $state.settings.chatModel,
            baseURL: chatBinding(\.llmBaseURL, \.chatBaseURL), apiKey: chatBinding(\.llmAPIKey, \.chatAPIKey),
            codexModel: $state.settings.codexModel, chatCodexModel: $state.settings.chatCodexModel,
            judge: $state.settings.judgeProvider, jevKey: $state.settings.jevAPIKey, chatSame: chatSameBinding,
            test: { Task { await state.testLLM(); await state.testChatLLM() } })
        .onAppear { unifyChat() }
    }

    /// 예전에 채팅만 다른 연결을 쓰던 저장값은 연결 구역 하나에 맞춘다 (모델과 저장된 다른 값은 그대로)
    private func unifyChat() {
        let c = state.settings
        if c.chatProvider != c.llmProvider { state.settings.chatProvider = c.llmProvider }
        if c.chatBaseURL != c.llmBaseURL { state.settings.chatBaseURL = c.llmBaseURL }
        if c.chatAPIKey != c.llmAPIKey { state.settings.chatAPIKey = c.llmAPIKey }
    }
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
    let result: String?
    let testing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if let result {
                let ok = result.hasPrefix("연결됨")
                HStack(spacing: 6) {
                    if !testing { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 13)) }
                    Text(result).font(Brand.suit(11)).lineLimit(3).multilineTextAlignment(.trailing).textSelection(.enabled)
                }.foregroundStyle(testing ? Brand.gray : ok ? Color(hex: 0x2D8053) : Color(hex: 0xC9452E))
            } else {
                Text("확인 전").font(Brand.suit(11)).foregroundStyle(Brand.gray)
            }
            if testing { ProgressView().controlSize(.small) }
            Button(action: action) { Text("연결 확인").font(Brand.suit(12, .medium)) }   // Figma 단추 글자는 12
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
        return [(selection, "\(selection) (목록에 없음)")] + models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !models.isEmpty { BrandMenu(selection: $selection, options: choices, width: 260) }
            if models.isEmpty || directEntry {
                BrandInput(text: $selection, placeholder: "모델 이름 직접 입력", width: 260, height: 34)
            }
        }
    }
}

private struct ConnectionSection: View {
    @EnvironmentObject private var state: AppState
    @Binding var provider: String
    @Binding var openAIModel: String
    @Binding var chatOpenAIModel: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var codexModel: String
    @Binding var chatCodexModel: String
    @Binding var judge: String
    @Binding var jevKey: String
    @Binding var chatSame: Bool
    let test: () -> Void
    @State private var jevResult: String?
    @State private var jevChecking = false
    @State private var apiModels: [String] = []
    @State private var judgeAPIModels: [String] = []
    @FocusState private var jevFocused: Bool

    private var testing: Bool { state.llmTestResult == "확인 중…" || state.chatTesting }

    /// 연결 상태 글: 정리 확인이 실패면 그것, 성공이면 채팅 확인이 실패인지 본다
    private var result: String? {
        guard let llm = state.llmTestResult else { return nil }
        if testing { return "확인 중…" }
        if !llm.hasPrefix("연결됨") { return llm }
        if let chat = state.chatTestResult, !chat.hasPrefix("연결됨") { return chat }
        return llm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("연결", top: 19, inset: 0, bottom: 0, height: 12)
            SettingCard {
                SettingRow("연결 방식", top: 16, bottom: 7) {
                    BrandMenu(selection: $provider, options: [("codex", "ChatGPT 구독"), ("openai", "API")], width: 190)
                }
                switch provider {
                case "openai": openAIRows
                default: codexRows
                }
            }
            if provider == "codex" { codexExtras }
            else if judge == "gpt", state.settings.judgeGPTProvider == "codex" {
                SettingCard { codexRows }
                codexExtras
            }
            SectionLabel("모델", top: 11, inset: 0, bottom: 0, height: 12)
            judgeRow
            if judge == "jev" { jevKeyRow }
            organizeRow
            chatRow
            Text("기록은 Mac에 저장되고, 정리와 채팅을 쓸 때 창 제목, 주소, 화면 텍스트 일부, 질문, 새 파일 정보가 연결한 AI 계정으로 전송돼요. 연결 확인은 개인 자료 없이 시험 호출만 하고, 모델 사용량이 소량 발생해요.")
                .font(Brand.suit(11)).foregroundStyle(Brand.gray).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .onChange(of: jevKey) { _, _ in jevResult = nil }
        .onChange(of: judge) { _, _ in jevResult = nil }
        .task(id: [provider, baseURL, apiKey]) {
            apiModels = await availableAPIModels(enabled: provider == "openai", address: baseURL, key: apiKey)
        }
        .task(id: [judge, state.settings.judgeGPTProvider, state.settings.judgeBaseURL, state.settings.judgeAPIKey]) {
            let settings = state.settings
            judgeAPIModels = await availableAPIModels(enabled: judge == "gpt" && settings.judgeGPTProvider == "openai",
                                                       address: settings.judgeBaseURL, key: settings.judgeAPIKey)
        }
    }

    // MARK: 줄 틀

    /// 키가 큰 줄(알약, 모델 목록, Jev 키): 제목은 왼쪽 위 slot 높이 칸 안에 가운데, 조작 요소는 오른쪽 column 폭 칸 안에 오른쪽 맞춤.
    /// 위 20, 아래 11(구분선 1pt 포함)이 모델 줄, 위 16, 아래 7이 키 줄이다. sub 는 제목 아래 작은 회색 글
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
            HStack(spacing: 3) { Text("키 받기"); Image(systemName: "arrow.up.right").font(.system(size: 8)) }
        }.buttonStyle(BrandButtonStyle()).help(help).fixedSize()
    }

    /// 연결 상태 줄: 결과 글과 연결 확인 단추 (키 줄 바로 아래)
    private var statusRow: some View {
        SettingRow("연결 상태", top: 16, bottom: 7) { SettingCheckStatus(result: result, testing: testing, action: test) }
    }

    // MARK: 연결 방식별 줄

    @ViewBuilder private var openAIRows: some View {
        SettingRow("서버 주소", top: 16, bottom: 7) { BrandInput(text: $baseURL, placeholder: "http://localhost:5010/v1", width: 460) }
        SettingRow("API 키", detail: "없으면 비워 둬요.", top: 16, bottom: 7) { BrandInput(text: $apiKey, placeholder: "", width: 460, secure: true) }
        statusRow
    }

    /// ChatGPT 구독: 로그인했으면 계정(연결 확인, 더 보기 메뉴)과 사용량. 로그인 전이면 로그인 단추 한 줄
    @ViewBuilder private var codexRows: some View {
        switch state.codexStatus {
        case .loggedIn(let email, let plan, _):
            SettingRow("ChatGPT 계정", detail: [email, plan.map { "\($0) 요금제로 연결됨" } ?? "연결됨"].compactMap { $0 }.joined(separator: ", "), top: 16, bottom: 7) {
                HStack(spacing: 14) {
                    SettingCheckStatus(result: result, testing: testing, action: test)
                    Menu {
                        if state.codexModelsLoading { Button("모델 검사 중단") { state.cancelCodexModelLoading() } }
                        else { Button("모델 다시 확인") { Task { await state.loadCodexModels(force: true) } } }
                        Button("사용량 자세히 보기") { NSWorkspace.shared.open(CodexResponsesClient.usagePage) }
                        Divider()
                        Button("로그아웃") { state.logoutCodex() }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(Brand.tabText).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("더 보기")
                }
            }
            if let usage = state.codexUsage {
                SettingRow("남은 사용량", top: 16, bottom: 7) {
                    HStack(spacing: 18) {
                        ForEach([usage.primary, usage.secondary].compactMap { $0 }, id: \.windowSeconds) { window in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(window.label).font(Brand.suit(10)).foregroundStyle(Brand.gray)
                                    Spacer(minLength: 6)
                                    Text("\(Int(window.remainingPercent.rounded()))%").font(Brand.jost(12)).foregroundStyle(Brand.text)
                                }
                                .frame(height: 16)
                                Capsule().fill(Brand.line).frame(height: 3)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { g in Capsule().fill(Color(hex: 0x86756B)).frame(width: g.size.width * window.remainingPercent / 100) }
                                    }
                            }
                            .frame(width: 110)
                        }
                    }
                    .frame(height: 35)
                }
            }
        case .loggedOut:
            if state.deviceCode == nil {
                SettingRow("로그인 안 됨", detail: "ChatGPT 계정으로 로그인하면 정리와 채팅을 쓸 수 있어요.", top: 16, bottom: 7) {
                    Button("ChatGPT 로그인") { state.startCodexLogin() }.buttonStyle(BrandButtonStyle(kind: .primary))
                }
            }
        }
    }

    /// 카드 아래: 기기 코드, 확인 결과, 오류
    @ViewBuilder private var codexExtras: some View {
        if case .loggedOut = state.codexStatus, let code = state.deviceCode { deviceCodeRows(code) }
        if case .loggedIn = state.codexStatus, let modelsError = state.codexModelsError { resultLine(modelsError) }
        if let message = state.codexMessage { resultLine(message) }
    }

    private func deviceCodeRows(_ code: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("열린 브라우저에 이 코드를 입력해 주세요").font(Brand.suit(12, .medium)).foregroundStyle(Brand.text)
                .padding(.vertical, 16)
            VStack(alignment: .leading, spacing: 8) {
                Text("기기 코드").font(Brand.suit(11)).foregroundStyle(Brand.gray)
                Text(code.userCode).font(Brand.jost(28)).tracking(1.4).foregroundStyle(Brand.ink).textSelection(.enabled)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
            HStack(spacing: 10) {
                Button("코드 복사") { state.copyDeviceCode() }.buttonStyle(BrandButtonStyle())
                Button("브라우저 다시 열기") { NSWorkspace.shared.open(code.verificationURL) }.buttonStyle(BrandButtonStyle())
                Button("취소") { state.cancelCodexLogin() }.buttonStyle(BrandButtonStyle())
                ProgressView().controlSize(.small)
            }
            .padding(.top, 14)
            Text("코드는 복사돼 있어요. 브라우저에 붙여 넣으세요.").font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(.top, 10).padding(.bottom, 14)
        }
    }

    private func resultLine(_ text: String) -> some View {
        Text(text).font(Brand.suit(11)).foregroundStyle(Brand.text).textSelection(.enabled).padding(.top, 10)
    }

    // MARK: 모델

    private var judgeRow: some View {
        tallRow("판단 모델", sub: "활동 기록을 어느 업무에 넣을지 판단해요") {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    SettingPill(on: judge == "gpt", action: { judge = "gpt" }) { Text("GPT") }
                    SettingPill(on: judge != "gpt", action: { if judge == "gpt" { judge = "jev" } }) { jevLabel("Jev") }
                }
                if judge == "gpt" {
                    BrandMenu(selection: $state.settings.judgeGPTProvider,
                              options: [("codex", "ChatGPT 구독"), ("openai", "별도 API")], width: 190)
                    switch state.settings.judgeGPTProvider {
                    case "openai":
                        TextField("판단 API 주소", text: $state.settings.judgeBaseURL).frame(width: 300)
                        SecureField("판단 API 키", text: $state.settings.judgeAPIKey).frame(width: 300)
                        ModelDropdown(selection: $state.settings.judgeAPIModel, models: judgeAPIModels.map { ($0, $0) }, directEntry: true)
                    default:
                        codexModelField($state.settings.judgeCodexModel, state.codexModels)
                    }
                }
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

    /// 알약 안: Jev 로고 14pt와 이름
    private func jevLabel(_ name: String) -> some View {
        HStack(spacing: 6) { SettingJevLogo(size: 14); Text(name) }
    }

    /// Jev API 키 줄: 키 받기, 키 칸(안에 Jev 로고 16pt). 키를 넣으면 칸 아래에 연결 확인이 나온다
    private var jevKeyRow: some View {
        tallRow("Jev API 키", slot: 36, top: 16, bottom: 7, column: nil) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    keyLink(AppSettings.jevSite, help: "Jev 사이트에서 키를 만들어요")
                    HStack(spacing: 8) {
                        SettingJevLogo(size: 16)
                        SecureField("", text: $jevKey, prompt: Text("Jev 사이트에서 받은 키를 붙여 넣어요").foregroundStyle(Color(hex: 0x9E9994)))
                            .textFieldStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.text)
                            .focused($jevFocused)
                    }
                    .settingField()
                    .frame(width: 460)
                    .contentShape(Rectangle())
                    .onTapGesture { jevFocused = true }
                }
                if !jevKey.isEmpty {
                    SettingCheckStatus(result: jevChecking ? "확인 중…" : jevResult, testing: jevChecking, action: checkJev)
                }
            }
        }
    }

    /// Jev 연결 확인: 개인 자료 없이 작은 문항 하나만 보낸다. 확인하는 사이 키를 바꾸면 그 결과는 버린다
    private func checkJev() {
        guard let endpoint = state.settings.judgeEndpoint else { jevResult = "Jev API 키를 먼저 넣어 주세요"; return }
        let key = jevKey
        jevChecking = true; jevResult = nil
        Task {
            var message = "연결됨"
            do { try await JevClient(endpoint: endpoint).verify() } catch { message = error.localizedDescription }
            if jevKey == key { jevResult = message }
            jevChecking = false
        }
    }

    /// 정리 모델: 고른 연결 방식의 모델 목록
    private var organizeRow: some View {
        tallRow("정리 모델", sub: "판단을 마친 업무의 이름과 요약을 만들어요") {
            modelList(codex: $codexModel, openAI: $openAIModel, codexModels: state.codexModels)
        }
    }

    /// 채팅 모델: 정리 모델과 같이(기본) 또는 따로 고르기. 따로 고르면 알약 아래에 같은 연결 방식의 모델 목록이 펼쳐진다
    private var chatRow: some View {
        tallRow("채팅 모델", sub: "채팅에서 질문을 읽고 답변을 작성해요") {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    SettingPill(on: chatSame, action: { chatSame = true }) { Text("정리 모델과 같이") }
                    SettingPill(on: !chatSame, action: { chatSame = false }) { Text("따로 고르기") }
                }
                if !chatSame {
                    modelList(codex: $chatCodexModel, openAI: $chatOpenAIModel,
                              codexModels: state.chatCodexModels.isEmpty ? state.codexModels : state.chatCodexModels)
                }
            }
        }
    }

    /// 고른 연결 방식에서 사용할 수 있는 모델을 메뉴로 보여 준다.
    @ViewBuilder private func modelList(codex: Binding<String>, openAI: Binding<String>, codexModels: [CodexModel]) -> some View {
        switch provider {
        case "openai": ModelDropdown(selection: openAI, models: apiModels.map { ($0, $0) }, directEntry: true)
        default: codexModelField(codex, codexModels)
        }
    }

    /// ChatGPT 모델을 불러오는 동안에는 현재 상태를 안내한다.
    @ViewBuilder private func codexModelField(_ selection: Binding<String>, _ models: [CodexModel]) -> some View {
        if state.codexModelsLoading {
            HStack(spacing: 8) {
                Text("불러오는 중…").font(Brand.suit(11)).foregroundStyle(Brand.gray)
                ProgressView().controlSize(.mini)
            }.frame(height: 28)
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

/// 켜고 끄기: 스위치 대신 체크 표시. 켜짐 = 하늘색 체크, 꺼짐 = 옅은 빈 동그라미
struct BrandSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(configuration.isOn ? Brand.blue : Color(hex: 0xC9C4BF))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .hoverHighlight(cornerRadius: 15)
                .opacity(enabled ? 1 : 0.4)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
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
