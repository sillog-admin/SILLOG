import AppKit
import Foundation
import UserNotifications
import WorkGraphCore

/// 파일 정리 제안과 일정 제안을 macOS 알림으로 보여 준다. 알림의 버튼으로 바로 옮기거나(등록하거나) 무시할 수 있다.
/// .app 번들로 실행될 때만 동작한다 (swift run 으로 띄운 실행 파일에는 알림 센터가 없다).
final class SuggestionNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Action { case move, ignore, open }
    enum EventAction { case register, ignore, open }
    /// 누른 알림이 어느 제안의 것인지
    enum Route: Equatable {
        case file(Action, Int64)
        case event(EventAction, Int64)
        /// 정리 제안
        case review
    }

    static let category = "FILE_SUGGESTION"
    static let eventCategory = "EVENT_SUGGESTION"
    var onAction: ((Action, Int64) -> Void)?
    var onEventAction: ((EventAction, Int64) -> Void)?
    var onReview: (() -> Void)?
    /// 알림이 시스템 설정에서 꺼져 있으면 true 로 알려 준다
    var onDenied: ((Bool) -> Void)?
    private let available: Bool
    private var authorized = false

    override init() {
        available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        super.init()
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let move = UNNotificationAction(identifier: "move", title: "옮기기", options: [])
        let ignore = UNNotificationAction(identifier: "ignore", title: "무시", options: [.destructive])
        let register = UNNotificationAction(identifier: "register", title: "등록", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [move, ignore], intentIdentifiers: [], options: []),
                                          UNNotificationCategory(identifier: Self.eventCategory, actions: [register, ignore], intentIdentifiers: [], options: [])])
    }

    /// 요청 없이 현재 상태만 읽는다 (앱 시작 때)
    func checkStatus() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            self?.onDenied?(settings.authorizationStatus == .denied)
        }
    }

    func notify(_ suggestion: FileSuggestion, home: String, recording: Bool = false) {
        guard available, let id = suggestion.id else { return }
        let title = recording ? FileSuggestionCopy.recordingTitle : FileSuggestionCopy.title
        let body = recording
            ? FileSuggestionCopy.recordingBody(fileName: suggestion.fileName, folder: suggestion.suggestedFolder, home: home)
            : FileSuggestionCopy.body(fileName: suggestion.fileName, folder: suggestion.suggestedFolder, home: home)
        deliver(title: title, body: body, category: Self.category, userInfo: ["suggestionId": id], identifier: "file-suggestion-\(id)")
    }

    /// 기록에서 찾은 일정: [등록]/[무시]
    func notify(event suggestion: EventSuggestion) {
        guard available else { return }
        deliver(title: EventSuggestionCopy.title, body: EventSuggestionCopy.body(suggestion), category: Self.eventCategory,
                userInfo: ["eventSuggestionId": suggestion.id], identifier: "event-suggestion-\(suggestion.id)")
    }

    /// 받아쓴 녹음을 저장만 했을 때 (폴더 제안 없음). 버튼 없음
    /// 새 정리 제안이 생겼을 때 (누르면 창과 제안 시트를 연다)
    func notifyReview(fresh: Int, summary: String) {
        guard available else { return }
        deliver(title: "새 정리 제안 \(fresh)개", body: summary, category: nil, userInfo: ["review": true], identifier: "review")
    }

    func notifyTranscribed(fileName: String, folder: String, home: String) {
        guard available else { return }
        deliver(title: FileSuggestionCopy.transcribedTitle, body: FileSuggestionCopy.transcribedBody(fileName: fileName, folder: folder, home: home),
                category: nil, userInfo: [:], identifier: "recording-\(UUID().uuidString)")
    }

    private func deliver(title: String, body: String, category: String?, userInfo: [AnyHashable: Any], identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            center.getNotificationSettings { [weak self] settings in
                AppLog.write("알림 권한: \(granted ? "허용" : "거부") 상태=\(settings.authorizationStatus.rawValue) 배너=\(settings.alertSetting.rawValue)\(error.map { " 오류=\($0.localizedDescription)" } ?? "")")
                self?.onDenied?(settings.authorizationStatus == .denied)
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category { content.categoryIdentifier = category }
            content.userInfo = userInfo
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                if let error { AppLog.write("알림 보내기 실패: \(error.localizedDescription)") }
            }
        }
    }

    func remove(id: Int64) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["file-suggestion-\(id)"])
    }

    func removeEvent(id: Int64) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["event-suggestion-\(id)"])
    }

    /// 제안에 없는 일정(등록·무시했거나 날짜가 지난 것)의 떠 있는 알림을 지운다
    func pruneEvents(keeping ids: Set<Int64>) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let stale = Self.staleEventIdentifiers(delivered.map(\.request.identifier), keeping: ids)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    static func staleEventIdentifiers(_ delivered: [String], keeping ids: Set<Int64>) -> [String] {
        let prefix = "event-suggestion-"
        return delivered.filter { $0.hasPrefix(prefix) && Int64($0.dropFirst(prefix.count)).map { !ids.contains($0) } ?? false }
    }

    /// 알림의 정보와 누른 단추로 어느 제안의 무슨 동작인지 정한다. 단추가 아니면(알림 본문) open
    static func route(userInfo: [AnyHashable: Any], action: String) -> Route? {
        func id(_ key: String) -> Int64? { userInfo[key] as? Int64 ?? (userInfo[key] as? NSNumber)?.int64Value }
        if let event = id("eventSuggestionId") {
            switch action {
            case "register": return .event(.register, event)
            case "ignore": return .event(.ignore, event)
            default: return .event(.open, event)
            }
        }
        if userInfo["review"] as? Bool == true { return .review }
        guard let file = id("suggestionId") else { return nil }
        switch action {
        case "move": return .file(.move, file)
        case "ignore": return .file(.ignore, file)
        default: return .file(.open, file)
        }
    }

    /// 시스템 설정 > 알림 > Sillog
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.sillog.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]                                   // 앱이 앞에 있어도 보여 준다
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch Self.route(userInfo: response.notification.request.content.userInfo, action: response.actionIdentifier) {
        case .file(let action, let id): onAction?(action, id)
        case .event(let action, let id): onEventAction?(action, id)
        case .review: onReview?()
        case nil: break
        }
    }
}
