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
}
