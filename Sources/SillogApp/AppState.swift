import AppKit
import Combine
import Foundation
import SillogCollectors
import SillogCore

/// 앱의 단일 상태. 수집기(actor)와 배치 실행기(actor)를 소유하고, 화면에는 요약만 내보낸다.
@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard !isPreview else { return }
            if settings.language != L10n.current { L10n.current = settings.language }
            // Every write redraws all text, so only a real change is written.
            if Brand.scale != settings.textScale { Brand.scale = settings.textScale }
            PIIMasker.enabled = settings.maskPII
        }
    }
    @Published var status = CollectorStatus()
    @Published var todayCount = 0
    @Published var pendingCount = 0
    @Published var lastBatchText = tr("아직 정리한 적 없음")
    @Published var batchRunning = false
    /// 업무를 지우는 중 (그동안 정리를 멈춘다)
    @Published var erasing = false
    @Published var batchResult: Bool?                  // 방금 끝난 지금 정리 결과(창 머리에 체크나 X 로 잠깐 보임). nil = 보이지 않음
    @Published var graphVersion = 0 { didSet { refreshTasks() } }   // Every graph change refreshes the task list here, once.
    @Published var recent: [Observation] = []
    @Published var batches: [BatchRecord] = []
    /// Connection check results by provider ("codex" / "openai").
    @Published var connectionChecks: [String: CheckResult] = [:]
    @Published var chatTestResult: CheckResult?
    var chatTesting: Bool { chatTestResult == .checking }
    var llmTestResult: CheckResult? { connectionChecks[settings.llmProvider] }
    @Published var startupError: String?
    @Published var codexStatus: CodexAuthStatus = .loggedOut
    /// 로그인 진행 중일 때만 값이 있다. 화면에 코드와 안내를 보여준다.
    @Published var deviceCode: DeviceCode?
    @Published var codexMessage: String?
    @Published var codexModels: [CodexModel] = []
    @Published var chatCodexModels: [CodexModel] = []
    /// The account's unverified list, so efforts are known while the slow per-model check runs.
    private var codexModelCandidates: [CodexModel] = []
    @Published var codexModelsLoading = false
    @Published var codexModelsError: String?
    @Published var chatCodexModelsError: String?
    /// Failed model checks by slug, so each settings row shows only its own model.
    @Published var codexModelFailures: [String: String] = [:]
    @Published var chatCodexModelFailures: [String: String] = [:]
    @Published var codexUsage: CodexUsage?
    /// 로그인해야 쓸 수 있다. `.ready` 가 되기 전에는 수집기도 배치도 돌지 않는다.
    @Published var phase: AppPhase = .login
    @Published var selectedTab: MainWindow.Tab = MainWindow.initialTab
    var showsChatResultsOnOpen = ["results", "library"].contains(SillogEnv.value("TAB") ?? "")
    /// 기록 자료 탭에서 보고 있는 구역 (메뉴 막대·알림이 파일 구역으로 바로 연다)
    @Published var recordsSection: RecordsView.Section = MainWindow.initialRecordsSection
    /// 설정 탭에서 보고 있는 구역 (권한 안내가 일반으로 바로 연다)
    @Published var settingsSection: SettingsView.Section = MainWindow.initialSettingsSection
    /// 커넥터 탭(맞춤 설정)에서 보고 있는 구역. SILLOG_TAB=skills 면 스킬로 시작
    @Published var customizeSection: CustomizeSection = SillogEnv.value("TAB") == "skills" ? .skills : .connectors
    /// 업무 드로어(창 왼쪽 업무 목록)에서 고른 업무와 상세가 펼쳐졌는지. 업무 목록에서 눌러도, 그래프에서 눌러도 같은 드로어가 열린다
    @Published var selectedTaskId: Int64?
    @Published var taskDetailOpen = false { didSet { if !taskDetailOpen { openNode = nil; nodeTrail = [] } } }   // 드로어를 닫으면 노드 상세도 닫는다
    /// 드로어에 띄운 업무가 아닌 노드 (그래프에서 분야·세션·자료·앱·주제 등을 눌렀을 때). nil 이면 업무 상세
    @Published var openNode: NodeRef?
    /// 노드 상세에서 연결된 노드로 넘어간 길 (‹ 뒤로)
    @Published var nodeTrail: [NodeRef] = []
    /// 지우기 확인 창에 띄울 것 (그래프 우클릭, 상세의 지우기 단추)
    @Published var eraseAsk: EraseAsk?
    /// 지우기가 실패했을 때 알림 창에 띄울 글 (실패하면 아무것도 안 지워진다)
    @Published var eraseError: String?
    /// 정리 제안 (대기 중인 것), 제안 시트, 제안을 만드는 중
    @Published var reviewProposals: [ReviewProposal] = []
    @Published var reviewSheetOpen = false
    @Published var reviewRunning = false
    /// 파일 정리 제안. 대기 중인 것이 앞에 온다.
    /// 대기 중인 제안 전부 + 지난 기록의 지금 쪽
    @Published var fileSuggestions: [FileSuggestion] = []
    /// 파일 > 지난 기록: 보고 있는 쪽(0부터)과 결정한 제안 전체 개수
    @Published var fileHistoryPage = 0
    /// History filter: nil shows all, "" shows rows without a field.
    @Published var fileHistoryField: String?
    @Published var fileHistoryOldestFirst = false
    /// Field counts over all history, not just the current page.
    @Published var fileHistoryLegend: [FileHistoryLegendItem] = []
    @Published var fileHistoryTotal = 0
    @Published var fileError: String?
    @Published var notificationsDenied = false
    @Published var taskList: [TaskSummary] = []
    /// 오늘 업무 외(집중 이탈) 시간: 앱별 초
    @Published var offTaskToday: [(app: String, seconds: Double)] = []
    @Published var resumeRequest: ResumeRequest?
    @Published var bootstrapped = false
    @Published var chat: ChatState?
    /// 온보딩 시트가 보여 줄 단계. nil 이면 시트가 없다 (OnboardingFlow 가 정한다)
    @Published var onboardingStep: OnboardingStep?
    /// 기기 코드 로그인이 꺼진 계정이라 로그인을 시작하지 못했다. 창이 OUT-W1 카드를 보여 준다
    @Published var loginBlocked = false
    /// 온보딩 권한 단계가 1초마다 직접 읽는 권한 (이때는 수집기가 아직 돌지 않는다)
    @Published var permissionGrants = PermissionGrants(accessibility: false, screenRecording: false)
    /// 이번 실행에서 화면 기록 권한을 요청했다. 허용해도 다시 실행해야 적용된다 (OUT-05)
    @Published var askedScreenRecording = false
    /// 원문 보관 정책. DB 에 저장해 sillogctl 과 같은 값을 쓴다
    @Published var retention = RetentionPolicy.standard
    @Published var storageUsage: StorageUsage?
    @Published var consolidationReport: Consolidator.Report?
    @Published var consolidating = false
    /// '지금 정리' 미리보기·첫 동의 시트
    @Published var cleanupPreview: CleanupPreview?
    @Published var retentionPins: [RetentionPin] = []
    @Published var pruneConsented = false
    /// 원문(화면 텍스트)이 남아 있는 첫 날. 정리한 적이 없으면 nil
    @Published var rawRecordsSince: String?
    // 녹음 (AppState+Recording)
    @Published var activeRecording: ActiveRecording?
    @Published var recordingWork: RecordingPipeline.Step?
    @Published var recordingProblem: RecordingProblem?
    @Published var recordings: [Recording] = []

    let databasePath = SillogDatabase.defaultPath()
    private(set) var db: SillogDatabase?
    private(set) var store: EventStore?
    private var coordinator: CollectorCoordinator?
    private var batcher: OntologyBatcher?
    /// 기록 정리 (사용 시간 기록 → 주간·월간 요약 → 동의했으면 원문 정리). 실행 잠금을 가진 이 인스턴스에서만 돈다
    var consolidator: Consolidator?
    var suggester: FolderSuggester?
    var folderIndex: FolderIndex?
    var folderIndexAt = 0.0
    var folderIndexTask: Task<FolderIndex, Never>?
    var recordingPipeline: RecordingPipeline?
    var recorder: any AudioRecording = VoiceRecorder()
    /// 녹음 중 미리 받아쓰기 (실제 앱에서만. 미리보기·시험은 직접 넣는다): 정리할 때 이 글을 쓰고, 없으면 파일 전체를 받아쓴다
    var liveTranscriptions: LiveTranscriptions?
    var recordingPermissions: any RecordingPermissions = SystemRecordingPermissions()
    var recordingQueue: Task<Void, Never>?
    /// 차례를 기다리거나 정리 중인 녹음 id (같은 녹음을 두 번 넣지 않게)
    var queuedRecordingIds: Set<Int64> = []
    var recordingStepToken = 0
    let notifier = SuggestionNotifier()
    private var tasks: [Task<Void, Never>] = []
    private let codexAuth = CodexAuthManager()
    private var loginTask: Task<Void, Never>?
    private var codexModelTask: Task<Void, Never>?
    private var codexModelTaskID: UUID?
    private var servicesRunning = false
    private var bootstrapLogged = false
    /// 스냅샷용 미리보기 상태. DB·잠금·수집기·권한 읽기를 하지 않는다
    private(set) var isPreview = false
    private let instanceLock = InstanceLock(databasePath: SillogDatabase.defaultPath())
    private static let onboardingKey = "sillog.onboardingCompleted"
    /// Figma OUT-W3 문구
    static let alreadyRunningMessage = tr("SILLOG이 이미 실행 중이에요. 메뉴 막대의 아이콘을 확인해 주세요.")

    init() {
        settings = AppSettings.load()
        L10n.current = settings.language
        Brand.scale = settings.textScale
        PIIMasker.enabled = settings.maskPII
        guard instanceLock.acquire() else {
            startupError = Self.alreadyRunningMessage
            AppLog.write("이미 실행 중인 Sillog 이 있어 시작하지 않음 (터미널에서 swift run 으로 띄운 실행도 확인)")
            return
        }
        do {
            let database = try SillogDatabase(path: databasePath)
            try database.writer.write { try TBox.seed(GraphTx($0), at: Date().timeIntervalSince1970) }
            let store = EventStore(database)
            let captures = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
            let coordinator = CollectorCoordinator(store: store, capturesDir: captures, settings: settings.collector)
            self.db = database
            self.store = store
            self.coordinator = coordinator
            FrameMonitor.shared.screen = { [weak self] in self?.screenName ?? "" }   // 개발용 프레임 측정 로그의 화면 이름
            self.chat = ChatState(db: database, makeClient: { [unowned self] in self.makeChatClient() },
                                  makeProjectClient: { [unowned self] in self.makeClient() })
            self.chat?.userInstructions = { [unowned self] in self.settings.chatInstructions }
            // 숨은 설정: defaults write com.sillog.app batchPipeline single (없으면 기본값인 3단계),
            // themes -bool true (없으면 분야 붙이기는 꺼짐), calendar -bool true (없으면 일정 찾기는 꺼짐, AppFeatures)
            let batchConfig = Self.batchConfig(themes: UserDefaults.standard.bool(forKey: "themes"), pipeline: UserDefaults.standard.string(forKey: "batchPipeline"),
                                               calendar: AppFeatures.calendarOn)
            let batcher = OntologyBatcher(db: database, llm: makeClient(), config: batchConfig, activityJudge: makeJudge())
            self.batcher = batcher
            self.consolidator = Consolidator(db: database, llm: makeClient())
            loadRetentionState()
            loadReview()
            let cardsOn = settings.screenCards && settings.captureScreenshots
            Task { await batcher.setScreenCards(cardsOn) }
            // 앱을 시작할 때 분야가 없거나 종류가 옛 판인 업무를 정리한다 (처음 한 번은 기존 업무 전부). 붙였으면 그래프를 새로 그린다
            Task { [weak self] in
                if await batcher.assignThemes() != nil { self?.graphVersion += 1 }
            }
            self.suggester = FolderSuggester(db: database, llm: makeQuickClient())
            self.recordingPipeline = makeRecordingPipeline(database)
            // 녹음 중에 앱을 끝내면 파일을 닫아 둔다 (다음 실행 때 받아쓰기부터 이어 간다)
            _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecordingOnQuit() }
            }
            notifier.onAction = { [weak self] action, id in Task { @MainActor in self?.handleNotificationAction(action, id: id) } }
            notifier.onEventAction = { [weak self] action, id in Task { @MainActor in self?.handleEventNotificationAction(action, id: id) } }
            notifier.onReview = { [weak self] in Task { @MainActor in self?.openReview() } }
            if AppFeatures.calendarOn { attachCalendar(database, batcher: batcher) }   // 캘린더를 꺼 두면 EventKit 도 읽지 않는다
            notifier.onDenied = { [weak self] denied in Task { @MainActor in self?.notificationsDenied = denied } }
        } catch {
            startupError = tr("데이터베이스를 열 수 없습니다: \(error.localizedDescription)")
        }
    }

    /// 개발용 미리보기 (SnapshotCatalog). DB·실행 잠금·수집기를 만들지 않고, configure 가 화면에 필요한 값만 채운다.
    /// database: 정리 상세처럼 DB 에서 읽는 화면을 그릴 때 쓰는 메모리 DB
    /// 지금 보고 있는 화면 이름 (개발용 프레임 측정 로그에 쓴다)
    var screenName: String {
        switch selectedTab {
        case .records: return "\(selectedTab.rawValue) > \(recordsSection.rawValue)"
        case .settings: return "\(selectedTab.rawValue) > \(settingsSection.rawValue)"
        default: return selectedTab.rawValue
        }
    }

    init(preview configure: (AppState) -> Void, database: SillogDatabase? = nil) {
        settings = AppSettings()
        isPreview = true
        bootstrapped = true
        if let database { db = database; store = EventStore(database) }
        configure(self)
    }

    // MARK: 단계 (온보딩 → 사용)

    /// 앱이 뜰 때 한 번: 로그인 상태를 읽어 단계를 정하고, 쓸 수 있는 상태면 서비스를 켠다.
    func bootstrap() async {
        guard !bootstrapped, !isPreview else { return }
        codexStatus = await codexAuth.status()
        bootstrapped = true
        updatePhase()
        if phase == .ready { await loadCodexModels() }
    }

    private func updatePhase() {
        let previous = phase
        // OpenAI 호환 서버(API 키)로 연결했으면 ChatGPT 로그인이 없어도 연결된 것으로 본다
        phase = AppPhase.decide(loggedIn: codexStatus != .loggedOut || settings.llmUsesAPI,
                                onboardingCompleted: UserDefaults.standard.bool(forKey: Self.onboardingKey))
        onboardingStep = OnboardingFlow.step(after: onboardingStep, phase: phase)
        if previous != phase || !bootstrapLogged {
            bootstrapLogged = true
            AppLog.write("단계: \(phase) (손쉬운 사용 \(Permissions.accessibility(prompt: false) ? tr("허용") : tr("없음")), 화면 기록 \(Permissions.screenRecording() ? tr("허용") : tr("없음")))")
        }
        phase.runsServices ? startServices() : stopServices()
    }

    /// 온보딩의 마지막 버튼. 이 뒤로는 실행할 때마다 바로 수집이 시작된다.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        updatePhase()
        Task {
            await loadCodexModels()
            await runBatch(force: false)                    // 로그인 전에 쌓여 있던 활동이 있으면 바로 정리
        }
    }

    /// 온보딩 마지막 버튼(화면 기록을 요청한 경우): 마침만 기록하고 앱을 다시 실행한다. 새 실행이 바로 수집을 시작한다
    func completeOnboardingAndRelaunch() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        relaunch()
    }

    /// 온보딩에서 API 키 연결 확인이 끝났을 때: 설정을 저장하고 단계를 다시 정해 권한 안내로 넘어가게 한다
    func finishAPIKeyConnection() {
        applySettings()
        updatePhase()
    }

    /// 온보딩 1단계의 "로그인 완료, 다음"
    func advanceOnboarding() {
        guard let step = onboardingStep else { return }
        onboardingStep = OnboardingFlow.advance(from: step, phase: phase)
    }

    /// 온보딩 시트의 닫기(×). 창은 화면 쪽이 닫는다
    func closeOnboarding() {
        onboardingStep = OnboardingFlow.close(onboardingStep, phase: phase)
    }

    /// 온보딩 권한 단계가 1초마다 부른다. 값이 같으면 화면을 건드리지 않는다
    func refreshPermissionGrants() {
        guard !isPreview else { return }
        let now = PermissionGrants(accessibility: Permissions.accessibility(prompt: false), screenRecording: Permissions.screenRecording())
        if now != permissionGrants { permissionGrants = now }
    }

    private func startServices() {
        guard !servicesRunning, let coordinator else { return }
        servicesRunning = true
        chat?.startScheduler()
        notifier.checkStatus()
        start(coordinator)
    }

    private func stopServices() {
        guard servicesRunning else { return }
        servicesRunning = false
        chat?.stop()
        tasks.forEach { $0.cancel() }
        tasks = []
        let coordinator = self.coordinator
        Task { await coordinator?.stop() }
    }

    /// 화면 기록 권한은 허용한 뒤 앱을 다시 켜야 적용된다.
    func relaunch() {
        // 새 실행이 잠금을 먼저 잡으려 하므로 미리 놓는다. 놓지 않으면 새 실행이 '이미 실행 중'(W3)으로 막힌다.
        // 다시 실행은 온보딩(수집기가 돌기 전)에서만 쓴다
        instanceLock.release()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func start(_ coordinator: CollectorCoordinator) {
        tasks.append(Task {
            await coordinator.setOnChange { [weak self] status in
                Task { @MainActor in if self?.status != status { self?.status = status } }
            }
            await coordinator.setOnFileAppeared { [weak self] path, origin in
                Task { @MainActor in await self?.fileDownloaded(path: path, origin: origin) }
            }
            await coordinator.start()
        })
        tasks.append(Task { [weak self] in                 // 화면용 숫자 갱신
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in                 // 1분마다 배치 조건 확인
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.runBatch(force: false)
            }
        })
        tasks.append(Task { [weak self] in                 // 기록 정리: 시작 10분 뒤부터 10분마다 조건 확인 (하루 한 번, 자리를 비웠을 때)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                await self?.consolidateIfDue()
                await self?.reviewIfDue()                  // 하루 한 번 정리 제안 (오늘 아직 안 만들었으면)
            }
        })
        tasks.append(Task { [weak self] in                 // 녹음: 꺼지기 전에 못 끝낸 것을 이어서 정리하고, 7일 지난 녹음 파일을 지운다 (켤 때와 하루 한 번)
            await self?.resumeRecordings()
            while !Task.isCancelled {
                self?.deleteExpiredRecordingAudio()
                try? await Task.sleep(nanoseconds: 86_400_000_000_000)
            }
        })
    }

    private func makeOpenAIClient() -> OpenAICompatClient {
        let e = settings.llmEndpoint
        let url = URL(string: e.url.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:5010/v1")!
        return OpenAICompatClient(baseURL: url, model: e.model, apiKey: e.key.isEmpty ? nil : e.key)
    }

    /// 행 배정(배치)용: 추론 medium. 평가에서 low 보다 업무 판정 +1.6%p, 자료 판정 +4%p 였고 배치는 백그라운드라 지연이 상관없다
    /// 정리 설정: 숨은 설정 값으로. 캘린더를 꺼 두면 정리 뒤 일정 찾기(AI 호출)도 하지 않는다
    static func batchConfig(themes: Bool, pipeline: String?, calendar: Bool) -> BatchConfig {
        var config = BatchConfig()
        config.pipeline = BatchPipeline(rawValue: pipeline ?? "") ?? config.pipeline
        config.themes = themes
        config.findEvents = calendar
        return config
    }

    func makeClient() -> any LLMClient {
        settings.llmUsesAPI ? makeOpenAIClient() : CodexResponsesClient(auth: codexAuth, model: settings.codexModel, reasoningEffort: "medium")
    }

    private func makeJudge() -> ActivityJudging {
        let s = settings
        switch s.judgeChoice {
        case .jev:
            guard let endpoint = s.judgeEndpoint else { return .unavailable(tr("판단 모델 Jev의 API 키를 설정해 주세요.")) }
            return .choice(JevClient(endpoint: endpoint))
        case .decisions:
            guard !s.decisionsAPIKey.isEmpty else { return .unavailable(tr("판단 모델 OpenAI Decisions의 API 키를 설정해 주세요.")) }
            return .choice(DecisionsClient(key: s.decisionsAPIKey))
        case .codex:
            return .gpt(CodexResponsesClient(auth: codexAuth, model: s.judgeCodexModel, reasoningEffort: "medium"))
        case .api, .customAPI:
            let (address, key) = s.judgeChoice == .api ? (s.llmBaseURL, s.llmAPIKey) : (s.judgeBaseURL, s.judgeAPIKey)
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ["http", "https"].contains(url.scheme ?? ""), url.host != nil, !s.judgeAPIModel.isEmpty else {
                return .unavailable(tr("판단 모델의 연결 주소, 모델, API 키를 확인해 주세요."))
            }
            return .gpt(OpenAICompatClient(baseURL: url, model: s.judgeAPIModel, apiKey: key.isEmpty ? nil : key))
        }
    }

    /// 파일 정리 제안용: 알림이 바로 떠야 하므로 low
    private func makeQuickClient() -> any LLMClient {
        settings.llmUsesAPI ? makeOpenAIClient() : CodexResponsesClient(auth: codexAuth, model: settings.codexModel, reasoningEffort: "low")
    }

    /// 녹음 정리: 기기 안 받아쓰기(녹음 중 미리 받아쓴 Whisper 글, 없으면 파일 전체를 Whisper 로, 못 쓰면 애플 음성 인식),
    /// 제목은 빠른 모델, 받아쓴 글은 ~/Documents/SILLOG 녹음. 미리 받아쓰기는 설정을 바꿔 다시 만들어도 녹음 중인 것을 잃지 않게 하나만 둔다
    private func makeRecordingPipeline(_ database: SillogDatabase) -> RecordingPipeline {
        let live = liveTranscriptions ?? LiveTranscriptions(prewarm: { await WhisperEngine.shared.prewarm() }) { samples in
            try await WhisperEngine.shared.transcribe(samples: samples)
        }
        liveTranscriptions = live
        return RecordingPipeline(db: database, transcriber: LiveFirstTranscriber(live: live, fallback: WhisperTranscriber()), llm: makeQuickClient(),
                                 textFolder: RecordingPipeline.defaultTextFolder(home: NSHomeDirectory()))
    }

    /// False only when a send cannot work; a failed model check is not, since it may be transient and is not retried.
    var chatConnected: Bool {
        if settings.chatUsesAPI {
            let endpoint = settings.chatEndpoint     // an API key is optional for local servers
            return !endpoint.url.trimmingCharacters(in: .whitespaces).isEmpty && !endpoint.model.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return codexStatus != .loggedOut
    }

    /// Args: 없음.
    /// Returns: 정리용 설정과 분리된 채팅 전용 연결.
    /// Raises: 없음. 인증·연결 오류는 실제 요청 시 전달된다.
    private func makeChatClient() -> ChatBackend {
        if settings.chatUsesAPI {
            let e = settings.chatEndpoint
            let url = URL(string: e.url.trimmingCharacters(in: .whitespaces)) ?? URL(string: "http://localhost:5010/v1")!
            return .model(OpenAICompatClient(baseURL: url, model: e.model, apiKey: e.key.isEmpty ? nil : e.key, reasoningEffort: settings.chatAPIEffort))
        }
        let model = chatCodexModel
        return .codex(CodexAppServerClient(auth: codexAuth, model: settings.effectiveChatCodexModel,
                                           effort: CodexEffort.resolve(settings.chatEffort, model: model),
                                           defaultEffort: CodexEffort.resolve(nil, model: model)))
    }

    /// Args: 없음.
    /// Returns: 없음. 개인 자료 없이 실제 채팅 스트림과 도구 호출을 검사한다.
    /// Raises: 없음. 연결·프로토콜 오류는 설정 화면에 표시한다.
    func testChatLLM() async {
        guard !chatTesting else { return }
        chatTestResult = .checking
        do {
            try await makeChatClient().checkChatConnection()
            chatTestResult = .ok(tr("연결됨 · 응답과 도구 호출 확인"))
        } catch {
            chatTestResult = .failed(error.localizedDescription)
        }
    }

    // MARK: ChatGPT 로그인

    /// 서버가 로그인을 폐기했으면(계정에서 Codex 연결 해제 등) 토큰이 지워져 있다. 그때는 수집을 멈추고 로그인 화면을 띄운다.
    func handleAuthLossIfNeeded() async {
        let status = await codexAuth.status()
        guard !settings.llmUsesAPI, status == .loggedOut, phase == .ready else { return }
        cancelCodexModelLoading(clear: true)
        codexStatus = status
        codexMessage = tr("ChatGPT 연결이 끊겨 다시 로그인해야 합니다. 계정 설정에서 Codex 연결을 해제했거나 다른 곳에서 로그아웃하면 이렇게 됩니다.")
        AppLog.write("로그인 무효화 감지 → 로그인 화면으로")
        updatePhase()
        WindowOpener.shared.openMain()
    }

    func refreshCodexStatus() {
        Task {
            codexStatus = await codexAuth.status()
            if codexStatus == .loggedOut { cancelCodexModelLoading(clear: true) }
            await loadCodexModels()
            await loadCodexUsage()
        }
    }

    func loadCodexUsage() async {
        guard codexStatus != .loggedOut else { codexUsage = nil; return }
        codexUsage = try? await CodexResponsesClient.fetchUsage(auth: codexAuth)
    }

    /// 선택한 ChatGPT 연결만 확인한다. 취소된 검사 결과는 새 로그인·검사에 적용하지 않는다.
    func loadCodexModels(force: Bool = false) async {
        let usesCodexJudge = settings.judgeChoice == .codex
        let checkBatch = (settings.llmProvider == "codex" || usesCodexJudge) && (force || codexModels.isEmpty)
        let checkChat = settings.effectiveChatProvider == "codex" && (force || chatCodexModels.isEmpty)
        guard codexStatus != .loggedOut, !codexModelsLoading, checkBatch || checkChat else { return }
        let id = UUID()
        codexModelTaskID = id
        codexModelsLoading = true
        if checkBatch { codexModelsError = nil; codexModelFailures = [:] }
        if checkChat { chatCodexModelsError = nil; chatCodexModelFailures = [:] }
        let task = Task { [self] in
            defer {
                if codexModelTaskID == id {
                    codexModelsLoading = false
                    codexModelTask = nil
                    codexModelTaskID = nil
                }
            }
            do {
                let candidates = try await CodexResponsesClient.listModels(auth: codexAuth)
                try Task.checkCancellation()
                guard codexModelTaskID == id else { return }
                guard !candidates.isEmpty else { throw LLMError.backend(tr("모델 후보 목록이 비어 있습니다.")) }
                codexModelCandidates = candidates
                let auth = codexAuth
                if checkBatch {
                    let result = try await CodexResponsesClient.verifyModels(candidates) { model in
                        let client = CodexResponsesClient(auth: auth, model: model.slug, reasoningEffort: "medium", timeout: 45)
                        if case .failure(let error) = await client.selfTest() { throw error }
                    }
                    try Task.checkCancellation()
                    guard codexModelTaskID == id else { return }
                    codexModels = result.models
                    codexModelsError = verificationError(result, empty: tr("현재 연결에서 사용할 수 있는 정리 모델이 없습니다."))
                    codexModelFailures = Self.failureLines(result)
                    if settings.llmProvider == "codex", result.isComplete, let first = result.models.first,
                       !result.models.contains(where: { $0.slug == settings.codexModel }),
                       !result.failures.contains(where: { $0.model.slug == settings.codexModel }) {
                        settings.codexModel = result.models.first { $0.slug == CodexResponsesClient.defaultModel }?.slug ?? first.slug
                        applySettings()
                    }
                    if !result.isComplete {
                        if checkChat { chatCodexModelsError = codexModelsError }
                        return
                    }
                }
                if checkChat {
                    let result = try await CodexResponsesClient.verifyModels(candidates) { model in
                        try await CodexAppServerClient(auth: auth, model: model.slug).checkConnection()
                    }
                    try Task.checkCancellation()
                    guard codexModelTaskID == id else { return }
                    chatCodexModels = result.models
                    chatCodexModelsError = verificationError(result, empty: tr("현재 연결에서 사용할 수 있는 채팅 모델이 없습니다."))
                    chatCodexModelFailures = Self.failureLines(result)
                    let chatModel = settings.effectiveChatCodexModel
                    if result.isComplete, let first = result.models.first,
                       !result.models.contains(where: { $0.slug == chatModel }),
                       !result.failures.contains(where: { $0.model.slug == chatModel }) {
                        // '정리 모델과 같이'인데 정리 모델이 채팅에서 안 되면 채팅만 '따로 고르기'로 돌려 확인된 모델로 보낸다
                        if settings.chatSameAsOrganize { settings.chatProvider = settings.llmProvider; settings.chatSameAsOrganize = false }
                        settings.chatCodexModel = result.models.first { $0.slug == CodexResponsesClient.defaultModel }?.slug ?? first.slug
                        applySettings()
                    }
                }
            } catch is CancellationError {
                // 로그아웃·연결 변경·중단으로 끝난 검사는 이전 결과를 덮어쓰지 않는다.
            } catch {
                guard codexModelTaskID == id, !Task.isCancelled else { return }
                let message = tr("모델 확인 실패: \(Self.friendlyModelError(error.localizedDescription))")
                if checkBatch { codexModelsError = message }
                if checkChat { chatCodexModelsError = message }
            }
        }
        codexModelTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// 서버 원문(HTTP 429 JSON 등)을 사람이 읽을 한 줄로 바꾼다
    static func friendlyModelError(_ raw: String) -> String {
        if raw.contains("usage_limit_reached") || raw.contains("HTTP 429") {
            guard let r = raw.range(of: #""resets_in_seconds":\s*(\d+)"#, options: .regularExpression),
                  let secs = Int(raw[r].filter(\.isNumber)) else { return tr("사용량 한도에 도달했어요") }
            let d = secs / 86400, h = secs % 86400 / 3600
            return tr("사용량 한도에 도달했어요. \(d > 0 ? tr("\(d)일 ") : "")\(h)시간 뒤 다시 쓸 수 있어요")
        }
        if raw.contains("HTTP 401") || raw.contains("HTTP 403") { return tr("다시 로그인해야 해요") }
        if raw.contains("HTTP 5") { return tr("서버가 잠시 응답하지 않아요") }
        let line = raw.split(separator: "\n").first.map(String.init) ?? raw
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }

    private static func failureLines(_ result: CodexModelVerification) -> [String: String] {
        Dictionary(result.failures.map { ($0.model.slug, "\($0.model.displayName): \(friendlyModelError($0.message))") }) { first, _ in first }
    }

    private func verificationError(_ result: CodexModelVerification, empty: String) -> String? {
        if !result.failures.isEmpty {
            return result.failures.map { "\($0.model.displayName): \(Self.friendlyModelError($0.message))" }.joined(separator: "\n")
        }
        return result.models.isEmpty ? empty : nil
    }

    /// 기록 자료의 파일 구역으로 (메뉴 막대 파일 줄, 알림 '열기')
    func openFileSuggestions() {
        selectedTab = .records
        recordsSection = .files
    }

    /// 설정의 일반 구역으로 (권한·알림 꺼짐 안내)
    func openGeneralSettings() {
        selectedTab = .settings
        settingsSection = .general
    }

    func cancelCodexModelLoading(clear: Bool = false) {
        codexModelTask?.cancel()
        codexModelTask = nil
        codexModelTaskID = nil
        codexModelsLoading = false
        if clear {
            codexModels = []
            chatCodexModels = []
            codexModelsError = nil
            chatCodexModelsError = nil
            codexModelFailures = [:]
            chatCodexModelFailures = [:]
        }
    }

    func updateCodexModelProviders() {
        cancelCodexModelLoading()
        Task { await loadCodexModels() }
    }

    /// 기기 코드 로그인: 코드를 받아 클립보드에 넣고 브라우저를 연 뒤, 사용자가 승인할 때까지 기다린다.
    func startCodexLogin() {
        guard loginTask == nil else { return }
        cancelCodexModelLoading(clear: true)
        codexMessage = nil
        loginBlocked = false
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loginTask = nil; self.deviceCode = nil }
            do {
                let code = try await self.codexAuth.beginDeviceLogin()
                self.deviceCode = code
                self.copyDeviceCode()
                NSWorkspace.shared.open(code.verificationURL)
                self.codexStatus = try await self.codexAuth.completeDeviceLogin(code)
                self.codexMessage = tr("로그인했습니다")
                self.updatePhase()                                      // 로그인 → 권한 안내(처음) 또는 바로 사용
                await self.loadCodexModels()
                if self.phase == .ready { await self.runBatch(force: false) }   // 밀려 있던 활동을 바로 정리
            } catch let error as CodexAuthError {
                self.codexMessage = error == .cancelled ? nil : error.description
                self.loginBlocked = error == .deviceLoginNotEnabled
            } catch is CancellationError {
                self.codexMessage = nil
            } catch {
                self.codexMessage = error.localizedDescription
            }
        }
    }

    func cancelCodexLogin() {
        loginTask?.cancel()
    }

    func copyDeviceCode() {
        guard let code = deviceCode?.userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func logoutCodex() {
        cancelCodexModelLoading(clear: true)
        Task {
            try? await codexAuth.logout()
            codexStatus = await codexAuth.status()
            codexMessage = nil
            updatePhase()                                               // 로그아웃하면 수집을 멈추고 로그인 화면으로
        }
    }

    // MARK: 동작

    func runBatch(force: Bool) async {
        guard let batcher, settings.batchEnabled || force, !batchRunning, !erasing else { return }   // 지우는 동안은 정리하지 않는다 (지운 업무를 다시 만들지 않게)
        batchRunning = true
        defer { batchRunning = false }
        var applied = false, failed = false
        var announced = 0                                  // 이번 정리에서 띄운 일정 알림 (3개까지)
        batchResult = nil
        for _ in 0..<20 {                                  // 밀린 구간이 많으면 이어서 처리
            let outcome = await batcher.runIfDue(force: force)
            switch outcome {
            case .ok(let stats):
                applied = true
                AppLog.write("정리 성공: 세션 \(stats.sessions + stats.sessionsExtended), 새 업무 \(stats.tasksCreated), 자료 \(stats.resources)")
                lastBatchText = MenuBarModel.batchSummary(clock: Self.clock.string(from: Date()), newTasks: stats.tasksCreated, resources: stats.resources)
                announced += announceEventSuggestions(limit: 3 - announced)
                if let waiting = stats.deferredJudgmentRows, waiting > 0 {
                    lastBatchText += tr(" · 판단 대기 \(waiting)행")
                    break
                }
                continue
            case .failed(let message):
                failed = true
                AppLog.write("정리 실패: \(message.prefix(200))")
                await handleAuthLossIfNeeded()
                lastBatchText = tr("\(Self.clock.string(from: Date())) 정리 실패: \(message.prefix(120))")
            case .skipped:
                break
            }
            break
        }
        if applied { graphVersion += 1 }
        refresh()
        if force {                                         // 직접 누른 정리만 결과를 잠깐 보여 준다
            batchResult = !failed
            Task { @MainActor in try? await Task.sleep(nanoseconds: 2_500_000_000); if !self.batchRunning { self.batchResult = nil } }
        }
    }

    func togglePause() {
        guard let coordinator else { return }
        let next = !status.paused
        Task { await coordinator.setPaused(next) }
    }

    /// The chosen chat model from the verified list; nil until the list loads.
    var chatCodexModel: CodexModel? {
        (chatCodexModels + codexModelCandidates).first { $0.slug == settings.effectiveChatCodexModel }
    }

    /// 채팅 화면에서 모델 바꾸기: 다음 메시지부터 그 모델로 보낸다. 설정 화면을 거치지 않으니 여기서 저장한다 (업무 정리 모델은 그대로)
    func selectChatModel(_ slug: String) {
        guard !slug.isEmpty, settings.effectiveChatCodexModel != slug else { return }
        // '정리 모델과 같이'였으면 채팅에서 다른 모델을 고르는 순간 '따로 고르기'로 바뀐다
        if settings.chatSameAsOrganize { settings.chatProvider = settings.llmProvider; settings.chatSameAsOrganize = false }
        settings.chatCodexModel = slug
        if !isPreview { settings.save() }
    }

    /// Picked in the chat model menu, which skips the settings screen, so it saves here.
    func selectChatEffort(_ effort: String) {
        guard settings.chatEffort != effort else { return }
        settings.chatEffort = effort
        if !isPreview { settings.save() }
    }

    func selectChatAPIEffort(_ effort: String?) {
        guard settings.chatAPIEffort != effort else { return }
        settings.chatAPIEffort = effort
        if !isPreview { settings.save() }
    }

    /// View-menu zoom skips the settings screen, so it saves here.
    func setTextScale(_ scale: Double) {
        guard settings.textScale != scale else { return }
        settings.textScale = scale
        if !isPreview { settings.save() }
    }

    func applySettings() {
        if !isPreview { settings.save() }
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        let collectorSettings = settings.collector
        let client = makeClient()
        let judge = makeJudge()
        let cardsOn = settings.screenCards && settings.captureScreenshots
        if let db {
            suggester = FolderSuggester(db: db, llm: makeQuickClient())
            recordingPipeline = makeRecordingPipeline(db)
        }
        folderIndex = nil                                   // 검색 폴더가 바뀌었을 수 있으니 다음 제안 때 다시 색인
        Task { [coordinator, batcher, consolidator] in
            await coordinator?.update(settings: collectorSettings)
            await batcher?.setModels(organizer: client, judge: judge)
            await batcher?.setScreenCards(cardsOn)
            await consolidator?.setLLM(client)
        }
    }

    func testLLM() async { await testConnection(settings.llmProvider) }

    /// Sends a small test call over one connection; "openai" is the API server, anything else the ChatGPT login.
    func testConnection(_ provider: String) async {
        connectionChecks[provider] = .checking
        if provider == "openai" {
            let client = makeOpenAIClient()
            let reachable = await client.ping()
            switch await client.selfTest() {
            case .success(let message): connectionChecks[provider] = .ok(tr("연결됨. \(message)"))
            case .failure(let error):
                connectionChecks[provider] = .failed(reachable
                    ? tr("서버는 응답하지만 호출에 실패했습니다.\n\(error.description.prefix(300))")
                    : tr("서버에 연결할 수 없습니다. 서버가 켜져 있는지 확인하세요.\n\(error.description.prefix(200))"))
            }
            return
        }
        let client = CodexResponsesClient(auth: codexAuth, model: settings.codexModel, reasoningEffort: "medium", timeout: 45)
        switch await client.selfTest() {
        case .success(let message): connectionChecks[provider] = .ok(tr("연결됨. \(message)"))
        case .failure(let error): connectionChecks[provider] = .failed(String(error.description.prefix(300)))
        }
        codexStatus = await codexAuth.status()
    }

    func refresh() {
        guard let store else { return }
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        // 값이 같으면 @Published 를 건드리지 않는다. 5초마다 전체 화면이 다시 그려지는 것을 막는다.
        if let counts = try? store.counts(since: startOfDay) {
            if counts.total != todayCount { todayCount = counts.total }
            if counts.unprocessed != pendingCount { pendingCount = counts.unprocessed }
        }
        let newRecent = (try? store.recent(limit: 500)) ?? []
        if newRecent != recent { recent = newRecent }
        let newBatches = (try? store.recentBatchSummaries(limit: 100)) ?? []
        if newBatches != batches { batches = newBatches }
        refreshFileSuggestions()
    }

    func observationText(_ textId: Int64) -> String? {
        (try? store?.texts(ids: [textId]))?[textId]
    }

    /// 상세 패널용: 선택한 배치만 프롬프트·응답까지 전부 읽는다.
    func batchDetail(_ id: Int64) -> BatchRecord? {
        (try? store?.batch(id: id)) ?? nil
    }

    /// 그래프 뷰로 보낼 JSON. 클래스 층도 함께 보내고, 보일지 말지는 화면에서 정한다.
    func graphJSON() -> String {
        guard let db, let graph = try? db.writer.read({ try GraphTx($0).subgraph(since: nil, includeTBox: true) }),
              let data = try? GraphJSONExporter.export(graph) else { return #"{"nodes":[],"links":[]}"# }
        return String(data: data, encoding: .utf8) ?? #"{"nodes":[],"links":[]}"#
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: databasePath)])
    }

    var statusLine: String {
        if startupError != nil { return tr("시작 실패") }
        if phase != .ready { return tr("시작하려면 ChatGPT 로그인이 필요합니다") }
        if status.paused { return tr("일시정지됨") }
        if status.idle { return tr("자리 비움") }
        return status.running ? tr("수집 중") : tr("시작하는 중")
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// Result of a connection check.
enum CheckResult: Equatable {
    case checking
    case ok(String)
    case failed(String)

    var isOK: Bool { if case .ok = self { return true } else { return false } }
    var message: String {
        switch self {
        case .checking: return tr("확인 중…")
        case .ok(let message), .failed(let message): return message
        }
    }
}
