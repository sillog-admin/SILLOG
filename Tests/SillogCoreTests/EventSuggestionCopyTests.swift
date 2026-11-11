import XCTest
@testable import SillogCore

final class EventSuggestionCopyTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func time(_ text: String) -> Double {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: text)!.timeIntervalSince1970
    }

    /// 알림 세 줄: 일정 제목, 날짜, 어디서 찾았는지
    func testBodyShowsTitleDateAndWhereItWasFound() {
        XCTAssertEqual(EventSuggestionCopy.body(title: "민수와 저녁 약속", start: time("2026-11-04 19:00"), allDay: false,
                                                evidence: "카카오톡 · 내일 7시에 강남역에서 보자", timeZone: seoul),
                       "민수와 저녁 약속\n11월 4일 수 19:00\n카카오톡 · 내일 7시에 강남역에서 보자")
        XCTAssertEqual(EventSuggestionCopy.body(title: "중간 발표", start: time("2026-11-20 00:00"), allDay: true, evidence: "", timeZone: seoul),
                       "중간 발표\n11월 20일 금")
    }

    func testDateTextLeavesOutTimeForAllDay() {
        XCTAssertEqual(EventSuggestionCopy.dateText(start: time("2026-11-10 23:59"), allDay: false, timeZone: seoul), "11월 10일 화 23:59")
        XCTAssertEqual(EventSuggestionCopy.dateText(start: time("2026-11-10 00:00"), allDay: true, timeZone: seoul), "11월 10일 화")
    }
}
