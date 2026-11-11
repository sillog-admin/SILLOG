import AVFoundation
import ServiceManagement
import Speech
import SwiftUI
import UserNotifications
import SillogCollectors
import SillogCore

/// 온보딩 화면 전체: 창 전체를 연한 바탕(#EFECE8)으로 덮고 내용을 가운데에 둔다. 뒤 화면은 비치지 않는다.
/// 1단계(로그인)는 AI 연결 고르기 → ChatGPT 계정 / API 키, 연결되면 판단 모델 고르기 → Jev API / 건너뛰기,
/// 2단계는 권한 허용 (Figma 859:1862, 877:2403~2553, 판단 모델은 OUT-24~27)
struct OnboardingOverlay: View {
    let step: OnboardingStep

    var body: some View {
        OnboardingSheet(step: step)
            .background(ResignFocus())
    }
}

/// 시트가 뜨는 순간 창의 키보드 포커스를 비운다. 시트 뒤 채팅 입력칸(NSTextView)이나 그래프(WKWebView)가 타이핑을 받지 않게
private struct ResignFocus: NSViewRepresentable {
    /// Clears focus once the view is in a window. At makeNSView time it may not be attached yet, and then nothing was cleared.
    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
        }
    }

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// "무엇이 기기 밖으로 나가나요?" 안내. 로그인 오류 카드(OUT-W1)가 쓴다.
/// W1 의 Figma 문구는 대표 화면 이미지 전송을 빠뜨려(스크린샷 카드가 기본으로 켜져 있다) 시트 문구로 맞춘다
enum PrivacyNote {
    static let title = tr("무엇이 기기 밖으로 나가나요?")
    static let body = tr("기록은 Mac에 저장돼요. 업무를 정리할 때 창 제목, 주소, 화면 텍스트와 대표 화면 이미지가 연결한 AI로 전송돼요. 채팅에서 조회한 원문, 코드, 문서도 전송될 수 있어요. 허용한 웹 검색과 커넥터는 외부 서비스와 통신해요.")
}

// MARK: 색과 그림 (온보딩 전용)

private enum OB {
    static let bg = Color(hex: 0xEFECE8)
    static let accent = Color(hex: 0x8A7566)          // 버튼 바탕
    static let border = Color(hex: 0xDDD7D1)          // 보조 버튼 테두리, 아래 막대 윗선
    static let chip = Color(hex: 0xEFE9E3)            // 숫자 동그라미, 복사 알약
    static let field = Color(hex: 0xF5F2EE)           // 카드 안 입력칸
    static let soft = Color(hex: 0xEEE9E4)            // 카드 안 구분선
    static let brown = Color(hex: 0x4A3F38)           // 기기 코드, 링크 아이콘
    static let warn = Color(hex: 0xA9432B)            // 따뜻한 붉은색 안내
    static let ok = Color(hex: 0x2F8F5B)              // 허용됨
    static let shadow = Color(hex: 0x6B5A4E, opacity: 0.10)
}

/// Resources/Brand 의 그림을 한 번만 읽는다 (없으면 nil, 화면은 글자만으로 그린다)
private enum OnboardingArt {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(_ name: String) -> NSImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        let url = BundledResources.url(forResource: name, withExtension: "png", subdirectory: "Brand", main: .main) { .module }
        guard let image = url.flatMap(NSImage.init(contentsOf:)) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

private struct ArtImage: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Group {
            if let image = OnboardingArt.image(name) { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() } else { Color.clear }
        }
        .frame(width: size, height: size)
    }
}

// MARK: 온보딩 시트

/// 1단계(로그인)의 화면. 앞의 셋은 AI 연결 고르기와 연결 방법별 화면, 뒤의 둘은 연결된 뒤에 거치는 판단 모델 고르기와 그 연결 화면
private enum LoginMethod { case choose, chatgpt, apiKey, judge, judgeJev, judgeDecisions }

struct OnboardingSheet: View {
    @EnvironmentObject private var state: AppState
    let step: OnboardingStep
    @State private var method: LoginMethod = OnboardingSheet.initialMethod
    @State private var apiURL = ""
    @State private var apiModel = ""
    @State private var apiKey = ""
    @State private var judgeJevKey = ""
    @State private var judgeDecisionsKey = ""
    @State private var testing = false
    @State private var notice: String?
    @StateObject private var perms = OnboardingPermissions()

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var connected: Bool { state.phase != .login }

    /// SILLOG_ONBOARDING=chatgpt|apikey|judge|jev 로 그 화면에서 시작한다 (개발, 스크린샷용)
    private static let initialMethod: LoginMethod = {
        switch SillogEnv.value("ONBOARDING") {
        case "chatgpt": return .chatgpt
        case "apikey": return .apiKey
        case "judge": return .judge
        case "jev": return .judgeJev
        case "decisions": return .judgeDecisions
        default: return .choose
        }
    }()

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ScrollView {
                    page
                        .padding(.horizontal, 56).padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: max(0, geo.size.height - 76), alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                bottomBar
            }
        }
        .background(OB.bg.ignoresSafeArea())
        .onAppear { state.refreshPermissionGrants(); Task { await perms.refresh() } }
        .onReceive(poll) { _ in
            guard step == .permissions else { return }
            state.refreshPermissionGrants()
            Task { await perms.refresh() }
        }
        // 로그인이 끝나면(새로 연결됐을 때) 바로 판단 모델 고르기로.
        // API 키 연결은 connect 가 직접 넘기니 여기서 건드리면 안 된다 (연결을 ChatGPT 로 되돌려 버린다)
        .onChange(of: state.phase) { old, new in
            if step == .login, old == .login, new != .login, method == .choose || method == .chatgpt { useChatGPTProvider(); goJudge() }
        }
        .onChange(of: state.codexStatus) { _, new in
            if step == .login, method == .chatgpt, case .loggedIn = new { useChatGPTProvider(); goJudge() }
        }
    }

    @ViewBuilder private var page: some View {
        if step == .permissions {
            permissionPage
        } else {
            switch method {
            case .choose: choosePage
            case .chatgpt: chatgptPage
            case .apiKey: apiKeyPage
            case .judge: judgePage
            case .judgeJev: judgeJevPage
            case .judgeDecisions: judgeDecisionsPage
            }
        }
    }

    // MARK: 공용 조각

    private func heading(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(Brand.suit(34, .bold)).tracking(-0.8).foregroundStyle(Brand.ink)
            Text(sub).font(Brand.suit(16)).foregroundStyle(Brand.gray)
        }
        .multilineTextAlignment(.center)
    }

    private func numberDot(_ n: Int, size: CGFloat = 28) -> some View {
        Text("\(n)").font(Brand.suit(size > 24 ? 13 : 11, .semibold)).foregroundStyle(OB.brown)
            .frame(width: size, height: size).background(Circle().fill(OB.chip))
    }

    private func go(_ next: LoginMethod) {
        notice = nil
        method = next
    }

    /// 연결이 끝난 뒤 판단 모델 고르기로. 앱이 아직 연결로 보지 않으면(ChatGPT 상태만 먼저 바뀐 경우) 가지 않는다:
    /// 거기서 건너뛰기를 눌러도 다음 단계(advanceOnboarding)가 안 넘어가 갇히기 때문
    private func goJudge() {
        // 이미 마친 계정(phase .ready)이 다시 로그인한 경우는 예전처럼 시트를 닫는다. 판단 모델은 설정에서 바꾼다
        if state.phase == .ready { state.advanceOnboarding() } else if connected { go(.judge) }
    }

    // MARK: 1. AI 연결 고르기

    private var choosePage: some View {
        VStack(spacing: 40) {
            heading(tr("AI를 하나 연결해요"), tr("기록을 업무별로 정리해 줄 AI예요."))
            HStack(spacing: 20) {
                MethodTile(title: tr("ChatGPT 계정"), detail: tr("쓰던 ChatGPT 구독으로 연결해요")) {
                    ArtImage(name: "openai_logo", size: 72)
                } action: { chooseChatGPT() }
                MethodTile(title: tr("API 키"), detail: tr("가진 키를 붙여 넣어요")) {
                    Image(systemName: "link").font(.system(size: 62, weight: .regular)).foregroundStyle(OB.brown)
                        .frame(width: 72, height: 72)
                } action: { go(.apiKey) }
            }
            .frame(maxWidth: 700)
            VStack(spacing: 10) {
                Text(tr("기록 원본은 이 Mac에만 있어요. 정리할 때만 필요한 내용을 고른 AI로 보내요."))
                    .font(Brand.suit(13)).foregroundStyle(Brand.gray)
                if connected {
                    Text(tr("이미 연결돼 있어요. 바꾸지 않으면 오른쪽 아래 다음으로 넘어가요."))
                        .font(Brand.suit(13, .medium)).foregroundStyle(OB.ok)
                }
            }
        }
    }

    /// ChatGPT 계정: 이미 로그인돼 있으면 그대로 다음 단계, 아니면 기기 코드 로그인을 시작한다
    private func chooseChatGPT() {
        go(.chatgpt)
        if case .loggedIn = state.codexStatus { return }
        state.startCodexLogin()
    }

    // MARK: 2. ChatGPT 계정

    private var chatgptPage: some View {
        VStack(spacing: 32) {
            heading(tr("ChatGPT 계정으로 연결해요"), tr("Plus, Pro 등 쓰고 있는 구독 그대로 써요. 아래 코드만 넣으면 돼요."))
            VStack(spacing: 0) {
                Text(tr("기기 코드")).font(Brand.suit(13)).foregroundStyle(Brand.gray)
                if let code = state.deviceCode {
                    // 코드 칸 폭(346pt)에 10~11글자(XXXX-XXXXX)가 한 줄로 들어가는 크기. 더 길면 줄바꿈 대신 조금 줄인다
                    Text(code.userCode).font(Brand.suit(38, .bold)).tracking(3).foregroundStyle(OB.brown)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .textSelection(.enabled).padding(.top, 14)
                } else {
                    ProgressView().controlSize(.regular).frame(height: 64).padding(.top, 14)
                }
                Button { state.copyDeviceCode() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.on.square").font(.system(size: 12))
                        Text(tr("복사"))
                    }
                    .font(Brand.suit(13, .medium)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Capsule().fill(OB.chip))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.deviceCode == nil)
                .padding(.top, 16)
            }
            .padding(.top, 22).padding(.bottom, 24).padding(.horizontal, 24)
            .frame(width: 394)
            .background(RoundedRectangle(cornerRadius: 22).fill(.white))
            .shadow(color: OB.shadow, radius: 14, y: 5)
            HStack(spacing: 14) {
                stepChip(1, tr("ChatGPT 열기")); stepArrow
                stepChip(2, tr("코드 넣기")); stepArrow
                stepChip(3, tr("연결 확인"))
            }
            if let line = notice ?? (connected ? nil : state.codexMessage) {
                Text(line).font(Brand.suit(13)).foregroundStyle(OB.warn).multilineTextAlignment(.center)
                    .textSelection(.enabled).frame(maxWidth: 560)
            }
        }
    }

    private func stepChip(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            numberDot(n, size: 22)
            Text(text).font(Brand.suit(15, .medium)).foregroundStyle(Brand.ink)
        }
    }

    private var stepArrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Color(hex: 0xC9BFB6))
    }

    /// ChatGPT 열기: 코드가 있으면 승인 페이지를 다시 열고, 없으면 로그인을 시작한다
    private func openChatGPT() {
        if let code = state.deviceCode { NSWorkspace.shared.open(code.verificationURL) } else { state.startCodexLogin() }
    }

    /// 연결 확인: 로그인돼 있으면 판단 모델 고르기로, 아니면 상태를 다시 읽는다
    private func confirmChatGPT() {
        if case .loggedIn = state.codexStatus { useChatGPTProvider(); goJudge(); return }
        state.refreshCodexStatus()
        if state.deviceCode == nil { state.startCodexLogin() } else { notice = tr("아직 승인 전이에요. ChatGPT에서 코드를 넣어 주세요.") }
    }

    /// API 키 연결을 쓰다 ChatGPT 로 바꾸는 경우 정리와 채팅 연결을 ChatGPT 로 되돌린다
    private func useChatGPTProvider() {
        guard state.settings.llmProvider != "codex" || state.settings.chatProvider != "codex" else { return }
        state.settings.llmProvider = "codex"; state.settings.chatProvider = "codex"
        state.applySettings()
    }

    private func keyField(_ text: Binding<String>, placeholder: String, fill: Color, height: CGFloat, radius: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty { Text(placeholder).font(Brand.suit(15)).foregroundStyle(Color(hex: 0xB3ABA4)).allowsHitTesting(false) }
            SecureField("", text: text).textFieldStyle(.plain).font(Brand.suit(15)).foregroundStyle(Brand.text)
        }
        .padding(.horizontal, 16).frame(height: height)
        .background(RoundedRectangle(cornerRadius: radius).fill(fill))
    }

    /// 연결 확인 결과 한 줄 (확인 중이면 진행 표시)
    @ViewBuilder private var resultLine: some View {
        if testing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(tr("연결을 확인하고 있어요")).font(Brand.suit(13)).foregroundStyle(Brand.gray) }
        } else if let notice {
            Text(notice).font(Brand.suit(13)).foregroundStyle(OB.warn).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: 640)
        }
    }

    // MARK: 3. API 키

    private var apiKeyPage: some View {
        VStack(spacing: 26) {
            heading(tr("API 키로 연결해요"), tr("OpenAI 방식으로 쓰는 서버면 돼요."))
            VStack(alignment: .leading, spacing: 18) {
                labeled(tr("서버 주소")) { plainField($apiURL, "https://api.openai.com/v1") }
                labeled(tr("모델")) { plainField($apiModel, tr("예: gpt-6.1-sol")) }
                labeled(tr("API 키")) { keyField($apiKey, placeholder: tr("여기에 붙여 넣기"), fill: .white, height: 56, radius: 18).shadow(color: OB.shadow, radius: 8, y: 3) }
            }
            .frame(maxWidth: 936)
            resultLine
        }
    }

    private func labeled<Field: View>(_ label: String, @ViewBuilder _ field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Brand.suit(14, .medium)).foregroundStyle(Brand.gray)
            field()
        }
    }

    private func plainField(_ text: Binding<String>, _ placeholder: String) -> some View {
        ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty { Text(placeholder).font(Brand.suit(15)).foregroundStyle(Color(hex: 0xB3ABA4)).allowsHitTesting(false) }
            TextField("", text: text).textFieldStyle(.plain).font(Brand.suit(15)).foregroundStyle(Brand.text)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: OB.shadow, radius: 8, y: 3)
    }

    /// OpenAI 호환 서버 연결: 값을 넣어 연결 확인(시험 호출)을 하고, 되면 저장하고 판단 모델 고르기로. 안 되면 원래 설정으로 되돌린다
    private func connect(baseURL: String, model: String, key: String) {
        guard !testing else { return }
        testing = true; notice = nil
        let before = state.settings
        var next = before
        next.llmProvider = "openai"; next.llmBaseURL = baseURL; next.llmModel = model; next.llmAPIKey = key
        next.chatProvider = "openai"; next.chatBaseURL = baseURL; next.chatModel = model; next.chatAPIKey = key
        state.settings = next
        Task {
            await state.testLLM()
            testing = false
            if state.llmTestResult?.isOK == true {
                state.finishAPIKeyConnection()
                goJudge()
            } else {
                state.settings = before
                notice = state.llmTestResult?.message ?? tr("연결하지 못했어요.")
            }
        }
    }

    private var apiKeyReady: Bool {
        !apiURL.trimmingCharacters(in: .whitespaces).isEmpty && !apiModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: 4. 판단 모델 고르기 (OUT-24~27)

    private var judgePage: some View {
        VStack(spacing: 40) {
            heading(tr("판단 모델을 골라요"), tr("업무를 고를 때만 쓰는 모델이에요. 안 쓰면 정리 모델이 판단해요."))
            HStack(spacing: 20) {
                MethodTile(title: "Jev API", detail: tr("Jev 키를 붙여 넣어요")) {
                    ArtImage(name: "jev", size: 72)
                } action: { go(.judgeJev) }
                MethodTile(title: "OpenAI Decisions", detail: tr("OpenAI API 키를 붙여 넣어요")) {
                    Image(systemName: "checklist").font(.system(size: 52)).foregroundStyle(Brand.ink)
                } action: { go(.judgeDecisions) }
            }
            .frame(maxWidth: 700)
            Text(tr("판단 모델은 나중에 설정에서 켜고 끌 수 있어요.")).font(Brand.suit(13)).foregroundStyle(Brand.gray)
        }
    }

    private var judgeJevPage: some View {
        VStack(spacing: 26) {
            heading(tr("Jev API로 연결해요"), tr("Jev 사이트에서 받은 키를 붙여 넣으면 돼요."))
            VStack(alignment: .leading, spacing: 18) {
                labeled(tr("Jev API 키")) { keyField($judgeJevKey, placeholder: tr("여기에 붙여 넣기"), fill: .white, height: 56, radius: 18).shadow(color: OB.shadow, radius: 8, y: 3) }
            }
            .frame(maxWidth: 936)
            resultLine
        }
    }

    private var judgeDecisionsPage: some View {
        VStack(spacing: 26) {
            heading(tr("OpenAI Decisions로 연결해요"), tr("OpenAI 사이트에서 받은 API 키를 붙여 넣으면 돼요."))
            VStack(alignment: .leading, spacing: 18) {
                labeled(tr("OpenAI API 키")) { keyField($judgeDecisionsKey, placeholder: tr("여기에 붙여 넣기"), fill: .white, height: 56, radius: 18).shadow(color: OB.shadow, radius: 8, y: 3) }
            }
            .frame(maxWidth: 936)
            resultLine
        }
    }

    /// 판단 모델을 저장하고 권한 단계로 ("none" 은 쓰지 않음)
    private func finishJudge(_ provider: String) {
        state.settings.judgeProvider = provider
        state.applySettings()
        state.advanceOnboarding()
    }

    /// Test-calls the judge; on success saves the key and moves on, otherwise shows why and saves nothing.
    private func connectJudge(_ provider: String, verify: @escaping () async throws -> Void, save: @escaping () -> Void) {
        guard !testing else { return }
        testing = true; notice = nil
        let startedOn = method
        Task {
            let failure: String?
            do {
                try await verify()
                failure = nil
            } catch {
                failure = error is ChoiceError ? error.localizedDescription : tr("판단 모델 서버에 연결하지 못했어요. \(error.localizedDescription)")
            }
            testing = false
            guard method == startedOn else { return }     // went back meanwhile: do not overwrite a skip
            if let failure { notice = failure; return }
            save()
            finishJudge(provider)
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: 5. 권한 허용

    private var permissionPage: some View {
        let grants = state.permissionGrants
        return VStack(spacing: 0) {
            heading(tr("한 번에 허용해요"), tr("필요한 권한을 한 화면에서 모두 켜요."))
            HStack(spacing: 16) {
                bigPermission(title: Permissions.accessibilityName, reads: tr("창 제목, 주소, 문서 경로를 읽어요"), warn: tr("켜지 않으면 창 제목·주소·문서 경로가 남지 않아요"),
                              icon: "perm_acc", granted: grants.accessibility) { requestAccessibility() }
                bigPermission(title: tr("화면 기록"), reads: tr("화면에 있던 글자를 읽어요"), warn: tr("켜지 않으면 화면 내용과 스크린샷을 남기지 못해요"),
                              icon: "perm_screen", granted: grants.screenRecording) { requestScreenRecording() }
            }
            .padding(.top, 26)
            Text(tr("쓰는 기능에 맞춰 켜요")).font(Brand.suit(13, .medium)).foregroundStyle(Brand.gray)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).padding(.bottom, 8)
            HStack(spacing: 12) {
                smallPermission(.notifications, icon: "perm_bell", title: tr("알림"), detail: tr("정리가 끝나면\n알려요"))
                smallPermission(.microphone, icon: "perm_mic", title: tr("마이크"), detail: tr("메뉴 막대에서\n녹음해요"))
                smallPermission(.speech, icon: "perm_speech", title: tr("음성 인식"), detail: tr("녹음을 Mac 안에서\n글로 받아써요"))
                smallPermission(.downloads, icon: "perm_folder", title: tr("다운로드 폴더"), detail: tr("새로 받은 파일을\n업무에 이어요"))
                smallPermission(.documents, icon: "perm_folder", title: tr("문서 폴더"), detail: tr("받아쓴 녹음을\n저장해요"))
                if AppFeatures.calendarOn { smallPermission(.calendar, icon: "", symbol: "calendar", title: tr("캘린더"), detail: tr("오늘 일정을 보고\n제안을 등록해요")) }
                smallPermission(.loginItem, icon: "perm_login", title: tr("로그인할 때 열기"), detail: tr("켜 두면\n빠짐없이 기록해요"))
            }
            Text(tr("\(Permissions.accessibilityName)과 화면 기록은 시스템 설정에서 켜요. 화면 기록은 켠 뒤 앱을 다시 실행해야 해요."))
                .font(Brand.suit(13)).foregroundStyle(Brand.gray).padding(.top, 26)
        }
        .frame(maxWidth: 1068)
    }

    private func bigPermission(title: String, reads: String, warn: String, icon: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Brand.suit(26, .bold)).tracking(-0.5).foregroundStyle(Brand.ink)
                Text(reads).font(Brand.suit(16)).foregroundStyle(Brand.gray).padding(.top, 8)
                Text(warn).font(Brand.suit(14, .medium)).foregroundStyle(OB.warn).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if granted { grantedLabel(size: 15) } else { Button(tr("허용하기"), action: request).buttonStyle(OBPillStyle(height: 32, size: 14)) }
                }
                .padding(.top, 16)
            }
            Spacer(minLength: 8)
            ArtImage(name: icon, size: 64)
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 183, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white))
        .shadow(color: OB.shadow, radius: 12, y: 4)
    }

    private func grantedLabel(size: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: size - 3, weight: .semibold))
            Text(tr("허용됨"))
        }
        .font(Brand.suit(size, .medium)).foregroundStyle(OB.ok)
        .frame(height: 32, alignment: .leading)
    }

    private func smallPermission(_ item: OnboardingPermissions.Item, icon: String, symbol: String? = nil, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(OB.brown)
                        .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(OB.chip))
                } else {
                    ArtImage(name: icon, size: 30)
                }
                Spacer(minLength: 4)
                if perms.granted.contains(item) {
                    grantedLabel(size: 12).frame(height: 28)
                } else {
                    Button(tr("허용하기")) { Task { await perms.request(item) } }.buttonStyle(OBPillStyle(height: 28, size: 12))
                }
            }
            Text(title).font(Brand.suit(15, .bold)).foregroundStyle(Brand.ink).lineLimit(1).minimumScaleFactor(0.8).padding(.top, 14)
            Text(detail).font(Brand.suit(12)).foregroundStyle(Brand.gray).lineSpacing(2).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white))
        .shadow(color: OB.shadow, radius: 10, y: 3)
    }

    private func requestAccessibility() {
        _ = Permissions.accessibility(prompt: true)
        Permissions.openSettings(.accessibility)
    }

    private func requestScreenRecording() {
        Permissions.requestScreenRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Permissions.openSettings(.screenRecording) }
        state.askedScreenRecording = true
    }

    /// 모두 허용: 시스템 권한 창이 차례로 뜬다 (이미 허용한 것은 건너뛴다)
    private func allowAll() {
        if !state.permissionGrants.accessibility { _ = Permissions.accessibility(prompt: true) }
        if !state.permissionGrants.screenRecording { Permissions.requestScreenRecording(); state.askedScreenRecording = true }
        Task { await perms.requestAll() }
    }

    // MARK: 아래 막대 (76, 윗선)

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let back = backLabel {
                Button { goBack() } label: {
                    HStack(spacing: 10) {
                        BackMark()
                        Text(back).font(Brand.suit(14, .medium)).foregroundStyle(Brand.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 40)
        .frame(height: 76)
        .overlay(alignment: .top) { Rectangle().fill(OB.border).frame(height: 1).padding(.horizontal, 40) }
    }

    private var backLabel: String? {
        if step == .permissions || method == .judge { return tr("이전") }
        return method == .choose ? nil : tr("다른 방법 고르기")
    }

    private func goBack() {
        notice = nil
        if step == .permissions {
            state.onboardingStep = .login        // 권한 앞 화면인 판단 모델 고르기로 돌아온다. 연결 방법은 거기서 이전으로 다시 고른다
            method = .judge
        } else if method == .judgeJev || method == .judgeDecisions {
            method = .judge
        } else {
            if method == .chatgpt { state.cancelCodexLogin() }
            method = .choose                     // 연결 방법을 다시 고르는 화면. 연결돼 있으면 거기서 다음으로 돌아온다 (판단 모델 고르기의 이전도 여기로)
        }
    }

    @ViewBuilder private var actions: some View {
        if step == .permissions {
            Button(tr("모두 허용")) { allowAll() }.buttonStyle(OBButtonStyle(kind: .secondary))
            Button(state.askedScreenRecording ? tr("다시 실행하고 시작") : tr("시작")) {
                if state.askedScreenRecording { state.completeOnboardingAndRelaunch() } else { state.completeOnboarding() }
            }
            .buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        } else {
            switch method {
            case .choose:
                if connected {
                    Button(tr("다음")) { goJudge() }.buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                }
            case .chatgpt:
                Button { openChatGPT() } label: { linkLabel(tr("ChatGPT 열기")) }.buttonStyle(OBButtonStyle(kind: .secondary))
                Button(tr("연결 확인")) { confirmChatGPT() }.buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            case .apiKey:
                Button(tr("연결 확인")) {
                    connect(baseURL: apiURL.trimmingCharacters(in: .whitespaces), model: apiModel.trimmingCharacters(in: .whitespaces),
                            key: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                .disabled(testing || !apiKeyReady)
            case .judge:
                Button(tr("건너뛰기")) { state.advanceOnboarding() }.buttonStyle(OBButtonStyle(kind: .secondary))   // keeps a judge picked earlier
            case .judgeJev:
                Button(tr("연결 확인")) {
                    let key = trimmed(judgeJevKey)
                    connectJudge("jev", verify: { try await JevClient(endpoint: JevEndpoint(url: JevEndpoint.typesafeURL, model: JevEndpoint.defaultModel, key: key)).verify() },
                                 save: { state.settings.jevAPIKey = key })
                }
                .buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                .disabled(testing || trimmed(judgeJevKey).isEmpty)
            case .judgeDecisions:
                Button(tr("연결 확인")) {
                    let key = trimmed(judgeDecisionsKey)
                    connectJudge("decisions", verify: { try await DecisionsClient(key: key).verify() }, save: { state.settings.decisionsAPIKey = key })
                }
                .buttonStyle(OBButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                .disabled(testing || trimmed(judgeDecisionsKey).isEmpty)
            }
        }
    }

    private func linkLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
            Image(systemName: "arrow.up.right.square").font(.system(size: 13))
        }
    }
}

// MARK: 부품

/// 연결 방법 큰 타일: 흰 바탕, 부드러운 그림자, 커서를 대면 살짝 뜬다
private struct MethodTile<Icon: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                icon().frame(height: 76)
                Text(title).font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink).padding(.top, 22)
                Text(detail).font(Brand.suit(14)).foregroundStyle(Brand.gray).padding(.top, 8)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            .background(RoundedRectangle(cornerRadius: 26).fill(.white))
            .shadow(color: OB.shadow.opacity(hover ? 1.6 : 1), radius: hover ? 18 : 12, y: hover ? 8 : 4)
            .contentShape(RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

/// 왼쪽을 가리키는 삼각형 세 개: 뒤로 갈수록(오른쪽으로) 옅어진다
private struct BackMark: View {
    var body: some View {
        HStack(spacing: 1) {
            ForEach([0x7A685B, 0xB5A89E, 0xDAD3CD], id: \.self) { hex in
                LeftTriangle().fill(Color(hex: UInt32(hex))).frame(width: 9, height: 11)
            }
        }
    }
}

private struct LeftTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 아래 막대 알약 버튼: 주색(#8A7566 바탕, 흰 글씨), 보조(흰 바탕, #DDD7D1 테두리)
private struct OBButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.suit(15, .medium))
            .foregroundStyle(kind == .primary ? Color.white : Brand.ink)
            .padding(.horizontal, 28).frame(height: 50)
            .background(Capsule().fill(kind == .primary ? OB.accent : .white).overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : OB.border)))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// 타일 안 작은 알약 버튼 (허용하기)
private struct OBPillStyle: ButtonStyle {
    let height: CGFloat
    let size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Brand.suit(size, .medium)).foregroundStyle(Brand.ink)
            .padding(.horizontal, size + 2).frame(height: height)
            .background(Capsule().fill(.white).overlay(Capsule().strokeBorder(OB.border)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

// MARK: 추가 권한 (알림, 마이크, 음성 인식, 폴더, 캘린더, 로그인 항목)

/// 온보딩 권한 화면의 작은 타일 일곱 개의 상태와 요청. 상태는 묻지 않고 읽을 수 있는 것만 읽고(알림, 마이크, 음성 인식, 로그인 항목),
/// 폴더는 읽기를 시도해야 알 수 있어(처음이면 시스템이 묻는다) 누른 뒤에만 허용됨으로 바뀐다
@MainActor
final class OnboardingPermissions: ObservableObject {
    enum Item: String, CaseIterable { case notifications, microphone, speech, downloads, documents, calendar, loginItem }

    @Published private(set) var granted: Set<Item> = []
    /// SILLOG_ONBOARDING_GRANTED=notifications,loginItem 처럼 정해 두면 시스템을 읽지 않고 그 상태로 고정한다 (스크린샷용)
    private let fixed: Set<Item>?

    init() {
        let raw = SillogEnv.value("ONBOARDING_GRANTED")
        fixed = raw.map { Set($0.split(separator: ",").compactMap { Item(rawValue: String($0)) }) }
        if let fixed { granted = fixed }
    }

    /// .app 번들로 실행했을 때만 알림, 마이크, 음성 인식 요청을 한다 (swift run 에서는 요청하면 시스템이 앱을 끝낸다)
    private var bundled: Bool {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier != nil else { return false }
        let info = bundle.infoDictionary ?? [:]
        return info["NSMicrophoneUsageDescription"] != nil && info["NSSpeechRecognitionUsageDescription"] != nil
    }

    func refresh() async {
        guard fixed == nil else { return }
        var now = granted.intersection([.downloads, .documents])     // 폴더는 누른 결과를 그대로 둔다
        if bundled {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { now.insert(.notifications) }
        }
        if CalendarService.isGranted { now.insert(.calendar) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        if SFSpeechRecognizer.authorizationStatus() == .authorized { now.insert(.speech) }
        // 로그인 항목 상태 조회는 수 초 걸릴 수 있는 동기 XPC 호출이라 메인 스레드 밖에서 읽는다
        if await Task.detached(priority: .utility, operation: { SMAppService.mainApp.status == .enabled }).value { now.insert(.loginItem) }
        if now != granted { granted = now }
    }

    func request(_ item: Item, openSettingsOnFail: Bool = true) async {
        guard fixed == nil else { return }
        switch item {
        case .notifications: await requestNotifications(openSettingsOnFail)
        case .microphone: await requestMicrophone(openSettingsOnFail)
        case .speech: await requestSpeech(openSettingsOnFail)
        case .downloads: await requestFolder(.downloadsDirectory, item, openSettingsOnFail)
        case .documents: await requestFolder(.documentDirectory, item, openSettingsOnFail)
        case .calendar: await CalendarService.shared.requestAccess(openSettingsOnFail: openSettingsOnFail)
        case .loginItem: await requestLoginItem(openSettingsOnFail)
        }
        await refresh()
    }

    /// 모두 허용: 아직 안 된 것을 차례로 요청한다 (실패해도 시스템 설정을 연달아 열지 않는다)
    func requestAll() async {
        for item in Item.allCases where !granted.contains(item) { await request(item, openSettingsOnFail: false) }
    }

    private func requestNotifications(_ openSettings: Bool) async {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        case .notDetermined: _ = try? await center.requestAuthorization(options: [.alert, .sound])
        default: if openSettings { SuggestionNotifier.openSystemSettings() }
        }
    }

    private func requestMicrophone(_ openSettings: Bool) async {
        guard bundled else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: _ = await AVCaptureDevice.requestAccess(for: .audio)
        default: if openSettings { Permissions.openSettings(.microphone) }
        }
    }

    private func requestSpeech(_ openSettings: Bool) async {
        guard bundled else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            // Speech 는 이 처리기를 배경 큐에서 부른다: 명시적으로 Sendable 로 표시한다 (RecordingPermissions 와 같은 방식)
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
            }
        default: if openSettings { Permissions.openSettings(.speechRecognition) }
        }
    }

    /// 폴더는 읽어 봐야 안다: 처음이면 시스템이 묻고, 막혀 있으면 읽기가 실패한다
    private func requestFolder(_ directory: FileManager.SearchPathDirectory, _ item: Item, _ openSettings: Bool) async {
        let path = FileManager.default.urls(for: directory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        let ok = await Task.detached(priority: .userInitiated) { (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }.value
        if ok { granted.insert(item) } else if openSettings { Permissions.openSettings(.filesAndFolders) }
    }

    private func requestLoginItem(_ openSettings: Bool) async {
        let status = await Task.detached(priority: .userInitiated) { () -> SMAppService.Status in
            try? SMAppService.mainApp.register()
            return SMAppService.mainApp.status
        }.value
        if status == .requiresApproval, openSettings { SMAppService.openSystemSettingsLoginItems() }
    }
}

// MARK: 시작 상태 화면 (Figma 859:1862, OUT-W3)

/// 불러오는 중: 연한 바탕 가운데 아이콘과 SILLOG 글자, 왼쪽 아래 진행 표시와 두 토막 얇은 선
struct BrandLoadingView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFAF9F7), Color(hex: 0xEBE8E3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 2) {
                ArtImage(name: "splash_icon", size: 66)
                if let mark = OnboardingArt.image("splash_wordmark") {
                    Image(nsImage: mark).resizable().interpolation(.high).scaledToFit().frame(height: 48).accessibilityLabel("SILLOG")
                } else {
                    Text("SILLOG").font(Brand.suit(34, .bold)).foregroundStyle(OB.brown)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                    Text(tr("실록 준비 중...")).font(Brand.suit(13)).foregroundStyle(Brand.ink)
                }
                HStack(spacing: 6) {
                    Capsule().fill(Color(hex: 0xDDD9D4)).frame(height: 3)
                    Capsule().fill(Color(hex: 0xDDD9D4)).frame(height: 3)
                }
            }
            .padding(.horizontal, 46).padding(.bottom, 46)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

/// 시작 실패: 경고 아이콘, 제목, 원인 문장
struct BrandStartupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(Brand.gray)
            Text(tr("시작하지 못했어요")).font(Brand.suit(22, .bold)).foregroundStyle(Brand.ink).padding(.top, 30)
            Text(message).font(Brand.suit(14)).foregroundStyle(Brand.gray).multilineTextAlignment(.center)
                .textSelection(.enabled).padding(.top, 17)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
    }
}
