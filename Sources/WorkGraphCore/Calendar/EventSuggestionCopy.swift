import Foundation

/// 일정 제안 알림과 메뉴 막대의 날짜 문구
public enum EventSuggestionCopy {
    public static let title = "일정을 캘린더에 넣을까요?"

    /// 세 줄: 일정 제목, 날짜, 어디서 찾았는지 (근거가 없으면 두 줄).
    /// "민수와 저녁 약속\n11월 4일 수 19:00\n카카오톡 · 내일 7시에 강남역에서 보자"
    public static func body(title: String, start: Double, allDay: Bool, evidence: String, timeZone: TimeZone = .current) -> String {
        ([title, dateText(start: start, allDay: allDay, timeZone: timeZone)] + (evidence.isEmpty ? [] : [evidence])).joined(separator: "\n")
    }

    public static func body(_ suggestion: EventSuggestion) -> String {
        body(title: suggestion.title, start: suggestion.start, allDay: suggestion.allDay, evidence: suggestion.evidence)
    }

    /// "11월 5일 목 14:00", 종일이면 시간 없이
    public static func dateText(start: Double, allDay: Bool, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = timeZone
        f.dateFormat = allDay ? "M월 d일 E" : "M월 d일 E HH:mm"
        return f.string(from: Date(timeIntervalSince1970: start))
    }
}
