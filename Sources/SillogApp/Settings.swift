import Foundation
import SillogCollectors
import SillogCore

/// 사용자 설정. UserDefaults 에 JSON 한 덩어리로 저장한다.
struct AppSettings: Codable, Equatable {
    /// "codex" = 앱 안에서 ChatGPT 로그인 후 직접 호출, "openai" = OpenAI 호환 서버(gpt-proxy, Ollama 등)
    var llmProvider = "codex"
    /// ChatGPT 로그인 방식에서 쓸 모델. 계정마다 가능한 모델이 달라 설정 화면에서 목록을 받아 고른다.
    var codexModel = CodexResponsesClient.defaultModel
    var llmBaseURL = "http://localhost:5010/v1"
    var llmModel = "gpt-5.4-mini"
    var llmAPIKey = ""
    var chatProvider = "codex"
    var chatCodexModel = CodexResponsesClient.defaultModel
    var chatBaseURL = "http://localhost:5010/v1"
    var chatModel = "gpt-5.4-mini"
    var chatAPIKey = ""
    /// Stored as "gpt" / "jev" / "decisions"; read through `judgeChoice`.
    var judgeProvider = "gpt"
    /// For the gpt judge: "codex", "openai" (the shared API server) or "custom" (its own URL and key).
    var judgeGPTProvider = "codex"
    var judgeCodexModel = CodexResponsesClient.defaultModel
    var judgeBaseURL = "http://localhost:5010/v1"
    var judgeAPIModel = "gpt-5.4-mini"
    var judgeAPIKey = ""
    var jevAPIKey = ""
    var decisionsAPIKey = ""
    /// 채팅 모델을 정리 모델과 같게 쓴다(기본). 끄면 chatProvider 와 채팅 모델을 따로 고른다
    var chatSameAsOrganize = true
    var batchEnabled = true
    var captureText = true
    var captureScreenshots = true
    var watchDownloads = true
    var readChatLogs = true
    var retentionDays = 7
    /// 메뉴바 아이콘은 노치나 다른 아이콘에 가려질 수 있어서 Dock 아이콘을 기본으로 보여준다.
    var showDockIcon = true
    var excludedBundles: [String] = PrivacyFilter.defaultExcludedBundles.sorted()
    var suggestFolders = true
    /// 화면 기억 카드: 대표 화면을 LLM 에 보내 화면 내용을 기록한다
    var screenCards = true
    var maskPII = true
    /// 정리 위치 후보를 찾을 폴더들 (~ 표기 허용)
    var folderRoots: [String] = ["~/Desktop", "~/Documents"]
    var language = AppLanguage.system

    private static let key = "sillog.settings.v1"

    init() {}

    /// 나중에 항목이 늘어도 예전에 저장한 설정이 통째로 초기화되지 않게, 없는 값은 기본값으로 채운다.
    /// Args: decoder는 저장된 사용자 설정이다.
    /// Returns: 기존 값을 보존하고 채팅 전용 설정을 채운 설정 객체.
    /// Raises: 저장된 값의 타입이 잘못된 경우 디코딩 오류.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        llmProvider = try c.decodeIfPresent(String.self, forKey: .llmProvider) ?? d.llmProvider
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? d.codexModel
        llmBaseURL = try c.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? d.llmBaseURL
        llmModel = try c.decodeIfPresent(String.self, forKey: .llmModel) ?? d.llmModel
        llmAPIKey = try c.decodeIfPresent(String.self, forKey: .llmAPIKey) ?? d.llmAPIKey
        // 기존 사용자는 처음 한 번 기존 연결을 이어받고, 이후에는 각각 저장한다.
        chatProvider = try c.decodeIfPresent(String.self, forKey: .chatProvider) ?? llmProvider
        chatCodexModel = try c.decodeIfPresent(String.self, forKey: .chatCodexModel) ?? codexModel
        chatBaseURL = try c.decodeIfPresent(String.self, forKey: .chatBaseURL) ?? llmBaseURL
        chatModel = try c.decodeIfPresent(String.self, forKey: .chatModel) ?? llmModel
        chatAPIKey = try c.decodeIfPresent(String.self, forKey: .chatAPIKey) ?? llmAPIKey
        let oldJudge = try c.decodeIfPresent(String.self, forKey: .judgeProvider) ?? "gpt"
        judgeProvider = ["jev", "decisions"].contains(oldJudge) ? oldJudge : "gpt"
        judgeGPTProvider = try c.decodeIfPresent(String.self, forKey: .judgeGPTProvider) ?? llmProvider
        judgeCodexModel = try c.decodeIfPresent(String.self, forKey: .judgeCodexModel) ?? codexModel
        judgeBaseURL = try c.decodeIfPresent(String.self, forKey: .judgeBaseURL) ?? llmBaseURL
        judgeAPIModel = try c.decodeIfPresent(String.self, forKey: .judgeAPIModel) ?? llmModel
        judgeAPIKey = try c.decodeIfPresent(String.self, forKey: .judgeAPIKey) ?? llmAPIKey
        jevAPIKey = try c.decodeIfPresent(String.self, forKey: .jevAPIKey) ?? d.jevAPIKey
        decisionsAPIKey = try c.decodeIfPresent(String.self, forKey: .decisionsAPIKey) ?? d.decisionsAPIKey
        // Before "custom" existed, an API judge always had its own address and key.
        if judgeGPTProvider == "openai", (judgeBaseURL, judgeAPIKey) != (llmBaseURL, llmAPIKey) { judgeGPTProvider = "custom" }
        // 예전 사용자는 채팅을 따로 골라 두었을 수 있다: 저장값이 없으면 정리와 채팅 설정이 이미 같을 때만 '같게'로 본다
        chatSameAsOrganize = try c.decodeIfPresent(Bool.self, forKey: .chatSameAsOrganize)
            ?? (chatProvider == llmProvider && chatCodexModel == codexModel && chatModel == llmModel)
        // 지금 쓰지 않는 연결 방식이 저장돼 있으면 ChatGPT 로그인으로 돌린다
        let known = ["codex", "openai"]
        if !known.contains(llmProvider) { llmProvider = "codex" }
        if !known.contains(chatProvider) { chatProvider = "codex" }
        if !(known + ["custom"]).contains(judgeGPTProvider) { judgeGPTProvider = "codex" }
        batchEnabled = try c.decodeIfPresent(Bool.self, forKey: .batchEnabled) ?? d.batchEnabled
        captureText = try c.decodeIfPresent(Bool.self, forKey: .captureText) ?? d.captureText
        captureScreenshots = try c.decodeIfPresent(Bool.self, forKey: .captureScreenshots) ?? d.captureScreenshots
        watchDownloads = try c.decodeIfPresent(Bool.self, forKey: .watchDownloads) ?? d.watchDownloads
        readChatLogs = try c.decodeIfPresent(Bool.self, forKey: .readChatLogs) ?? d.readChatLogs
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        // Older saves list system windows that are now always excluded.
        excludedBundles = (try c.decodeIfPresent([String].self, forKey: .excludedBundles) ?? d.excludedBundles)
            .filter { !PrivacyFilter.alwaysExcludedBundles.contains($0) }
        suggestFolders = try c.decodeIfPresent(Bool.self, forKey: .suggestFolders) ?? d.suggestFolders
        screenCards = try c.decodeIfPresent(Bool.self, forKey: .screenCards) ?? d.screenCards
        maskPII = try c.decodeIfPresent(Bool.self, forKey: .maskPII) ?? d.maskPII
        folderRoots = try c.decodeIfPresent([String].self, forKey: .folderRoots) ?? d.folderRoots
        // Saves from before the setting existed had a Korean UI.
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .ko
    }

    /// API keys go to the Keychain; the UserDefaults JSON keeps them blank.
    private static let secrets: [(account: String, field: WritableKeyPath<AppSettings, String>)] = [
        ("settings.llm", \.llmAPIKey), ("settings.chat", \.chatAPIKey), ("settings.judge", \.judgeAPIKey),
        ("settings.jev", \.jevAPIKey), ("settings.decisions", \.decisionsAPIKey),
    ]

    /// The Dock setting alone, read without the Keychain: launch needs it before AppState loads the full settings,
    /// and a second full load asked for Keychain access twice.
    static var savedShowDockIcon: Bool {
        let saved = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        return (saved ?? AppSettings()).showDockIcon
    }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var saved = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        var plaintext = false
        for secret in secrets {
            // A key still in the JSON is from before the move, so it wins and gets moved now.
            if !saved[keyPath: secret.field].isEmpty { plaintext = true; continue }
            saved[keyPath: secret.field] = (try? ChatSecrets.load(secret.account)) ?? ""
        }
        if plaintext { saved.save() }
        return saved
    }

    func save() {
        var stored = self
        for secret in Self.secrets {
            // Keep the plaintext copy if the Keychain refuses, so the key is not lost.
            if (try? ChatSecrets.save(self[keyPath: secret.field], account: secret.account)) != nil { stored[keyPath: secret.field] = "" }
        }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var collector: CollectorSettings {
        var settings = CollectorSettings()
        settings.captureText = captureText
        settings.captureScreenshots = captureScreenshots
        settings.watchDownloads = watchDownloads
        settings.readChatLogs = readChatLogs
        settings.retentionDays = retentionDays
        settings.excludedBundles = Set(excludedBundles)
        return settings
    }

    /// 정리, 채팅이 API(OpenAI 호환 서버)로 가는지. 아니면 ChatGPT 로그인
    var llmUsesAPI: Bool { llmProvider != "codex" }
    /// 채팅이 실제로 쓰는 연결: '정리 모델과 같이'면 정리 연결을 그대로 쓴다
    var effectiveChatProvider: String { chatSameAsOrganize ? llmProvider : chatProvider }
    var chatUsesAPI: Bool { effectiveChatProvider != "codex" }
    /// API 로 갈 때 실제로 쓰는 주소, 모델, 키
    var llmEndpoint: (url: String, model: String, key: String) { (llmBaseURL, llmModel, llmAPIKey) }
    var chatEndpoint: (url: String, model: String, key: String) {
        if chatSameAsOrganize { return llmEndpoint }
        return (chatBaseURL, chatModel, chatAPIKey)
    }
    /// Chat picks its own connection and model now; a save that followed organize starts from the same values.
    mutating func splitChatFromOrganize() {
        if chatSameAsOrganize {
            chatProvider = llmProvider; chatCodexModel = codexModel; chatModel = llmModel
            chatSameAsOrganize = false
        }
        // Organize and chat share one API server.
        chatBaseURL = llmBaseURL; chatAPIKey = llmAPIKey
    }
    var effectiveChatCodexModel: String { chatSameAsOrganize ? codexModel : chatCodexModel }
    var chatModelName: String { chatUsesAPI ? chatEndpoint.model : effectiveChatCodexModel }
    /// Jev 연결. 키가 비어 있으면 판단을 대기한다.
    var judgeEndpoint: JevEndpoint? {
        switch judgeProvider {
        case "jev": return jevAPIKey.isEmpty ? nil : JevEndpoint(url: JevEndpoint.typesafeURL, model: JevEndpoint.defaultModel, key: jevAPIKey)
        default: return nil
        }
    }
    static let jevSite = URL(string: "https://typesafe.ai")!
    static let openAIKeySite = URL(string: "https://platform.openai.com/api-keys")!

    enum JudgeChoice: String, CaseIterable {
        case codex, api, customAPI, jev, decisions
    }

    var judgeChoice: JudgeChoice {
        get {
            switch judgeProvider {
            case "jev": return .jev
            case "decisions": return .decisions
            default:
                switch judgeGPTProvider {
                case "openai": return .api
                case "custom": return .customAPI
                default: return .codex
                }
            }
        }
        set {
            switch newValue {
            case .jev, .decisions: judgeProvider = newValue == .jev ? "jev" : "decisions"
            case .codex, .api, .customAPI:
                judgeProvider = "gpt"
                judgeGPTProvider = [.codex: "codex", .api: "openai", .customAPI: "custom"][newValue]!
            }
        }
    }
    static func providerName(_ provider: String) -> String { provider == "openai" ? "API" : tr("ChatGPT 구독") }
}

extension UserDefaults {
    /// Moves pre-rename `workgraph.*` keys to `sillog.*` once.
    static func migrateLegacyKeys(_ defaults: UserDefaults = .standard) {
        for name in ["settings.v1", "onboardingCompleted", "launchedBefore"] {
            let old = "workgraph.\(name)", new = "sillog.\(name)"
            guard defaults.object(forKey: new) == nil, let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
            defaults.removeObject(forKey: old)
        }
    }
}
