import XCTest
import GRDB
@testable import SillogCore

final class EventFinderTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    private func time(_ day: String, _ clock: String = "00:00") -> Double {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = seoul; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) \(clock)")!.timeIntervalSince1970
    }

    /// 2026-11-03 (화) 14:20
    private var now: Double { time("2026-11-03", "14:20") }

    private func row(_ n: Int, app: String, title: String, snippet: String, type: String, observation: Int64? = nil, chat: Bool = false) -> ActivityRow {
        ActivityRow(row: n, start: now - 600, end: now - 300, dwell: chat ? 0 : 300, app: app, appBundle: "b.\(app)", title: title, uri: nil, type: type,
                    projectKey: nil, projectTitle: nil, snippet: snippet, observationIds: observation.map { [$0] } ?? [], isChat: chat)
    }

    /// 업무 외 메신저 대화, 과제 페이지, 녹음
    private var rows: [ActivityRow] {
        [row(1, app: "카카오톡", title: "민수", snippet: "민수: 내일 7시에 강남역에서 보자 / 나: 좋아", type: "Messenger", observation: 11),
         row(2, app: "Google Chrome", title: "과제 3 - LMS", snippet: "데이터베이스 과제 3 마감: 2026-11-10 23:59", type: "WebPage", observation: 12),
         row(3, app: "녹음", title: "기획 회의", snippet: "다음 주 목요일 오후 3시에 다시 회의하기로 했어요", type: "Recording", chat: true)]
    }

    private func known(_ title: String, _ day: String, _ clock: String? = nil) -> EventFinder.Known {
        EventFinder.Known(title: title, start: Date(timeIntervalSince1970: time(day, clock ?? "00:00")), allDay: clock == nil)
    }

    func testPromptGivesWeekdaysKnownEventsAndEveryRow() {
        let prompt = EventFinder.prompt(rows: rows, cards: [:], known: [known("팀 회의", "2026-11-05", "15:00"), known("중간 발표", "2026-11-20")],
                                        now: now, timeZone: seoul)
        XCTAssertTrue(prompt.contains("NOW: 2026-11-03 Tue 14:20"), prompt)
        XCTAssertTrue(prompt.contains("2026-11-12 Thu"), "'다음 주 목요일'을 날짜로 풀 수 있게 이번 주·다음 주 날짜를 준다")
        XCTAssertTrue(prompt.contains("- 2026-11-05 15:00 팀 회의"), prompt)
        XCTAssertTrue(prompt.contains("- 2026-11-20 all day 중간 발표"), prompt)
        XCTAssertTrue(prompt.contains("내일 7시에 강남역에서 보자"), "업무 외 메신저 행도 보낸다")
        XCTAssertTrue(prompt.contains("다음 주 목요일 오후 3시에"), "녹음 행도 보낸다")
    }

    func testSavesFoundEventsAsPendingSuggestions() async throws {
        let db = try SillogDatabase.inMemory()
        let llm = StubLLM([.success("""
        {"events":[{"row":1,"title":"민수와 저녁 약속","date":"2026-11-04","start_time":"19:00","evidence":"내일 7시에 강남역에서 보자"},
                   {"row":2,"title":"데이터베이스 과제 3 마감","date":"2026-11-10","start_time":"23:59","evidence":"과제 3 마감: 2026-11-10 23:59"},
                   {"row":3,"title":"기획 회의","date":"2026-11-12","start_time":"15:00","end_time":"16:00","evidence":"다음 주 목요일 오후 3시"}]}
        """)])
        let ids = try await EventFinder.run(db: db, llm: llm, rows: rows, cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(llm.lastSystem, EventFinder.system)
        let pending = try EventSuggestionStore(db).pending(now: Date(timeIntervalSince1970: now))
        XCTAssertEqual(pending.map(\.title), ["민수와 저녁 약속", "데이터베이스 과제 3 마감", "기획 회의"])
        XCTAssertEqual(pending[0].start, time("2026-11-04", "19:00"))
        XCTAssertNil(pending[0].end)
        XCTAssertFalse(pending[0].allDay)
        XCTAssertEqual(pending[0].evidenceId, 11, "근거 행의 첫 관측")
        XCTAssertEqual(pending[0].evidence, "카카오톡 · 내일 7시에 강남역에서 보자")
        XCTAssertEqual(pending[2].end, time("2026-11-12", "16:00"))
        XCTAssertNil(pending[2].evidenceId, "녹음 행에는 관측이 없다")
    }

    func testSkipsPastMalformedKnownAndRepeatedEvents() async throws {
        let db = try SillogDatabase.inMemory()
        // 예전에 제안했다가 무시한 일정
        let dismissed = try await db.writer.write {
            try EventSuggestionStore.insert($0, title: "중간 발표", start: Date(timeIntervalSince1970: self.time("2026-11-20")), end: nil, allDay: true,
                                            evidenceId: nil, evidence: "", now: 0, timeZone: self.seoul)
        }
        try EventSuggestionStore(db).setStatus(try XCTUnwrap(dismissed), EventSuggestionStore.dismissed)
        let llm = StubLLM([.success("""
        {"events":[{"row":1,"title":"어제 일","date":"2026-11-02","evidence":"어제"},
                   {"row":1,"title":"오늘 아침 회의","date":"2026-11-03","start_time":"09:00","evidence":"오늘 9시"},
                   {"row":1,"title":"날짜 모름","date":"11월 5일","evidence":"5일"},
                   {"row":1,"title":" ","date":"2026-11-06","evidence":"6일"},
                   {"row":3,"title":"팀회의","date":"2026-11-05","start_time":"15:00","evidence":"목요일 3시"},
                   {"row":2,"title":"중간발표","date":"2026-11-20","evidence":"중간 발표 11/20"},
                   {"row":2,"title":"쿠폰 만료","date":"2030-01-01","evidence":"2030년 1월 1일까지"},
                   {"row":1,"title":"민수 시험","date":"2026-11-06","whose":"others","keep":false,"evidence":"저 목요일에 시험이 있어서"},
                   {"row":2,"title":"채용 특강 신청 마감","date":"2026-11-07","whose":"public","keep":true,"evidence":"특강 신청이 토요일 마감입니다"},
                   {"row":2,"title":"보류한 일","date":"2026-11-07","whose":"mine","keep":false,"evidence":"토요일쯤"},
                   {"row":3,"title":"기획 회의","date":"2026-11-12","start_time":"15:00","evidence":"다음 주 목요일 오후 3시"},
                   {"row":3,"title":"기획 회의","date":"2026-11-12","start_time":"15:00","evidence":"다시 한 번"}]}
        """)])
        let ids = try await EventFinder.run(db: db, llm: llm, rows: rows, cards: [:], calendar: [known("팀 회의", "2026-11-05", "15:00")], now: now, timeZone: seoul)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(try EventSuggestionStore(db).pending(now: Date(timeIntervalSince1970: now)).map(\.title), ["기획 회의"])
        XCTAssertTrue(llm.lastUser.contains("- 2026-11-05 15:00 팀 회의"), "캘린더 일정을 AI 에 보여 준다")
        XCTAssertTrue(llm.lastUser.contains("중간 발표"), "무시한 제안도 다시 찾지 않게 보여 준다")
    }

    /// 무시한 제안을 거절한 예로 보여 줘 비슷한 것(계획표의 주차별 기간 같은 것)을 다시 내지 않게 한다. 지난 것도 예로는 쓴다
    func testDismissedSuggestionsAreShownAsRejectedExamples() async throws {
        let db = try SillogDatabase.inMemory()
        let id = try await db.writer.write { conn -> Int64? in
            try EventSuggestionStore.insert(conn, title: "AI기초수학 주차별 학습 정리", start: Date(timeIntervalSince1970: self.time("2026-10-26")), end: nil, allDay: true,
                                            evidenceId: nil, evidence: "Notion · 10.26~10.30", now: 0, timeZone: self.seoul)
        }
        try EventSuggestionStore(db).setStatus(try XCTUnwrap(id), EventSuggestionStore.dismissed)
        let llm = StubLLM([.success(#"{"mentions":[]}"#)])
        _ = try await EventFinder.run(db: db, llm: llm, rows: rows, cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertTrue(llm.lastUser.contains("REJECTED"), llm.lastUser)
        XCTAssertTrue(llm.lastUser.contains("AI기초수학 주차별 학습 정리 ← Notion · 10.26~10.30"), llm.lastUser)
    }

    /// 캘린더 앱 화면에 보이는 일정은 이미 캘린더에 있다: 그 행은 보내지 않는다
    func testCalendarAppRowsAreNotSent() async throws {
        let db = try SillogDatabase.inMemory()
        var calendarRow = row(4, app: "캘린더", title: "캘린더", snippet: "자료구조 시험 12월 15일 오후 12시", type: "WebPage", observation: 14)
        calendarRow.appBundle = "com.apple.iCal"
        let llm = StubLLM([.success(#"{"mentions":[]}"#)])
        _ = try await EventFinder.run(db: db, llm: llm, rows: rows + [calendarRow], cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertFalse(llm.lastUser.contains("자료구조 시험 12월 15일"))
        _ = try await EventFinder.run(db: db, llm: llm, rows: [calendarRow], cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertEqual(llm.calls, 1, "캘린더 화면뿐이면 묻지 않는다")
    }

    /// 한 웹페이지에서 3개 넘게 남기면 계획표·강의계획서로 보고 버린다 (대화·녹음에서 정한 것은 그대로)
    func testManyDatesKeptFromOnePageAreDropped() async throws {
        let db = try SillogDatabase.inMemory()
        let llm = StubLLM([.success("""
        {"mentions":[{"row":2,"title":"주차별 학습 정리 1","date":"2026-11-09","whose":"mine","keep":true,"evidence":"11.9~11.13"},
                     {"row":2,"title":"주차별 학습 정리 2","date":"2026-11-16","whose":"mine","keep":true,"evidence":"11.16~11.20"},
                     {"row":2,"title":"주차별 학습 정리 3","date":"2026-11-23","whose":"mine","keep":true,"evidence":"11.23~11.27"},
                     {"row":3,"title":"기획 회의","date":"2026-11-12","start_time":"15:00","whose":"mine","keep":true,"evidence":"다음 주 목요일 오후 3시"},
                     {"row":3,"title":"중간 발표","date":"2026-11-20","whose":"mine","keep":true,"evidence":"발표는 20일"},
                     {"row":3,"title":"최종 보고서 마감","date":"2026-11-27","whose":"mine","keep":true,"evidence":"보고서는 27일까지"}]}
        """)])
        let ids = try await EventFinder.run(db: db, llm: llm, rows: rows, cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(try EventSuggestionStore(db).pending(now: Date(timeIntervalSince1970: now)).map(\.title), ["기획 회의", "중간 발표", "최종 보고서 마감"])
    }

    func testDoesNotAskWithoutRows() async throws {
        let db = try SillogDatabase.inMemory()
        let llm = StubLLM([])
        let ids = try await EventFinder.run(db: db, llm: llm, rows: [], cards: [:], calendar: [], now: now, timeZone: seoul)
        XCTAssertEqual(ids, [])
        XCTAssertEqual(llm.calls, 0)
    }

    /// 날짜 표현을 먼저 모두 늘어놓고 하나씩 누구 일정인지 가르게 한다 (빠뜨림과 남의 일정을 줄인다)
    func testToolListsEveryMentionWithWhoseAndKeep() throws {
        let schema = String(decoding: try JSONEncoder().encode(EventFinder.tool.parameters), as: UTF8.self)
        XCTAssertTrue(schema.contains("\"mentions\""))
        XCTAssertTrue(schema.contains("\"whose\""))
        XCTAssertTrue(schema.contains("\"keep\""))
        let found = EventFinder.decode(Data(#"{"mentions":[{"row":1,"title":"t","date":"2026-11-10","whose":"mine","keep":true,"evidence":"e"}]}"#.utf8))
        XCTAssertEqual(found.first?.whose, "mine")
        XCTAssertEqual(found.first?.keep, true)
    }

    func testReadsLooseAnswers() {
        let data = Data(#"{"events":"[{\"row\":\"2\",\"title\":\"과제 마감\",\"date\":\"2026-11-10\",\"evidence\":\"마감 11/10\"}]"}"#.utf8)
        let found = EventFinder.decode(data)
        XCTAssertEqual(found.map(\.row), [2])
        XCTAssertEqual(found.first?.title, "과제 마감")
        XCTAssertEqual(EventFinder.decode(Data("not json".utf8)), [])
    }

    func testSameEventMatchesSpacingOrContainedTitleOnTheSameDay() {
        let meeting = known("팀 회의", "2026-11-05", "15:00")
        XCTAssertTrue(EventFinder.isSame(known("팀회의", "2026-11-05", "18:00"), meeting, timeZone: seoul), "띄어쓰기만 다름")
        XCTAssertTrue(EventFinder.isSame(known("기획 팀 회의", "2026-11-05"), meeting, timeZone: seoul), "종일 일정이 같은 회의를 품음")
        XCTAssertFalse(EventFinder.isSame(known("요가", "2026-11-05", "15:00"), meeting, timeZone: seoul), "같은 시간이라도 제목이 다르면 겹치는 다른 약속")
        XCTAssertFalse(EventFinder.isSame(known("저녁 약속", "2026-11-05", "19:00"), meeting, timeZone: seoul))
        XCTAssertFalse(EventFinder.isSame(known("팀 회의", "2026-11-06", "15:00"), meeting, timeZone: seoul), "다른 날")
    }

    /// 같은 날 같은 시각에 마감하는 다른 과제를 하나로 보면, 하나를 등록할 때 다른 하나가 조용히 사라진다
    func testSameEventNeedsMatchingNumbersAndCloseTimes() {
        XCTAssertFalse(EventFinder.isSame(known("데이터베이스 과제 3 마감", "2026-11-08", "23:59"), known("운영체제 과제 2 마감", "2026-11-08", "23:59"), timeZone: seoul),
                       "같은 시각에 마감하는 다른 과제")
        XCTAssertFalse(EventFinder.isSame(known("과제 3 마감", "2026-11-08", "23:59"), known("과제 4 마감", "2026-11-08", "23:59"), timeZone: seoul), "번호가 다름")
        XCTAssertFalse(EventFinder.isSame(known("회의", "2026-11-05", "10:00"), known("기획 회의", "2026-11-05", "15:00"), timeZone: seoul), "시간이 먼 다른 회의")
        XCTAssertTrue(EventFinder.isSame(known("회의", "2026-11-05", "15:00"), known("기획 회의", "2026-11-05", "15:10"), timeZone: seoul), "같은 시간대의 같은 회의")
        XCTAssertTrue(EventFinder.isSame(known("과제 3 마감", "2026-11-08"), known("데이터베이스 과제 3 마감", "2026-11-08", "23:59"), timeZone: seoul),
                      "종일로 적은 같은 마감")
    }

    func testReadsTimesWithSecondsSingleDigitHoursAndMidnight() {
        func start(_ text: String) -> Double? {
            let json = #"{"events":[{"row":1,"title":"t","date":"2026-11-04","start_time":"\#(text)","evidence":""}]}"#
            guard let found = EventFinder.decode(Data(json.utf8)).first, let times = EventFinder.times(found, timeZone: seoul), !times.allDay else { return nil }
            return times.start.timeIntervalSince1970
        }
        XCTAssertEqual(start("19:00:00"), time("2026-11-04", "19:00"))
        XCTAssertEqual(start("9:30"), time("2026-11-04", "09:30"))
        XCTAssertEqual(start("24:00"), time("2026-11-04", "23:59"), "자정 마감은 그날 23:59")
        XCTAssertNil(start("저녁"), "시간이 아니면 종일")
    }

    /// 행에는 시각만 있어 '내일'을 정리한 시각으로 풀면 자정 무렵이나 밀린 정리에서 하루가 밀린다. 날이 바뀔 때마다 날짜 줄을 넣는다
    func testRowsCarryTheirDateSoRelativeDaysResolveFromTheRow() throws {
        var late = row(1, app: "카카오톡", title: "민수", snippet: "민수: 내일 7시에 보자", type: "Messenger", observation: 11)
        late.start = time("2026-11-02", "23:55"); late.end = time("2026-11-02", "23:58")
        var early = row(2, app: "Google Chrome", title: "과제", snippet: "마감 11/10", type: "WebPage", observation: 12)
        early.start = time("2026-11-03", "00:05"); early.end = time("2026-11-03", "00:10")
        let lines = EventFinder.prompt(rows: [late, early], cards: [:], known: [], now: time("2026-11-03", "00:20"), timeZone: seoul).components(separatedBy: "\n")
        let monday = try XCTUnwrap(lines.firstIndex(of: "DATE 2026-11-02 Mon"), lines.joined(separator: "\n"))
        let tuesday = try XCTUnwrap(lines.firstIndex(of: "DATE 2026-11-03 Tue"))
        XCTAssertTrue(lines[monday + 1].hasPrefix("1 | 23:55"))
        XCTAssertTrue(lines[tuesday + 1].hasPrefix("2 | 00:05"))
        XCTAssertTrue(EventFinder.system.contains("date of the row"))
    }

    /// 일정 찾기는 EventFinder 한 곳에서만: ③ 업무 설명이 또 찾으면 같은 일정이 다른 제목으로 두 번 제안된다
    func testWorkDescriptionNoLongerFindsEvents() throws {
        XCTAssertFalse(StagePrompt.describeSystem.contains("calendar_events"))
        let schema = try JSONEncoder().encode(StageTool.describe.parameters)
        XCTAssertFalse(String(decoding: schema, as: UTF8.self).contains("calendar_events"))
    }
}

/// 정리 한 번이 끝나면 모은 기록 전부(업무 외 행 포함)에서 일정을 찾는다
final class BatchEventFinderTests: XCTestCase {
    private let patch = """
    {"tasks":[{"ref":"A","match":"new","title":"데이터베이스 과제 3","task_type":"기타"}],
     "rows":[{"rows":"1","task":"A"},{"rows":"2","task":"off"},{"rows":"3","task":"A"}],
     "work":[{"task":"A","summary":"과제 3 안내를 읽었다","topics":["SQL"]}]}
    """
    /// 시계(450초, 1970-01-01)에서 며칠 뒤
    private let events = """
    {"events":[{"row":2,"title":"민수와 저녁 약속","date":"1970-01-05","start_time":"19:00","evidence":"내일 7시에 보자"}]}
    """

    private func seed(_ db: SillogDatabase) throws {
        let store = EventStore(db)
        try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                     windowTitle: "데이터베이스 과제 3 (마감 11/10 23:59) - LMS", url: "https://lms.example.com/assign/3"))
        try store.insert(Observation(ts: 160, trigger: "app_activate", appBundle: "com.kakao.KakaoTalkMac", appName: "KakaoTalk", windowTitle: "민수"))
        try store.insert(Observation(ts: 400, trigger: "app_activate", appBundle: "com.microsoft.Word", appName: "Microsoft Word", windowTitle: "과제3.docx"))
    }

    private func batcher(_ db: SillogDatabase, _ llm: StubLLM) -> OntologyBatcher {
        var config = BatchConfig.singleCall
        config.findEvents = true
        return OntologyBatcher(db: db, llm: llm, config: config, home: "/Users/me", fileExists: { _ in false }, clock: { 450 })
    }

    func testBatchFindsEventsInEveryRowAfterApplying() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.success(patch), .success(events)])
        let batcher = batcher(db, llm)
        await batcher.setUpcomingEvents { _, _ in [EventFinder.Known(title: "치과 예약", start: Date(timeIntervalSince1970: 4_000_000_000), allDay: false)] }
        guard case .ok = await batcher.runIfDue(force: true) else { return XCTFail("정리는 성공해야 함") }
        XCTAssertEqual(llm.calls, 2)
        XCTAssertEqual(llm.lastSystem, EventFinder.system)
        XCTAssertTrue(llm.lastUser.contains("민수"), "업무 외로 판정된 메신저 행도 일정 찾기에 보낸다")
        XCTAssertTrue(llm.lastUser.contains("마감 11/10 23:59"))
        XCTAssertTrue(llm.lastUser.contains("치과 예약"), "캘린더에 있는 일정을 같이 보낸다")
        XCTAssertEqual(try EventSuggestionStore(db).pending(now: Date(timeIntervalSince1970: 0)).map(\.title), ["민수와 저녁 약속"])
    }

    func testFinderFailureKeepsBatchResult() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.success(patch)])                // 일정 찾기 호출은 실패한다
        guard case .ok = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("일정 찾기가 실패해도 정리는 성공") }
        XCTAssertEqual(llm.calls, 2)
        XCTAssertTrue(try EventStore(db).unprocessed(limit: 10).isEmpty, "행은 처리 완료로 남는다")
        XCTAssertTrue(try EventSuggestionStore(db).pending(now: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    func testFailedBatchDoesNotLookForEvents() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.failure(.transport("down"))])
        guard case .failed = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("판정 실패") }
        XCTAssertEqual(llm.calls, 1, "행이 다음 정리에 다시 들어가므로 일정은 그때 찾는다")
    }
}
