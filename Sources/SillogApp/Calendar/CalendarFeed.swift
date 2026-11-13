import Foundation
import SillogCore

/// 캘린더 화면의 웹 달력(FullCalendar)에 넘기는 일정 목록. 캘린더 일정은 그 캘린더 색으로, 아직 등록 안 한 제안은 점선(sillog-suggestion)으로
enum CalendarFeed {
    /// 캘린더 하나 (오른쪽 '연결한 캘린더' 목록). color 는 "#RRGGBB", writable 은 일정을 넣을 수 있는지 (공휴일·구독 캘린더는 못 넣는다)
    struct Source: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: String
        var writable = true
    }

    /// 캘린더 일정 하나
    struct Item: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date?
        let allDay: Bool
        let calendarId: String
        let location: String?
        let notes: String?
    }

    /// 앱에서 직접 연결한 구글 계정의 캘린더 묶음 이름, 그 캘린더 id 앞에 붙는 것
    static var googleAccount: String { tr("Google (SILLOG 연결)") }
    static let googlePrefix = "google:"

    /// 맥 캘린더(EventKit)의 캘린더에 앱에서 연결한 구글 캘린더를 붙인다. 맥의 Google 계정에 같은 이름의 캘린더가 있으면 맥 쪽만 남긴다
    /// (맥이 이미 구글과 동기화하므로 두 번 보이지 않게)
    static func merge(eventKit: [Source], google: [GoogleCalendarClient.Calendar]) -> [Source] {
        let onMac = Set(eventKit.filter { $0.account.localizedCaseInsensitiveContains("google") }.map(\.title))
        return eventKit + google.filter { !onMac.contains($0.title) }.map {
            Source(id: googlePrefix + $0.id, title: $0.title, account: googleAccount, color: $0.color, writable: $0.writable)
        }
    }

    /// 앱에서 연결한 구글 캘린더의 일정 → 달력 일정
    static func items(google events: [GoogleCalendarClient.Event], calendarId: String) -> [Item] {
        events.map { Item(id: "google-\($0.id)", title: $0.title, start: $0.start, end: $0.end, allDay: $0.allDay,
                          calendarId: googlePrefix + calendarId, location: $0.location, notes: $0.notes) }
    }

    /// 고를 수 있는 보기: 일·주·월
    static let views = ["timeGridDay", "timeGridWeek", "dayGridMonth"]

    /// 기억해 둔 보기. 없거나 모르는 보기면 주
    static func view(stored: String?) -> String {
        stored.flatMap { views.contains($0) ? $0 : nil } ?? "timeGridWeek"
    }

    /// Returns: FullCalendar 이벤트 객체 (JSON 으로 넘길 수 있는 값만). 숨긴 캘린더의 일정은 뺀다. 제안은 아직 어느 캘린더에도 없어 늘 넣는다
    static func events(items: [Item], suggestions: [EventSuggestion], sources: [Source], hidden: Set<String>, timeZone: TimeZone = .current) -> [[String: Any]] {
        let byId = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [[String: Any]] = items.filter { !hidden.contains($0.calendarId) }.map { item in
            let source = byId[item.calendarId]
            var extra: [String: Any] = ["kind": "event", "color": source?.color ?? "#8A7566",
                                        "calendar": source.map { "\($0.title) · \($0.account)" } ?? ""]
            if let location = item.location, !location.isEmpty { extra["location"] = location }
            if let notes = item.notes, !notes.isEmpty { extra["notes"] = String(notes.prefix(400)) }
            return ["id": "event-\(item.id)", "title": item.title, "extendedProps": extra]
                .merging(times(start: item.start, end: item.end, allDay: item.allDay, timeZone: timeZone)) { $1 }
        }
        events += suggestions.map { suggestion in
            let start = Date(timeIntervalSince1970: suggestion.start)
            let extra: [String: Any] = ["kind": "suggestion", "suggestionId": suggestion.id, "evidence": suggestion.evidence]
            return ["id": "suggestion-\(suggestion.id)", "title": suggestion.title, "classNames": ["sillog-suggestion"], "extendedProps": extra]
                .merging(times(start: start, end: suggestion.end.map { Date(timeIntervalSince1970: $0) }, allDay: suggestion.allDay, timeZone: timeZone)) { $1 }
        }
        return events
    }

    /// 끝 시각을 모르는 일정의 끝: 한 시간 뒤, 단 자정을 넘기지 않는다 (23:59 마감이 다음 날까지 걸치지 않게. 캘린더에 등록할 때도 쓴다)
    static func defaultEnd(for start: Date, calendar: Calendar = .current) -> Date {
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) ?? start.addingTimeInterval(3_600)
        return min(start.addingTimeInterval(3_600), midnight)
    }

    /// 시간 있는 일정은 시간대가 붙은 ISO 시각, 종일 일정은 날짜만. 종일의 끝은 마지막 날의 다음 날 (FullCalendar 는 끝 날짜를 빼고 센다)
    private static func times(start: Date, end: Date?, allDay: Bool, timeZone: TimeZone) -> [String: Any] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard allDay else {
            let iso = ISO8601DateFormatter()
            iso.timeZone = timeZone
            iso.formatOptions = [.withInternetDateTime]
            let finish = end.flatMap { $0 > start ? $0 : nil } ?? defaultEnd(for: start, calendar: calendar)
            return ["allDay": false, "start": iso.string(from: start), "end": iso.string(from: finish)]
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(first, (end ?? start).addingTimeInterval(-1)))     // 23:59:59 이든 다음 날 0시든 마지막 날로
        let after = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return ["allDay": true, "start": day.string(from: first), "end": day.string(from: after)]
    }
}

/// [등록]할 캘린더 (기억한다). 고르지 않았거나 고른 캘린더가 없어졌거나 읽기 전용이면 nil: '실록' 캘린더에 넣는다
struct CalendarTarget {
    static let key = "calendarRegisterTarget"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 기억해 둔 캘린더 id (아직 목록에 없을 수도 있다: 앱을 막 켜서 구글 캘린더를 아직 못 받았을 때)
    var stored: String? { defaults.string(forKey: Self.key) }

    func set(_ id: String?) {
        if let id { defaults.set(id, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    func resolve(in sources: [CalendarFeed.Source]) -> CalendarFeed.Source? {
        guard let id = defaults.string(forKey: Self.key) else { return nil }
        return sources.first { $0.id == id && $0.writable }
    }
}

/// 캘린더 화면에서 숨긴 캘린더 (기억한다)
struct CalendarVisibility {
    static let key = "calendarHidden"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var hidden: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func set(_ id: String, visible: Bool) {
        var ids = hidden
        if visible { ids.remove(id) } else { ids.insert(id) }
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}
