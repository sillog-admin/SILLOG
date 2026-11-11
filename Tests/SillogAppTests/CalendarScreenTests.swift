import XCTest
import SillogCore
@testable import SillogApp

final class CalendarScreenTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func date(_ text: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: text)!
    }

    private let sources = [CalendarFeed.Source(id: "cal-home", title: "개인", account: "iCloud", color: "#1BADF8"),
                           CalendarFeed.Source(id: "cal-school", title: "학교", account: "me@example.com", color: "#63DA38")]

    private func item(_ id: String, _ title: String, _ start: String, _ end: String?, allDay: Bool = false, calendar: String = "cal-home",
                      location: String? = nil) -> CalendarFeed.Item {
        CalendarFeed.Item(id: id, title: title, start: date(start), end: end.map(date), allDay: allDay, calendarId: calendar, location: location, notes: nil)
    }

    func testTimedEventUsesItsCalendarColorAndHiddenCalendarsAreLeftOut() {
        let events = CalendarFeed.events(items: [item("e1", "기획 회의", "2026-11-05 15:00:00", "2026-11-05 16:00:00", location: "본관 305"),
                                                 item("e2", "학과 행사", "2026-11-05 10:00:00", nil, calendar: "cal-school")],
                                         suggestions: [], sources: sources, hidden: ["cal-school"], timeZone: seoul)
        XCTAssertEqual(events.count, 1, "숨긴 캘린더의 일정은 빼고 보낸다")
        XCTAssertEqual(events[0]["id"] as? String, "event-e1")
        XCTAssertEqual(events[0]["title"] as? String, "기획 회의")
        XCTAssertEqual(events[0]["start"] as? String, "2026-11-05T15:00:00+09:00")
        XCTAssertEqual(events[0]["end"] as? String, "2026-11-05T16:00:00+09:00")
        XCTAssertEqual(events[0]["allDay"] as? Bool, false)
        let extra = events[0]["extendedProps"] as? [String: Any]
        XCTAssertEqual(extra?["kind"] as? String, "event")
        XCTAssertEqual(extra?["color"] as? String, "#1BADF8")
        XCTAssertEqual(extra?["calendar"] as? String, "개인 · iCloud")
        XCTAssertEqual(extra?["location"] as? String, "본관 305")
    }

    /// EventKit 종일 일정의 끝은 마지막 날 23:59:59 이거나 다음 날 0시다. 달력에는 끝 날짜를 빼고 세는 다음 날로 넘긴다
    func testAllDayEventsEndTheDayAfterTheirLastDay() {
        let events = CalendarFeed.events(items: [item("a", "중간고사", "2026-11-05 00:00:00", "2026-11-05 23:59:59", allDay: true),
                                                 item("b", "학회", "2026-11-06 00:00:00", "2026-11-08 00:00:00", allDay: true)],
                                         suggestions: [], sources: sources, hidden: [], timeZone: seoul)
        XCTAssertEqual(events.map { $0["start"] as? String }, ["2026-11-05", "2026-11-06"])
        XCTAssertEqual(events.map { $0["end"] as? String }, ["2026-11-06", "2026-11-08"])
        XCTAssertEqual(events.map { $0["allDay"] as? Bool }, [true, true])
    }

    func testSuggestionsAreDashedAndShownWhateverCalendarsAreHidden() throws {
        let db = try SillogDatabase.inMemory()
        try db.writer.write { conn in
            _ = try EventSuggestionStore.insert(conn, title: "민수와 저녁 약속", start: self.date("2026-11-04 19:00:00"), end: nil, allDay: false, evidenceId: nil,
                                                evidence: "카카오톡 · 내일 7시에 보자", now: 0, timeZone: self.seoul)
            _ = try EventSuggestionStore.insert(conn, title: "과제 제출", start: self.date("2026-11-10 00:00:00"), end: nil, allDay: true, evidenceId: nil,
                                                evidence: "", now: 0, timeZone: self.seoul)
        }
        let suggestions = try EventSuggestionStore(db).pending(now: date("2026-11-03 12:00:00"))
        let events = CalendarFeed.events(items: [], suggestions: suggestions, sources: sources, hidden: ["cal-home", "cal-school"], timeZone: seoul)
        XCTAssertEqual(events.count, 2, "제안은 아직 어느 캘린더에도 없어 숨김과 상관없이 보인다")
        XCTAssertEqual(events[0]["id"] as? String, "suggestion-\(suggestions[0].id)")
        XCTAssertEqual(events[0]["classNames"] as? [String], ["sillog-suggestion"])
        XCTAssertEqual(events[0]["start"] as? String, "2026-11-04T19:00:00+09:00")
        let extra = events[0]["extendedProps"] as? [String: Any]
        XCTAssertEqual(extra?["kind"] as? String, "suggestion")
        XCTAssertEqual(extra?["suggestionId"] as? Int64, suggestions[0].id)
        XCTAssertEqual(extra?["evidence"] as? String, "카카오톡 · 내일 7시에 보자")
        XCTAssertEqual(events[1]["start"] as? String, "2026-11-10")
        XCTAssertEqual(events[1]["end"] as? String, "2026-11-11")
    }

    /// 끝 시각을 모르는 일정은 한 시간으로 치되 자정을 넘기지 않는다 (23:59 마감이 다음 날까지 걸쳐 보이지 않게)
    func testEventsWithoutAnEndStopAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        XCTAssertEqual(CalendarFeed.defaultEnd(for: date("2026-11-05 19:00:00"), calendar: calendar), date("2026-11-05 20:00:00"))
        XCTAssertEqual(CalendarFeed.defaultEnd(for: date("2026-11-06 23:59:00"), calendar: calendar), date("2026-11-07 00:00:00"))
    }

    func testRemembersTheViewAndFallsBackToWeek() {
        XCTAssertEqual(CalendarFeed.view(stored: "dayGridMonth"), "dayGridMonth")
        XCTAssertEqual(CalendarFeed.view(stored: "timeGridDay"), "timeGridDay")
        XCTAssertEqual(CalendarFeed.view(stored: nil), "timeGridWeek")
        XCTAssertEqual(CalendarFeed.view(stored: "listYear"), "timeGridWeek", "모르는 보기면 주")
    }

    /// [등록]할 캘린더: 고른 것을 기억하고, 없어졌거나 읽기 전용(공휴일·구독)이면 실록 캘린더로 (nil)
    func testRegisterTargetFallsBackToSillogWhenMissingOrReadOnly() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "calendar-target-\(UUID().uuidString)"))
        let google = CalendarFeed.Source(id: "cal-google", title: "개인", account: "Google", color: "#4285F4")
        let holidays = CalendarFeed.Source(id: "cal-holidays", title: "대한민국의 휴일", account: "Google", color: "#0B8043", writable: false)
        let target = CalendarTarget(defaults: defaults)
        XCTAssertNil(target.resolve(in: [google, holidays]), "고른 적 없으면 실록")
        target.set("cal-google")
        XCTAssertEqual(CalendarTarget(defaults: defaults).resolve(in: [google, holidays]), google, "기억한다")
        XCTAssertNil(target.resolve(in: [holidays]), "고른 캘린더가 없어졌으면 실록")
        target.set("cal-holidays")
        XCTAssertNil(target.resolve(in: [google, holidays]), "읽기 전용이면 실록")
        target.set(nil)
        XCTAssertNil(defaults.string(forKey: CalendarTarget.key))
    }

    /// 앱에서 구글 계정을 연결하면 그 캘린더가 목록에 붙는다. 맥의 Google 계정에 같은 이름의 캘린더가 있으면 맥 쪽만 남긴다 (두 번 보이지 않게)
    func testGoogleCalendarsJoinTheListUnlessTheMacAlreadyHasThem() {
        let mac = [CalendarFeed.Source(id: "ek-1", title: "me@gmail.com", account: "Google", color: "#9FE1E7"),
                   CalendarFeed.Source(id: "ek-2", title: "집", account: "iCloud", color: "#1BADF8")]
        let api = [GoogleCalendarClient.Calendar(id: "me@gmail.com", title: "me@gmail.com", color: "#9FE1E7", writable: true, primary: true),
                   GoogleCalendarClient.Calendar(id: "team@group.calendar.google.com", title: "기획 팀", color: "#AC725E", writable: true, primary: false),
                   GoogleCalendarClient.Calendar(id: "ko#holiday", title: "대한민국의 휴일", color: "#16A765", writable: false, primary: false)]
        let merged = CalendarFeed.merge(eventKit: mac, google: api)
        XCTAssertEqual(merged.map(\.id), ["ek-1", "ek-2", "google:team@group.calendar.google.com", "google:ko#holiday"])
        XCTAssertEqual(merged.last?.account, CalendarFeed.googleAccount)
        XCTAssertEqual(merged.map(\.writable), [true, true, true, false])
        XCTAssertEqual(CalendarFeed.merge(eventKit: [], google: api).count, 3, "맥에 구글을 안 붙였으면 다 보인다")
    }

    func testGoogleEventsBecomeItemsOfTheirCalendar() {
        let events = [GoogleCalendarClient.Event(id: "e1", title: "기획 회의", start: date("2026-11-05 15:00:00"), end: date("2026-11-05 16:00:00"),
                                                 allDay: false, location: "본관", notes: nil)]
        let items = CalendarFeed.items(google: events, calendarId: "team@group.calendar.google.com")
        XCTAssertEqual(items.first?.calendarId, "google:team@group.calendar.google.com")
        XCTAssertEqual(items.first?.id, "google-e1")
        XCTAssertEqual(items.first?.location, "본관")
    }

    func testGoogleSignInAsksOnlyForTheCalendarScopesItNeeds() {
        XCTAssertEqual(ConnectorAuth.googleScopes(["gcal"]), ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                                                           "https://www.googleapis.com/auth/calendar.events"])
        XCTAssertEqual(ConnectorAuth.googleScopes(["gmail", "drive"]), ["https://www.googleapis.com/auth/drive.readonly",
                                                                     "https://www.googleapis.com/auth/gmail.readonly"])
    }

    func testHiddenCalendarsAreRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "calendar-visibility-\(UUID().uuidString)"))
        let visibility = CalendarVisibility(defaults: defaults)
        XCTAssertEqual(visibility.hidden, [])
        visibility.set("cal-school", visible: false)
        visibility.set("cal-home", visible: false)
        visibility.set("cal-home", visible: true)
        XCTAssertEqual(CalendarVisibility(defaults: defaults).hidden, ["cal-school"])
    }

    /// 달력 화면(FullCalendar 6, MIT)은 앱 안의 파일로 돈다: swift run 은 리소스 번들, .app 은 make-app.sh 가 넣는다
    func testCalendarPageAndLibraryShipWithTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/SillogApp/Resources/calendar")
        for file in ["index.html", "calendar.js", "style.css", "vendor/fullcalendar/index.global.min.js", "vendor/fullcalendar/ko.global.min.js",
                     "vendor/fullcalendar/LICENSE.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path), file)
        }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8).contains("Resources/calendar"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8).contains(#".copy("Resources/calendar")"#))
    }
}
