import XCTest
@testable import WorkGraphApp
import WorkGraphCore

/// 업무 탭 왼쪽: 분야 폴더 안에 업무 (파일 트리처럼)
@MainActor
final class TaskTreeTests: XCTestCase {
    private func task(_ id: Int64, _ title: String, theme: String?, last: Double, seconds: Double = 60) -> TaskSummary {
        TaskSummary(id: id, key: "t\(id)", title: title, taskType: "코드작성", activeSeconds: seconds, lastActive: last, sessionCount: 1, theme: theme)
    }

    func testTaskListCarriesEachTasksField() throws {
        let database = try WGDatabase.inMemory()
        try database.writer.write { conn in
            let tx = GraphTx(conn)
            for (key, title, theme) in [("flask", "Flask 웹앱 개발", Optional("프로젝트")), ("misc", "아직 분야 없는 업무", nil)] {
                let taskId = try tx.upsertNode(label: NodeLabel.task, key: key, subtype: nil, title: title,
                                               props: ["active_seconds": .number(600), "last_active": .number(100)], at: 100)
                let sessionId = try tx.upsertNode(label: NodeLabel.session, key: "s-\(key)", subtype: nil, title: "세션", props: [:], at: 100)
                _ = try tx.upsertEdge(src: sessionId, dst: taskId, type: EdgeType.partOf, props: [:], addWeight: 0, at: 100)
                if let theme { _ = try ThemeGraph.attach(taskId: taskId, to: theme, tx, now: 100) }
            }
        }
        let state = AppState(preview: { s in s.phase = .ready }, database: database)
        state.refreshTasks()
        XCTAssertEqual(state.taskList.first { $0.key == "flask" }?.theme, "프로젝트")
        XCTAssertNil(state.taskList.first { $0.key == "misc" }?.theme)
    }

    func testFoldersGroupByFieldNewestFirstWithNoFieldLast() {
        let tasks = [task(1, "회귀 실습", theme: "학업", last: 300), task(2, "분류 안 된 일", theme: nil, last: 290),
                     task(3, "Sillog UI", theme: "프로젝트", last: 280, seconds: 600), task(4, "자료구조 수업", theme: "학업", last: 100),
                     task(5, "발표 자료", theme: "프로젝트", last: 50, seconds: 120)]
        let folders = TasksView.folders(tasks)
        XCTAssertEqual(folders.map(\.name), ["학업", "프로젝트", "분야 없음"], "최근에 일한 분야가 위, 분야 없음은 늘 맨 아래")
        XCTAssertEqual(folders[0].tasks.map(\.id), [1, 4], "폴더 안은 받은 순서(최근 활동 순) 그대로")
        XCTAssertEqual(folders[1].seconds, 720)
        XCTAssertEqual(folders[2].tasks.map(\.id), [2])
    }
}
