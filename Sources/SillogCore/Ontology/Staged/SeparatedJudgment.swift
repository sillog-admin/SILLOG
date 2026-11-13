import Foundation

/// The judge model picked in settings.
public enum ActivityJudging: Sendable {
    case gpt(any LLMClient)
    case choice(any ChoiceModel)
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
        Choose an existing task ID for the same goal, new for a distinct goal, off for distraction unrelated to work
        or when the record does not show which goal it serves, and none only for a record with no content
        (a system screen, a switch between apps, an empty page). Do not title or describe tasks.
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

    /// Picks a verdict per row. Rows after the first undecided one are left for the next batch.
    /// Raises: `PipelineError.incomplete` when not even the first row was decided, `LLMError` from the GPT judge.
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
            let options = input.openTasks.map { "\($0.id): \(describe($0))" }
            let user = ([OntologyPrompt.nowLine(input.now, timeZone: input.timeZone), "EXISTING GOALS"] + options
                + [StagePrompt.rowsHeader] + OntologyPrompt.rowLines(input.rows, cards: input.cards, timeZone: input.timeZone)).joined(separator: "\n")
            let result = try await call("assign", system: choiceRules, user: user, tool: chooseTool, state: state, llm: client)
            state.calls.append(record("assign", system: choiceRules, user: user, result))
            let output = try? JSONDecoder().decode(Decisions.self, from: result.arguments)
            for (id, answers) in Dictionary(grouping: output?.rows ?? [], by: \.row) where rowIDs.contains(id) && answers.count == 1 {
                let answer = answers[0]
                if ids.contains(answer.choice) || special.contains(answer.choice) { selected[id] = answer }
            }
        case .choice(let client):
            let chunks = stride(from: 0, to: max(input.openTasks.count, 1), by: choiceTaskLimit).map { start in
                Array(input.openTasks.dropFirst(start).prefix(choiceTaskLimit))
            }
            var failure: String?
            await withTaskGroup(of: (Int, Result<String, any Error>).self) { group in
                var queue = input.rows[...]
                func enqueue() {
                    guard failure == nil, let row = queue.popFirst() else { return }
                    group.addTask { (row.row, await chooseRow(row, input: input, chunks: chunks, client: client)) }
                }
                for _ in 0..<choiceConcurrency { enqueue() }
                for await (row, result) in group {
                    switch result {
                    case .success(let choice): selected[row] = .init(row: row, choice: choice, reason: tr("판단 모델"))
                    // Stop sending new rows while the server is failing; keep the message for the batch log.
                    case .failure(let error): failure = failure ?? error.localizedDescription
                    }
                    enqueue()
                }
            }
            if let failure { AppLog.write("판단 모델 호출 실패: \(failure.prefix(200))") }
            let result = selected.values.sorted { $0.row < $1.row }.map { "\($0.row): \($0.choice)" }.joined(separator: "\n")
            state.calls.append(.init(stage: "assign-choice", system: choiceRules, user: "", raw: failure ?? "",
                                     arguments: result + (failure.map { tr("\n판단 모델 호출 실패: \($0)") } ?? ""),
                                     model: client.modelName, promptTokens: 0, completionTokens: 0))
        }

        // Only the leading run of decided rows is applied, so a skipped row never stretches a later row's dwell time.
        let accepted = input.rows.prefix { selected[$0.row] != nil }
        if accepted.isEmpty {
            throw PipelineError.incomplete(stage: "판단 모델", missing: input.rows.map(\.row), calls: state.calls)
        }
        let acceptedIDs = Set(accepted.map(\.row))
        selected = selected.filter { acceptedIDs.contains($0.key) }

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

        state.input.rows = Array(accepted)
        return state
    }

    static let choiceConcurrency = 4
    /// Below this confidence the row is treated as `none` instead of waiting for a better answer forever.
    static let choiceConfidenceFloor = 0.6
    /// Options per question, specials included. Accuracy drops past 20.
    static let choiceMaxOptions = 20
    private static let choiceSpecials = ["new": "Work for a different goal than the listed goals.",
                                         "off": "Distraction unrelated to work, or a record that does not show which goal it serves.",
                                         "none": "No content: a system screen, a switch between apps, or an empty page."]
    private static var choiceTaskLimit: Int { choiceMaxOptions - choiceSpecials.count }
    /// Jev rejects states over 64,000 characters.
    static let choiceStateLimit = 20_000

    /// Asks one row against each chunk of tasks in turn; `new` on an earlier chunk moves on to the next chunk.
    /// Returns: the chosen task ID, `new`, `off` or `none`. Low confidence and refusals become `none`.
    /// Raises: never; transport errors come back as `.failure`.
    private static func chooseRow(_ row: ActivityRow, input: JudgeInput, chunks: [[TaskDigest]], client: any ChoiceModel) async -> Result<String, any Error> {
        let text = choiceState(row, cards: input.cards, now: input.now, timeZone: input.timeZone)
        for (index, tasks) in chunks.enumerated() {
            var options = choiceSpecials
            for task in tasks { options[task.id] = describe(task) }
            do {
                let response = try await client.choose(state: text, questions: ["activity": .init(instructions: choiceRules, options: options)])
                guard let answer = response["activity"], answer.confidence >= choiceConfidenceFloor, options[answer.choice] != nil else { return .success("none") }
                if answer.choice == "new" && index + 1 < chunks.count { continue }
                return .success(answer.choice)
            } catch {
                return .failure(error)
            }
        }
        return .success("new")
    }

    /// Option text: the task title and what it is for, or its latest summary.
    static func describe(_ task: TaskDigest) -> String {
        let title = OntologyPrompt.clip(task.title, 90)
        guard let detail = [task.goal ?? "", task.recentSummaries.first ?? ""].first(where: { !$0.isEmpty }) else { return title }
        return "\(title): \(OntologyPrompt.clip(detail, 140))"
    }

    /// The same row line the organize model sees, with screen cards.
    static func choiceState(_ row: ActivityRow, cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone) -> String {
        let lines = [OntologyPrompt.nowLine(now, timeZone: timeZone), StagePrompt.rowsHeader] + OntologyPrompt.rowLines([row], cards: cards, timeZone: timeZone)
        return String(lines.joined(separator: "\n").prefix(choiceStateLimit))
    }

    /// 판단을 마친 행만 정리 모델에 보낸다. 새 업무에 제목·목표를 붙인 뒤 기존 요약 단계를 사용한다.
    static func organizeDecisions(_ judgment: JudgeState, llm: any LLMClient) async throws -> JudgeState {
        var state = judgment
        let fresh = state.unassigned
        if !fresh.isEmpty {
            let system = "All rows were already judged to be new work. Group rows that serve the same goal. Give each group a short \(L10n.current.promptName) title and concrete goal. Include every row exactly once."
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
