import Foundation
import XCTest
@testable import SillogApp

/// 업무 줄의 하루 시간대 줄: 자정을 넘긴 세션은 나누고, 겹치면 합치고, 14일보다 옛날은 뺀다
final class DayTimelineTests: XCTestCase {
    func testSplitsAtMidnightMergesAndDropsOld() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        let day = cal.startOfDay(for: now).timeIntervalSince1970
        let h = 3600.0
        let spans = DayTimeline.spans([
            (day - 2 * h, day + 1 * h),
            (day + 9 * h, day + 10 * h), (day + 9.5 * h, day + 11 * h),
            (day - 20 * 24 * h, day - 19 * 24 * h),
        ], now: now, calendar: cal)
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].upperBound, 1.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(spans[1].lowerBound, 9.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(spans[1].upperBound, 11.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(spans[2].lowerBound, 22.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(spans[2].upperBound, 1)
    }
}
