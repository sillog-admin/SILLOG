import XCTest
@testable import SillogApp
import SillogCore

/// Dates in the task detail follow the app language, also after it changes while the app runs.
@MainActor
final class TaskDetailTextTests: XCTestCase {
    func testSessionDayFollowsTheAppLanguage() throws {
        let day = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 3, day: 5, hour: 9).date)
        XCTAssertEqual(TasksView.dayLabel(day), "3월 5일")
        L10n.current = .en
        defer { L10n.current = .ko }
        XCTAssertEqual(TasksView.dayLabel(day), "Mar 5")
        XCTAssertTrue(TasksView.dayLabel(Date()).hasPrefix("Today, "))
    }

    // 기간 단추와 막대에 커서를 대면 날짜가 보인다
    func testRangeButtonsAndBarsSayWhichDays() throws {
        let now = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 11, day: 19, hour: 15).date).timeIntervalSince1970
        let first = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 10, day: 5, hour: 9).date).timeIntervalSince1970
        XCTAssertEqual(TasksView.rangeSpan(.week, first: first, now: now), "11월 13일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.month, first: first, now: now), "10월 21일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.all, first: first, now: now), "10월 5일 ~ 오늘")
        XCTAssertEqual(TasksView.rangeSpan(.today, first: first, now: now), "11월 19일")
        let day = try XCTUnwrap(DateComponents(calendar: .current, year: 2026, month: 11, day: 16).date)
        XCTAssertEqual(TasksView.barLabel(RangeTime.Bar(start: day, seconds: 4200), weekly: false), "11월 16일 · 1시간 10분")
        XCTAssertEqual(TasksView.barLabel(RangeTime.Bar(start: day, seconds: 4200), weekly: true), "11월 16일부터 한 주 1시간 10분")
    }

    // 분야 나무: 고른 분야가 많아도 종류 알약을 숨기거나 자르지 않는다. 옆에 자리가 없으면 줄을 내려 아래에서 펼치고,
    // 알약끼리도, 다른 분야의 줄과도 겹치지 않는다 (늘 오른쪽이면 잘렸고, 칸 기준이면 겹쳤고, 숨기면 목록이 안 보였다)
    @discardableResult
    private func layout(_ circles: [CGFloat], needs: [CGFloat], rows: [Int], line: UInt = #line) -> (circles: [CGFloat], spots: [TasksView.TreeSpot]) {
        let out = TasksView.treeLayout(circles: circles, needs: needs, rows: rows, width: 249)
        let cx = out.circles, s = out.spots
        func region(_ k: Int) -> ClosedRange<CGFloat> { s[k].left ? (cx[k] - 14 - s[k].room)...(cx[k] - 14) : (cx[k] + 14)...(cx[k] + 14 + s[k].room) }
        for k in cx.indices {
            XCTAssertGreaterThanOrEqual(s[k].room, needs[k], "알약이 잘리지 않는다 (\(k))", line: line)
            XCTAssertTrue(region(k).lowerBound >= 0 && region(k).upperBound <= 249, "목록 밖으로 나가지 않는다 (\(k))", line: line)
            for u in cx.indices where u != k {
                if s[k].top < s[u].top + rows[u] { XCTAssertFalse(region(k).contains(cx[u]), "\(k) 알약이 \(u) 줄을 덮지 않는다", line: line) }
                if max(s[k].top, s[u].top) < min(s[k].top + rows[k], s[u].top + rows[u]) {
                    XCTAssertFalse(region(k).overlaps(region(u)), "\(k)와 \(u) 알약이 겹치지 않는다", line: line)
                }
            }
        }
        for (a, b) in zip(cx, cx.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, 22, "원끼리 겹치지 않는다", line: line) }
        return out
    }

    func testFieldTreesShowEveryPillWithoutOverlapping() {
        layout([11, 93, 143, 185, 227], needs: [96, 74, 96, 90, 70], rows: [5, 5, 4, 4, 1])     // 다섯 분야를 다 고름
        let three = layout([143, 185, 227], needs: [100, 90, 70], rows: [4, 4, 1])               // 오른쪽 셋
        XCTAssertEqual(three.spots[0], TasksView.TreeSpot(left: true, room: 100, top: 0), "첫 나무는 원 바로 옆 왼쪽에")
        let two = layout([11, 120], needs: [80, 96], rows: [5, 5])                                // 옆에 다 들어가면 나란히
        XCTAssertEqual(two.spots.map(\.top), [0, 0])
        XCTAssertTrue(layout([215], needs: [80], rows: [1]).spots[0].left, "맨 오른쪽 분야 하나: 왼쪽으로")
        XCTAssertFalse(layout([12], needs: [80], rows: [1]).spots[0].left, "맨 왼쪽 분야 하나: 오른쪽으로")
    }

    // 종류 알약을 누르면 그 분야에서는 그 종류 업무만 남고, 다른 분야는 그대로
    func testTypePillsNarrowTheirFieldOnly() {
        func task(_ field: String, _ type: String) -> TaskSummary {
            TaskSummary(id: 1, key: "t", title: "t", taskType: type, activeSeconds: 60, lastActive: 0, sessionCount: 1, theme: field, field: field)
        }
        let fields: Set<String> = ["프로젝트", "학업"], types: Set<String> = [TasksView.typeKey("프로젝트", "코드작성")]
        XCTAssertTrue(TasksView.passes(task("프로젝트", "코드작성"), fields: fields, types: types))
        XCTAssertFalse(TasksView.passes(task("프로젝트", "회의"), fields: fields, types: types))
        XCTAssertTrue(TasksView.passes(task("학업", "복습"), fields: fields, types: types), "종류를 안 고른 분야는 그대로")
        XCTAssertFalse(TasksView.passes(task("개인", "코드작성"), fields: fields, types: types), "고르지 않은 분야는 빠진다")
        XCTAssertTrue(TasksView.passes(task("개인", "코드작성"), fields: [], types: []), "아무것도 안 골랐으면 전부")
    }

    // 고른 업무를 다시 누르면 닫는 것은 그 업무 카드가 떠 있을 때만: 카드를 닫았거나 분야 같은 다른 상세가 떠 있으면 다시 연다
    func testPressingTheChosenTaskClosesOnlyItsOwnOpenCard() {
        XCTAssertTrue(TasksView.pressCloses(chosen: true, cardOpen: true, showingNode: false))
        XCTAssertFalse(TasksView.pressCloses(chosen: true, cardOpen: false, showingNode: false), "×로 닫은 뒤 다시 누르면 연다")
        XCTAssertFalse(TasksView.pressCloses(chosen: true, cardOpen: true, showingNode: true), "분야 상세가 떠 있으면 업무 상세로 바꾼다")
        XCTAssertFalse(TasksView.pressCloses(chosen: false, cardOpen: true, showingNode: false))
    }
}
