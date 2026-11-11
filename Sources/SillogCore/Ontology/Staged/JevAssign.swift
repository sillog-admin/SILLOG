import Foundation

/// 판단 모델(Jev)이 행 하나에 대해 낸 결정
enum JevPick: Equatable {
    /// 후보 업무 (TaskDigest.id)
    case task(String)
    /// 후보 어느 것도 아닌 새 업무. 이름과 목표는 LLM 이 쓴다
    case new
}

struct JevDecision: Equatable {
    var pick: JevPick
    var confidence: Double
}

/// ② 업무 대입의 "행 → 기존 업무 또는 새 업무" 고르기를 판단 모델(Jev)에게 묻는다.
/// Jev 는 글을 만들지 못하므로 고르기만 맡고, 새 업무의 이름과 목표는 LLM 이 쓴다.
/// 확신이 기준 미만이거나 호출이 실패한 행은 결정 없이 남겨 LLM 판정으로 넘긴다.
/// 보내는 글은 LLM 에 보내는 행 줄과 같은 것뿐이다 (JudgeInput 에 들어온 입력만 쓴다)
enum JevAssign {
    /// 이 확신 이상이면 Jev 의 답을 쓴다
    static let confidenceFloor = 0.6
    /// Jev 에 보내는 글(state)의 최대 글자 수. Jev 는 64,000자를 넘으면 요청을 거절한다
    static let stateLimit = 20_000
    /// 보기 최대 수(새 업무 포함). 20개를 넘으면 정확도가 떨어진다 (ThemeCatalog.limit 와 같은 Jev 선택지 제한)
    static let maxOptions = 20
    /// 새 업무 보기의 이름
    static let newOption = "new"
    /// 배치 기록에 남기는 단계 이름
    static let stage = "assign-jev"
    private static let questionID = "task"

    static let instructions = """
    Which goal does the user's activity row serve? Each option is one of the user's current goals, given as its title and what it is for.
    Judge by what the row's content is used for, not by the app or site. Sub-steps belong to the goal they serve: reading documentation for it, checking or managing the account, subscription or billing of a tool used for it, installing a tool for it, looking at examples or references for it.
    Choose "new" only when the row serves a goal that none of the other options covers.
    """
    static let newDescription = "None of the other options: a different goal (another course, project or deliverable, errand or routine) that is not listed."

    /// 문항: 새 업무 보기 하나와 후보 업무(가장 최근 것부터 보기 한도까지).
    /// truncated 는 보기에 못 넣은 업무가 있는지 (있으면 "새 업무" 답을 믿을 수 없다)
    static func makeQuestion(_ openTasks: [TaskDigest]) -> (question: JevQuestion, candidates: [String], truncated: Bool) {
        let shown = Array(openTasks.prefix(maxOptions - 1))
        var options = [newOption: newDescription]
        for task in shown { options[task.id] = describe(task) }
        return (JevQuestion(instructions: instructions, options: options), shown.map(\.id), openTasks.count > shown.count)
    }

    /// 보기 설명: 제목과 무엇을 위한 업무인지 (없으면 최근에 한 일)
    static func describe(_ task: TaskDigest) -> String {
        let title = OntologyPrompt.clip(task.title, 90)
        guard let detail = [task.goal ?? "", task.recentSummaries.first ?? ""].first(where: { !$0.isEmpty }) else { return title }
        return "\(title): \(OntologyPrompt.clip(detail, 140))"
    }

    /// Jev 에 보내는 글: LLM 에 보내는 것과 같은 행 줄(화면 카드 포함) 하나. 후보 업무는 글이 아니라 보기로 간다
    static func stateText(_ row: ActivityRow, cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone) -> String {
        let lines = [OntologyPrompt.nowLine(now, timeZone: timeZone), StagePrompt.rowsHeader] + OntologyPrompt.rowLines([row], cards: cards, timeZone: timeZone)
        return String(lines.joined(separator: "\n").prefix(stateLimit))
    }

    /// Jev 의 답 하나를 결정으로 바꾼다. 확신이 기준 미만이거나 보기에 없는 답이면 nil (LLM 이 판정한다)
    static func resolve(_ answer: JevChoice?, candidates: [String], truncated: Bool) -> JevDecision? {
        guard let answer, answer.confidence >= confidenceFloor else { return nil }
        if answer.choice == newOption { return truncated ? nil : JevDecision(pick: .new, confidence: answer.confidence) }
        return candidates.contains(answer.choice) ? JevDecision(pick: .task(answer.choice), confidence: answer.confidence) : nil
    }

    /// 행 판정 이유로 남기는 한 줄 (Jev 는 글을 쓰지 못하니 이유 문장 대신 확신을 남긴다)
    static func reason(_ decision: JevDecision) -> String {
        "판단 모델(Jev) 확신 \(String(format: "%.2f", decision.confidence))"
    }

    /// 행마다 Jev 에 묻는다. 확정된 행만 결정으로 돌려주고, 나머지(확신 낮음, 보기에 없는 답, 오류)는 LLM 이 판정한다.
    /// 첫 오류에서 멈추고 남은 행은 묻지 않는다. call 은 배치 기록에 남길 단계 기록 (요청을 한 번도 안 보냈으면 nil)
    static func decide(_ rows: [ActivityRow], openTasks: [TaskDigest], cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone,
                       judge: any JevChoosing) async -> (decisions: [Int: JevDecision], call: StageCall?) {
        let (question, candidates, truncated) = makeQuestion(openTasks)
        var decisions: [Int: JevDecision] = [:]
        var asked: [ActivityRow] = []
        var logged: [String: Any] = [:]
        // ponytail: 행마다 요청 하나를 차례로 보낸다 (행 150개면 150번). 느리거나 요청 한도에 걸리면 행 여러 개를 한 요청에 묶는다
        for row in rows {
            asked.append(row)
            do {
                let answers = try await judge.choose(state: stateText(row, cards: cards, now: now, timeZone: timeZone), questions: [questionID: question])
                guard let answer = answers[questionID] else { logged["\(row.row)"] = NSNull(); continue }
                logged["\(row.row)"] = ["choice": answer.choice, "confidence": answer.confidence] as [String: Any]
                if let decision = resolve(answer, candidates: candidates, truncated: truncated) { decisions[row.row] = decision }
            } catch {
                logged["\(row.row)"] = ["error": (error as? LocalizedError)?.errorDescription ?? "\(error)"]
                AppLog.write("판단 모델 호출 실패, 남은 행은 LLM 이 판정: \(String(describing: error).prefix(200))")
                break
            }
        }
        guard !asked.isEmpty else { return (decisions, nil) }

        var json = "{}"
        if JSONSerialization.isValidJSONObject(logged),
           let data = try? JSONSerialization.data(withJSONObject: logged, options: [.sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) { json = text }
        let sent = ([OntologyPrompt.nowLine(now, timeZone: timeZone), StagePrompt.rowsHeader] + OntologyPrompt.rowLines(asked, cards: cards, timeZone: timeZone)).joined(separator: "\n")
        let listing = question.options.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        let newRows = decisions.values.filter { $0.pick == .new }.count
        AppLog.write("판단 모델: 행 \(asked.count)개 중 \(decisions.count)개 확정 (새 업무 \(newRows)개), 나머지는 LLM 이 판정")
        let call = StageCall(stage: stage, system: "\(question.instructions)\nOPTIONS:\n\(listing)", user: sent, raw: json, arguments: json,
                             model: judge.modelName, promptTokens: 0, completionTokens: 0)
        return (decisions, call)
    }
}
