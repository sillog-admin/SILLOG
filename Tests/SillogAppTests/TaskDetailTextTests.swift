import XCTest
@testable import SillogApp
import SillogCore

/// Dates in the task detail follow the app language, also after it changes while the app runs.
@MainActor
final class TaskDetailTextTests: XCTestCase {
    func testSessionDayFollowsTheAppLanguage() throws {
        let day = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 3, day: 5, hour: 9).date)
        XCTAssertEqual(TasksView.dayLabel(day), "3월 5일")
        L10n.current = .en
        defer { L10n.current = .ko }
        XCTAssertEqual(TasksView.dayLabel(day), "Mar 5")
        XCTAssertTrue(TasksView.dayLabel(Date()).hasPrefix("Today, "))
    }

    // 기간 단추와 막대에 커서를 대면 날짜가 보인다
    func testRangeButtonsAndBarsSayWhichDays() throws {
        let now = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 11, day: 19, hour: 15).date).timeIntervalSince1970
        let first = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 10, day: 5, hour: 9).date).timeIntervalSince1970
        XCTAssertEqual(TasksView.rangeSpan(.week, first: first, now: now), "11월 13일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.month, first: first, now: now), "10월 21일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.all, first: first, now: now), "10월 5일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.today, first: first, now: now), "11월 19일")
        let day = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 11, day: 16).date)
        XCTAssertEqual(TasksView.barLabel(RangeTime.Bar(start: day, seconds: 4200), weekly: false), "11월 16일 · 1시간 10분")
        XCTAssertEqual(TasksView.barLabel(RangeTime.Bar(start: day, seconds: 4200), weekly: true), "11월 16일부터 한 주 1시간 10분")
    }

    // 고른 업무를 다시 누르면 닫는 것은 그 업무 카드가 떠 있을 때만: 카드를 닫았거나 분야 같은 다른 상세가 떠 있으면 다시 연다
    func testPressingTheChosenTaskClosesOnlyItsOwnOpenCard() {
        XCTAssertTrue(TasksView.pressCloses(chosen: true, cardOpen: true, showingNode: false))
        XCTAssertFalse(TasksView.pressCloses(chosen: true, cardOpen: false, showingNode: false), "×로 닫은 뒤 다시 누르면 연다")
        XCTAssertFalse(TasksView.pressCloses(chosen: true, cardOpen: true, showingNode: true), "분야 상세가 떠 있으면 업무 상세로 바꾼다")
        XCTAssertFalse(TasksView.pressCloses(chosen: false, cardOpen: true, showingNode: false))
    }
}
