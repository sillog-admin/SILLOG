import Foundation
import GRDB

/// 정리 한 번에 모은 기록 전부(업무 외로 판정된 메신저 대화, 녹음, AI 대화 포함)에서 사용자 본인의 앞으로 일정을 AI 에 찾게 한다:
/// 웹페이지의 과제 마감, 채팅에서 정한 약속, 회의에서 정한 다음 회의 같은 것. 찾은 일정은 캘린더 제안으로만 저장한다 (등록은 사용자가 누를 때).
/// 캘린더에 이미 있거나 이미 제안한 일정은 AI 에 보여 주어 다시 찾지 않게 하고, 그래도 겹치면 버린다 (isSame). 지난 일정도 버린다
public enum EventFinder {
    /// 이미 아는 일정: 캘린더에 있는 것(앱이 EventKit 으로 읽어 준다) 또는 이미 제안한 것
    public struct Known: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var allDay: Bool
        public init(title: String, start: Date, allDay: Bool) { self.title = title; self.start = start; self.allDay = allDay }
    }

    /// AI 가 기록에서 찾은 날짜 표현 한 건. date 는 yyyy-MM-dd, 시간은 HH:mm (없으면 종일).
    /// whose 는 mine(사용자 본인 일정) · others(다른 사람의 일정) · public(둘러본 공지), keep 은 제안할지 (mine 이고 지나지 않았고 KNOWN 에 없을 때)
    public struct Found: Decodable, Equatable, Sendable {
        public var row: Int
        public var title: String
        public var date: String
        public var startTime: String?
        public var endTime: String?
        public var evidence: String
        public var whose: String?
        public var keep: Bool?

        enum CodingKeys: String, CodingKey { case row, title, date, startTime = "start_time", endTime = "end_time", evidence, whose, keep }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            row = try c.lenientInt(.row) ?? 0
            title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
            date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
            startTime = try? c.decodeIfPresent(String.self, forKey: .startTime)
            endTime = try? c.decodeIfPresent(String.self, forKey: .endTime)
            evidence = (try? c.decodeIfPresent(String.self, forKey: .evidence)) ?? ""
            whose = (try? c.decodeIfPresent(String.self, forKey: .whose))?.trimmingCharacters(in: .whitespaces).lowercased()
            keep = (try? c.decodeIfPresent(Bool.self, forKey: .keep)) ?? (try? c.decodeIfPresent(String.self, forKey: .keep)).flatMap { Bool($0.lowercased()) }
        }

        /// 제안할 것: keep 이 false 가 아니고 본인 일정 (작은 모델이 둘 중 하나를 빠뜨리면 본인 일정으로 본다)
        public var wanted: Bool { keep != false && (whose ?? "mine") == "mine" }
    }

    public static var system: String { """
    You find the user's own upcoming schedule in their desktop activity records, so it can be suggested for their calendar.

    You receive:
    - NOW, THIS_WEEK and NEXT_WEEK: the current date, weekday and time, and the dates of this week and next week (weeks start on Monday).
    - KNOWN: events already in the user's calendar or already suggested to the user.
    - REJECTED: suggestions the user dismissed, with the words they came from. They show what the user does not want in the calendar.
    \(StagePrompt.rowsGuide)
    - DATE lines: ROWS are grouped by day. A row happened on the date of the DATE line above it.

    Go through every row and list in `mentions` each expression that points to a coming day or time: a date, a weekday, 오늘/내일/모레/다음 주, a deadline, a period such as "~ 10. 27. 23:59", a time such as "7시". Chats, course pages, assignment lists, recordings and the user's messages to an AI assistant are the usual places. For each mention give:
    - row: the row where it appears
    - evidence: the words that state the day or the time, quoted as written (under 80 characters)
    - title: a short \(L10n.current.promptName) title that says what it is and with whom or for which course ("민수와 저녁 약속", "데이터베이스 과제 3 마감", "기획 팀 회의")
    - date: yyyy-MM-dd. Resolve relative days ("오늘", "내일", "모레", "이번 주 금요일", "다음 주 목요일") from the date of the row where they appear, or from the date the screen shows for a quoted message (a date divider above it), not from NOW; THIS_WEEK and NEXT_WEEK help with weekday names.
    - start_time and end_time: HH:mm, only when a time is stated. A deadline's time goes in start_time. Read a time without 오전/오후 as the hour that fits the plan (저녁 7시 → 19:00, 3시 회의 → 15:00).
    - whose: mine for the user's own commitment (a plan the user agreed to or will attend, something the user must submit or pay, an assignment or exam of a course the user takes, a meeting or deadline of a team the user belongs to). others for another person's own plan, exam or task, even when they mention it in a chat with the user. public for a date in news, an ad, a posting, a notice or an event listing the user only browsed.
    - keep: true only for one of these two kinds, when whose is mine, the exact day is stated or can be worked out (not a vague "다음 주" or "이번 달"), the day or time is not past, and the event is not in KNOWN (even when it is worded differently):
      1. an appointment, meeting, plan or deadline set in a conversation the user takes part in: a chat, messenger, mail, recording, or the user's own message to an AI assistant ("내일 7시에 강남역에서 보자" answered with "좋아"; "토요일까지 각자 맡은 부분 고쳐 주세요" in the team chat).
      2. the deadline of one assignment, submission, application or payment, when the row is that item's own page or submission screen. A submission window on that page ("26. 10. 12. 11:35 ~ 26. 10. 27. 23:59") gives the deadline: its last day and time.
      Not kept: a date range or period that is not such a deadline ("11.9~11.13" in a weekly plan, "인정 기간 ~12.14"); dates on a page that lists many of them, such as a syllabus, a weekly study plan, a timetable or a course schedule; plans nobody agreed to ("언제 한번 보자") and dates still offered as options ("12.24나 1.1 어때?"); anything like the suggestions in REJECTED.
    An empty list is normal. Always answer by calling find_events. Do not write prose.
    """ }

    public static var tool: ToolSpec {
        ToolSpec(name: "find_events", description: "Every mention of a coming day or time in the rows, with whose it is and whether to suggest it.", parameters: .object([
            "type": "object",
            "properties": .object([
                "mentions": .object(["type": "array", "description": "기록에서 앞으로의 날짜·시간을 가리키는 표현 전부. 없으면 빈 배열", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "row": .object(["type": "integer", "description": "표현이 나온 행 번호"]),
                        "evidence": .object(["type": "string", "description": "날짜나 시간을 말하는 기록의 문구 그대로, 80자 이내"]),
                        "title": .object(["type": "string", "description": "무엇인지와 누구와·어느 과목인지 담은 짧은 한국어 제목"]),
                        "date": .object(["type": "string", "description": "yyyy-MM-dd"]),
                        "start_time": .object(["type": "string", "description": "HH:mm, 시간이 나올 때만 (마감 시각도 여기)"]),
                        "end_time": .object(["type": "string", "description": "HH:mm, 끝 시간이 나올 때만"]),
                        "whose": .object(["type": "string", "enum": .array(["mine", "others", "public"]),
                                          "description": "mine: 사용자 본인 일정(약속, 제출, 속한 수업·팀·모임의 마감과 회의), others: 다른 사람의 일정, public: 둘러본 공지·게시글·광고"]),
                        "keep": .object(["type": "boolean", "description": "mine 이고 지나지 않았고 KNOWN 에 없을 때만 true"]),
                    ]),
                    "required": .array(["row", "evidence", "title", "date", "whose", "keep"]),
                ])]),
            ]),
            "required": .array(["mentions"]),
        ]))
    }

    /// NOW 와 이번 주·다음 주 날짜(요일을 날짜로 풀게), 이미 아는 일정, 거절한 예, 행 전부
    static func prompt(rows: [ActivityRow], cards: [Int: [ScreenCard]], known: [Known], rejected: [EventSuggestion] = [], now: Double, timeZone: TimeZone) -> String {
        prompt(rowLines: OntologyPrompt.rowLines(rows, cards: cards, timeZone: timeZone, dates: true), known: known, rejected: rejected, now: now, timeZone: timeZone)
    }

    /// 행 줄을 이미 만들어 둔 경우 (sillogctl find-events 가 저장된 배치의 행 줄로 다시 물을 때)
    public static func prompt(rowLines: [String], known: [Known], rejected: [EventSuggestion] = [], now: Double, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .iso8601)                      // 주는 월요일부터
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        func text(_ date: Date, _ format: String) -> String { f.dateFormat = format; return f.string(from: date) }
        let today = Date(timeIntervalSince1970: now)
        let monday = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        func week(_ offset: Int) -> String {
            (0..<7).compactMap { calendar.date(byAdding: .day, value: offset * 7 + $0, to: monday) }
                .map { text($0, "yyyy-MM-dd EEE") + (calendar.isDate($0, inSameDayAs: today) ? " (today)" : "") }
                .joined(separator: ", ")
        }
        var lines = ["NOW: \(text(today, "yyyy-MM-dd EEE HH:mm")) (\(timeZone.identifier))", "THIS_WEEK: \(week(0))", "NEXT_WEEK: \(week(1))",
                     "KNOWN (already in the calendar or already suggested):"]
        func when(_ start: Date, _ allDay: Bool) -> String { allDay ? text(start, "yyyy-MM-dd") + " all day" : text(start, "yyyy-MM-dd HH:mm") }
        lines += known.isEmpty ? ["- (none)"] : known.map { "- \(when($0.start, $0.allDay)) \(OntologyPrompt.clip($0.title, 60))" }
        lines.append("REJECTED (suggestions the user dismissed; do not keep events like these):")
        lines += rejected.isEmpty ? ["- (none)"] : rejected.map { suggestion in
            let source = suggestion.evidence.isEmpty ? "" : " ← \(OntologyPrompt.clip(suggestion.evidence, 80))"
            return "- \(when(Date(timeIntervalSince1970: suggestion.start), suggestion.allDay)) \(OntologyPrompt.clip(suggestion.title, 60))\(source)"
        }
        lines.append("\(StagePrompt.rowsHeader) — find the user's upcoming events:")
        lines += rowLines
        return lines.joined(separator: "\n")
    }

    /// 응답 해석. 작은 모델의 흔들림(문자열로 감싼 JSON, 문자열 행 번호, mentions 대신 events)을 받아 준다
    public static func decode(_ data: Data) -> [Found] {
        guard let root = StageDecode.object(data) else { return [] }
        return StageDecode.decode([Found].self, root["mentions"] ?? root["events"]) ?? []
    }

    /// 찾은 일정의 시작·끝. 날짜 형식이 틀리면 nil, 시작 시간이 없거나 시간이 아니면 종일
    static func times(_ found: Found, timeZone: TimeZone) -> (start: Date, end: Date?, allDay: Bool)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: found.date.trimmingCharacters(in: .whitespaces)) else { return nil }
        func at(_ text: String?) -> Date? { clock(text).flatMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: day) } }
        guard let start = at(found.startTime) else { return (day, nil, true) }
        return (start, at(found.endTime).flatMap { $0 > start ? $0 : nil }, false)
    }

    /// "19:00", "9:30", "19:00:00" → 시·분. 자정 마감 "24:00" 은 그날 23:59. 시간이 아니면 nil
    static func clock(_ text: String?) -> (hour: Int, minute: Int)? {
        let parts = (text ?? "").trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), (1...2).contains(parts[0].count), parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]), minute < 60 else { return nil }
        if hour == 24, minute == 0 { return (23, 59) }
        return hour < 24 ? (hour, minute) : nil
    }

    /// 같은 일정인지 (한쪽을 버리거나 닫아도 되는지): 같은 날이고 제목의 숫자(과제 번호 같은 것)가 같으면서, 제목이 같거나,
    /// 한쪽 제목이 다른 쪽을 품고 시간이 맞을 때 (둘 다 시간이 있으면 30분 안쪽). 띄어쓰기·기호·대소문자는 무시한다.
    /// 헷갈리면 다른 일정으로 본다: 같은 날 23:59 에 마감하는 다른 과제를 하나로 보면 하나가 조용히 사라진다. 표현만 다른 같은 일정은 AI 가 KNOWN 을 보고 거른다
    public static func isSame(_ a: Known, _ b: Known, timeZone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.isDate(a.start, inSameDayAs: b.start) else { return false }
        let x = key(a.title), y = key(b.title)
        guard !x.isEmpty, !y.isEmpty, numbers(x) == numbers(y) else { return false }
        if x == y { return true }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard short.count >= 2, long.contains(short) else { return false }
        return a.allDay || b.allDay || abs(a.start.timeIntervalSince(b.start)) <= 30 * 60
    }

    private static func key(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 제목 속 숫자 묶음: "과제3마감2차" → ["3", "2"]
    private static func numbers(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isNumber }).map(String.init)
    }

    /// 제안에 남길 근거: "카카오톡 · 내일 7시에 강남역에서 보자" (캘린더에 등록할 때 메모로 들어간다). 인용이 없으면 행 제목
    static func evidence(_ found: Found, row: ActivityRow?) -> String {
        let quote = OntologyPrompt.clip(found.evidence.trimmingCharacters(in: .whitespacesAndNewlines), 100)
        guard let row else { return quote }
        let text = quote.isEmpty ? (row.title ?? row.uri ?? "") : quote
        return text.isEmpty ? row.app : "\(row.app) · \(text)"
    }

    /// 이보다 먼 날짜(일)는 제안하지 않는다
    static let horizonDays: Double = 366
    /// 한 웹페이지(대화·녹음이 아닌 행)에서 이보다 많이 남기면 계획표·강의계획서로 보고 버린다
    static let maxPerPage = 2
    /// 이 앱의 화면은 보내지 않는다: 보이는 일정이 이미 캘린더에 있다
    static let calendarApps: Set<String> = ["com.apple.iCal"]

    /// AI 에 묻고 새 제안을 저장한다. calendar 는 캘린더에 이미 있는 일정 (권한이 없으면 빈 목록).
    /// Returns: 새로 만든 제안 id (AI 가 답한 순서). 행이 없으면 묻지 않는다.
    /// Raises: AI 호출 오류, DB 오류.
    public static func run(db: SillogDatabase, llm: any LLMClient, rows: [ActivityRow], cards: [Int: [ScreenCard]], calendar: [Known],
                           now: Double, timeZone: TimeZone = .current) async throws -> [Int64] {
        let rows = rows.filter { !calendarApps.contains($0.appBundle) }
        guard !rows.isEmpty else { return [] }
        var days = Calendar(identifier: .gregorian)
        days.timeZone = timeZone
        let today = days.startOfDay(for: Date(timeIntervalSince1970: now))
        let store = EventSuggestionStore(db)
        let suggested = try store.upcoming(from: today).map { Known(title: $0.title, start: Date(timeIntervalSince1970: $0.start), allDay: $0.allDay) }
        var known = (calendar + suggested).sorted { $0.start < $1.start }
        let user = prompt(rows: rows, cards: cards, known: Array(known.prefix(60)), rejected: try store.dismissed(), now: now, timeZone: timeZone)
        let result = try await llm.callFunction(system: system, user: user, tool: tool)
        let byNumber = Dictionary(rows.map { ($0.row, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = decode(result.arguments).filter(\.wanted)
        // 한 웹페이지에서 너무 많이 남긴 것은 계획표로 보고 버린다 (대화·녹음 행은 그대로)
        let perRow = Dictionary(grouping: wanted, by: \.row).mapValues(\.count)
        let plans = Set(perRow.filter { $0.value > maxPerPage && !(byNumber[$0.key]?.isChat ?? false) }.keys)
        // 형식이 틀린 것, 지난 것, 이미 아는 일정과 겹치는 것(같은 답 안의 되풀이도)을 거른다
        var picked: [(found: Found, title: String, start: Date, end: Date?, allDay: Bool)] = []
        for found in wanted where !plans.contains(found.row) {
            let title = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let (start, end, allDay) = times(found, timeZone: timeZone) else { continue }
            guard allDay ? start >= today : (end ?? start).timeIntervalSince1970 >= now else { continue }
            guard start.timeIntervalSince(today) <= Self.horizonDays * 86_400 else { continue }     // 쿠폰·자격 만료 같은 먼 날짜
            let candidate = Known(title: title, start: start, allDay: allDay)
            guard !known.contains(where: { isSame(candidate, $0, timeZone: timeZone) }) else { continue }
            known.append(candidate)
            picked.append((found, title, start, end, allDay))
        }
        let chosen = picked
        return try await db.writer.write { conn in
            try chosen.compactMap { item in
                let source = byNumber[item.found.row]
                return try EventSuggestionStore.insert(conn, title: item.title, start: item.start, end: item.end, allDay: item.allDay,
                                                       evidenceId: source?.observationIds.first, evidence: evidence(item.found, row: source),
                                                       now: now, timeZone: timeZone)
            }
        }
    }
}
