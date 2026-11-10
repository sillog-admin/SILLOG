import Foundation

/// 앱에서 독립적으로 선택한 판단 모델.
public enum ActivityJudging: Sendable {
    case gpt(any LLMClient)
    case jev(any JevChoosing)
    case unavailable(String)
}

extension StagedPipeline {
    private struct Decision: Decodable {
        let row: Int
        let choice: String
        let reason: String
    }

    private struct Decisions: Decodable { let rows: [Decision] }

    private struct NewTask: Decodable {
        let rows: [Int]
        let title: String
        let goal: String
    }

    private struct NewTasks: Decodable { let tasks: [NewTask] }

    private static let choiceRules = """
        Decide which goal each activity serves. Use the content and purpose, rather than the app name.
        Choose an existing task ID for the same goal, new for a distinct goal, off for distraction unrelated to work,
        or none if the record has too little content to establish a goal. Do not title or describe tasks.
        Reading, setup, references, and tool billing belong to the goal they help achieve.
        """

    private static var chooseTool: ToolSpec {
        .init(name: "choose_activity", description: "Choose an existing goal, new, off, or none for each activity row.", parameters: .object([
            "type": "object", "required": .array(["rows"]),
            "properties": .object(["rows": .object(["type": "array", "items": .object([
                "type": "object", "required": .array(["row", "choice", "reason"]),
                "properties": .object(["row": .object(["type": "integer"]), "choice": .object(["type": "string"]), "reason": .object(["type": "string"])]),
            ])])]),
        ]))
    }

    private static var nameTool: ToolSpec {
        .init(name: "name_new_tasks", description: "Group activities already judged to be new work and give each group a title and goal.", parameters: .object([
            "type": "object", "required": .array(["tasks"]),
            "properties": .object(["tasks": .object(["type": "array", "items": .object([
                "type": "object", "required": .array(["rows", "title", "goal"]),
                "properties": .object([
                    "rows": .object(["type": "array", "items": .object(["type": "integer"])]),
                    "title": .object(["type": "string"]), "goal": .object(["type": "string"]),
                ]),
            ])])]),
        ]))
    }

    /// 실패하거나 판단이 비어 있는 행은 결과에서 뺀다. 호출자가 그 원본을 미처리 상태로 둔다.
    static func decideSeparately(_ input: JudgeInput, using judge: ActivityJudging) async throws -> JudgeState {
        var state = JudgeState(input: input)
        var selected: [Int: Decision] = [:]
        let ids = Set(input.openTasks.map(\.id))
        let rowIDs = Set(input.rows.map(\.row))
        let special: Set<String> = ["new", "off", "none"]
        switch judge {
        case .unavailable(let message):
            throw LLMError.backend(message)
        case .gpt(let client):
            let options = input.openTasks.map { "\($0.id): \(JevAssign.describe($0))" }
            let user = ([OntologyPrompt.nowLine(input.now, timeZone: input.timeZone), "EXISTING GOALS"] + options
                + [StagePrompt.rowsHeader] + OntologyPrompt.rowLines(input.rows, cards: input.cards, timeZone: input.timeZone)).joined(separator: "\n")
            let result = try await call("assign", system: choiceRules, user: user, tool: chooseTool, state: state, llm: client)
            state.calls.append(record("assign", system: choiceRules, user: user, result))
            let output = try? JSONDecoder().decode(Decisions.self, from: result.arguments)
            for (id, answers) in Dictionary(grouping: output?.rows ?? [], by: \.row) where rowIDs.contains(id) && answers.count == 1 {
                let answer = answers[0]
                if ids.contains(answer.choice) || special.contains(answer.choice) { selected[id] = answer }
            }
        case .jev(let client):
            let limit = JevAssign.maxOptions - special.count
            let chunks = stride(from: 0, to: max(input.openTasks.count, 1), by: limit).map { start in
                Array(input.openTasks.dropFirst(start).prefix(limit))
            }
            var failures = 0
            rowLoop: for row in input.rows {
                let text = JevAssign.stateText(row, cards: input.cards, now: input.now, timeZone: input.timeZone)
                for (index, tasks) in chunks.enumerated() {
                    var options = ["new": "Work for a different goal than the listed goals.", "off": "Distraction unrelated to work.",
                                   "none": "Too little content to establish a goal."]
                    for task in tasks { options[task.id] = JevAssign.describe(task) }
                    do {
                        let response = try await client.choose(state: text, questions: ["activity": .init(instructions: choiceRules, options: options)])
                        guard let answer = response["activity"], answer.confidence >= JevAssign.confidenceFloor,
                              options[answer.choice] != nil else { break }
                        if answer.choice == "new" && index + 1 < chunks.count { continue }
                        selected[row.row] = .init(row: row.row, choice: answer.choice, reason: "Jev 판단")
                        break
                    } catch {
                        failures += 1
                        // 연결이 끊긴 동안 같은 호출을 반복하지 않는다.
                        break rowLoop
                    }
                }
            }
            let result = selected.values.sorted { $0.row < $1.row }.map { "\($0.row): \($0.choice)" }.joined(separator: "\n")
            state.calls.append(.init(stage: "assign-jev", system: choiceRules, user: "", raw: "",
                                     arguments: result + (failures > 0 ? "\n판단 모델 호출 실패" : ""),
                                     model: client.modelName, promptTokens: 0, completionTokens: 0))
        }

        for row in input.rows {
            guard let answer = selected[row.row] else { continue }
            let kind = RowKind(rawValue: answer.choice) ?? .work
            state.verdicts[row.row] = .init(kind: kind, reason: answer.reason)
            guard kind == .work, answer.choice != "new" else { continue }
            state.assignment.rows[row.row] = .init(task: answer.choice, reason: answer.reason)
            if !state.assignment.tasks.contains(where: { $0.ref == answer.choice }) {
                state.assignment.tasks.append(.init(ref: answer.choice, match: "existing", id: answer.choice))
            }
        }

        let missing = input.rows.filter { selected[$0.row] == nil }
        if missing.count == input.rows.count {
            throw PipelineError.incomplete(stage: "판단 모델", missing: missing.map(\.row), calls: state.calls)
        }
        state.input.rows = input.rows.filter { selected[$0.row] != nil }
        return state
    }

    /// 판단을 마친 행만 정리 모델에 보낸다. 새 업무에 제목·목표를 붙인 뒤 기존 요약 단계를 사용한다.
    static func organizeDecisions(_ judgment: JudgeState, llm: any LLMClient) async throws -> JudgeState {
        var state = judgment
        let fresh = state.unassigned
        if !fresh.isEmpty {
            let system = "All rows were already judged to be new work. Group rows that serve the same goal. Give each group a short Korean title and concrete goal. Include every row exactly once."
            let user = ([StagePrompt.rowsHeader] + OntologyPrompt.rowLines(fresh, cards: state.input.cards, timeZone: state.input.timeZone)).joined(separator: "\n")
            let result = try await call("describe", system: system, user: user, tool: nameTool, state: state, llm: llm)
            state.calls.append(record("describe-new", system: system, user: user, result))
            let expected = Set(fresh.map(\.row))
            let tasks = (try? JSONDecoder().decode(NewTasks.self, from: result.arguments))?.tasks ?? []
            let returned = tasks.flatMap(\.rows)
            guard Set(returned) == expected, returned.count == expected.count,
                  tasks.allSatisfy({ !$0.rows.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw PipelineError.incomplete(stage: "새 업무 이름 정리", missing: fresh.map(\.row), calls: state.calls)
            }
            for (index, task) in tasks.enumerated() {
                let ref = "new-\(index + 1)"
                var named = AssignmentPatch.TaskDef(ref: ref, match: "new", title: task.title)
                named.goal = task.goal
                state.assignment.tasks.append(named)
                for id in task.rows { state.assignment.rows[id] = .init(task: ref, reason: state.verdicts[id]?.reason ?? "") }
            }
        }
        if !state.assignedRows.isEmpty { state = try await describe(state, llm) }
        return state
    }
}
