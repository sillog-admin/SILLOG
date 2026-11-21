import XCTest
@testable import SillogCore

final class RangeTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }

    private func at(_ daysAgo: Int, _ hour: Int) -> Double {
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour))!
        return calendar.date(byAdding: .day, value: -daysAgo, to: today)!.timeIntervalSince1970
    }

    private func time(_ sessions: [(daysAgo: Int, seconds: Double)], _ range: RangeTime.Range) -> RangeTime {
        RangeTime.of(sessions.map { (start: at($0.daysAgo, 10), seconds: $0.seconds) }, range: range, now: at(0, 15), calendar: calendar)
    }

    func testRangeCountsSessionsStartedInItAndAveragesOverItsDays() {
        let sessions: [(daysAgo: Int, seconds: Double)] = [(0, 3600), (2, 1800), (2, 1800), (10, 7200), (40, 3600)]
        XCTAssertEqual(time(sessions, .today), RangeTime(seconds: 3600, sessions: 1, workedDays: 1, spanDays: 1))
        XCTAssertEqual(time(sessions, .week), RangeTime(seconds: 7200, sessions: 3, workedDays: 2, spanDays: 7))
        XCTAssertEqual(time(sessions, .month), RangeTime(seconds: 14400, sessions: 4, workedDays: 3, spanDays: 30))
        XCTAssertEqual(time(sessions, .all), RangeTime(seconds: 18000, sessions: 5, workedDays: 4, spanDays: 41))
    }

    func testANewTaskAveragesOverTheDaysSinceItsFirstSession() {
        let young = time([(2, 1800), (0, 3600)], .week)
        XCTAssertEqual(young, RangeTime(seconds: 5400, sessions: 2, workedDays: 2, spanDays: 3))
        XCTAssertEqual(young.dailyAverage, 1800)
    }

    private func bars(_ sessions: [(daysAgo: Int, seconds: Double)], _ range: RangeTime.Range) -> [RangeTime.Bar] {
        RangeTime.bars(sessions.map { (start: at($0.daysAgo, 10), seconds: $0.seconds) }, range: range, now: at(0, 15), calendar: calendar)
    }

    func testBarsAreOnePerDayOldestFirstAndTodayHasNone() {
        let sessions: [(daysAgo: Int, seconds: Double)] = [(0, 3600), (2, 1800), (2, 1800), (10, 7200), (40, 3600)]
        XCTAssertEqual(bars(sessions, .today), [])
        let week = bars(sessions, .week)
        XCTAssertEqual(week.map(\.seconds), [0, 0, 0, 0, 3600, 0, 3600])
        XCTAssertEqual(week.first?.start, calendar.startOfDay(for: Date(timeIntervalSince1970: at(6, 0))))
        XCTAssertEqual(bars(sessions, .month).count, 30)
        XCTAssertEqual(bars(sessions, .month).reduce(0) { $0 + $1.seconds }, 14400)
        let all = bars(sessions, .all)
        XCTAssertEqual(all.count, 41, "전체: 첫 세션 날부터 오늘까지 하루씩")
        XCTAssertEqual(all.first?.seconds, 3600)
    }

    func testAllTimeOverSixtyDaysBecomesWeeksEndingToday() {
        let all = bars([(100, 3600), (3, 600), (0, 1200)], .all)
        XCTAssertEqual(all.count, 15, "101일을 오늘에서부터 7일씩")
        XCTAssertEqual(all.last?.seconds, 1800)
        XCTAssertEqual(all.last?.start, calendar.startOfDay(for: Date(timeIntervalSince1970: at(6, 0))))
        XCTAssertEqual(all.first?.seconds, 3600)
    }

    func testRangeStartIsMidnightOfItsFirstDay() {
        XCTAssertEqual(RangeTime.start(of: .week, now: at(0, 15), calendar: calendar), calendar.startOfDay(for: Date(timeIntervalSince1970: at(6, 0))).timeIntervalSince1970)
        XCTAssertNil(RangeTime.start(of: .all, now: at(0, 15), calendar: calendar))
    }

    func testItemsGroupByTheirStartDayKeepingOrder() {
        let starts = [at(0, 14), at(0, 9), at(2, 18), at(2, 8)]
        let days = RangeTime.byDay(starts, start: { $0 }, calendar: calendar)
        XCTAssertEqual(days.map(\.items), [[at(0, 14), at(0, 9)], [at(2, 18), at(2, 8)]])
        XCTAssertEqual(days.first?.day, calendar.startOfDay(for: Date(timeIntervalSince1970: at(0, 14))))
    }
}

final class RangeTimeHourlyTests: XCTestCase {
    func testSplitsAcrossHoursAndMidnightAndDropsOldSessions() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 15))!
        let day = cal.startOfDay(for: now).timeIntervalSince1970
        let h = 3600.0
        let hours = RangeTime.hourly([
            (day - 0.5 * h, day + 1.5 * h),
            (day + 9.25 * h, day + 9.75 * h),
            (day + 9.5 * h, day + 10.25 * h),
            (day - 20 * 24 * h, day - 19 * 24 * h),
        ], now: now, calendar: cal)
        XCTAssertEqual(hours[23], 1800, accuracy: 1e-6)
        XCTAssertEqual(hours[0], 3600, accuracy: 1e-6)
        XCTAssertEqual(hours[1], 1800, accuracy: 1e-6)
        XCTAssertEqual(hours[9], 3600, accuracy: 1e-6)
        XCTAssertEqual(hours[10], 900, accuracy: 1e-6)
        XCTAssertEqual(hours.reduce(0, +), 11700, accuracy: 1e-6)
    }
}
