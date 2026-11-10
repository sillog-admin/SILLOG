import XCTest
@testable import WorkGraphCore

/// 채팅의 기록 검색: 받아쓴 녹음을 찾고 읽는다. 프로젝트 전용 업무의 녹음은 그 프로젝트 안에서만
final class RecordingSearchTests: XCTestCase {
    func testRecordingsAreFoundAndReadOnlyWhereTheirTaskIsVisible() throws {
        let db = try WGDatabase.inMemory()
        let taskId = try db.writer.write { conn in
            try GraphTx(conn).upsertNode(label: NodeLabel.task, key: "t_ds", subtype: nil, title: "자료구조", props: ["status": "active"], at: 0)
        }
        let recordings = RecordingStore(db)
        let lecture = try recordings.insert(Recording(startedAt: 1_000, endedAt: 1_600, duration: 600, audioPath: "/r/1.m4a",
                                                       textPath: "/Users/me/Documents/학교/자료구조/강의.md", title: "자료구조 3주차 강의",
                                                       summary: "연결 리스트 강의.", transcript: "오늘은 연결리스트의 삽입과 삭제를 봅니다.\n다음 시간에는 스택입니다.",
                                                       status: .ready, readyAt: 1_700, taskId: taskId))
        _ = try recordings.insert(Recording(startedAt: 2_000, audioPath: "/r/2.m4a", transcript: "연결리스트 이야기", status: .transcribing))   // 정리 중인 것은 안 보인다

        let found = try ContextSearch(db).search(query: "연결리스트", from: 0, to: 10_000).filter { $0.id.hasPrefix("recording:") }
        XCTAssertEqual(found.map(\.id), ["recording:\(lecture.id!)"])
        XCTAssertEqual(found.first?.title, "녹음 · 자료구조 3주차 강의")
        XCTAssertEqual(found.first?.location, "/Users/me/Documents/학교/자료구조/강의.md")
        XCTAssertTrue(found.first?.excerpt.contains("요약: 연결 리스트 강의.") ?? false)
        XCTAssertTrue(found.first?.excerpt.contains("받아쓴 글") ?? false)

        let read = try XCTUnwrap(ContextSearch(db).read("recording:\(lecture.id!)").first)
        XCTAssertTrue(read.excerpt.contains("다음 시간에는 스택입니다."))
        XCTAssertTrue(read.excerpt.contains("[전체 "))

        // 업무를 프로젝트 전용으로 옮기면 프로젝트 밖에서는 찾지도 읽지도 못한다
        let projects = ProjectStore(db)
        var project = ChatProject(title: "전용", goal: "분리")
        project.memoryMode = .projectOnly
        try projects.save(project)
        try projects.move("task:\(taskId)", to: project.id)
        XCTAssertTrue(try ContextSearch(db).search(query: "연결리스트", from: 0, to: 10_000).filter { $0.id.hasPrefix("recording:") }.isEmpty)
        XCTAssertTrue(try ContextSearch(db).read("recording:\(lecture.id!)").isEmpty)
        let inside = try ContextSearch(db, projectID: project.id).search(query: "연결리스트", from: 0, to: 10_000).filter { $0.id.hasPrefix("recording:") }
        XCTAssertEqual(inside.count, 1)
    }

    func testRecordingsAreLeftOutWhenActivityRecordsAreOff() throws {
        let db = try WGDatabase.inMemory()
        let recording = try RecordingStore(db).insert(Recording(startedAt: 1_000, endedAt: 1_100, duration: 100, audioPath: "/r/1.m4a",
                                                                 title: "회의", transcript: "분기 목표를 정했습니다.", status: .ready, readyAt: 1_200))
        let search = ContextSearch(db, includeActivity: false)
        XCTAssertTrue(try search.search(query: "분기 목표", from: 0, to: 10_000).filter { $0.id.hasPrefix("recording:") }.isEmpty)
        XCTAssertTrue(try search.read("recording:\(recording.id!)").isEmpty)
    }

    func testTheChatPromptNamesRecordingSources() throws {
        let template = try ChatSystemPrompt.template()
        XCTAssertTrue(template.contains("message:, recording:, library:"))
        XCTAssertTrue(template.contains("Voice recordings (recording:)"))
    }
}
