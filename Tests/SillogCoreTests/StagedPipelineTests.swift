import XCTest
import GRDB
@testable import SillogCore

final class PromptPiecesTests: XCTestCase {
    private let digest = TaskDigest(id: "t_a", title: "대시보드 카드 UI 구현", taskType: "코드작성", topics: ["React"], recentResources: ["TaskCard.tsx"],
                                    lastActive: 0, recentSummaries: ["카드를 만들었다"], goal: "대시보드 카드 UI 를 만든다")

    func testBuildIsTheSumOfItsPieces() {
        let rows = Fixtures.frontendRows()
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let built = OntologyPrompt.build(rows: rows, openTasks: [digest], now: 1_000_000, timeZone: seoul)
        var pieces: [String] = [OntologyPrompt.nowLine(1_000_000, timeZone: seoul), "TASK_TYPES: \(TBox.leafTaskTypes.joined(separator: ", "))", "OPEN_TASKS:"]
        pieces += OntologyPrompt.taskLines([digest])
        pieces.append("ROWS (row | time | dwell | app | type | title | uri) — assign every row:")
        pieces += OntologyPrompt.rowLines(rows, cards: [:], timeZone: seoul)
        XCTAssertEqual(built.user, pieces.joined(separator: "\n"))
        XCTAssertTrue(built.user.contains("- id=t_a | 대시보드 카드 UI 구현 | 코드작성 | goal: 대시보드 카드 UI 를 만든다 | topics: React | recent work: 카드를 만들었다 | recent: TaskCard.tsx"))
    }

    func testBriefTaskLinesKeepOnlyIdTitleAndGoal() {
        XCTAssertEqual(OntologyPrompt.taskLines([digest], brief: true), ["- id=t_a | 대시보드 카드 UI 구현 | goal: 대시보드 카드 UI 를 만든다"])
        XCTAssertEqual(OntologyPrompt.taskLines([], brief: true), ["(none)"])
    }

    func testASubsetShowsItsFirstCardInFull() {
        let rows = Fixtures.frontendRows()
        let card = ScreenCard(id: 7, tsStart: 0, tsEnd: 10, screenHash: 0, screenshotPath: nil, appBundle: "b", appName: "Cursor", windowTitle: nil, uri: nil,
                              activity: "TaskCard 를 고치고 있다", content: "줄 1", kind: "code", createdAt: 0)
        let lines = OntologyPrompt.rowLines(Array(rows[1...2]), cards: [2: [card], 3: [card]], timeZone: .current)
        XCTAssertTrue(lines.contains("    screen: TaskCard 를 고치고 있다"), "부분 목록에서는 2행이 처음이라 전문")
        XCTAssertTrue(lines.contains("    screen: (same screen as row 2)"))
    }
}

final class StageDecodeTests: XCTestCase {
    func testRowListsAndArraysAreRead() {
        let verdicts = StageDecode.classify(Data(#"{"rows":[{"rows":"1, 3","kind":"work","reason":"구현"},{"rows":[5,"6-7"],"kind":"off","reason":"게임"}]}"#.utf8))
        XCTAssertEqual(Set(verdicts.keys), [1, 3, 5, 6, 7])
        XCTAssertEqual(verdicts[3]?.kind, .work)
        XCTAssertEqual(verdicts[6]?.kind, .off)
        let assigned = StageDecode.assign(Data(#"{"tasks":[{"ref":"A","match":"new","title":"카드 UI","goal":"카드"}],"rows":[{"rows":"1 3","task":"A","reason":"구현"},{"rows":[5],"task":"A","reason":"구현"}]}"#.utf8))
        XCTAssertEqual(Set(assigned.rows.keys), [1, 3, 5])
    }

    func testAssignWithoutATaskMeansNoGoal() {
        let assigned = StageDecode.assign(Data(#"{"tasks":[],"rows":[{"rows":"1","task":null,"reason":"무관"},{"rows":"2","task":"","reason":"무관"},{"rows":"3","task":"none","reason":"무관"},{"rows":"4","task":"null","reason":"무관"}]}"#.utf8))
        for row in 1...4 { XCTAssertEqual(assigned.rows[row]?.task, AssignmentPatch.offTask, "행 \(row)") }
        XCTAssertEqual(assigned.rows[1]?.reason, "무관")
    }

    func testClassifyReadsRangesCaseAndSkipsUnknownKinds() {
        let data = Data(#"{"rows":[{"rows":"1-3","kind":"Work","reason":"카드 구현"},{"rows":4,"kind":"off","reason":"게임"},{"rows":"5","kind":"task","reason":"?"}]}"#.utf8)
        let verdicts = StageDecode.classify(data)
        XCTAssertEqual(verdicts[1], RowVerdict(kind: .work, reason: "카드 구현"))
        XCTAssertEqual(verdicts[3]?.kind, .work)
        XCTAssertEqual(verdicts[4]?.kind, .off)
        XCTAssertNil(verdicts[5], "모르는 kind 는 빠진 행으로 남는다")
    }

    func testAssignReadsTasksAndOff() {
        let data = Data(#"{"tasks":[{"ref":"A","match":"new","title":"카드 UI","goal":"카드를 만든다"}],"rows":[{"rows":"1-2","task":"A","reason":"구현"},{"rows":"3","task":"OFF","reason":"무관"}]}"#.utf8)
        let result = StageDecode.assign(data)
        XCTAssertEqual(result.tasks.map(\.ref), ["A"])
        XCTAssertEqual(result.rows[2], TaskChoice(task: "A", reason: "구현"))
        XCTAssertEqual(result.rows[3]?.task, AssignmentPatch.offTask)
    }

    func testDescribeReadsResourcesWorkTypesProblemsAndLaterItems() {
        let data = Data(#"{"resources":[{"rows":"1-2","resource":true},{"rows":"3","resource":false}],"work":[{"task":"A","summary":"카드를 만들었다","topics":["React"],"task_type":"코드작성"}],"problems":[{"row":2,"kind":"build","message":"key 경고","resolved_by_row":3}],"later_items":[{"row":3,"text":"간격 조정"}]}"#.utf8)
        let result = StageDecode.describe(data)
        XCTAssertEqual(result.resources, [1: true, 2: true, 3: false])
        XCTAssertEqual(result.work.first?.summary, "카드를 만들었다")
        XCTAssertEqual(result.taskTypes["A"], "코드작성")
        XCTAssertEqual(result.problems.first?.resolvedByRow, 3)
        XCTAssertEqual(result.laterItems.first?.text, "간격 조정")
    }

    func testStagePromptsCarryTheRulesAndOnlyTheirRows() {
        XCTAssertTrue(StagePrompt.classifySystem.contains("Hobbies and entertainment are not goals"))
        XCTAssertTrue(StagePrompt.classifySystem.contains("rows whose app is Sillog"))
        XCTAssertTrue(StagePrompt.classifySystem.contains("choose work"))
        XCTAssertTrue(StagePrompt.assignSystem.contains("managing the account, subscription or billing"))
        XCTAssertTrue(StagePrompt.describeSystem.contains("task_type"))
        XCTAssertTrue(StagePrompt.describeSystem.contains("use the weaker verb"))
        let rows = Fixtures.frontendRows()
        let user = StagePrompt.assign(rows: Array(rows[0...1]), openTasks: [], cards: [:], now: 1_000_000, timeZone: .current)
        XCTAssertTrue(user.contains("TaskCard.tsx"))
        XCTAssertFalse(user.contains("디자인팀"), "받은 행만 들어간다")
        let groups = [StagePrompt.Group(ref: "A", isNew: true, title: "카드 UI", goal: "카드를 만든다", rows: Array(rows[0...1]))]
        let describe = StagePrompt.describe(groups: groups, cards: [:], now: 1_000_000, timeZone: .current)
        XCTAssertTrue(describe.contains("## A | NEW | 카드 UI | goal: 카드를 만든다"))
    }

    /// 주제 덜 만들기: 기존 업무면 이미 쓰는 주제를 보여 주고 같은 뜻이면 그 이름을 다시 쓰게 한다 (11/06: '그래프 시각화' 변형 6개)
    func testDescribeShowsTopicsInUseForExistingTasks() {
        let rows = Fixtures.frontendRows()
        let groups = [StagePrompt.Group(ref: "t_sillog", isNew: false, title: "Sillog 개발", goal: nil, rows: Array(rows[0...1]), topics: ["그래프 시각화", "SwiftUI"])]
        let describe = StagePrompt.describe(groups: groups, cards: [:], now: 1_000_000, timeZone: .current)
        XCTAssertTrue(describe.contains("## t_sillog | existing | Sillog 개발 | topics in use: 그래프 시각화, SwiftUI"), describe)
        XCTAssertTrue(StagePrompt.describeSystem.contains("topics in use"))
        // ②가 기존 업무에 붙인 행이면 그 업무의 주제를 묶음에 싣는다
        var state = JudgeState(input: JudgeInput(rows: rows, openTasks: [TaskDigest(id: "t_sillog", title: "Sillog 개발", taskType: nil, topics: ["그래프 시각화"], recentResources: [],
                                                                                    lastActive: 0, resourceKeys: [], apps: [], recentSummaries: [], goal: nil)],
                                                  cards: [:], now: 1_000_000))
        state.verdicts[rows[0].row] = RowVerdict(kind: .work, reason: "")
        state.assignment.tasks = [AssignmentPatch.TaskDef(ref: "A", match: "existing", id: "t_sillog")]
        state.assignment.rows[rows[0].row] = TaskChoice(task: "A", reason: "")
        XCTAssertEqual(StagedPipeline.taskGroups(state).first?.topics, ["그래프 시각화"])
    }
}

enum StageReplies {
    static let classifyAll = #"{"rows":[{"rows":"1-5","kind":"work","reason":"카드 구현"},{"rows":"6","kind":"none","reason":"내용 없음"}]}"#
    static let assignA = #"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"대시보드 카드 UI 를 만든다"}],"rows":[{"rows":"1-5","task":"A","reason":"카드 구현"}]}"#
    static let describeA = #"{"resources":[{"rows":"1-2","resource":true},{"rows":"3-4","resource":false},{"rows":"5","resource":true}],"work":[{"task":"A","summary":"TaskCard 를 구현했다","topics":["React"],"task_type":"코드작성"}],"problems":[{"row":4,"kind":"build","message":"React key prop warning","resolved_by_row":5}],"later_items":[]}"#
}

final class StagedMergeTests: XCTestCase {
    private func state(_ rows: [ActivityRow]) -> JudgeState { JudgeState(input: JudgeInput(rows: rows, openTasks: [], now: 1_000_000)) }

    func testStageFunctionsFillTheStateAndMergeIntoOnePatch() async throws {
        let rows = Fixtures.frontendRows()
        let llm = StubLLM([.success(StageReplies.classifyAll), .success(StageReplies.assignA), .success(StageReplies.describeA)])
        var current = try await StagedPipeline.classify(state(rows), llm)
        XCTAssertEqual(current.workRows.map(\.row), [1, 2, 3, 4, 5])
        current = try await StagedPipeline.assign(current, llm)
        XCTAssertFalse(llm.users[1].contains("디자인팀"), "②에는 업무 행만")
        current = try await StagedPipeline.describe(current, llm)
        XCTAssertTrue(llm.users[2].contains("## A | NEW | 대시보드 카드 UI 구현"))
        let patch = StagedPipeline.patch(from: current)
        XCTAssertEqual(patch.tasks.map(\.ref), ["A"])
        XCTAssertEqual(patch.tasks.first?.taskType, "코드작성", "새 업무의 종류는 ③의 것")
        let byRow = patch.byRow()
        XCTAssertEqual(byRow[3]?.task, "A")
        XCTAssertEqual(byRow[3]?.resource, false)
        XCTAssertNil(byRow[6]?.task, "①에서 없음")
        XCTAssertEqual(patch.problems?.first?.resolvedByRow, 5)
        XCTAssertEqual(current.calls.map(\.stage), ["classify", "assign", "describe"])
    }

    func testAssignRangeOverRowsItDidNotReceiveIsIgnored() async throws {
        let rows = Fixtures.frontendRows()
        let llm = StubLLM([.success(StageReplies.classifyAll),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드"}],"rows":[{"rows":"1-6","task":"A","reason":"카드 구현"}]}"#)])
        var current = try await StagedPipeline.classify(state(rows), llm)
        current = try await StagedPipeline.assign(current, llm)
        XCTAssertNil(current.assignment.rows[6], "6행은 ②가 받지 않았다")
        XCTAssertNil(StagedPipeline.patch(from: current).byRow()[6]?.task, "①의 없음 그대로")
    }

    func testMissingResourceLeavesTheDefaultToTheApplier() async throws {
        let rows = Fixtures.frontendRows()
        let llm = StubLLM([.success(StageReplies.classifyAll), .success(StageReplies.assignA),
                           .success(#"{"resources":[{"rows":"1","resource":true}],"work":[{"task":"A","summary":"s","topics":[],"task_type":"코드작성"}]}"#)])
        var current = try await StagedPipeline.classify(state(rows), llm)
        current = try await StagedPipeline.assign(current, llm)
        current = try await StagedPipeline.describe(current, llm)
        XCTAssertNil(StagedPipeline.patch(from: current).byRow()[2]?.resource, "빠진 resource 는 비워 둔다")
    }

    func testStagedPatchBuildsTheSameGraphAsTheEquivalentSingleCall() async throws {
        let rows = Fixtures.frontendRows()
        let llm = StubLLM([.success(StageReplies.classifyAll), .success(StageReplies.assignA), .success(StageReplies.describeA)])
        var current = try await StagedPipeline.classify(state(rows), llm)
        current = try await StagedPipeline.assign(current, llm)
        current = try await StagedPipeline.describe(current, llm)
        let staged = StagedPipeline.patch(from: current)
        let single = try Fixtures.patch("""
        {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"대시보드 카드 UI 를 만든다","task_type":"코드작성"}],
         "rows":[{"rows":"1-2","task":"A","resource":true,"reason":"카드 구현"},{"rows":"3-4","task":"A","resource":false,"reason":"카드 구현"},
                 {"rows":"5","task":"A","resource":true,"reason":"카드 구현"},{"rows":"6","task":null,"resource":false,"reason":"내용 없음"}],
         "work":[{"task":"A","summary":"TaskCard 를 구현했다","topics":["React"]}],
         "problems":[{"row":4,"kind":"build","message":"React key prop warning","resolved_by_row":5}],"later_items":[]}
        """)
        func graph(_ patch: AssignmentPatch) throws -> [String] {
            let db = try SillogDatabase.inMemory()
            return try db.writer.write { conn in
                let tx = GraphTx(conn)
                try TBox.seed(tx, at: 0)
                _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000, requireComplete: true)
                let nodes = try String.fetchAll(conn, sql: "SELECT label || ':' || title FROM nodes WHERE label NOT IN ('TaskType', 'ResourceType') ORDER BY 1")
                let edges = try String.fetchAll(conn, sql: "SELECT type || ':' || COUNT(*) FROM edges GROUP BY type ORDER BY 1")
                return nodes + edges
            }
        }
        XCTAssertEqual(try graph(staged), try graph(single))
    }

    func testMermaidListsEveryNodeAndEdge() {
        let text = StagedPipeline.graph.mermaid()
        for piece in ["flowchart TD", "classify[\"① 업무 여부\"]", "assign[\"② 업무 대입\"]", "describe[\"③ 클래스 부여\"]",
                      "classify -->|빠진 행| classify", "classify -->|업무 행 없음| save", "assign -->|업무 있음| describe", "describe -->|끝| save"] {
            XCTAssertTrue(text.contains(piece), piece)
        }
    }
}

final class StagedFlowTests: XCTestCase {
    func testThreeCallsWhenThereIsWork() async throws {
        let llm = StubLLM([.success(StageReplies.classifyAll), .success(StageReplies.assignA), .success(StageReplies.describeA)])
        let (patch, calls) = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(llm.calls, 3)
        XCTAssertEqual(calls.map(\.stage), ["classify", "assign", "describe"])
        XCTAssertEqual(patch.rows.count, 6)
    }

    func testOneCallWhenNoRowIsWork() async throws {
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-5","kind":"off","reason":"게임"},{"rows":"6","kind":"none","reason":"내용 없음"}]}"#)])
        let (patch, _) = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(llm.calls, 1)
        XCTAssertTrue(patch.tasks.isEmpty)
        XCTAssertEqual(patch.byRow()[1]?.task, AssignmentPatch.offTask)
    }

    func testMissingRowsAreAskedAgainAlone() async throws {
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-5","kind":"work","reason":"카드 구현"}]}"#),
                           .success(#"{"rows":[{"rows":"6","kind":"none","reason":"내용 없음"}]}"#),
                           .success(StageReplies.assignA), .success(StageReplies.describeA)])
        _ = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(llm.calls, 4)
        XCTAssertTrue(llm.users[1].contains("디자인팀"))
        XCTAssertFalse(llm.users[1].contains("TaskCard.tsx"), "다시 물을 때는 빠진 행만")
    }

    func testStillMissingAfterRetryFails() async throws {
        let partial = #"{"rows":[{"rows":"1-5","kind":"work","reason":"카드 구현"}]}"#
        let llm = StubLLM([.success(partial), .success(#"{"rows":[]}"#)])
        do {
            _ = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
            XCTFail("빠진 행이 남으면 실패해야 함")
        } catch let error as PipelineError {
            XCTAssertEqual(error.calls.count, 2)
            guard case .incomplete(_, let missing, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(missing, [6])
        }
    }

    func testRowsAnsweredAsListsOrWithoutATaskAreNotAskedAgain() async throws {
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1, 3, 5","kind":"work","reason":"구현"},{"rows":[2, 4],"kind":"work","reason":"구현"},{"rows":"6","kind":"none","reason":"내용 없음"}]}"#),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드"}],"rows":[{"rows":"1, 3","task":"A","reason":"구현"},{"rows":[2],"task":"A","reason":"구현"},{"rows":"4-5","task":null,"reason":"무관"}]}"#),
                           .success(#"{"resources":[],"work":[{"task":"A","summary":"s","topics":[],"task_type":"코드작성"}]}"#)])
        let (patch, calls) = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(calls.map(\.stage), ["classify", "assign", "describe"], "다시 묻지 않는다")
        let byRow = patch.byRow()
        XCTAssertEqual(byRow[2]?.task, "A")
        XCTAssertEqual(byRow[5]?.task, AssignmentPatch.offTask, "업무 없음 답은 업무 외")
    }

    func testARowOnARefTheAnswerDidNotDefineIsAskedAgain() async throws {
        let llm = StubLLM([.success(StageReplies.classifyAll),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드"}],"rows":[{"rows":"1-3","task":"A","reason":"카드"},{"rows":"4-5","task":"existing","reason":"카드"}]}"#),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드"}],"rows":[{"rows":"4-5","task":"A","reason":"카드"}]}"#),
                           .success(#"{"resources":[],"work":[{"task":"A","summary":"s","topics":[],"task_type":"코드작성"}]}"#)])
        let rows = Fixtures.frontendRows()
        let (patch, calls) = try await StagedPipeline.run(JudgeInput(rows: rows, openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(calls.map(\.stage), ["classify", "assign", "assign", "describe"])
        XCTAssertEqual(patch.byRow()[4]?.task, "r2-A")
        XCTAssertNil(AssignmentCheck.rejection(patch, rows: rows, openTasks: [], now: 2_000_000), "앱이 받아들이는 판정")
    }

    func testAnOpenTaskIdUsedDirectlyAsARefMeansThatTask() async throws {
        let open = TaskDigest(id: "t_0f8d2fa1", title: "대시보드 카드 UI 구현", taskType: "코드작성", topics: [], recentResources: [],
                              lastActive: 0, recentSummaries: [], goal: "카드를 만든다")
        let rows = Fixtures.frontendRows()
        let llm = StubLLM([.success(StageReplies.classifyAll),
                           .success(#"{"tasks":[],"rows":[{"rows":"1-3","task":"t_0f8d2fa1","reason":"카드"}]}"#),
                           .success(#"{"tasks":[],"rows":[{"rows":"4-5","task":"t_0f8d2fa1","reason":"카드"}]}"#),
                           .success(#"{"resources":[],"work":[{"task":"t_0f8d2fa1","summary":"s","topics":[]}]}"#)])
        let (patch, _) = try await StagedPipeline.run(JudgeInput(rows: rows, openTasks: [open], now: 1_000_000), llm: llm)
        XCTAssertEqual(patch.tasks, [AssignmentPatch.TaskDef(ref: "t_0f8d2fa1", match: "existing", id: "t_0f8d2fa1")])
        XCTAssertEqual(patch.byRow()[4]?.task, "t_0f8d2fa1", "다시 물어도 접두어 없이 같은 업무")
        XCTAssertTrue(llm.users[3].contains("## t_0f8d2fa1 | existing | 대시보드 카드 UI 구현"))
        let db = try SillogDatabase.inMemory()
        try await db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            _ = try tx.upsertNode(label: NodeLabel.task, key: "t_0f8d2fa1", subtype: nil, title: "대시보드 카드 UI 구현", props: [:], at: 0)
            _ = try AssignmentApplier().apply(patch, rows: rows, tx: tx, now: 2_000_000, requireComplete: true)
        }
    }

    func testRetryRefsDoNotCollideWithTheFirstAttempt() async throws {
        let llm = StubLLM([.success(StageReplies.classifyAll),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드"}],"rows":[{"rows":"1-3","task":"A","reason":"카드"}]}"#),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"오류 해결 조사","goal":"오류를 고친다"}],"rows":[{"rows":"4-5","task":"A","reason":"오류"}]}"#),
                           .success(#"{"resources":[],"work":[{"task":"A","summary":"s","topics":[],"task_type":"코드작성"},{"task":"r2-A","summary":"s","topics":[],"task_type":"코드작성"}]}"#)])
        let (patch, _) = try await StagedPipeline.run(JudgeInput(rows: Fixtures.frontendRows(), openTasks: [], now: 1_000_000), llm: llm)
        XCTAssertEqual(Set(patch.tasks.map(\.ref)), ["A", "r2-A"])
        XCTAssertEqual(patch.byRow()[4]?.task, "r2-A")
        XCTAssertEqual(patch.tasks.first { $0.ref == "r2-A" }?.title, "오류 해결 조사")
    }
}

final class StagedBatcherTests: XCTestCase {
    private func seed(_ db: SillogDatabase) throws {
        let store = EventStore(db)
        _ = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.todesktop.230313mzl4w4u92", appName: "Cursor", windowTitle: "TaskCard.tsx — dashboard"))
        _ = try store.insert(Observation(ts: 160, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                         windowTitle: "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card"))
    }

    private func batcher(_ db: SillogDatabase, _ llm: StubLLM) -> OntologyBatcher {
        var config = BatchConfig()
        config.pipeline = .staged
        config.themes = false
        config.findEvents = false                           // 일정 찾기 호출은 EventFinderTests 에서
        return OntologyBatcher(db: db, llm: llm, config: config, home: "/Users/me", fileExists: { _ in false }, clock: { 450 })
    }

    /// 측정에서 성공 기준을 넘어 기본 판정 방식은 3단계다
    func testDefaultPipelineIsStaged() {
        XCTAssertEqual(BatchConfig().pipeline, .staged)
    }

    func testStagedBatchAppliesAndRecordsEveryStage() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-2","kind":"work","reason":"카드 구현"}]}"#),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드를 만든다"}],"rows":[{"rows":"1-2","task":"A","reason":"카드 구현"}]}"#),
                           .success(#"{"resources":[{"rows":"1-2","resource":true}],"work":[{"task":"A","summary":"카드를 만들었다","topics":["React"],"task_type":"코드작성"}]}"#)])
        guard case .ok(let stats) = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("배치 성공해야 함") }
        XCTAssertEqual(stats.tasksCreated, 1)
        XCTAssertEqual(llm.calls, 3, "업무가 하나뿐이라 업무 합치기 호출은 없음")
        let batch = try XCTUnwrap(EventStore(db).recentBatches(limit: 1).first)
        XCTAssertEqual(batch.status, "ok")
        XCTAssertEqual(batch.promptTokens, 300, "단계 토큰 합계")
        XCTAssertTrue(batch.rawResponse?.contains("\"classify\"") ?? false)
        XCTAssertTrue(batch.userPrompt?.contains("[assign]") ?? false)
        XCTAssertTrue(try EventStore(db).unprocessed(limit: 10).isEmpty)
    }

    func testAFailedStageKeepsTheEarlierStagesInTheRecord() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-2","kind":"work","reason":"카드 구현"}]}"#), .failure(.http(429, "rate"))])
        guard case .failed(let message) = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("실패해야 함") }
        XCTAssertTrue(message.contains("429"), message)
        let batch = try XCTUnwrap(EventStore(db).recentBatches(limit: 1).first)
        XCTAssertEqual(batch.status, "failed")
        XCTAssertEqual(batch.promptTokens, 100, "끝난 ①의 토큰")
        XCTAssertTrue(batch.userPrompt?.contains("[classify]") ?? false)
        XCTAssertTrue(batch.userPrompt?.contains("[assign]") ?? false, "실패한 단계의 프롬프트도 남긴다")
        let stages = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((batch.rawResponse ?? "").utf8)) as? [[String: Any]])
        XCTAssertEqual(stages.first?["stage"] as? String, "classify")
        XCTAssertTrue((stages.first?["arguments"] as? String)?.contains("카드 구현") ?? false)
    }

    func testTheStageRecordStaysValidJSONWhenAnswersAreLong() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let long = String(repeating: "카드 구현 ", count: 4_000)
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-2","kind":"work","reason":"\#(long)"}]}"#),
                           .success(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","goal":"카드를 만든다"}],"rows":[{"rows":"1-2","task":"A","reason":"카드 구현"}]}"#),
                           .success(#"{"resources":[{"rows":"1-2","resource":true}],"work":[{"task":"A","summary":"카드를 만들었다","topics":["React"],"task_type":"코드작성"}]}"#)])
        guard case .ok = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("배치 성공해야 함") }
        let raw = try XCTUnwrap(EventStore(db).recentBatches(limit: 1).first?.rawResponse)
        XCTAssertLessThanOrEqual(raw.count, 20_000)
        let stages = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]], "잘려도 JSON 이어야 함")
        XCTAssertEqual(stages.map { $0["stage"] as? String }, ["classify", "assign", "describe"])
        XCTAssertTrue((stages.last?["arguments"] as? String)?.contains("카드를 만들었다") ?? false)
    }

    func testAFailedLaterStageAppliesNothing() async throws {
        let db = try SillogDatabase.inMemory()
        try seed(db)
        let llm = StubLLM([.success(#"{"rows":[{"rows":"1-2","kind":"work","reason":"카드 구현"}]}"#), .failure(.http(500, "server"))])
        guard case .failed = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("실패해야 함") }
        XCTAssertEqual(try EventStore(db).unprocessed(limit: 10).count, 2, "행은 미처리로 남는다")
        XCTAssertEqual(try EventStore(db).recentBatches(limit: 1).first?.status, "failed")
        let tasks = try await db.writer.read { try GraphTx($0).nodes(label: NodeLabel.task) }
        XCTAssertTrue(tasks.isEmpty)
    }
}
