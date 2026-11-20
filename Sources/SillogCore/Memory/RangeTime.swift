import Foundation

/// A task's work time over today, the last 7 or 30 days, or all time, from its sessions
public struct RangeTime: Equatable, Sendable {
    public enum Range: String, CaseIterable, Sendable {
        case today, week, month, all
        public var days: Int? {
            switch self {
            case .today: 1
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    public var seconds: Double
    public var sessions: Int
    public var workedDays: Int
    /// Days the average divides by: the range, or fewer when the task's first session is inside it
    public var spanDays: Int

    public init(seconds: Double, sessions: Int, workedDays: Int, spanDays: Int) {
        self.seconds = seconds; self.sessions = sessions; self.workedDays = workedDays; self.spanDays = spanDays
    }

    public var dailyAverage: Double { seconds / Double(max(spanDays, 1)) }

    /// Args: sessions as start (Unix seconds) and active seconds; now; the calendar that sets day boundaries.
    /// Returns: the time of the sessions that started in the range.
    // shortcut: a session past midnight counts on its start day (5 of 560 in a real DB), split with LedgerBuilder.rows if that matters
    public static func of(_ sessions: [(start: Double, seconds: Double)], range: Range, now: Double, calendar: Calendar = .current) -> RangeTime {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        guard let first = sessions.map(\.start).min() else { return RangeTime(seconds: 0, sessions: 0, workedDays: 0, spanDays: range.days ?? 1) }
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: first))
        let rangeStart = start(of: range, now: now, calendar: calendar).map { Date(timeIntervalSince1970: $0) } ?? firstDay
        let start = max(rangeStart, firstDay)
        let inside = sessions.filter { $0.start >= rangeStart.timeIntervalSince1970 }
        let worked = Set(inside.filter { $0.seconds > 0 }.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.start)) })
        let span = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        return RangeTime(seconds: inside.reduce(0) { $0 + $1.seconds }, sessions: inside.count, workedDays: worked.count, spanDays: max(span, 1))
    }

    /// Midnight of the range's first day, or nil for all time
    public static func start(of range: Range, now: Double, calendar: Calendar = .current) -> Double? {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        return range.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }?.timeIntervalSince1970
    }

    /// One bar of the work time chart: a day, or a week when all time is long
    public struct Bar: Equatable, Sendable {
        public var start: Date
        public var seconds: Double
        public init(start: Date, seconds: Double) { self.start = start; self.seconds = seconds }
    }

    /// Seconds per day for the last `days` days, oldest first, by session start day
    public static func daily(_ sessions: [(start: Double, seconds: Double)], days: Int, now: Double, calendar: Calendar = .current) -> [Bar] {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        var bars = (0..<max(days, 0)).compactMap { offset in
            calendar.date(byAdding: .day, value: offset + 1 - days, to: today).map { Bar(start: $0, seconds: 0) }
        }
        for session in sessions {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: session.start))
            guard let ago = calendar.dateComponents([.day], from: day, to: today).day, ago >= 0, ago < bars.count else { continue }
            bars[bars.count - 1 - ago].seconds += session.seconds
        }
        return bars
    }

    /// The chart under the total: none for today, a day per bar, and weeks ending today when all time passes 60 days
    public static func bars(_ sessions: [(start: Double, seconds: Double)], range: Range, now: Double, calendar: Calendar = .current) -> [Bar] {
        if range == .today { return [] }
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: now))
        let days = range.days ?? sessions.map(\.start).min().map {
            (calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: $0)), to: today).day ?? 0) + 1
        } ?? 1
        let daily = daily(sessions, days: days, now: now, calendar: calendar)
        guard daily.count > 60 else { return daily }
        return stride(from: daily.count, to: 0, by: -7).reversed().map { end in
            let week = daily[max(end - 7, 0)..<end]
            return Bar(start: week.first!.start, seconds: week.reduce(0) { $0 + $1.seconds })
        }
    }

    /// Items grouped by the day they start, in the order given
    public static func byDay<T>(_ items: [T], start: (T) -> Double, calendar: Calendar = .current) -> [(day: Date, items: [T])] {
        var groups: [(day: Date, items: [T])] = []
        for item in items {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: start(item)))
            if groups.last?.day == day { groups[groups.count - 1].items.append(item) } else { groups.append((day, [item])) }
        }
        return groups
    }
}
