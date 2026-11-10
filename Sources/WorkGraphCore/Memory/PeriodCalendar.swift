import Foundation

/// 현지 날짜·ISO 주(월~일)·달력 월. 사용 시간 기록, 다이제스트, 정리가 같은 경계를 쓴다
public struct PeriodCalendar: Sendable {
    public enum Level: String, Codable, Sendable { case week, month }

    public struct Period: Equatable, Hashable, Sendable {
        public let level: Level
        /// "2026-W41" 또는 "2026-10"
        public let id: String
        public let start: Double
        public let end: Double
        public let days: [String]
    }

    public let timeZone: TimeZone
    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// 현지 날짜 "YYYY-MM-DD"
    public func day(_ ts: Double) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func dayStart(_ day: String) -> Double? {
        let numbers = day.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2]))?.timeIntervalSince1970
    }

    /// 다음 날 0시
    public func dayEnd(_ day: String) -> Double? {
        dayStart(day).flatMap { start in calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: start))?.timeIntervalSince1970 }
    }

    public func addDays(_ day: String, _ count: Int) -> String {
        guard let start = dayStart(day), let moved = calendar.date(byAdding: .day, value: count, to: Date(timeIntervalSince1970: start)) else { return day }
        return self.day(moved.timeIntervalSince1970)
    }

    /// [from, to) 와 겹치는 날들 (시간순)
    public func days(from: Double, to: Double) -> [String] {
        guard to > from else { return [] }
        var result: [String] = []
        var current = day(from)
        while let start = dayStart(current), start < to {
            result.append(current)
            current = addDays(current, 1)
            if result.count > 20_000 { break }
        }
        return result
    }

    public func week(containing ts: Double) -> Period {
        let date = Date(timeIntervalSince1970: ts)
        let interval = calendar.dateInterval(of: .weekOfYear, for: date)!
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let id = String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
        return period(.week, id, interval)
    }

    public func month(containing ts: Double) -> Period {
        let date = Date(timeIntervalSince1970: ts)
        let interval = calendar.dateInterval(of: .month, for: date)!
        let parts = calendar.dateComponents([.year, .month], from: date)
        return period(.month, String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0), interval)
    }

    /// "2026-W41" 또는 "2026-10"
    public func period(id: String) -> Period? {
        if id.contains("-W") {
            let parts = id.split(separator: "-")
            guard parts.count == 2, let year = Int(parts[0]), let week = Int(parts[1].dropFirst()),
                  let date = calendar.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) else { return nil }
            let found = self.week(containing: date.timeIntervalSince1970)
            return found.id == id ? found : nil
        }
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)) else { return nil }
        return month(containing: date.timeIntervalSince1970)
    }

    public func next(_ period: Period) -> Period {
        period.level == .week ? week(containing: period.end + 1) : month(containing: period.end + 1)
    }

    /// 기간의 주들 (월간 다이제스트의 재료)
    public func weeks(overlapping period: Period) -> [Period] {
        var result: [Period] = []
        var current = week(containing: period.start)
        while current.start < period.end {
            result.append(current)
            current = next(current)
        }
        return result
    }

    private func period(_ level: Level, _ id: String, _ interval: DateInterval) -> Period {
        let start = interval.start.timeIntervalSince1970, end = interval.end.timeIntervalSince1970
        return Period(level: level, id: id, start: start, end: end, days: days(from: start, to: end))
    }
}

/// 사람이 읽는 시간 문구. 다이제스트 본문과 채팅 집계가 같은 표현을 쓴다
public enum TimePhrase {
    public static func approx(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return seconds > 0 ? "1분 미만" : "0분" }
        if minutes < 60 { return "약 \(minutes)분" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "약 \(hours)시간" : "약 \(hours)시간 \(rest)분"
    }
}
