import XCTest
@testable import SillogCore

final class EventSuggestionStoreTests: XCTestCase {
    func testDuplicateTitleAndDayIsIgnoredAndStatusHidesFromPending() throws {
        let db = try SillogDatabase.inMemory()
        let store = EventSuggestionStore(db)
        let day = Date().addingTimeInterval(2 * 86400)
        let first = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day, end: nil, allDay: true, evidenceId: nil, evidence: "공지", now: 0) }
        let again = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day.addingTimeInterval(3600), end: nil, allDay: false, evidenceId: nil, evidence: "", now: 0) }
        XCTAssertNotNil(first)
        XCTAssertNil(again)
        let pending = try store.pending()
        XCTAssertEqual(pending.map(\.id), [first])
        try store.setStatus(pending[0].id, EventSuggestionStore.dismissed)
        XCTAssertTrue(try store.pending().isEmpty)
        // 무시한 것도 같은 제목+날짜로 다시 만들지 않는다
        let third = try db.writer.write { try EventSuggestionStore.insert($0, title: "중간고사", start: day, end: nil, allDay: true, evidenceId: nil, evidence: "", now: 0) }
        XCTAssertNil(third)
    }

    /// 오늘 마감처럼 오늘 날짜의 종일 일정은 오늘이 끝날 때까지 제안에 남는다
    func testAllDaySuggestionForTodayStaysUntilDayEnds() throws {
        let db = try SillogDatabase.inMemory()
        let store = EventSuggestionStore(db)
        let today = Calendar.current.startOfDay(for: Date())
        try db.writer.write { _ = try EventSuggestionStore.insert($0, title: "과제 제출", start: today, end: nil, allDay: true, evidenceId: nil, evidence: "", now: 0) }
        XCTAssertEqual(try store.pending(now: today.addingTimeInterval(15 * 3600)).map(\.title), ["과제 제출"])
        XCTAssertTrue(try store.pending(now: today.addingTimeInterval(86400 + 60)).isEmpty)
    }

    /// 일정 찾기에 보여 줄 이미 아는 제안: 상태와 관계없이 아직 안 지난 것
    func testUpcomingIncludesEveryStatus() throws {
        let db = try SillogDatabase.inMemory()
        let store = EventSuggestionStore(db)
        let now = Date()
        let ids = try db.writer.write { conn in
            try ["지난 일", "등록한 일", "무시한 일"].enumerated().map { index, title in
                try EventSuggestionStore.insert(conn, title: title, start: now.addingTimeInterval(Double(index == 0 ? -3 : index) * 86400), end: nil,
                                                allDay: false, evidenceId: nil, evidence: "", now: 0)
            }
        }
        try store.setStatus(try XCTUnwrap(ids[1]), EventSuggestionStore.registered)
        try store.setStatus(try XCTUnwrap(ids[2]), EventSuggestionStore.dismissed)
        XCTAssertEqual(try store.upcoming(from: now).map(\.title), ["등록한 일", "무시한 일"])
    }
}
