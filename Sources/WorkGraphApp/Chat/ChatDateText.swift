import Foundation
import WorkGraphCore

/// 채팅 화면의 날짜 글자. 화면은 이것만 쓴다.
enum ChatDateText {
    /// 예: "11월 2일" (현지 시간대)
    static func day(_ time: Double) -> String { RecordingText.date(time, "M월 d일", timeZone: .current) }

    /// 오늘, 어제, 그저께, 그 밖에는 day와 같다.
    static func relative(_ time: Double, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: time)), to: calendar.startOfDay(for: now)).day ?? 99
        switch ago {
        case 0: return "오늘"
        case 1: return "어제"
        case 2: return "그저께"
        default: return day(time)
        }
    }
}
