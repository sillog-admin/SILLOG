import AppKit
import ApplicationServices
import CoreGraphics
import SillogCore

public struct CollectorSettings: Sendable, Equatable {
    /// 컨텍스트(앱·창·URL) 확인 주기(초). 접근성 호출 두세 번이라 가볍다.
    public var sampleInterval: Double = 3
    /// 같은 창에 머물러도 이 간격으로 생존 신호 행을 남긴다. 체류시간 계산의 기준.
    public var heartbeat: Double = 60
    public var idleThreshold: Double = 120
    public var captureText = true
    public var captureScreenshots = true
    public var watchDownloads = true
    /// AI 코딩 도구(Claude Code, Codex CLI)에 입력한 메시지를 로컬 로그에서 읽는다
    public var readChatLogs = true
    public var enableWebAccessibility = true
    /// 컨텍스트가 바뀐 뒤 화면이 자리 잡을 때까지 기다렸다가 텍스트·스크린샷을 뜬다.
    public var settleDelay: Double = 1.5
    public var screenshotMinInterval: Double = 10
    /// 접근성 텍스트가 이보다 적으면 OCR 로 보충한다.
    public var ocrMinChars = 100
    /// 제목만 바뀌는 창(터미널 스피너, 재생 시간)은 이 간격으로만 새 행을 만든다.
    public var titleChangeMinInterval: Double = 10
    public var retentionDays = 7
    public var excludedBundles: Set<String> = PrivacyFilter.defaultExcludedBundles

    public init() {}
}

public struct CollectorStatus: Sendable, Equatable {
    public var running = false
    public var paused = false
    public var idle = false
    public var accessibility = false
    public var screenRecording = false
    public var observations = 0
    public var screenshots = 0
    public var lastObservation: Observation?

    public init() {}
}

/// 수집 총괄. 상태는 전부 이 actor 안에 있고, UI 는 onChange 로 요약만 받는다.
/// 어떤 실패(권한 없음, DB 오류)에도 멈추지 않고 다음 주기에 다시 시도한다.
public actor CollectorCoordinator {
    private let store: EventStore
    private let capturesDir: URL
    private var settings: CollectorSettings
    private let sampler = ContextSampler()
    private let capturer = ScreenCapturer()

    private var loop: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var watcher: DownloadsWatcher?
    private var chatWatcher: ChatLogWatcher?

    private var last: ContextSnapshot?
    private var lastObservationId: Int64?
    private var lastObservationAt = 0.0
    private var lastScreenshotAt = 0.0
    private var lastScreenshotHash: UInt64?
    private var lastCleanupAt = 0.0
    private var isIdle = false
    private var locked = false
    private var status = CollectorStatus()
    private var onChange: (@Sendable (CollectorStatus) -> Void)?
    private var onFileAppeared: (@Sendable (_ path: String, _ originURL: String?) -> Void)?

    public init(store: EventStore, capturesDir: URL, settings: CollectorSettings = CollectorSettings()) {
        self.store = store
        self.capturesDir = capturesDir
        self.settings = settings
    }

    public func setOnChange(_ handler: (@Sendable (CollectorStatus) -> Void)?) { onChange = handler }
    /// 다운로드 폴더에 새 파일이 생겼을 때 (기록 후) 알려 준다. 정리 위치 제안이 여기에 붙는다.
    public func setOnFileAppeared(_ handler: (@Sendable (_ path: String, _ originURL: String?) -> Void)?) { onFileAppeared = handler }
    public func currentStatus() -> CollectorStatus { status }

    public func update(settings new: CollectorSettings) {
        let downloadsChanged = new.watchDownloads != settings.watchDownloads
        let chatChanged = new.readChatLogs != settings.readChatLogs
        settings = new
        if downloadsChanged, loop != nil { configureDownloadsWatcher() }
        if chatChanged, loop != nil { configureChatWatcher() }
    }

    public func setPaused(_ paused: Bool) {
        status.paused = paused
        if paused { settleTask?.cancel(); last = nil }
        publish()
    }

    public func start() {
        guard loop == nil else { return }
        try? store.closeIdle(at: Date().timeIntervalSince1970)        // 지난 실행에서 열린 채 남은 유휴 구간 정리
        status.running = true
        registerObservers()
        configureDownloadsWatcher()
        configureChatWatcher()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let interval = await self.settings.sampleInterval
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel(); loop = nil
        settleTask?.cancel(); settleTask = nil
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        watcher?.stop(); watcher = nil
        chatWatcher?.stop(); chatWatcher = nil
        status.running = false
        publish()
    }

    // MARK: 주기 작업

    private func tick() async {
        let now = Date().timeIntervalSince1970
        status.accessibility = AXIsProcessTrusted()
        status.screenRecording = CGPreflightScreenCaptureAccess()
        defer { publish() }
        guard !status.paused else { return }

        let idleSeconds = IdleMonitor.secondsSinceLastInput()
        if locked || idleSeconds >= settings.idleThreshold {
            if !isIdle {
                isIdle = true
                settleTask?.cancel()
                try? store.openIdle(at: max(lastObservationAt, now - idleSeconds))
            }
            status.idle = true
            return
        }
        if isIdle {
            isIdle = false
            try? store.closeIdle(at: now)
            last = nil                                        // 돌아오면 같은 창이어도 새 행으로 시작
        }
        status.idle = false

        guard var snapshot = sampleContext() else { return }
        let privacy = PrivacyFilter(excludedBundles: settings.excludedBundles)
        var redacted = false
        if privacy.isExcluded(bundle: snapshot.appBundle) {
            // 제외한 앱은 이름과 시간만 남긴다. 창 제목·주소·텍스트·스크린샷은 남기지 않는다.
            snapshot = ContextSnapshot(appBundle: snapshot.appBundle, appName: snapshot.appName, windowTitle: nil, url: nil, docPath: nil, pid: snapshot.pid)
            redacted = true
        } else if privacy.isPrivateWindow(title: snapshot.windowTitle) {
            snapshot.windowTitle = tr("비공개 창"); snapshot.url = nil; snapshot.docPath = nil
            redacted = true
        }

        if !snapshot.sameContext(as: last) {
            let titleOnly = last.map { $0.pid == snapshot.pid && $0.windowFrame == snapshot.windowFrame && $0.screenWindowID == snapshot.screenWindowID && $0.appBundle == snapshot.appBundle && $0.url == snapshot.url && $0.docPath == snapshot.docPath } ?? false
            if titleOnly, now - lastObservationAt < settings.titleChangeMinInterval { return }
            let trigger = last?.appBundle == snapshot.appBundle ? "window_change" : "app_activate"
            guard let id = insert(snapshot, trigger: trigger, at: now) else { return }
            if !redacted { scheduleSettle(observationId: id, snapshot: snapshot) }
        } else if now - lastObservationAt >= settings.heartbeat {
            guard let id = insert(snapshot, trigger: "periodic", at: now) else { return }
            if !redacted, settings.captureScreenshots {
                await captureScreenshot(observationId: id, snapshot: snapshot, needImageForOCR: false)
            }
        }
        if now - lastCleanupAt > 6 * 3600 { lastCleanupAt = now; cleanupOldCaptures(now: now) }
    }

    private func insert(_ snapshot: ContextSnapshot, trigger: String, at now: Double) -> Int64? {
        let observation = Observation(ts: now, trigger: trigger, appBundle: snapshot.appBundle, appName: snapshot.appName,
                                      windowTitle: snapshot.windowTitle, url: snapshot.url, docPath: snapshot.docPath)
        guard let id = try? store.insert(observation) else { return nil }
        last = snapshot
        lastObservationId = id
        lastObservationAt = now
        status.observations += 1
        var saved = observation
        saved.id = id
        status.lastObservation = saved
        return id
    }

    private func scheduleSettle(observationId: Int64, snapshot: ContextSnapshot) {
        settleTask?.cancel()
        let delay = settings.settleDelay
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.settle(observationId: observationId, snapshot: snapshot)
        }
    }

    /// 화면이 자리 잡은 뒤: 접근성 텍스트 → 부족하면 OCR → 스크린샷 저장.
    private func settle(observationId: Int64, snapshot: ContextSnapshot) async {
        guard isCurrent(snapshot) else { return }
        var text = ""
        if settings.captureText, let read = sampler.readText(pid: snapshot.pid) { text = read.text }
        guard isCurrent(snapshot) else { return }
        let needOCR = settings.captureText && text.count < settings.ocrMinChars
        // 화면이 바뀌었으면 한 장은 꼭 남긴다 (화면 기억 카드의 대표 후보)
        let image = await captureScreenshot(observationId: observationId, snapshot: snapshot, needImageForOCR: needOCR, contextChanged: true)

        var source = "ax"
        if needOCR, let image {
            let recognized = OCRReader.recognize(image)
            if !recognized.isEmpty {
                source = text.isEmpty ? "ocr" : "hybrid"
                text = text.isEmpty ? recognized : text + "\n" + recognized
            }
        }
        text = ScreenText.trimmed(text, appBundle: snapshot.appBundle, appName: snapshot.appName)   // 편집기는 앞부분만
        guard isCurrent(snapshot), settings.captureText, !text.isEmpty,
              let textId = try? store.upsertText(text, source: source, at: Date().timeIntervalSince1970) else { return }
        try? store.attach(observationId: observationId, textId: textId, screenshotPath: nil)
    }

    private func sampleContext() -> ContextSnapshot? {
        sampler.sample(enableWebAccessibility: settings.enableWebAccessibility,
                       identifyScreenWindow: status.screenRecording && (settings.captureText || settings.captureScreenshots))
    }

    private func isCurrent(_ snapshot: ContextSnapshot) -> Bool {
        let privacy = PrivacyFilter(excludedBundles: settings.excludedBundles)
        return !Task.isCancelled && status.running && !status.paused && !locked && !isIdle
            && !privacy.isExcluded(bundle: snapshot.appBundle) && !privacy.isPrivateWindow(title: snapshot.windowTitle)
            && snapshot.sameContext(as: last)
            && snapshot.sameContext(as: sampleContext())
    }

    /// 화면이 거의 안 바뀌었으면 저장하지 않는다. OCR 용으로만 필요한 경우 이미지는 돌려주되 파일은 남기지 않을 수 있다.
    @discardableResult
    private func captureScreenshot(observationId: Int64, snapshot: ContextSnapshot, needImageForOCR: Bool, contextChanged: Bool = false) async -> CGImage? {
        let now = Date().timeIntervalSince1970
        // 화면이 바뀐 직후는 간격과 상관없이 찍는다 (2초 안의 연속 전환만 거른다). 같은 화면에 머무는 동안은 간격을 지킨다
        let minInterval = contextChanged ? 2.0 : settings.screenshotMinInterval
        let wantsFile = settings.captureScreenshots && now - lastScreenshotAt >= minInterval
        guard wantsFile || needImageForOCR, CGPreflightScreenCaptureAccess(), isCurrent(snapshot) else { return nil }
        let privacy = PrivacyFilter(excludedBundles: settings.excludedBundles)
        guard let image = await capturer.capture(snapshot: snapshot, excluding: privacy) else { return nil }
        guard isCurrent(snapshot) else { return nil }

        let hash = ScreenCapturer.differenceHash(image)
        if wantsFile && settings.captureScreenshots {
            // 같은 화면에 머무는 동안은 내용이 바뀐 것(스크롤 등)만 저장한다. 화면이 바뀐 직후는 비슷해 보여도 저장한다
            if contextChanged || (lastScreenshotHash.map({ !ScreenCapturer.isSimilar($0, hash) }) ?? true) {
                let date = Date(timeIntervalSince1970: now)
                let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
                let time = DateFormatter(); time.dateFormat = "HHmmss"
                let url = capturesDir.appendingPathComponent(day.string(from: date), isDirectory: true)
                    .appendingPathComponent("\(time.string(from: date))_\(observationId).jpg")
                if capturer.saveJPEG(image, to: url) {
                    lastScreenshotHash = hash
                    lastScreenshotAt = now
                    status.screenshots += 1
                    try? store.attachScreen(observationId: observationId, path: url.path, hash: hash)
                    return image
                }
            }
        }
        try? store.attachScreen(observationId: observationId, path: nil, hash: hash)     // 저장은 안 했어도 해시는 남긴다
        return image
    }

    // MARK: 시스템 이벤트

    private func registerObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @Sendable (CollectorCoordinator) async -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                Task { await action(self) }
            }
            observers.append((center, token))
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { await $0.tick() }      // 앱 전환은 즉시 반영
        observe(workspace, NSWorkspace.willSleepNotification) { await $0.setLocked(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { await $0.setLocked(false) }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { await $0.setLocked(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { await $0.setLocked(false) }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { await $0.setLocked(true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { await $0.setLocked(false) }
    }

    private func setLocked(_ value: Bool) async {
        locked = value
        await tick()
    }

    private func configureDownloadsWatcher() {
        watcher?.stop()
        watcher = nil
        guard settings.watchDownloads else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
        let created = DownloadsWatcher(paths: [downloads]) { [weak self] path, origin in
            guard let self else { return }
            Task { await self.fileAppeared(path: path, origin: origin) }
        }
        created.start()
        watcher = created
    }

    private func configureChatWatcher() {
        chatWatcher?.stop()
        chatWatcher = nil
        guard settings.readChatLogs else { return }
        let created = ChatLogWatcher(store: store)
        created.start()
        chatWatcher = created
    }

    private func fileAppeared(path: String, origin: String?) {
        guard !status.paused else { return }
        try? store.insertFileEvent(FileEvent(ts: Date().timeIntervalSince1970, path: path, kind: "created",
                                             originUrl: origin, observationId: lastObservationId))
        onFileAppeared?(path, origin)
    }

    private func cleanupOldCaptures(now: Double) {
        defer { try? store.clearMissingScreenshotFolders() }
        guard settings.retentionDays > 0,
              let folders = try? FileManager.default.contentsOfDirectory(at: capturesDir, includingPropertiesForKeys: nil) else { return }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let cutoff = now - Double(settings.retentionDays) * 86_400
        for folder in folders {
            if let day = formatter.date(from: folder.lastPathComponent), day.timeIntervalSince1970 < cutoff,
               (try? FileManager.default.removeItem(at: folder)) != nil {
                try? store.clearScreenshotPaths(under: folder.path)
            }
        }
    }

    private func publish() { onChange?(status) }
}
