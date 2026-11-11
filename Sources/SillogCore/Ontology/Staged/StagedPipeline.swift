import Foundation

/// 3단계 판정의 입력: 그래프 밖에서 준비한 행·후보 업무·화면 카드
public struct JudgeInput: Sendable {
    public var rows: [ActivityRow]
    public var openTasks: [TaskDigest]
    public var cards: [Int: [ScreenCard]]
    public var now: Double
    public var timeZone: TimeZone

    public init(rows: [ActivityRow], openTasks: [TaskDigest], cards: [Int: [ScreenCard]] = [:], now: Double, timeZone: TimeZone = .current) {
        self.rows = rows; self.openTasks = openTasks; self.cards = cards; self.now = now; self.timeZone = timeZone
    }
}

/// 단계 호출 하나의 기록 (배치 기록에 남긴다)
public struct StageCall: Sendable {
    public var stage: String
    public var system: String
    public var user: String
    public var raw: String
    /// 모델이 돌려준 함수 인자 (배치 기록에는 이것을 남긴다)
    public var arguments: String
    public var model: String
    public var promptTokens: Int
    public var completionTokens: Int
}

/// 단계 사이를 오가는 상태. LangGraph 에는 이 값 하나를 통째로 넘긴다
public struct JudgeState: Sendable {
    public var input: JudgeInput
    public var verdicts: [Int: RowVerdict] = [:]
    public var classifyAttempts = 0
    public var assignment = AssignResult()
    public var assignAttempts = 0
    public var description = DescribeResult()
    public var calls: [StageCall] = []

    public init(input: JudgeInput) { self.input = input }

    /// ①이 아직 판정하지 않은 행
    public var unclassified: [ActivityRow] { input.rows.filter { verdicts[$0.row] == nil } }
    /// ①이 업무로 본 행
    public var workRows: [ActivityRow] { input.rows.filter { verdicts[$0.row]?.kind == .work } }
    /// 업무 행 중 ②가 아직 배정하지 않은 행
    public var unassigned: [ActivityRow] { workRows.filter { assignment.rows[$0.row] == nil } }
    /// ②가 업무에 붙인 행 (off 제외)
    public var assignedRows: [ActivityRow] {
        workRows.filter { row in assignment.rows[row.row].map { $0.task != AssignmentPatch.offTask } ?? false }
    }
}

public enum PipelineError: Error, CustomStringConvertible {
    case incomplete(stage: String, missing: [Int], calls: [StageCall])
    /// 단계 호출 자체가 실패함 (요청 한도·연결 등). calls 에는 끝난 단계와 실패한 단계의 프롬프트가 있다
    case stageFailed(stage: String, underlying: Error, calls: [StageCall])
    case lostState

    public var description: String {
        switch self {
        case .incomplete(let stage, let missing, _):
            return tr("\(stage) 단계가 행 \(missing.count)개를 판정하지 못함 (\(missing.prefix(10).map(String.init).joined(separator: ", ")))")
        case .stageFailed(let stage, let underlying, _):
            return tr("\(stage) 단계 호출 실패: \("\(underlying)")")
        case .lostState:
            return tr("단계 사이에서 상태를 잃음")
        }
    }

    public var calls: [StageCall] {
        switch self {
        case .incomplete(_, _, let calls), .stageFailed(_, _, let calls): return calls
        case .lostState: return []
        }
    }
}

/// 그래프 정의: 실행기와 흐름도가 같은 정의를 읽는다
public struct PipelineGraph: Sendable {
    public struct Edge: Sendable {
        public var label: String
        public var target: String
    }

    public struct Node: Sendable {
        public var id: String
        public var title: String
        public var run: @Sendable (JudgeState, any LLMClient) async throws -> JudgeState
        /// 다음으로 갈 간선의 이름
        public var route: @Sendable (JudgeState) -> String
        public var edges: [Edge]
    }

    /// 끝 (저장)
    public static let end = "end"
    public var entry: String
    public var nodes: [Node]

    /// Mermaid 흐름도. LangGraph-Swift 는 그래프 그리기를 지원하지 않아 직접 만든다
    public func mermaid() -> String {
        var lines = ["flowchart TD", "    start([준비]) --> \(entry)"]
        for node in nodes { lines.append("    \(node.id)[\"\(node.title)\"]") }
        lines.append("    save([저장])")
        for node in nodes {
            for edge in node.edges { lines.append("    \(node.id) -->|\(edge.label)| \(edge.target == Self.end ? "save" : edge.target)") }
        }
        return lines.joined(separator: "\n")
    }
}

/// ① 업무 여부 → ② 업무 대입 → ③ 클래스 부여
public enum StagedPipeline {
    /// 빠진 행을 다시 묻는 것까지 포함한 단계별 최대 시도
    public static let maxAttempts = 2
    /// 단계 이름 (흐름도·오류 메시지)
    public static let titles = ["classify": "① 업무 여부", "assign": "② 업무 대입", "describe": "③ 클래스 부여"]

    public static var graph: PipelineGraph {
        PipelineGraph(entry: "classify", nodes: [
            .init(id: "classify", title: titles["classify"]!, run: classify, route: { state in
                if !state.unclassified.isEmpty { return state.classifyAttempts < maxAttempts ? "빠진 행" : "실패" }
                return state.workRows.isEmpty ? "업무 행 없음" : "업무 행 있음"
            }, edges: [.init(label: "빠진 행", target: "classify"), .init(label: "업무 행 있음", target: "assign"),
                       .init(label: "업무 행 없음", target: PipelineGraph.end), .init(label: "실패", target: PipelineGraph.end)]),
            .init(id: "assign", title: titles["assign"]!, run: assign, route: { state in
                if !state.unassigned.isEmpty { return state.assignAttempts < maxAttempts ? "빠진 행" : "실패" }
                return state.assignedRows.isEmpty ? "업무 없음" : "업무 있음"
            }, edges: [.init(label: "빠진 행", target: "assign"), .init(label: "업무 있음", target: "describe"),
                       .init(label: "업무 없음", target: PipelineGraph.end), .init(label: "실패", target: PipelineGraph.end)]),
            .init(id: "describe", title: titles["describe"]!, run: describe, route: { _ in "끝" },
                  edges: [.init(label: "끝", target: PipelineGraph.end)]),
        ])
    }

    /// 판정 전체: 그래프를 돌리고 합친 patch 와 단계 호출 기록을 돌려준다. 빠진 행이 남으면 PipelineError.incomplete
    public static func run(_ input: JudgeInput, llm: any LLMClient, runner: any PipelineRunner = LangGraphRunner()) async throws -> (patch: AssignmentPatch, calls: [StageCall]) {
        let final = try await runner.run(graph, JudgeState(input: input), llm: llm)
        if !final.unclassified.isEmpty {
            throw PipelineError.incomplete(stage: titles["classify"]!, missing: final.unclassified.map(\.row), calls: final.calls)
        }
        if !final.unassigned.isEmpty {
            throw PipelineError.incomplete(stage: titles["assign"]!, missing: final.unassigned.map(\.row), calls: final.calls)
        }
        return (patch(from: final), final.calls)
    }

    static func record(_ stage: String, system: String, user: String, _ result: LLMResult) -> StageCall {
        StageCall(stage: stage, system: system, user: user, raw: result.raw, arguments: String(data: result.arguments, encoding: .utf8) ?? "",
                  model: result.model, promptTokens: result.promptTokens, completionTokens: result.completionTokens)
    }

    /// 단계 호출 하나. 실패하면 지금까지의 기록에 실패한 단계의 프롬프트를 더해 던진다 (배치 기록에 남도록)
    static func call(_ stage: String, system: String, user: String, tool: ToolSpec, state: JudgeState, llm: any LLMClient) async throws -> LLMResult {
        do {
            return try await llm.callFunction(system: system, user: user, tool: tool)
        } catch {
            let failed = StageCall(stage: stage, system: system, user: user, raw: "", arguments: "", model: llm.modelName, promptTokens: 0, completionTokens: 0)
            throw PipelineError.stageFailed(stage: titles[stage] ?? stage, underlying: error, calls: state.calls + [failed])
        }
    }

    /// ① 아직 판정하지 않은 행만 묻는다 (첫 시도는 전부)
    public static func classify(_ state: JudgeState, _ llm: any LLMClient) async throws -> JudgeState {
        var next = state
        let pending = state.unclassified
        let user = StagePrompt.classify(rows: pending, openTasks: state.input.openTasks, cards: state.input.cards, now: state.input.now, timeZone: state.input.timeZone)
        let result = try await call("classify", system: StagePrompt.classifySystem, user: user, tool: StageTool.classify, state: state, llm: llm)
        let wanted = Set(pending.map(\.row))
        for (row, verdict) in StageDecode.classify(result.arguments) where wanted.contains(row) { next.verdicts[row] = verdict }
        next.classifyAttempts += 1
        next.calls.append(record("classify", system: StagePrompt.classifySystem, user: user, result))
        return next
    }

    /// ② 업무 행 중 아직 배정하지 않은 행만. 다시 물을 때 정의한 ref 는 앞 시도와 겹치지 않게 접두어를 붙인다.
    public static func assign(_ state: JudgeState, _ llm: any LLMClient) async throws -> JudgeState {
        var next = state
        let pending = state.unassigned
        if !pending.isEmpty {
            try await ask(pending, openTasks: state.input.openTasks, prefix: state.assignAttempts == 0 ? "" : "r\(state.assignAttempts + 1)-", into: &next, llm: llm)
        }
        next.assignAttempts += 1
        return next
    }

    /// LLM 에 행들의 업무를 묻고 답을 next 에 합친다. openTasks 는 프롬프트에 보이는 후보, prefix 는 이 답이 정의한 ref 에 붙인다
    private static func ask(_ rows: [ActivityRow], openTasks: [TaskDigest], prefix: String, into next: inout JudgeState, llm: any LLMClient) async throws {
        let input = next.input
        let user = StagePrompt.assign(rows: rows, openTasks: openTasks, cards: input.cards, now: input.now, timeZone: input.timeZone)
        let result = try await call("assign", system: StagePrompt.assignSystem, user: user, tool: StageTool.assign, state: next, llm: llm)
        let answer = StageDecode.assign(result.arguments)
        let defined = Set(answer.tasks.map(\.ref)), openIds = Set(openTasks.map(\.id))
        // 정의 없이 후보 업무의 id 를 바로 쓴 ref 는 그 업무 자체라 다시 물어도 이름을 바꾸지 않는다
        func isOpenId(_ ref: String) -> Bool { !defined.contains(ref) && openIds.contains(ref) }
        func renamed(_ ref: String) -> String {
            if ref == AssignmentPatch.offTask || isOpenId(ref) { return ref }
            return prefix + ref
        }
        let wanted = Set(rows.map(\.row))
        var used = Set<String>()
        for (row, choice) in answer.rows where wanted.contains(row) {
            // 이 답이 정의하지 않은 ref ("existing" 같은 실수) 에 붙은 행은 답하지 않은 것으로 보고 다시 묻는다
            guard choice.task == AssignmentPatch.offTask || defined.contains(choice.task) || isOpenId(choice.task) else { continue }
            next.assignment.rows[row] = TaskChoice(task: renamed(choice.task), reason: choice.reason)
            used.insert(renamed(choice.task))
        }
        for var definition in answer.tasks where used.contains(renamed(definition.ref)) {
            definition.ref = renamed(definition.ref)
            next.assignment.tasks.append(definition)
        }
        for ref in used.sorted() where isOpenId(ref) && !next.assignment.tasks.contains(where: { $0.ref == ref }) {
            next.assignment.tasks.append(AssignmentPatch.TaskDef(ref: ref, match: "existing", id: ref))
        }
        next.calls.append(record("assign", system: StagePrompt.assignSystem, user: user, result))
    }

    /// ③ 업무별로 묶은 행
    public static func describe(_ state: JudgeState, _ llm: any LLMClient) async throws -> JudgeState {
        var next = state
        let user = StagePrompt.describe(groups: taskGroups(state), cards: state.input.cards, now: state.input.now, timeZone: state.input.timeZone)
        let result = try await call("describe", system: StagePrompt.describeSystem, user: user, tool: StageTool.describe, state: state, llm: llm)
        next.description = StageDecode.describe(result.arguments)
        next.calls.append(record("describe", system: StagePrompt.describeSystem, user: user, result))
        return next
    }

    /// ②의 업무별로 행을 묶는다. 머리줄은 기존 업무면 후보 목록의 제목·목표, 새 업무면 ②가 쓴 것
    public static func taskGroups(_ state: JudgeState) -> [StagePrompt.Group] {
        let byId = Dictionary(state.input.openTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = [], rowsByRef: [String: [ActivityRow]] = [:]
        for row in state.assignedRows {
            guard let ref = state.assignment.rows[row.row]?.task else { continue }
            if rowsByRef[ref] == nil { order.append(ref) }
            rowsByRef[ref, default: []].append(row)
        }
        return order.map { ref in
            let definition = state.assignment.tasks.first { $0.ref == ref }
            let existing = definition?.match == "existing" ? definition?.id.flatMap { byId[$0] } : nil
            return StagePrompt.Group(ref: ref, isNew: existing == nil, title: existing?.title ?? definition?.title ?? ref,
                                     goal: existing?.goal ?? definition?.goal, rows: rowsByRef[ref] ?? [], topics: existing?.topics ?? [])
        }
    }

    /// 세 단계 결과를 지금과 같은 AssignmentPatch 로 합친다
    public static func patch(from state: JudgeState) -> AssignmentPatch {
        var rows: [AssignmentPatch.RowRef] = []
        for row in state.input.rows {
            guard let verdict = state.verdicts[row.row] else { continue }
            let number = "\(row.row)"
            switch verdict.kind {
            case .none:
                rows.append(.init(rows: number, task: nil, resource: false, reason: verdict.reason))
            case .off:
                rows.append(.init(rows: number, task: AssignmentPatch.offTask, resource: false, reason: verdict.reason))
            case .work:
                guard let choice = state.assignment.rows[row.row] else { continue }
                if choice.task == AssignmentPatch.offTask {
                    rows.append(.init(rows: number, task: AssignmentPatch.offTask, resource: false, reason: choice.reason))
                } else {
                    rows.append(.init(rows: number, task: choice.task, resource: state.description.resources[row.row], reason: choice.reason))
                }
            }
        }
        let used = Set(rows.compactMap(\.task))
        var tasks = state.assignment.tasks.filter { used.contains($0.ref) }
        for index in tasks.indices where tasks[index].taskType == nil {
            tasks[index].taskType = state.description.taskTypes[tasks[index].ref]
        }
        return AssignmentPatch(tasks: tasks, rows: rows, work: state.description.work,
                               problems: state.description.problems, laterItems: state.description.laterItems)
    }
}
