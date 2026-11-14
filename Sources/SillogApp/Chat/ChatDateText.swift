import Foundation
import SillogCore

/// 채팅 화면의 날짜 글자. 화면은 이것만 쓴다.
enum ChatDateText {
    /// 예: "11월 2일" (현지 시간대)
    static func day(_ time: Double) -> String { RecordingText.date(time, tr("M월 d일"), timeZone: .current) }

    /// e.g. "11월 13일 오후 1:43" or "Nov 13 at 1:43 PM", in the app language rather than the system's.
    static func dateTime(_ time: Double, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle.dateTime.month().day().hour().minute()
        style.locale = Locale(identifier: L10n.current.rawValue); style.timeZone = timeZone
        return Date(timeIntervalSince1970: time).formatted(style)
    }

    /// e.g. "목요일 오후 11:48" within the past week, otherwise dateTime, in the app language.
    static func divider(_ time: Double, now: Date = Date()) -> String {
        guard now.timeIntervalSince1970 - time < 6 * 86400 else { return dateTime(time) }
        var style = Date.FormatStyle.dateTime.weekday(.wide).hour().minute()
        style.locale = Locale(identifier: L10n.current.rawValue)
        return Date(timeIntervalSince1970: time).formatted(style)
    }

    /// 오늘, 어제, 그저께, 그 밖에는 day와 같다.
    static func relative(_ time: Double, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: time)), to: calendar.startOfDay(for: now)).day ?? 99
        switch ago {
        case 0: return tr("오늘")
        case 1: return tr("어제")
        case 2: return tr("그저께")
        default: return day(time)
        }
    }
}
