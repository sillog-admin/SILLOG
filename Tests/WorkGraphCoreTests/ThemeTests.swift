import XCTest
import GRDB
@testable import WorkGraphCore

final class ThemeOntologyTests: XCTestCase {
    func testTasksArePartOfAThemeAndThemeIsAClass() {
        XCTAssertTrue(RelationSchema.allows(type: EdgeType.partOf, from: NodeLabel.task, to: NodeLabel.theme))
        XCTAssertFalse(RelationSchema.allows(type: EdgeType.partOf, from: NodeLabel.theme, to: NodeLabel.task))
        XCTAssertTrue(RelationSchema.allows(type: EdgeType.partOf, from: NodeLabel.session, to: NodeLabel.task), "세션 → 업무는 그대로")
        XCTAssertEqual(ClassSchema.definition(NodeLabel.theme)?.name, "분야")
    }

    func testNewTaskTypesAndVersion() {
        for name in ["신청·지원", "일정·공지확인", "면접·시험준비"] { XCTAssertTrue(TBox.leafTaskTypes.contains(name), name) }
        XCTAssertFalse(TBox.leafTaskTypes.contains("행정처리"), "상위 종류는 고를 수 없음")
        XCTAssertEqual(TBox.leafTaskTypes.count, 14)
        XCTAssertEqual(TBox.version, 2)
        XCTAssertEqual(TBox.leafType("신청 지원"), "신청·지원", "공백·가운뎃점 차이는 같은 종류")
        XCTAssertNil(TBox.leafType("행정처리"))
    }

    func testANewTaskRecordsTheTypeVersion() throws {
        let db = try WGDatabase.inMemory()
        let patch = try Fixtures.patch(#"{"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],"rows":[{"rows":"1-6","task":"A"}]}"#)
        let version = try db.writer.write { conn -> Double? in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            _ = try AssignmentApplier().apply(patch, rows: Fixtures.frontendRows(), tx: tx, now: 2_000_000)
            return try tx.nodes(label: NodeLabel.task).first?.props["type_version"]?.doubleValue
        }
        XCTAssertEqual(version, Double(TBox.version))
    }

    func testAttachReusesTheSameNameCanonicalizesDefaultsAndRejectsLongNames() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "A", props: [:], at: 0)
            let b = try tx.upsertNode(label: NodeLabel.task, key: "t_b", subtype: nil, title: "B", props: [:], at: 0)
            let c = try tx.upsertNode(label: NodeLabel.task, key: "t_c", subtype: nil, title: "C", props: [:], at: 0)
            let first = try XCTUnwrap(ThemeGraph.attach(taskId: a, to: "취업준비", tx, now: 1))
            XCTAssertEqual(first.node.title, "취업 준비", "기본 분야의 표기로 만든다")
            XCTAssertTrue(first.created)
            let second = try XCTUnwrap(ThemeGraph.attach(taskId: b, to: " 취업  준비 ", tx, now: 1))
            XCTAssertEqual(second.node.id, first.node.id)
            XCTAssertFalse(second.created)
            XCTAssertNil(try ThemeGraph.attach(taskId: a, to: "학업", tx, now: 1), "분야가 이미 있는 업무는 그대로")
            XCTAssertNil(try ThemeGraph.attach(taskId: c, to: String(repeating: "가", count: ThemeCatalog.nameLimit + 1), tx, now: 1),
                         "너무 긴 이름은 받지 않음")
            XCTAssertEqual(try ThemeGraph.theme(ofTask: b, tx)?.title, "취업 준비")
        }
    }

    func testThemesStopAtTheLimitAndEmptyOnesArePruned() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            for index in 0..<ThemeCatalog.limit {
                let task = try tx.upsertNode(label: NodeLabel.task, key: "t_\(index)", subtype: nil, title: "업무 \(index)", props: [:], at: 0)
                XCTAssertNotNil(try ThemeGraph.attach(taskId: task, to: "분야 \(index)", tx, now: 1))
            }
            let extra = try tx.upsertNode(label: NodeLabel.task, key: "t_extra", subtype: nil, title: "추가", props: [:], at: 0)
            XCTAssertNil(try ThemeGraph.attach(taskId: extra, to: "새 분야", tx, now: 1), "20개가 차면 새 분야는 못 만든다")
            XCTAssertNotNil(try ThemeGraph.attach(taskId: extra, to: "분야 3", tx, now: 1), "있는 분야는 쓸 수 있다")
            try conn.execute(sql: "DELETE FROM edges WHERE src = (SELECT id FROM nodes WHERE key = 't_0')")
            XCTAssertEqual(try ThemeGraph.pruneEmpty(tx), 1)
            XCTAssertEqual(try tx.nodes(label: NodeLabel.theme).count, ThemeCatalog.limit - 1)
        }
    }
}

final class ThemeStepTests: XCTestCase {
    /// 업무 노드 (분야·종류·판·목표는 선택)
    static func task(_ tx: GraphTx, _ key: String, _ title: String, theme: String? = nil, type: String? = nil,
                     version: Int? = nil, goal: String? = nil) throws -> Int64 {
        var props: [String: JSONValue] = ["status": "active", "last_active": .number(100)]
        if let version { props["type_version"] = .number(Double(version)) }
        if let goal { props["goal"] = .string(goal) }
        let id = try tx.upsertNode(label: NodeLabel.task, key: key, subtype: nil, title: title, props: props, at: 100)
        if let type, let typeNode = try tx.node(label: NodeLabel.taskType, key: type) {
            try tx.upsertEdge(src: id, dst: typeNode.id, type: EdgeType.instanceOf, props: [:], addWeight: 0, at: 100, countHit: false)
        }
        if let theme { try ThemeGraph.attach(taskId: id, to: theme, tx, now: 100) }
        return id
    }

    static func seeded() throws -> WGDatabase {
        let db = try WGDatabase.inMemory()
        try db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        return db
    }

    /// "종류 | 분야 | 판"
    static func summary(_ db: WGDatabase, _ key: String) throws -> String {
        try db.writer.read { conn in
            let tx = GraphTx(conn)
            guard let node = try tx.node(label: NodeLabel.task, key: key) else { return "없음" }
            let type = try tx.edges(from: node.id, type: EdgeType.instanceOf).compactMap { try tx.node(id: $0.dst)?.title }.joined(separator: ",")
            let theme = try ThemeGraph.theme(ofTask: node.id, tx)?.title ?? "-"
            let version = Int(node.props["type_version"]?.doubleValue ?? 0)
            return "\(type) | \(theme) | \(version)"
        }
    }

    func testOnlyTasksWithoutAThemeOrWithAnOldTypeAreTargets() throws {
        let db = try Self.seeded()
        let loaded = try db.writer.write { conn -> (targets: [ThemeStep.Target], themes: [ThemeStep.ThemeLine]) in
            let tx = GraphTx(conn)
            _ = try Self.task(tx, "t_done", "끝난 정리", theme: "학업", type: "복습", version: 2)
            _ = try Self.task(tx, "t_new", "새 업무", type: "코드작성", version: 2)
            _ = try Self.task(tx, "t_old", "옛 업무", theme: "프로젝트", type: "기타")
            return try ThemeStep.load(tx)
        }
        XCTAssertEqual(loaded.targets.map(\.key).sorted(), ["t_new", "t_old"])
        let byKey = Dictionary(uniqueKeysWithValues: loaded.targets.map { ($0.key, $0) })
        XCTAssertEqual(byKey["t_new"]?.needsTheme, true)
        XCTAssertEqual(byKey["t_new"]?.needsType, false)
        XCTAssertEqual(byKey["t_old"]?.needsTheme, false)
        XCTAssertEqual(byKey["t_old"]?.needsType, true)
        XCTAssertEqual(Set(loaded.themes.map(\.name)), ["학업", "프로젝트"])
        XCTAssertEqual(loaded.themes.first { $0.name == "학업" }?.tasks, ["끝난 정리"])
    }

    func testPromptCarriesThemesDefaultsSlotsAndNeedsButTheRulesHaveNoExamples() {
        let target = ThemeStep.Target(key: "t_a", title: "현대오토에버 과제테스트 지원", goal: "신입 채용에 지원한다", taskType: "기타",
                                      recent: ["과제 안내를 읽었다"], needsTheme: true, needsType: true)
        let user = ThemeStep.user(targets: [target], themes: [ThemeStep.ThemeLine(name: "취업 준비", tasks: ["AI SCM 면접 준비"])])
        XCTAssertTrue(user.contains("- 취업 준비 | tasks: AI SCM 면접 준비"))
        XCTAssertTrue(user.contains("DEFAULT_THEMES (not used yet): 학업, 프로젝트, 직장 업무, 생활 행정, 자기계발"))
        XCTAssertTrue(user.contains("SLOTS: 19"))
        XCTAssertTrue(user.contains("TASK_TYPES: "))
        XCTAssertTrue(user.contains("- id=t_a | NEEDS_THEME, NEEDS_TYPE | 현대오토에버 과제테스트 지원 | goal: 신입 채용에 지원한다 | type: 기타 | recent: 과제 안내를 읽었다"))
        for name in ThemeCatalog.defaults { XCTAssertFalse(ThemeStep.system.contains(name), "규칙에 분야 예시를 넣지 않는다: \(name)") }
        let themeOnly = ThemeStep.user(targets: [ThemeStep.Target(key: "t_b", title: "B", goal: nil, taskType: nil, recent: [],
                                                                  needsTheme: true, needsType: false)], themes: [])
        XCTAssertFalse(themeOnly.contains("TASK_TYPES:"), "종류를 다시 붙일 업무가 없으면 종류 목록을 보내지 않는다")
        XCTAssertTrue(themeOnly.contains("THEMES:\n(none)"))
    }

    func testDecodeReadsThemesAndTypesLeniently() {
        let data = Data(#"{"tasks":[{"id":"t_a","theme":" 취업  준비 ","new_theme":false,"task_type":"신청 지원"},{"id":"t_b","theme":"","task_type":"모름"},{"theme":"학업"}]}"#.utf8)
        let answers = ThemeStep.decode(data)
        XCTAssertEqual(answers["t_a"], ThemeStep.Answer(theme: "취업 준비", taskType: "신청·지원"))
        XCTAssertEqual(answers["t_b"], ThemeStep.Answer(theme: nil, taskType: nil))
        XCTAssertEqual(answers.count, 2, "id 없는 답은 버린다")
    }

    func testApplyReusesCreatesSharesANewThemeAndSkipsBadAnswers() throws {
        let db = try Self.seeded()
        let outcome = try db.writer.write { conn -> ThemeStep.Outcome in
            let tx = GraphTx(conn)
            _ = try Self.task(tx, "t_job", "AI SCM 면접 준비", theme: "취업 준비", version: 2)
            for key in ["t_a", "t_b", "t_c", "t_d", "t_e"] { _ = try Self.task(tx, key, key, version: 2) }
            let targets = try ThemeStep.load(tx).targets
            let answers: [String: ThemeStep.Answer] = [
                "t_a": .init(theme: "취업준비", taskType: nil),
                "t_b": .init(theme: "부업", taskType: nil),
                "t_c": .init(theme: "부업", taskType: nil),
                "t_d": .init(theme: nil, taskType: nil),
                "t_zz": .init(theme: "학업", taskType: nil),
            ]
            return try ThemeStep.apply(answers, targets: targets, tx, now: 200)
        }
        XCTAssertEqual(outcome.themed, 3)
        XCTAssertEqual(outcome.created, ["부업"], "같은 호출의 새 분야는 하나만 생긴다")
        XCTAssertEqual(outcome.skipped, 2, "빈 답(t_d)과 답 없음(t_e)")
        let themes = try db.writer.read { try GraphTx($0).nodes(label: NodeLabel.theme).map(\.title) }
        XCTAssertEqual(Set(themes), ["취업 준비", "부업"], "대상에 없는 id 의 답은 반영하지 않는다")
    }

    func testRetypeReplacesTheTypeAndRecordsTheVersion() throws {
        let db = try Self.seeded()
        let outcome = try db.writer.write { conn -> ThemeStep.Outcome in
            let tx = GraphTx(conn)
            _ = try Self.task(tx, "t_a", "과제테스트 지원", theme: "취업 준비", type: "기타")
            _ = try Self.task(tx, "t_b", "혜택 신청", theme: "생활 행정", type: "시장조사")
            let targets = try ThemeStep.load(tx).targets
            let answers: [String: ThemeStep.Answer] = ["t_a": .init(theme: "학업", taskType: "신청·지원"), "t_b": .init(theme: nil, taskType: nil)]
            return try ThemeStep.apply(answers, targets: targets, tx, now: 200)
        }
        XCTAssertEqual(outcome.retyped, 1)
        XCTAssertEqual(try Self.summary(db, "t_a"), "신청·지원 | 취업 준비 | 2", "분야가 있는 업무의 분야 답은 무시")
        XCTAssertEqual(try Self.summary(db, "t_b"), "시장조사 | 생활 행정 | 0", "답이 없으면 종류와 판이 그대로")
    }

    func testRunSkipsTheCallWhenNothingIsMissingAndPrunesEmptyThemes() async throws {
        let db = try Self.seeded()
        try await db.writer.write { conn in
            let tx = GraphTx(conn)
            _ = try Self.task(tx, "t_a", "A", theme: "학업", type: "복습", version: 2)
            let gone = try tx.upsertNode(label: NodeLabel.task, key: "t_gone", subtype: nil, title: "지워질 업무", props: [:], at: 0)
            try ThemeGraph.attach(taskId: gone, to: "자기계발", tx, now: 0)
            try conn.execute(sql: "DELETE FROM edges WHERE src = ?", arguments: [gone])
            try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [gone])
        }
        let llm = StubLLM([])
        let outcome = try await ThemeStep.run(db: db, llm: llm, now: 300)
        XCTAssertNil(outcome)
        XCTAssertEqual(llm.calls, 0)
        let themes = try await db.writer.read { try GraphTx($0).nodes(label: NodeLabel.theme).map(\.title) }
        XCTAssertEqual(themes, ["학업"], "업무가 없는 분야는 지운다")
    }

    func testRunSendsOneCallAndAppliesTheAnswer() async throws {
        let db = try Self.seeded()
        try await db.writer.write { conn in _ = try Self.task(GraphTx(conn), "t_a", "자료구조 강의 수강", type: "강의수강") }
        let llm = StubLLM([.success(#"{"tasks":[{"id":"t_a","theme":"학업","new_theme":false,"task_type":"강의수강"}]}"#)])
        let outcome = try await ThemeStep.run(db: db, llm: llm, now: 300)
        XCTAssertEqual(outcome?.themed, 1)
        XCTAssertEqual(outcome?.retyped, 1)
        XCTAssertEqual(outcome?.created, ["학업"])
        XCTAssertEqual(llm.calls, 1)
        XCTAssertTrue(llm.lastUser.contains("NEEDS_THEME, NEEDS_TYPE"))
        XCTAssertEqual(try Self.summary(db, "t_a"), "강의수강 | 학업 | 2")
    }
}

/// 정리 호출은 정해진 답을, 테마 단계 호출은 받은 업무마다 같은 분야로 답하는 가짜 LLM
final class ThemeAwareLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, LLMError>]
    private let theme: Result<String, LLMError>
    private(set) var themeCalls = 0
    let modelName = "stub-model"

    init(_ replies: [Result<String, LLMError>], theme: Result<String, LLMError>) { self.replies = replies; self.theme = theme }

    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        if tool.name == ThemeStep.tool.name {
            lock.withLock { themeCalls += 1 }
            let name = try theme.get()
            let ids = user.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("- id=") else { return nil }
                return line.dropFirst(5).split(separator: " ").first.map(String.init)
            }
            var entries: [String] = []
            for id in ids { entries.append("{\"id\":\"\(id)\",\"theme\":\"\(name)\"}") }
            let json = "{\"tasks\":[\(entries.joined(separator: ","))]}"
            return LLMResult(arguments: Data(json.utf8), model: modelName, promptTokens: 10, completionTokens: 5, raw: json)
        }
        let next: Result<String, LLMError> = lock.withLock { replies.isEmpty ? .failure(.transport("no stub")) : replies.removeFirst() }
        let json = try next.get()
        return LLMResult(arguments: Data(json.utf8), model: modelName, promptTokens: 100, completionTokens: 20, raw: json)
    }
}

final class ThemeHookTests: XCTestCase {
    private let patch = """
    {"tasks":[{"ref":"A","match":"new","title":"대시보드 카드 UI 구현","task_type":"코드작성"}],"rows":[{"rows":"1-2","task":"A"}],
     "work":[{"task":"A","summary":"카드 구현","topics":["React"]}]}
    """

    private func seedRows(_ db: WGDatabase) throws {
        let store = EventStore(db)
        _ = try store.insert(Observation(ts: 100, trigger: "app_activate", appBundle: "com.todesktop.230313mzl4w4u92", appName: "Cursor", windowTitle: "TaskCard.tsx — dashboard"))
        _ = try store.insert(Observation(ts: 160, trigger: "app_activate", appBundle: "com.google.Chrome", appName: "Google Chrome",
                                         windowTitle: "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card"))
    }

    private func batcher(_ db: WGDatabase, _ llm: ThemeAwareLLM) -> OntologyBatcher {
        var config = BatchConfig.singleCall
        config.themes = true
        return OntologyBatcher(db: db, llm: llm, config: config, home: "/Users/me", fileExists: { _ in false }, clock: { 450 })
    }

    func testABatchThatCreatesATaskGivesItATheme() async throws {
        let db = try WGDatabase.inMemory()
        try seedRows(db)
        let llm = ThemeAwareLLM([.success(patch)], theme: .success("프로젝트"))
        guard case .ok = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("배치 성공해야 함") }
        XCTAssertEqual(llm.themeCalls, 1)
        let themes = try await db.writer.read { try GraphTx($0).nodes(label: NodeLabel.theme).map(\.title) }
        XCTAssertEqual(themes, ["프로젝트"])
    }

    func testAThemeFailureLeavesTheBatchApplied() async throws {
        let db = try WGDatabase.inMemory()
        try seedRows(db)
        let llm = ThemeAwareLLM([.success(patch)], theme: .failure(.http(429, "rate")))
        guard case .ok = await batcher(db, llm).runIfDue(force: true) else { return XCTFail("테마 단계가 실패해도 정리는 성공") }
        let counts = try await db.writer.read { conn -> [Int] in
            let tx = GraphTx(conn)
            let tasks = try tx.nodes(label: NodeLabel.task).count
            let themes = try tx.nodes(label: NodeLabel.theme).count
            return [tasks, themes]
        }
        XCTAssertEqual(counts, [1, 0])
    }

    func testAssignThemesNeverThrowsWhenTheModelIsUnreachable() async throws {
        let db = try WGDatabase.inMemory()
        try await db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "자료구조 강의 수강",
                              props: ["status": "active", "last_active": .number(100)], at: 100)
        }
        let llm = ThemeAwareLLM([], theme: .failure(.transport("offline")))
        let outcome = await batcher(db, llm).assignThemes(now: 500)
        XCTAssertNil(outcome)
        XCTAssertEqual(llm.themeCalls, 1)
    }

    func testMergingGivesTheSurvivorTheVictimsThemeWhenItHasNone() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let keep = try tx.upsertNode(label: NodeLabel.task, key: "t_keep", subtype: nil, title: "남는 업무", props: ["status": "active"], at: 0)
            let victim = try tx.upsertNode(label: NodeLabel.task, key: "t_victim", subtype: nil, title: "사라지는 업무", props: ["status": "active"], at: 0)
            try ThemeGraph.attach(taskId: victim, to: "학업", tx, now: 0)
            _ = try TaskMerger.merge(TaskMerger.Group(keep: "t_keep", merge: ["t_victim"]), conn: conn, now: 10)
            XCTAssertEqual(try ThemeGraph.theme(ofTask: keep, tx)?.title, "학업")
        }
    }

    func testMergingKeepsTheSurvivorsOwnThemeAndDropsTheEmptyOne() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let keep = try tx.upsertNode(label: NodeLabel.task, key: "t_keep", subtype: nil, title: "남는 업무", props: ["status": "active"], at: 0)
            let victim = try tx.upsertNode(label: NodeLabel.task, key: "t_victim", subtype: nil, title: "사라지는 업무", props: ["status": "active"], at: 0)
            try ThemeGraph.attach(taskId: keep, to: "프로젝트", tx, now: 0)
            try ThemeGraph.attach(taskId: victim, to: "학업", tx, now: 0)
            _ = try TaskMerger.merge(TaskMerger.Group(keep: "t_keep", merge: ["t_victim"]), conn: conn, now: 10)
            XCTAssertEqual(try ThemeGraph.theme(ofTask: keep, tx)?.title, "프로젝트")
            XCTAssertEqual(try tx.nodes(label: NodeLabel.theme).map(\.title), ["프로젝트"], "업무가 없는 분야는 지운다")
        }
    }

    func testRetiringATaskDropsItsNowEmptyTheme() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_game", subtype: nil, title: "게임 리그", props: ["status": "active"], at: 0)
            try ThemeGraph.attach(taskId: task, to: "자기계발", tx, now: 0)
            XCTAssertTrue(try TaskMerger.retire("t_game", conn: conn, now: 10))
            XCTAssertTrue(try tx.nodes(label: NodeLabel.theme).isEmpty)
        }
    }

    func testRebuildKeepsTaskThemes() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "A", props: ["status": "active"], at: 0)
            try ThemeGraph.attach(taskId: task, to: "학업", tx, now: 0)
        }
        _ = try GraphRebuilder(db: db, store: EventStore(db), home: "/Users/me", fileExists: { _ in false }).rebuildFromAssignments(now: 100)
        let theme = try db.writer.read { conn -> String? in
            let tx = GraphTx(conn)
            guard let task = try tx.node(label: NodeLabel.task, key: "t_a") else { return nil }
            return try ThemeGraph.theme(ofTask: task.id, tx)?.title
        }
        XCTAssertEqual(theme, "학업")
    }
}

final class ThemeViewTests: XCTestCase {
    func testATimeWindowStillShowsTheThemesOfVisibleTasks() throws {
        let db = try WGDatabase.inMemory()
        let graph = try db.writer.write { conn -> Subgraph in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "A", props: [:], at: 1_000)
            try ThemeGraph.attach(taskId: task, to: "학업", tx, now: 10)
            try conn.execute(sql: "UPDATE nodes SET updated_at = 10 WHERE label = 'Theme'")
            return try tx.subgraph(since: 500, includeTBox: false)
        }
        XCTAssertEqual(Set(graph.nodes.map(\.label)), [NodeLabel.task, NodeLabel.theme])
        XCTAssertEqual(graph.edges.map(\.type), [EdgeType.partOf])
    }

    func testRDFExportDeclaresThemeAndLinksTasksToIt() throws {
        let db = try WGDatabase.inMemory()
        let graph = try db.writer.write { conn -> Subgraph in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "A", props: [:], at: 0)
            try ThemeGraph.attach(taskId: task, to: "학업", tx, now: 0)
            return try tx.subgraph(since: nil, includeTBox: false)
        }
        let turtle = RDFExporter.export(graph)
        XCTAssertTrue(turtle.contains("wg:Theme a rdfs:Class ;\n    rdfs:subClassOf skos:Concept"))
        XCTAssertTrue(turtle.contains("a wg:Theme, skos:Concept"))
        XCTAssertTrue(turtle.contains("dcterms:isPartOf"))
    }
}

/// 마지막 검토에서 찾은 문제들
final class ThemeReviewFixTests: XCTestCase {
    func testTheGraphViewSeesAThemeAsRecentAsItsNewestTask() throws {
        let now: Double = 10_000_000
        let db = try WGDatabase.inMemory()
        let graph = try db.writer.write { conn -> Subgraph in
            let tx = GraphTx(conn)
            let old = try tx.upsertNode(label: NodeLabel.task, key: "t_old", subtype: nil, title: "옛 업무", props: [:], at: now - 30 * 86_400)
            try ThemeGraph.attach(taskId: old, to: "학업", tx, now: now - 30 * 86_400)
            let fresh = try tx.upsertNode(label: NodeLabel.task, key: "t_new", subtype: nil, title: "오늘 업무", props: [:], at: now)
            try ThemeGraph.attach(taskId: fresh, to: "학업", tx, now: now)
            return try tx.subgraph(since: nil, includeTBox: false)
        }
        let data = try GraphJSONExporter.export(graph, now: now)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let theme = try XCTUnwrap((json["nodes"] as? [[String: Any]])?.first { $0["label"] as? String == NodeLabel.theme })
        XCTAssertEqual(theme["updatedAt"] as? Double, now, "그래프 뷰는 노드의 updatedAt 으로 오늘·7일을 거른다")
    }

    func testRetypingAndThemingDoNotMakeAnOldTaskLookRecent() throws {
        let db = try ThemeStepTests.seeded()
        let old: Double = 1_000
        let result = try db.writer.write { conn -> (updated: Double?, recent: [String]) in
            let tx = GraphTx(conn)
            let id = try tx.upsertNode(label: NodeLabel.task, key: "t_old", subtype: nil, title: "옛 업무",
                                       props: ["status": "active", "last_active": .number(old)], at: old)
            if let typeNode = try tx.node(label: NodeLabel.taskType, key: "기타") {
                try tx.upsertEdge(src: id, dst: typeNode.id, type: EdgeType.instanceOf, props: [:], addWeight: 0, at: old, countHit: false)
            }
            let targets = try ThemeStep.load(tx).targets
            _ = try ThemeStep.apply(["t_old": .init(theme: "학업", taskType: "복습")], targets: targets, tx, now: 50_000)
            let updated = try tx.node(id: id)?.updatedAt
            let recent = try tx.subgraph(since: 40_000, includeTBox: false).nodes.map(\.key)
            return (updated, recent)
        }
        XCTAssertEqual(result.updated, old, "업무의 마지막 갱신 시각을 바꾸지 않는다")
        XCTAssertFalse(result.recent.contains("t_old"), "최근 그래프에 옛 업무가 끼지 않는다")
        XCTAssertEqual(try ThemeStepTests.summary(db, "t_old"), "복습 | 학업 | 2")
    }

    func testRetypingKeepsThePreviousTypeSoItCanBeUndone() throws {
        let db = try ThemeStepTests.seeded()
        let previous = try db.writer.write { conn -> String? in
            let tx = GraphTx(conn)
            let id = try ThemeStepTests.task(tx, "t_a", "과제테스트 지원", theme: "취업 준비", type: "기타")
            let targets = try ThemeStep.load(tx).targets
            _ = try ThemeStep.apply(["t_a": .init(theme: nil, taskType: "신청·지원")], targets: targets, tx, now: 200)
            return try tx.node(id: id)?.props["previous_type"]?.stringValue
        }
        XCTAssertEqual(previous, "기타")
    }

    func testTheThemeStepIsOffUnlessTurnedOn() async throws {
        XCTAssertFalse(BatchConfig().themes, "분야 측정이 기준 미달이라 사용자가 켤 때까지 꺼 둔다")
        let db = try WGDatabase.inMemory()
        try await db.writer.write { conn in
            let tx = GraphTx(conn)
            try TBox.seed(tx, at: 0)
            try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "자료구조 강의 수강",
                              props: ["status": "active", "last_active": .number(100)], at: 100)
        }
        let llm = ThemeAwareLLM([], theme: .success("학업"))
        let batcher = OntologyBatcher(db: db, llm: llm, config: .singleCall, home: "/Users/me", fileExists: { _ in false }, clock: { 450 })
        let outcome = await batcher.assignThemes(now: 500)
        XCTAssertNil(outcome)
        XCTAssertEqual(llm.themeCalls, 0, "꺼져 있으면 앱 시작 때도 부르지 않는다")
    }

    func testDetachRemovesTheThemeAndDropsAnEmptyOne() throws {
        let db = try WGDatabase.inMemory()
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let a = try tx.upsertNode(label: NodeLabel.task, key: "t_a", subtype: nil, title: "A", props: [:], at: 0)
            let b = try tx.upsertNode(label: NodeLabel.task, key: "t_b", subtype: nil, title: "B", props: [:], at: 0)
            try ThemeGraph.attach(taskId: a, to: "학업", tx, now: 0)
            try ThemeGraph.attach(taskId: b, to: "프로젝트", tx, now: 0)
            XCTAssertTrue(try ThemeGraph.detach(taskId: a, tx))
            XCTAssertNil(try ThemeGraph.theme(ofTask: a, tx))
            XCTAssertEqual(try tx.nodes(label: NodeLabel.theme).map(\.title), ["프로젝트"], "업무가 없는 분야는 지운다")
            XCTAssertFalse(try ThemeGraph.detach(taskId: a, tx), "분야가 없으면 할 일이 없다")
            XCTAssertNotNil(try ThemeGraph.attach(taskId: a, to: "자기계발", tx, now: 1), "빼면 다시 붙일 수 있다")
        }
    }
}
