import Foundation
import XCTest
@testable import SillogApp

/// 업무 줄의 시간대 물결: 세션을 시간별로 나눠 더하고, 14일보다 옛날은 뺀다
final class DayTimelineTests: XCTestCase {
    func testAddsSecondsPerHourAcrossMidnightAndDropsOld() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        let day = cal.startOfDay(for: now).timeIntervalSince1970
        let h = 3600.0
        let hours = DayTimeline.hours([
            (day - 0.5 * h, day + 1.5 * h),                // 23:30~01:30
            (day + 9.25 * h, day + 9.75 * h),              // 9시에 30분
            (day + 9.5 * h, day + 10.25 * h),              // 9시에 30분 더, 10시에 15분
            (day - 20 * 24 * h, day - 19 * 24 * h),        // 14일보다 옛날
        ], now: now, calendar: cal)
        XCTAssertEqual(hours[23], 1800, accuracy: 1e-6)
        XCTAssertEqual(hours[0], 3600, accuracy: 1e-6)
        XCTAssertEqual(hours[1], 1800, accuracy: 1e-6)
        XCTAssertEqual(hours[9], 3600, accuracy: 1e-6)
        XCTAssertEqual(hours[10], 900, accuracy: 1e-6)
        XCTAssertEqual(hours.reduce(0, +), 11700, accuracy: 1e-6)
    }
}
