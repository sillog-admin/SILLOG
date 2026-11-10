import XCTest
@testable import WorkGraphCore

/// 구글 캘린더 API (맥에 구글 계정을 안 붙인 사람용). 실제 구글 대신 정해 둔 응답을 돌려준다
final class GoogleCalendarClientTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(String, Int)]
        private(set) var requests: [URLRequest] = []
        init(_ responses: [(String, Int)]) { self.responses = responses }
        func next(_ request: URLRequest) -> (Data, Int) {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            let (body, status) = responses.isEmpty ? ("{}", 500) : responses.removeFirst()
            return (Data(body.utf8), status)
        }
    }

    private func client(_ recorder: Recorder) -> GoogleCalendarClient {
        GoogleCalendarClient(token: { "token-1" }, fetch: { recorder.next($0) })
    }

    private func date(_ text: String) -> Date {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!
    }

    func testListsCalendarsWithWhetherEventsCanBeAdded() async throws {
        let recorder = Recorder([("""
        {"items":[{"id":"me@gmail.com","summary":"me@gmail.com","backgroundColor":"#9fe1e7","accessRole":"owner","primary":true},
                  {"id":"ko.south_korea#holiday@group.v.calendar.google.com","summary":"대한민국의 휴일","backgroundColor":"#16a765","accessRole":"reader"},
                  {"id":"team@group.calendar.google.com","summary":"team","summaryOverride":"기획 팀","backgroundColor":"#ac725e","accessRole":"writer"}]}
        """, 200)])
        let calendars = try await client(recorder).calendars()
        XCTAssertEqual(calendars.map(\.title), ["me@gmail.com", "대한민국의 휴일", "기획 팀"], "내가 바꾼 이름이 있으면 그 이름")
        XCTAssertEqual(calendars.map(\.writable), [true, false, true])
        XCTAssertEqual(calendars.first?.color, "#9FE1E7")
        XCTAssertEqual(recorder.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(recorder.requests.first?.url?.path, "/calendar/v3/users/me/calendarList")
    }

    func testReadsEventsInARangeAcrossPagesAndSkipsCancelled() async throws {
        let recorder = Recorder([("""
        {"items":[{"id":"e1","summary":"기획 회의","start":{"dateTime":"2026-11-05T15:00:00+09:00"},"end":{"dateTime":"2026-11-05T16:00:00+09:00"},"location":"본관"},
                  {"id":"e2","status":"cancelled"}],
         "nextPageToken":"p2"}
        """, 200), ("""
        {"items":[{"id":"e3","summary":"중간고사","start":{"date":"2026-11-10"},"end":{"date":"2026-11-11"}}]}
        """, 200)])
        let events = try await client(recorder).events(calendarId: "me@gmail.com", from: date("2026-11-01 00:00"), to: date("2026-11-30 00:00"))
        XCTAssertEqual(events.map(\.title), ["기획 회의", "중간고사"])
        XCTAssertEqual(events[0].start, date("2026-11-05 15:00"))
        XCTAssertEqual(events[0].end, date("2026-11-05 16:00"))
        XCTAssertEqual(events[0].location, "본관")
        XCTAssertTrue(events[1].allDay)
        XCTAssertEqual(events[1].start, Calendar.current.startOfDay(for: events[1].start), "종일은 그날 0시 (이 Mac 시간대)")
        let first = try XCTUnwrap(recorder.requests.first?.url?.absoluteString)
        XCTAssertTrue(first.contains("/calendars/me%40gmail.com/events"), "캘린더 id 는 경로에 맞게 바꿔 넣는다 (# 이 든 공휴일 id 도): \(first)")
        XCTAssertTrue(first.contains("singleEvents=true"), "되풀이 일정은 하나씩 펼쳐 받는다")
        XCTAssertTrue(first.contains("timeMin="))
        XCTAssertTrue(recorder.requests.last?.url?.absoluteString.contains("pageToken=p2") ?? false, "다음 쪽까지 받는다")
    }

    func testAddsTimedAndAllDayEvents() async throws {
        let recorder = Recorder([(#"{"id":"new-1"}"#, 200), (#"{"id":"new-2"}"#, 200)])
        let api = client(recorder)
        let timed = try await api.insert(calendarId: "team@group.calendar.google.com", title: "기획 회의", start: date("2026-11-12 15:00"),
                                         end: date("2026-11-12 16:00"), allDay: false, notes: "실록 기록에서 찾은 일정", timeZone: seoul)
        let allDay = try await api.insert(calendarId: "me@gmail.com", title: "과제 제출", start: date("2026-11-10 00:00"), end: nil, allDay: true,
                                          notes: nil, timeZone: seoul)
        XCTAssertEqual([timed, allDay], ["new-1", "new-2"])
        let request = recorder.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.googleapis.com/calendar/v3/calendars/team%40group.calendar.google.com/events")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["summary"] as? String, "기획 회의")
        XCTAssertEqual(body["description"] as? String, "실록 기록에서 찾은 일정")
        XCTAssertEqual((body["start"] as? [String: String])?["dateTime"], "2026-11-12T15:00:00+09:00")
        XCTAssertEqual((body["start"] as? [String: String])?["timeZone"], "Asia/Seoul")
        let dayBody = try XCTUnwrap(JSONSerialization.jsonObject(with: recorder.requests[1].httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual((dayBody["start"] as? [String: String])?["date"], "2026-11-10")
        XCTAssertEqual((dayBody["end"] as? [String: String])?["date"], "2026-11-11", "종일 일정의 끝은 다음 날 (구글은 끝 날짜를 빼고 센다)")
    }

    func testExpiredLoginIsReportedSeparately() async {
        let recorder = Recorder([(#"{"error":{"code":401,"message":"Invalid Credentials"}}"#, 401)])
        do {
            _ = try await client(recorder).calendars()
            XCTFail("401 이면 오류")
        } catch let error as GoogleCalendarClient.Failure {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("\(error)")
        }
    }
}
