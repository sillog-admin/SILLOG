import XCTest
import GRDB
@testable import WorkGraphCore

enum Fixtures {
    /// 회의 문서의 프론트 개발 예시 (14:02 ~ 15:30). base = 14:02 의 Unix 초.
    static func frontendRows(base: Double = 1_000_000) -> [ActivityRow] {
        func row(_ n: Int, _ startMin: Double, _ endMin: Double, app: String, bundle: String, title: String,
                 uri: String? = nil, type: String? = nil, projectKey: String? = nil, projectTitle: String? = nil) -> ActivityRow {
            ActivityRow(row: n, start: base + startMin * 60, end: base + endMin * 60, dwell: Int((endMin - startMin) * 60),
                        app: app, appBundle: bundle, title: title, uri: uri, type: type,
                        projectKey: projectKey, projectTitle: projectTitle, snippet: nil, observationIds: [Int64(n)])
        }
        return [
            row(1, 0, 9, app: "Cursor", bundle: "com.todesktop.230313mzl4w4u92", title: "TaskCard.tsx",
                uri: "code:dashboard/TaskCard.tsx", type: "CodeFile", projectKey: "project:dashboard", projectTitle: "dashboard"),
            row(2, 9, 22, app: "Google Chrome", bundle: "com.google.Chrome", title: "Card - shadcn/ui",
                uri: "https://ui.shadcn.com/docs/components/card", type: "Documentation"),
            row(3, 22, 36, app: "Google Chrome", bundle: "com.google.Chrome", title: "localhost:3000", uri: "local:3000/", type: "Preview"),
            row(4, 36, 50, app: "Terminal", bundle: "com.apple.Terminal", title: "npm run dev"),
            row(5, 50, 78, app: "Google Chrome", bundle: "com.google.Chrome", title: "React key prop warning - Stack Overflow",
                uri: "https://stackoverflow.com/questions/28329382", type: "QnA"),
            row(6, 78, 88, app: "Slack", bundle: "com.tinyspeck.slackmacgap", title: "디자인팀"),
        ]
    }

    /// 행 6개가 전부 한 업무. 문제 하나(4행, 5행 페이지로 해결), 나중에 할 일 하나(6행)
    static let frontendPatchJSON = """
    {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],
     "rows":[{"rows":"1-6","task":"A","resource":true}],
     "work":[{"task":"A","summary":"TaskCard 컴포넌트 구현, key prop 경고 해결","topics":["React","shadcn/ui"]}],
     "problems":[{"row":4,"kind":"build","message":"React key prop warning","resolved_by_row":5}],
     "later_items":[{"row":6,"text":"카드 간격 16px로 조정"}]}
    """

    static func patch(_ json: String) throws -> AssignmentPatch {
        try JSONDecoder().decode(AssignmentPatch.self, from: Data(json.utf8))
    }
}

final class OntologyApplierTests: XCTestCase {
    private func makeDB() throws -> WGDatabase {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in try TBox.seed(GraphTx(conn), at: 0) }
        return db
    }

    func testFrontendScenarioBuildsExpectedGraph() throws {
        let db = try makeDB()
        let rows = Fixtures.frontendRows()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let (stats, assignments) = try AssignmentApplier().apply(try Fixtures.patch(Fixtures.frontendPatchJSON), rows: rows, tx: tx, now: 2_000_000)
            XCTAssertEqual(stats.sessions, 1)
            XCTAssertEqual(stats.tasksCreated, 1)
            XCTAssertEqual(stats.resources, 4)
            XCTAssertEqual(stats.topics, 2)
            XCTAssertEqual(stats.problems, 1)
            XCTAssertEqual(stats.laterItems, 1)
            XCTAssertEqual(stats.uncoveredRows, 0)
            XCTAssertEqual(assignments.count, 6)
            XCTAssertTrue(assignments.allSatisfy { $0.taskId != nil && $0.resource })

            let counts = try tx.counts().nodesByLabel
            XCTAssertEqual(counts["Task"], 1)
            XCTAssertEqual(counts["Session"], 1)
            XCTAssertEqual(counts["Resource"], 4)
            XCTAssertEqual(counts["App"], 4)
            XCTAssertEqual(counts["Topic"], 2)
            XCTAssertEqual(counts["Problem"], 1)
            XCTAssertEqual(counts["LaterItem"], 1)
            XCTAssertEqual(counts["Project"], 1)

            let task = try XCTUnwrap(tx.nodes(label: "Task").first)
            XCTAssertEqual(task.title, "대시보드 카드 UI 구현")
            XCTAssertEqual(task.props["status"], "active")
            XCTAssertEqual(task.props["active_seconds"], 5280)
            let typeEdge = try XCTUnwrap(tx.edges(from: task.id, type: "INSTANCE_OF").first)
            XCTAssertEqual(try tx.node(id: typeEdge.dst)?.key, "코드작성")

            let session = try XCTUnwrap(tx.nodes(label: "Session").first)
            XCTAssertEqual(session.props["start"], .number(rows[0].start))
            XCTAssertEqual(session.props["end"], .number(rows[5].end))
            XCTAssertEqual(session.props["active_seconds"], 5280)
            XCTAssertEqual(session.props["summary"], "TaskCard 컴포넌트 구현, key prop 경고 해결")
            XCTAssertTrue(session.title.contains("–") && session.title.hasSuffix("· 대시보드 카드 UI 구현"), "세션 제목 = 시간대 · 업무: \(session.title)")
            XCTAssertEqual(try tx.edges(from: session.id, type: "PART_OF").first?.dst, task.id)

            // 같은 앱(Chrome) 세 행의 USED 는 한 엣지에 누적된다.
            let chrome = try XCTUnwrap(tx.node(label: "App", key: "com.google.Chrome"))
            let used = try XCTUnwrap(tx.edges(from: session.id, type: "USED").first { $0.dst == chrome.id })
            XCTAssertEqual(used.weight, Double(rows[1].dwell + rows[2].dwell + rows[4].dwell))

            let docs = try XCTUnwrap(tx.node(label: "Resource", key: "https://ui.shadcn.com/docs/components/card"))
            XCTAssertEqual(docs.subtype, "Documentation")
            let touched = try XCTUnwrap(tx.edges(from: session.id, type: "TOUCHED").first { $0.dst == docs.id })
            XCTAssertEqual(touched.weight, 780)
            let docType = try XCTUnwrap(tx.edges(from: docs.id, type: "INSTANCE_OF").first)
            XCTAssertEqual(try tx.node(id: docType.dst)?.key, "Documentation")

            let problem = try XCTUnwrap(tx.nodes(label: "Problem").first)
            XCTAssertEqual(problem.title, "React key prop warning")
            let so = try XCTUnwrap(tx.node(label: "Resource", key: "https://stackoverflow.com/questions/28329382"))
            XCTAssertEqual(try tx.edges(from: problem.id, type: "RESOLVED_BY").first?.dst, so.id)
            XCTAssertEqual(try tx.edges(from: session.id, type: "HIT").first?.dst, problem.id)

            let later = try XCTUnwrap(tx.nodes(label: "LaterItem").first)
            XCTAssertEqual(later.title, "카드 간격 16px로 조정")
            XCTAssertEqual(try tx.edges(from: later.id, type: "FOR").first?.dst, task.id)

            let code = try XCTUnwrap(tx.node(label: "Resource", key: "code:dashboard/TaskCard.tsx"))
            let project = try XCTUnwrap(tx.node(label: "Project", key: "project:dashboard"))
            XCTAssertEqual(try tx.edges(from: code.id, type: "BELONGS_TO").first?.dst, project.id)
            let on = try XCTUnwrap(tx.edges(from: task.id, type: "ON").first)
            XCTAssertEqual(on.dst, project.id)
            XCTAssertEqual(on.weight, Double(rows[0].dwell), "업무 → 프로젝트 가중치 = 그 프로젝트 파일에 머문 초")
        }
    }

    func testRowsAreJudgedOneByOneNotAsABatch() throws {
        // 1~4행 카드 UI, 5행(스택오버플로 대신 유튜브라 치자) 다른 일, 6행 다시 카드 UI, 그리고 일이 아닌 행 하나
        let db = try makeDB()
        var rows = Fixtures.frontendRows()
        rows.append(ActivityRow(row: 7, start: rows[5].end, end: rows[5].end + 30, dwell: 30, app: "loginwindow", appBundle: "com.apple.loginwindow",
                                title: nil, uri: nil, type: nil, projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [7]))
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"},
                  {"ref":"B","match":"new","title":"YouTube 시청","task_type":"기타"}],
         "rows":[{"rows":"1-4","task":"A","resource":true},{"rows":"5","task":"B","resource":true},{"rows":"6","task":"A","resource":true},{"rows":"7","task":null}],
         "work":[{"task":"A","summary":"카드 구현","topics":["React"]},{"task":"B","summary":"영상 시청","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let (stats, assignments) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000)
            XCTAssertEqual(stats.tasksCreated, 2)
            XCTAssertEqual(stats.sessions, 2, "끼어든 업무는 제 세션을 갖고, 앞뒤 업무의 세션은 하나로 이어진다")
            XCTAssertEqual(stats.unassignedRows, 1)
            XCTAssertNil(assignments[6].taskId)

            let card = try XCTUnwrap(tx.nodes(label: "Task").first { $0.title == "대시보드 카드 UI 구현" })
            let tube = try XCTUnwrap(tx.nodes(label: "Task").first { $0.title == "YouTube 시청" })
            XCTAssertEqual(card.props["active_seconds"], .number(Double(rows[0...3].reduce(0) { $0 + $1.dwell } + rows[5].dwell)))
            XCTAssertEqual(tube.props["active_seconds"], .number(Double(rows[4].dwell)))

            let sessions = try tx.nodes(label: "Session")
            let cardSession = try XCTUnwrap(sessions.first { try tx.edges(from: $0.id, type: "PART_OF").first?.dst == card.id })
            let tubeSession = try XCTUnwrap(sessions.first { try tx.edges(from: $0.id, type: "PART_OF").first?.dst == tube.id })
            XCTAssertEqual(cardSession.props["start"], .number(rows[0].start))
            XCTAssertEqual(cardSession.props["end"], .number(rows[5].end), "끼어든 뒤 이어진 행까지 한 세션")
            XCTAssertEqual(tubeSession.props["start"], .number(rows[4].start))
            // 흐름: 카드 → 유튜브 → 카드
            XCTAssertEqual(try tx.edges(from: cardSession.id, type: "SWITCHED_TO").first?.dst, tubeSession.id)
            XCTAssertEqual(try tx.edges(from: tubeSession.id, type: "SWITCHED_TO").first?.dst, cardSession.id)
            // 5행의 자료(스택오버플로 페이지)는 유튜브 업무의 세션에만
            let so = try XCTUnwrap(tx.node(label: "Resource", key: "https://stackoverflow.com/questions/28329382"))
            XCTAssertEqual(try tx.edges(to: so.id, type: "TOUCHED").map(\.src), [tubeSession.id])
        }
    }

    func testSameTaskResumedWithin30MinutesExtendsTheSession() throws {
        let db = try makeDB()
        let rows = Fixtures.frontendRows()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let applier = AssignmentApplier()
            _ = try applier.apply(try Fixtures.patch(Fixtures.frontendPatchJSON), rows: rows, tx: tx, now: 2_000_000)
            let taskKey = try XCTUnwrap(tx.nodes(label: "Task").first).key

            var next = rows[0]
            next.row = 1; next.start = rows[5].end + 1_500; next.end = next.start + 200; next.dwell = 200      // 25분 뒤
            let followUp = try Fixtures.patch("""
            {"tasks":[{"ref":"A","match":"existing","id":"\(taskKey)"}],"rows":[{"rows":"1","task":"A"}],
             "work":[{"task":"A","summary":"카드 간격 조정","topics":["React"]}]}
            """)
            let (stats, _) = try applier.apply(followUp, rows: [next], tx: tx, now: 2_000_100)
            XCTAssertEqual(stats.sessions, 0)
            XCTAssertEqual(stats.sessionsExtended, 1)
            XCTAssertEqual(stats.tasksCreated, 0)

            let sessions = try tx.nodes(label: "Session")
            XCTAssertEqual(sessions.count, 1)
            XCTAssertEqual(sessions[0].props["end"], .number(next.end))
            XCTAssertEqual(sessions[0].props["active_seconds"], 5480)
            XCTAssertEqual(sessions[0].props["summary"], "카드 간격 조정", "가장 최근 요약")
            XCTAssertEqual(sessions[0].props["summaries"]?.arrayValue?.compactMap(\.stringValue), ["TaskCard 컴포넌트 구현, key prop 경고 해결", "카드 간격 조정"], "배치마다 한 문장씩 쌓인다")
            XCTAssertTrue(sessions[0].title.hasSuffix(" · 대시보드 카드 UI 구현"), sessions[0].title)
            let task = try XCTUnwrap(tx.nodes(label: "Task").first)
            XCTAssertEqual(task.title, "대시보드 카드 UI 구현")          // 기존 제목 유지
            XCTAssertEqual(task.props["active_seconds"], 5480)

            // 30분 넘게 비면 새 세션
            var later = next
            later.start = next.end + 2_000; later.end = later.start + 60; later.dwell = 60
            let (third, _) = try applier.apply(followUp, rows: [later], tx: tx, now: 2_000_200)
            XCTAssertEqual(third.sessions, 1)
            XCTAssertEqual(try tx.nodes(label: "Session").count, 2)
        }
    }

    func testUnknownTaskTypeFallsBackAndTitleMatchReusesTask() throws {
        let db = try makeDB()
        let rows = Fixtures.frontendRows()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let applier = AssignmentApplier()
            let first = try Fixtures.patch("""
            {"tasks":[{"ref":"A","match":"new","title":"논문 읽기","task_type":"없는종류"}],"rows":[{"rows":"1-2","task":"A"}],"work":[]}
            """)
            _ = try applier.apply(first, rows: rows, tx: tx, now: 1)
            let task = try XCTUnwrap(tx.nodes(label: "Task").first)
            let typeEdge = try XCTUnwrap(tx.edges(from: task.id, type: "INSTANCE_OF").first)
            XCTAssertEqual(try tx.node(id: typeEdge.dst)?.key, "기타")

            // 없는 id 로 existing 이라고 하거나 같은 제목으로 new 라고 해도 같은 Task 를 쓴다.
            let second = try Fixtures.patch("""
            {"tasks":[{"ref":"X","match":"existing","id":"t_nope","title":" 논문  읽기 ","task_type":"문헌조사"}],"rows":[{"rows":"3-4","task":"X"}],"work":[]}
            """)
            let (stats, _) = try applier.apply(second, rows: rows, tx: tx, now: 2)
            XCTAssertEqual(stats.tasksCreated, 0)
            XCTAssertEqual(try tx.nodes(label: "Task").count, 1)
        }
    }

    func testRowsNotMentionedAreUncoveredAndOutOfRangeIsIgnored() throws {
        let db = try makeDB()
        let rows = Fixtures.frontendRows()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let patch = try Fixtures.patch("""
            {"tasks":[{"ref":"A","match":"new","title":"A","task_type":"코드작성"},{"ref":"C","match":"new","title":"C","task_type":"코드작성"}],
             "rows":[{"rows":"1-3","task":"A"},{"rows":"40-50","task":"C"},{"rows":"4","task":"없는ref"}],"work":[]}
            """)
            let (stats, assignments) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 1)
            XCTAssertEqual(stats.sessions, 1)
            XCTAssertEqual(stats.uncoveredRows, 2, "5, 6 행은 언급되지 않음")
            XCTAssertEqual(stats.unassignedRows, 1, "모르는 ref 는 배정 없음")
            XCTAssertNil(assignments[3].taskId)
            XCTAssertEqual(try tx.nodes(label: "Task").map(\.title).sorted(), ["A", "C"], "C 는 만들어지지만 행이 없어 세션이 없다")
        }
    }

    func testPatchDecodingIsLenient() throws {
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":1,"id":"t_1"},{"ref":"B","title":"T"}],
         "rows":[{"rows":"1","task":"1"},{"rows":2,"task":"B"},{"rows":"3~5","task":"null"},{"rows":"6-4","task":"B"}],
         "work":[{"task":"B","summary":"s"}],"problems":[{"row":"2","message":"에러"}]}
        """)
        XCTAssertEqual(patch.tasks[0].match, "existing", "id 가 있으면 existing")
        XCTAssertEqual(patch.tasks[1].match, "new")
        let byRow = patch.byRow()
        XCTAssertEqual(byRow[1]?.task, "1")
        XCTAssertEqual(byRow[2]?.task, "B")
        XCTAssertNil(byRow[3]?.task); XCTAssertNil(byRow[5]?.task)
        XCTAssertNil(byRow[6], "뒤집힌 범위는 무시")
        XCTAssertNil(byRow[1]?.resource, "resource 를 안 적으면 nil (반영기가 종류별 기본값을 쓴다)")
        XCTAssertEqual(patch.work[0].topics, [])
        XCTAssertEqual(patch.problems?.first?.kind, "error")
        XCTAssertEqual(patch.problems?.first?.row, 2)
    }

    func testLenientDecodeHandlesNestedJSONStrings() throws {
        let quirky = #"""
        {"tasks":"[{\"ref\": \"A\", \"match\": \"new\", \"title\": \"선형대수 3주차 학습\", \"task_type\": \"복습\"}]",
         "rows":[{"rows":"1-3","task":"A"}],"work":"[{\"task\": \"A\", \"summary\": \"고유값 분해 학습\", \"topics\": [\"선형대수학\"]}]"}
        """#
        let patch = try XCTUnwrap(AssignmentPatch.decodeLenient(from: Data(quirky.utf8)))
        XCTAssertEqual(patch.tasks.first?.title, "선형대수 3주차 학습")
        XCTAssertEqual(patch.work.first?.topics, ["선형대수학"])
        XCTAssertNil(AssignmentPatch.decodeLenient(from: Data("not json".utf8)))
    }

    func testPromptContainsRowsTasksAndTypes() {
        let rows = Fixtures.frontendRows()
        let digest = TaskDigest(id: "t_ab12", title: "대시보드 카드 UI 구현", taskType: "코드작성", topics: ["React"],
                                recentResources: ["TaskCard.tsx"], lastActive: 1)
        let prompt = OntologyPrompt.build(rows: rows, openTasks: [digest], now: 1_005_280)
        XCTAssertTrue(prompt.system.contains("assign_rows"))
        XCTAssertTrue(prompt.system.contains("never assigned to a task because neighbouring rows are"))
        XCTAssertTrue(prompt.system.contains("task \"off\""), "이탈 갈래")
        XCTAssertFalse(prompt.system.contains("기학기") || prompt.system.contains("YouTube"), "특정 사례 이름은 프롬프트에 없다")
        XCTAssertTrue(prompt.user.contains("id=t_ab12"))
        XCTAssertTrue(prompt.user.contains("코드작성"))
        XCTAssertTrue(prompt.user.contains("https://ui.shadcn.com/docs/components/card"))
        XCTAssertTrue(prompt.user.contains("| 540s |"))
        XCTAssertEqual(AssignmentSchema.tool.name, "assign_rows")
    }
}

final class ProjectBindingTests: XCTestCase {
    private func row(_ n: Int, _ dwell: Int, uri: String, project: String, title: String) -> ActivityRow {
        ActivityRow(row: n, start: Double(n * 1_000), end: Double(n * 1_000 + dwell), dwell: dwell, app: "Code", appBundle: "com.microsoft.VSCode",
                    title: title, uri: uri, type: "CodeFile", projectKey: project, projectTitle: (project as NSString).lastPathComponent,
                    snippet: nil, observationIds: [Int64(n)])
    }

    func testProjectBelongsToTheTaskThatWorkedInItMost() throws {
        let db = try WGDatabase.inMemory()
        let lab = "file:~/Desktop/study/기학기/실습환경", repo = "file:~/Desktop/study/앱 개발/WorkGraph"
        let rows = [row(1, 600, uri: lab + "/[0922]lab.ipynb", project: lab, title: "lab.ipynb"),
                    row(2, 900, uri: repo + "/App.swift", project: repo, title: "App.swift"),
                    row(3, 60, uri: lab + "/[0917]lab.ipynb", project: lab, title: "lab.ipynb")]      // LLM 이 앱 업무 행으로 판단한 실습 파일
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"L","match":"new","title":"기학기 회귀분석 실습","task_type":"복습"},{"ref":"C","match":"new","title":"앱 화면 구현","task_type":"코드작성"}],
         "rows":[{"rows":"1","task":"L"},{"rows":"2-3","task":"C"}],
         "work":[{"task":"L","summary":"실습","topics":[]},{"task":"C","summary":"구현","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 1)
            _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 10_000)
            let links = try Row.fetchAll(conn, sql: """
                SELECT t.title AS task, p.title AS project, e.weight AS seconds FROM edges e
                JOIN nodes t ON t.id = e.src JOIN nodes p ON p.id = e.dst WHERE e.type = 'ON' ORDER BY t.title
                """).map { ($0["task"] as String, $0["project"] as String, $0["seconds"] as Double) }
            XCTAssertEqual(links.map { "\($0.0) → \($0.1) (\(Int($0.2)))" }, ["기학기 회귀분석 실습 → 실습환경 (600)", "앱 화면 구현 → WorkGraph (900)"],
                           "실습환경은 실습 업무의 것. 앱 업무가 60초 스친 것은 연결하지 않는다")
            let appTask = try XCTUnwrap(tx.nodes(label: NodeLabel.task).first { $0.title == "앱 화면 구현" })
            XCTAssertEqual(appTask.props["project_seconds"]?.objectValue?[lab]?.doubleValue, 60, "시간은 남아 있어서 나중에 뒤집힐 수 있다")
        }
    }

    func testResourceFalseKeepsAppTimeButNoResourceOrProject() throws {
        let db = try WGDatabase.inMemory()
        let lab = "file:~/Desktop/study/기학기/실습환경", repo = "file:~/Desktop/study/앱 개발/WorkGraph"
        let rows = [row(1, 900, uri: repo + "/App.swift", project: repo, title: "App.swift"),
                    row(2, 60, uri: lab + "/[0917]lab.ipynb", project: lab, title: "lab.ipynb — study")]
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"C","match":"new","title":"앱 화면 구현","task_type":"코드작성"}],
         "rows":[{"rows":"1","task":"C"},{"rows":"2","task":"C","resource":false}],"work":[{"task":"C","summary":"구현","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 1)
            let (_, assignments) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 10_000)
            XCTAssertFalse(assignments[1].resource)
            XCTAssertNil(try tx.node(label: NodeLabel.resource, key: lab + "/[0917]lab.ipynb"), "보이기만 한 파일은 자료로 남지 않는다")
            XCTAssertNil(try tx.node(label: NodeLabel.project, key: lab))
            let used = try Row.fetchAll(conn, sql: "SELECT weight FROM edges WHERE type = 'USED'").map { $0["weight"] as Double }
            XCTAssertEqual(used, [960], "앱 시간은 두 행 모두 센다")
        }
    }
}

final class TaskMergerTests: XCTestCase {
    func testMergingThreeTasksAccumulatesAllValues() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            for (key, seconds, last) in [("A", 10.0, 100.0), ("B", 20.0, 300.0), ("C", 30.0, 200.0)] {
                _ = try tx.upsertNode(label: "Task", key: key, subtype: nil, title: key,
                                     props: ["active_seconds": .number(seconds), "last_active": .number(last),
                                             "project_seconds": .object(["p": .number(seconds)])], at: 0)
            }
            XCTAssertEqual(try TaskMerger.merge(.init(keep: "A", merge: ["B", "C"], title: nil), conn: conn, now: 400), 2)
            let task = try XCTUnwrap(tx.node(label: "Task", key: "A"))
            XCTAssertEqual(task.props["active_seconds"], .number(60))
            XCTAssertEqual(task.props["last_active"], .number(300))
            XCTAssertEqual(task.props["project_seconds"]?.objectValue?["p"], .number(60))
        }
    }

    func testMergingMovesRowsSessionsTopicsAndTimeThenDeletesTheDuplicate() async throws {
        let db = try WGDatabase.inMemory()
        try await db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        let rows = Fixtures.frontendRows()
        // 같은 목표를 두 제목으로: A(1~3행) 와 B(4~6행)
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"},{"ref":"B","match":"new","title":"대시보드 카드 컴포넌트 작업","task_type":"코드작성"}],
         "rows":[{"rows":"1-3","task":"A"},{"rows":"4-6","task":"B"}],
         "work":[{"task":"A","summary":"카드 구현","topics":["React"]},{"task":"B","summary":"카드 마무리","topics":["shadcn/ui"]}]}
        """)
        let (keepKey, victimKey): (String, String) = try await db.writer.write { conn in
            let tx = GraphTx(conn)
            let (_, assignments) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000)
            for item in assignments { try EventStore.assign(conn, observationIds: item.row.observationIds, taskId: item.taskId, relevant: item.resource) }
            let tasks = try tx.nodes(label: NodeLabel.task)
            return (tasks.first { $0.title == "대시보드 카드 UI 구현" }!.key, tasks.first { $0.title == "대시보드 카드 컴포넌트 작업" }!.key)
        }
        let llm = StubLLM([.success(#"{"groups":[{"keep":"\#(keepKey)","merge":["\#(victimKey)"]}]}"#)])
        let outcome = try await TaskMerger.run(db: db, llm: llm, since: 0, now: 2_000_500)
        XCTAssertEqual(outcome.merged, 1)
        XCTAssertTrue(llm.lastUser.contains("대시보드 카드 컴포넌트 작업"))
        try await db.writer.read { conn in
            let tx = GraphTx(conn)
            let tasks = try tx.nodes(label: NodeLabel.task)
            XCTAssertEqual(tasks.map(\.title), ["대시보드 카드 UI 구현"])
            let keep = tasks[0]
            XCTAssertEqual(keep.props["active_seconds"], 5280, "시간은 합산")
            XCTAssertEqual(try tx.edges(to: keep.id, type: "PART_OF").count, 2, "두 세션 모두 남은 업무의 것")
            XCTAssertEqual(Set(try tx.edges(from: keep.id, type: "ABOUT").compactMap { try tx.node(id: $0.dst)?.title }), ["React", "shadcn/ui"])
            XCTAssertEqual(try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges e LEFT JOIN nodes n ON n.id = e.src OR n.id = e.dst WHERE n.id IS NULL"), 0, "끊긴 엣지 없음")
        }
    }
}

final class TransientPagesTests: XCTestCase {
    func testSearchResultsBlankTabsAndLoginsAreNotResources() throws {
        XCTAssertTrue(TransientPages.isTransient(url: "https://google.com/search?q=steno", title: "steno - Google 검색"))
        XCTAssertTrue(TransientPages.isTransient(url: "https://www.youtube.com/results?search_query=x", title: "x - YouTube"))
        XCTAssertTrue(TransientPages.isTransient(url: "https://github.com/new", title: "New repository"))
        XCTAssertTrue(TransientPages.isTransient(url: "https://example.com/page", title: "제목 없음"))
        XCTAssertTrue(TransientPages.isTransient(url: "https://console.typesafe.ai/login?error=signups_disabled", title: "TypeSafe"))
        XCTAssertFalse(TransientPages.isTransient(url: "https://github.com/octocat/Hello-World", title: "octocat/Hello-World"))
        XCTAssertFalse(TransientPages.isTransient(url: "https://lms.example.com/ultra/courses/_12345_1/outline", title: "기계학습기초"))
        XCTAssertFalse(TransientPages.isTransient(url: "file:~/Desktop/study/기학기/[0922]Regression.pdf", title: "[0922]Regression.pdf"))

        // 세션에 붙지 않는다 (앱 시간은 센다)
        let db = try WGDatabase.inMemory()
        let rows = [ActivityRow(row: 1, start: 0, end: 60, dwell: 60, app: "Google Chrome", appBundle: "com.google.Chrome", title: "steno - Google 검색",
                                uri: "https://google.com/search?q=steno", type: "WebPage", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [1]),
                    ActivityRow(row: 2, start: 60, end: 120, dwell: 60, app: "Google Chrome", appBundle: "com.google.Chrome", title: "Steno — AI notepad",
                                uri: "https://stenoai.co/", type: "WebPage", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [2])]
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"서비스명 정하기","task_type":"기타"}],"rows":[{"rows":"1-2","task":"A","resource":true}],"work":[{"task":"A","summary":"이름 조사","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let (stats, _) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 1_000)
            XCTAssertEqual(stats.resources, 1)
            XCTAssertEqual(try tx.nodes(label: NodeLabel.resource).map(\.key), ["https://stenoai.co/"])
            XCTAssertEqual(try Row.fetchAll(conn, sql: "SELECT weight FROM edges WHERE type = 'USED'").map { $0["weight"] as Double }, [120])
        }
    }
}

final class ResourceDefaultTests: XCTestCase {
    func testWhenTheLLMSaysNothingOnlyFilesAndDocumentsAreResources() {
        func row(_ uri: String?, _ type: String?, chat: Bool = false) -> ActivityRow {
            ActivityRow(row: 1, start: 0, end: 10, dwell: 10, app: "x", appBundle: "x", title: "t", uri: uri, type: type, projectKey: nil, projectTitle: nil,
                        snippet: nil, observationIds: [], isChat: chat)
        }
        XCTAssertTrue(AssignmentApplier.defaultResource(row("file:~/a.pdf", "Document")))
        XCTAssertTrue(AssignmentApplier.defaultResource(row("https://docs.swift.org/x", "Documentation")))
        XCTAssertTrue(AssignmentApplier.defaultResource(row("chat:claude-code:s1", "AIChat", chat: true)))
        XCTAssertFalse(AssignmentApplier.defaultResource(row("https://github.com/someone", "WebPage")), "그냥 웹페이지는 LLM 이 true 라고 해야 자료")
        XCTAssertFalse(AssignmentApplier.defaultResource(row("local:3000/", "Preview")))
    }

    func testOrphanResourcesArePrunedOnRebuild() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let kept = try tx.upsertNode(label: NodeLabel.resource, key: "https://a.example/doc", subtype: "WebPage", title: "doc", props: [:], at: 1)
            _ = try tx.upsertNode(label: NodeLabel.resource, key: "https://b.example/profile", subtype: "WebPage", title: "profile", props: [:], at: 1)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t", subtype: nil, title: "t", props: [:], at: 1)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s", subtype: nil, title: "s", props: [:], at: 1)
            try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1)
            try tx.upsertEdge(src: session, dst: kept, type: EdgeType.touched, props: [:], addWeight: 5, at: 1)
            XCTAssertEqual(try tx.pruneOrphanResources(), 1)
            XCTAssertEqual(try tx.nodes(label: NodeLabel.resource).map(\.key), ["https://a.example/doc"])
        }
    }
}

final class OffTaskTests: XCTestCase {
    func testOffTaskRowsMakeNoTaskSessionOrResourceButKeepTheirTime() throws {
        let db = try WGDatabase.inMemory()
        let store = EventStore(db)
        let ids = [try store.insert(Observation(ts: 1_000, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "docs")),
                   try store.insert(Observation(ts: 1_060, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "someone's profile")),
                   try store.insert(Observation(ts: 1_120, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome", windowTitle: "docs"))]
        let rows = [ActivityRow(row: 1, start: 1_000, end: 1_060, dwell: 60, app: "Google Chrome", appBundle: "com.google.Chrome", title: "docs", uri: "https://docs.example/a", type: "Documentation", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [ids[0]]),
                    ActivityRow(row: 2, start: 1_060, end: 1_120, dwell: 60, app: "Google Chrome", appBundle: "com.google.Chrome", title: "someone's profile", uri: "https://social.example/u/x", type: "WebPage", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [ids[1]]),
                    ActivityRow(row: 3, start: 1_120, end: 1_180, dwell: 60, app: "Google Chrome", appBundle: "com.google.Chrome", title: "docs", uri: "https://docs.example/a", type: "Documentation", projectKey: nil, projectTitle: nil, snippet: nil, observationIds: [ids[2]])]
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"문서 읽기","task_type":"문헌조사"}],
         "rows":[{"rows":"1","task":"A","resource":true},{"rows":"2","task":"off","resource":false},{"rows":"3","task":"A","resource":true}],
         "work":[{"task":"A","summary":"문서를 읽었다","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            let (stats, assignments) = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000)
            XCTAssertEqual(stats.offTaskRows, 1)
            XCTAssertEqual(stats.unassignedRows, 0)
            XCTAssertTrue(assignments[1].offTask); XCTAssertNil(assignments[1].taskId); XCTAssertFalse(assignments[1].resource)
            for item in assignments { try EventStore.assign(conn, observationIds: item.row.observationIds, taskId: item.taskId, relevant: item.resource, offTask: item.offTask) }
            XCTAssertEqual(try tx.nodes(label: NodeLabel.task).map(\.title), ["문서 읽기"])
            XCTAssertEqual(try tx.nodes(label: NodeLabel.session).count, 1, "이탈은 세션이 없고, 앞뒤 문서 읽기는 한 세션")
            XCTAssertEqual(try tx.nodes(label: NodeLabel.resource).map(\.key), ["https://docs.example/a"])
            XCTAssertEqual(try tx.nodes(label: NodeLabel.task).first?.props["active_seconds"], 120)
        }
        let off = try store.offTaskSeconds(from: 0, to: 10_000)
        XCTAssertEqual(off.map { "\($0.app) \(Int($0.seconds))" }, ["Google Chrome 60"], "이탈 시간은 행에서 집계된다")
    }
}

final class TaskGoalTests: XCTestCase {
    func testNewTaskStoresItsGoalAndTheCandidateListShowsIt() throws {
        let db = try WGDatabase.inMemory()
        let rows = Fixtures.frontendRows()
        let patch = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"Acme 직무 PT 자료 준비","task_type":"발표자료","goal":"Acme 면접에서 발표할 직무 PT 준비"}],
         "rows":[{"rows":"1-6","task":"A","resource":true}],"work":[{"task":"A","summary":"슬라이드를 만들었다","topics":[]}]}
        """)
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000)
            let task = try XCTUnwrap(tx.nodes(label: NodeLabel.task).first)
            XCTAssertEqual(task.props["goal"]?.stringValue, "Acme 면접에서 발표할 직무 PT 준비")
            let digest = try XCTUnwrap(tx.openTasks(limit: 5).first)
            XCTAssertEqual(digest.goal, "Acme 면접에서 발표할 직무 PT 준비")
            let prompt = OntologyPrompt.build(rows: [], openTasks: [digest], now: 2_000_000)
            XCTAssertTrue(prompt.user.contains("goal: Acme 면접에서 발표할 직무 PT 준비"), prompt.user)

            // 기존 업무의 goal 은 덮어쓰지 않는다 (비어 있을 때만 채운다)
            let again = try Fixtures.patch("""
            {"tasks":[{"ref":"A","match":"existing","id":"\\(task.key)","goal":"다른 문장"}],"rows":[{"rows":"1","task":"A"}],"work":[]}
            """)
            _ = try AssignmentApplier().apply(again, rows: rows, tx: tx, now: 2_000_100)
            XCTAssertEqual(try tx.node(id: task.id)?.props["goal"]?.stringValue, "Acme 면접에서 발표할 직무 PT 준비")
        }
    }

    func testCardPromptForbidsGuessingPurposeAndQuotesMessages() {
        XCTAssertTrue(CardMaker.system.contains("not what it means"))
        XCTAssertTrue(CardMaker.system.contains("quote the visible messages verbatim"))
    }
}
