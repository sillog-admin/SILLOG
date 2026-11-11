import AppKit
import EventKit
import SwiftUI
import SillogCore

/// 애플 캘린더 연동 (EventKit). 오늘 일정을 읽고, 기록에서 찾은 일정 제안을 "실록" 캘린더에 등록한다.
/// 앞으로의 일정은 일정 찾기(EventFinder)에 넘겨 이미 있는 일정을 다시 제안하지 않게 하고, 사용자가 직접 넣은 일정은 제안에서 뺀다.
/// 구글 캘린더는 Mac 의 인터넷 계정에 추가하면 이 캘린더 목록에 같이 보인다. 맥에 구글을 안 붙였으면 앱에서 구글 계정을 바로 연결할 수 있다 (아래 확장).
@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()
    static let calendarName = "실록"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")

    struct TodayEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let time: String      // "14:00" 또는 "종일"
    }

    private let store = EKEventStore()
    private var db: SillogDatabase?
    @Published private(set) var granted = false
    @Published private(set) var today: [TodayEvent] = []
    @Published private(set) var suggestions: [EventSuggestion] = []
    /// 연결한 캘린더 (캘린더 화면 오른쪽 목록), 그중 숨긴 것
    @Published private(set) var sources: [CalendarFeed.Source] = []
    @Published private(set) var hidden: Set<String> = CalendarVisibility().hidden
    /// [등록]할 캘린더. nil 이면 '실록' 캘린더 (없으면 만든다)
    @Published private(set) var target: CalendarFeed.Source?
    /// 캘린더 화면의 웹 달력이 일정을 다시 물어야 할 때마다 늘어난다 (캘린더가 바뀜, 제안을 정함, 숨김을 바꿈)
    @Published private(set) var changes = 0
    /// 제안을 등록·무시했거나 캘린더에 이미 있어 뺐을 때 (떠 있는 알림을 지운다)
    var onDecided: ((Int64) -> Void)?
    private var announcer = EventAnnouncer()
    /// 앱에서 직접 연결한 구글 계정 (ConnectorAuth "gcal"): 연결 여부, 연결·읽기 중, 오류 문구
    @Published private(set) var googleConnected = false
    @Published private(set) var googleBusy = false
    @Published private(set) var googleError: String?
    private var googleCalendars: [GoogleCalendarClient.Calendar] = []
    /// 기간별 구글 일정 (몇 분 동안 다시 받지 않는다)
    private var googleCache: [String: (at: Date, events: [GoogleCalendarClient.Event])] = [:]
    private var eventKitSources: [CalendarFeed.Source] = []

    private init() {
        guard AppFeatures.calendarOn else { return }
        granted = Self.isGranted
        googleConnected = (try? ConnectorAuth.isConnected("gcal")) ?? false
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static var isGranted: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Info.plist 에 설명문이 없으면(swift run) 요청하는 순간 시스템이 앱을 끝낸다. .app 번들에서만 요청한다
    static var canPrompt: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.infoDictionary?["NSCalendarsFullAccessUsageDescription"] != nil
    }

    func attach(_ db: SillogDatabase?) {
        if let db { self.db = db }
        refresh()
        if googleCalendars.isEmpty { Task { await loadGoogle() } }
        if self.db != nil, !announcer.started { _ = announcer.fresh(ids: suggestions.map(\.id)) }   // 앱을 켤 때 이미 있던 제안은 알리지 않는다
    }

    /// 지난번 뒤로 새로 생긴 제안 (가까운 날짜부터). 정리가 끝나면 알림을 띄울 것
    func freshSuggestions() -> [EventSuggestion] {
        let ids = Set(announcer.fresh(ids: suggestions.map(\.id)))
        return suggestions.filter { ids.contains($0.id) }
    }

    /// 권한이 있으면 오늘 일정을 다시 읽고, 제안은 DB 에서 다시 읽는다. 사용자가 캘린더에 직접 넣은 일정의 제안은 in_calendar 로 닫는다
    /// (실록 캘린더는 제안을 등록한 곳이라 보지 않는다: 같은 날 마감하는 다른 과제를 닫지 않게)
    func refresh() {
        granted = Self.isGranted
        let pending = (try? db.map { try EventSuggestionStore($0).pending() }) ?? []
        guard granted else { suggestions = pending; eventKitSources = []; mergeSources(); today = []; changes += 1; return }
        var byDay: [Date: [EventFinder.Known]] = [:]
        func calendarEvents(on day: Date) -> [EventFinder.Known] {
            if let cached = byDay[day] { return cached }
            let found = events(from: day, to: day.addingTimeInterval(86_400), excludingCalendar: Self.calendarName)
            byDay[day] = found
            return found
        }
        let added = pending.filter { suggestion in
            let known = EventFinder.Known(title: suggestion.title, start: Date(timeIntervalSince1970: suggestion.start), allDay: suggestion.allDay)
            return calendarEvents(on: Calendar.current.startOfDay(for: known.start)).contains { EventFinder.isSame(known, $0) }
        }
        for suggestion in added {
            try? db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.inCalendar) }
            onDecided?(suggestion.id)
        }
        suggestions = pending.filter { suggestion in !added.contains { $0.id == suggestion.id } }
        eventKitSources = store.calendars(for: .event)
            .map { CalendarFeed.Source(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "", color: Self.hex($0.cgColor),
                                       writable: $0.allowsContentModifications) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        mergeSources()
        changes += 1
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        today = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate ?? start) < ($1.isAllDay ? 0 : 1, $1.startDate ?? start) }
            .map { TodayEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "제목 없음", time: $0.isAllDay ? "종일" : clock.string(from: $0.startDate)) }
    }

    /// 캘린더에 있는 일정 (권한이 없으면 빈 목록). excludingCalendar 는 빼고 읽을 캘린더 이름
    func events(from start: Date, to end: Date, excludingCalendar: String? = nil) -> [EventFinder.Known] {
        guard Self.isGranted, end > start else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { excludingCalendar == nil || $0.calendar?.title != excludingCalendar }
            .map { EventFinder.Known(title: $0.title ?? "", start: $0.startDate ?? start, allDay: $0.isAllDay) }
    }

    /// 캘린더 화면의 한 기간: 보이는 캘린더(맥 캘린더와 앱에서 연결한 구글)의 일정과 제안 (FullCalendar 이벤트 객체)
    func feed(from start: Date, to end: Date) async -> [[String: Any]] {
        let google = await googleItems(from: start, to: end)
        return CalendarFeed.events(items: items(from: start, to: end) + google, suggestions: suggestions, sources: sources, hidden: hidden)
    }

    /// 맥 캘린더 목록 + 앱에서 연결한 구글 캘린더 (맥과 겹치면 맥 쪽만), [등록]할 캘린더
    private func mergeSources() {
        sources = CalendarFeed.merge(eventKit: eventKitSources, google: googleCalendars)
        target = CalendarTarget().resolve(in: sources)
    }

    /// 캘린더 일정 (권한이 없으면 빈 목록). 되풀이 일정은 같은 id 를 나눠 쓰므로 시작 시각을 붙여 칸마다 다른 id 로
    func items(from start: Date, to end: Date) -> [CalendarFeed.Item] {
        guard Self.isGranted, end > start else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil)).map { event in
            let begin = event.startDate ?? start
            return CalendarFeed.Item(id: "\(event.eventIdentifier ?? UUID().uuidString)-\(Int(begin.timeIntervalSince1970))", title: event.title ?? "제목 없음",
                                     start: begin, end: event.endDate, allDay: event.isAllDay, calendarId: event.calendar?.calendarIdentifier ?? "",
                                     location: event.location, notes: event.notes)
        }
    }

    /// 캘린더 화면 오른쪽 목록의 체크: 끄면 그 캘린더 일정을 달력에서 숨긴다 (기억한다)
    func setVisible(_ id: String, _ visible: Bool) {
        let visibility = CalendarVisibility()
        visibility.set(id, visible: visible)
        hidden = visibility.hidden
        changes += 1
    }

    /// [등록]할 캘린더를 고른다 (nil 이면 실록). 기억한다
    func setTarget(_ id: String?) {
        CalendarTarget().set(id)
        mergeSources()
    }

    /// [등록]이 넣을 캘린더: 고른 캘린더, 없거나 못 쓰면 '실록'
    private func registerCalendar() throws -> EKCalendar {
        if let id = target?.id, let chosen = store.calendar(withIdentifier: id), chosen.allowsContentModifications { return chosen }
        return try sillogCalendar()
    }

    /// 캘린더 색 → "#RRGGBB" (못 읽으면 앱 갈색)
    static func hex(_ color: CGColor?) -> String {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB), let rgb = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = rgb.components, parts.count >= 3 else { return "#8A7566" }
        return String(format: "#%02X%02X%02X", Int((parts[0] * 255).rounded()), Int((parts[1] * 255).rounded()), Int((parts[2] * 255).rounded()))
    }

    /// 이미 허용이면 바로 true. 처음이면 시스템이 묻고, 막혀 있으면 시스템 설정을 연다 (openSettingsOnFail)
    @discardableResult
    func requestAccess(openSettingsOnFail: Bool = true) async -> Bool {
        if Self.isGranted { refresh(); return true }
        guard Self.canPrompt else { return false }
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        } else if openSettingsOnFail, let url = Self.settingsURL {
            NSWorkspace.shared.open(url)
        }
        refresh()
        return granted
    }

    /// "실록" 캘린더: 있으면 그것, 없으면 만든다 (iCloud 가 있으면 iCloud, 없으면 이 Mac)
    private func sillogCalendar() throws -> EKCalendar {
        if let found = store.calendars(for: .event).first(where: { $0.title == Self.calendarName && $0.allowsContentModifications }) { return found }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarName
        let sources = store.sources
        guard let source = sources.first(where: { $0.sourceType == .calDAV && $0.title == "iCloud" })
                ?? sources.first(where: { $0.sourceType == .local }) ?? store.defaultCalendarForNewEvents?.source else {
            throw NSError(domain: "Sillog", code: 1, userInfo: [NSLocalizedDescriptionKey: "일정을 담을 캘린더 계정이 없어요"])
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// [등록]: 고른 캘린더(기본은 "실록")에 넣은 뒤 제안을 registered 로. 앱에서 연결한 구글 캘린더면 구글 API 로, 아니면 권한을 받고 맥 캘린더로
    func register(_ suggestion: EventSuggestion) async {
        if CalendarTarget().stored?.hasPrefix(CalendarFeed.googlePrefix) == true, googleCalendars.isEmpty { await loadGoogle() }   // 막 켜서 아직 목록이 없을 때
        if let id = target?.id, id.hasPrefix(CalendarFeed.googlePrefix) {
            await registerToGoogle(suggestion, calendarId: String(id.dropFirst(CalendarFeed.googlePrefix.count)))
            refresh()
            return
        }
        guard await requestAccess() else { return }
        do {
            let event = EKEvent(eventStore: store)
            event.title = suggestion.title
            event.calendar = try registerCalendar()
            event.startDate = Date(timeIntervalSince1970: suggestion.start)
            event.isAllDay = suggestion.allDay
            event.endDate = suggestion.allDay ? event.startDate : suggestion.end.map { Date(timeIntervalSince1970: $0) } ?? CalendarFeed.defaultEnd(for: event.startDate)
            if !suggestion.evidence.isEmpty { event.notes = "실록 기록에서 찾은 일정: \(suggestion.evidence)" }
            try store.save(event, span: .thisEvent, commit: true)
            try db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.registered) }
            onDecided?(suggestion.id)
        } catch {
            AppLog.write("캘린더 등록 실패: \(error.localizedDescription)")
        }
        refresh()
    }

    func dismiss(_ suggestion: EventSuggestion) {
        try? db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.dismissed) }
        onDecided?(suggestion.id)
        refresh()
    }

    /// 제안 줄의 날짜: "11월 5일 목 14:00", 종일이면 시간 없이
    static func dateText(_ s: EventSuggestion) -> String {
        EventSuggestionCopy.dateText(start: s.start, allDay: s.allDay)
    }
}

// MARK: 구글 계정 직접 연결 (맥에 구글을 안 붙인 사람용)

extension CalendarService {
    /// 이 빌드에 구글 클라이언트 ID 가 있어 연결할 수 있는지
    var googleAvailable: Bool { (try? ConnectorAuth.isAvailable("gcal")) ?? false }

    private var google: GoogleCalendarClient { .live(token: { try await ConnectorAuth.accessToken("gcal") }) }
    private static let googleExpired = "구글 로그인이 만료됐어요. 다시 연결해 주세요."

    /// 브라우저에서 구글 로그인 → 캘린더 목록을 받는다
    func connectGoogle() async {
        googleBusy = true
        defer { googleBusy = false }
        do {
            let clientID = try ConnectorAuth.configuration("google-client", environment: "GOOGLE_CLIENT_ID")
            try await ConnectorAuth.connectGoogle(["gcal"], clientID: clientID)
            googleConnected = true
            googleError = nil
            await loadGoogle()
        } catch {
            googleError = "구글 연결 실패: \(error.localizedDescription)"
        }
    }

    /// 이 Mac 에 저장한 구글 토큰만 지운다. [등록]할 곳이 구글이었으면 실록으로
    func disconnectGoogle() {
        try? ConnectorAuth.disconnect("gcal")
        googleConnected = false
        googleCalendars = []
        googleCache = [:]
        googleError = nil
        if CalendarTarget().stored?.hasPrefix(CalendarFeed.googlePrefix) == true { CalendarTarget().set(nil) }
        mergeSources()
        changes += 1
    }

    func loadGoogle() async {
        guard googleConnected else { return }
        do {
            googleCalendars = try await google.calendars()
            googleError = nil
        } catch GoogleCalendarClient.Failure.unauthorized {
            googleError = Self.googleExpired
        } catch {
            googleError = "구글 캘린더를 읽지 못했어요: \(error.localizedDescription)"
        }
        googleCache = [:]
        mergeSources()
        changes += 1
    }

    /// 구글 캘린더(맥과 겹치지 않는 것)의 기간 일정. visibleOnly 면 숨긴 캘린더는 받지 않는다. 같은 기간은 5분 동안 다시 받지 않는다
    func googleItems(from start: Date, to end: Date, visibleOnly: Bool = true) async -> [CalendarFeed.Item] {
        guard googleConnected else { return [] }
        var items: [CalendarFeed.Item] = []
        for source in sources where source.id.hasPrefix(CalendarFeed.googlePrefix) && !(visibleOnly && hidden.contains(source.id)) {
            let id = String(source.id.dropFirst(CalendarFeed.googlePrefix.count))
            let key = "\(id)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))"
            if let cached = googleCache[key], Date().timeIntervalSince(cached.at) < 300 {
                items += CalendarFeed.items(google: cached.events, calendarId: id)
                continue
            }
            do {
                let events = try await google.events(calendarId: id, from: start, to: end)
                googleCache[key] = (Date(), events)
                items += CalendarFeed.items(google: events, calendarId: id)
            } catch GoogleCalendarClient.Failure.unauthorized {
                googleError = Self.googleExpired
                break
            } catch {
                AppLog.write("구글 일정 읽기 실패: \(error.localizedDescription)")
            }
        }
        return items
    }

    /// 일정 찾기가 다시 제안하지 않게 보여 줄 일정: 맥 캘린더 + 앱에서 연결한 구글 (숨긴 것도)
    func knownEvents(from start: Date, to end: Date) async -> [EventFinder.Known] {
        let google = await googleItems(from: start, to: end, visibleOnly: false)
        return events(from: start, to: end) + google.map { EventFinder.Known(title: $0.title, start: $0.start, allDay: $0.allDay) }
    }

    private func registerToGoogle(_ suggestion: EventSuggestion, calendarId: String) async {
        let start = Date(timeIntervalSince1970: suggestion.start)
        let end = suggestion.allDay ? nil : suggestion.end.map { Date(timeIntervalSince1970: $0) } ?? CalendarFeed.defaultEnd(for: start)
        do {
            _ = try await google.insert(calendarId: calendarId, title: suggestion.title, start: start, end: end, allDay: suggestion.allDay,
                                        notes: suggestion.evidence.isEmpty ? nil : "실록 기록에서 찾은 일정: \(suggestion.evidence)")
            try db.map { try EventSuggestionStore($0).setStatus(suggestion.id, EventSuggestionStore.registered) }
            onDecided?(suggestion.id)
            googleCache = [:]
            changes += 1
        } catch GoogleCalendarClient.Failure.unauthorized {
            googleError = Self.googleExpired
        } catch {
            googleError = "구글 캘린더에 넣지 못했어요: \(error.localizedDescription)"
            AppLog.write("구글 캘린더 등록 실패: \(error.localizedDescription)")
        }
    }
}

/// 새로 생긴 제안만 고른다. 처음 본 목록은 기억만 한다 (앱을 켤 때 이미 있던 제안을 다시 알리지 않게)
struct EventAnnouncer {
    private var seen: Set<Int64>?
    var started: Bool { seen != nil }

    /// Returns: 지난번에 없던 id (받은 순서 그대로)
    mutating func fresh(ids: [Int64]) -> [Int64] {
        guard let known = seen else { seen = Set(ids); return [] }
        let new = ids.filter { !known.contains($0) }
        seen = known.union(new)
        return new
    }
}
