import Foundation

/// ① 업무 여부의 판정
public enum RowKind: String, Sendable { case work, off, none }

public struct RowVerdict: Equatable, Sendable {
    public var kind: RowKind
    public var reason: String
    public init(kind: RowKind, reason: String) { self.kind = kind; self.reason = reason }
}

/// ② 업무 대입: 행 → 업무 ref 또는 "off"
public struct TaskChoice: Equatable, Sendable {
    public var task: String
    public var reason: String
    public init(task: String, reason: String) { self.task = task; self.reason = reason }
}

public struct AssignResult: Equatable, Sendable {
    public var tasks: [AssignmentPatch.TaskDef] = []
    public var rows: [Int: TaskChoice] = [:]
    public init() {}
}

/// ③ 클래스 부여: 자료 여부, 업무별 요약·주제, 새 업무의 종류, 문제, 나중에 할 일
public struct DescribeResult: Equatable, Sendable {
    public var resources: [Int: Bool] = [:]
    public var work: [AssignmentPatch.Work] = []
    public var taskTypes: [String: String] = [:]
    public var problems: [AssignmentPatch.ProblemRef] = []
    public var laterItems: [AssignmentPatch.LaterRef] = []
    public init() {}
}

/// 세 단계의 도구 정의
public enum StageTool {
    static let rowRange: JSONValue = .object(["type": "string", "description": "Row number \"7\" or range \"5-12\""])
    static let rowNumber: JSONValue = .object(["type": "integer", "description": "Row number"])

    public static var classify: ToolSpec {
        ToolSpec(name: "classify_rows", description: "For every activity row: work toward a goal, off-task, or no content.", parameters: .object([
            "type": "object",
            "properties": .object(["rows": .object(["type": "array", "description": "Every row, none left out. When consecutive rows have the same kind and the same reason, use a range like \"5-12\"", "items": .object([
                "type": "object",
                "properties": .object([
                    "rows": rowRange,
                    "kind": .object(["type": "string", "enum": .array(["work", "off", "none"])]),
                    "reason": .object(["type": "string", "description": .string("A few \(L10n.current.promptName) words: for work, what it was used for; for off, why it serves no goal; for none, '\(tr("내용 없음"))'")]),
                ]),
                "required": .array(["rows", "kind", "reason"]),
            ])])]),
            "required": .array(["rows"]),
        ]))
    }

    public static var assign: ToolSpec {
        ToolSpec(name: "assign_tasks", description: "Assign every work row to the goal (task) it serves.", parameters: .object([
            "type": "object",
            "properties": .object([
                "tasks": .object(["type": "array", "description": "The tasks used in this answer. rows refer to them by ref", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "ref": .object(["type": "string", "description": "A short name used only within this answer (A, B, …). Do not use \"off\""]),
                        "match": .object(["type": "string", "enum": .array(["existing", "new"])]),
                        "id": .object(["type": "string", "description": "When match=existing: the id from OPEN_TASKS"]),
                        "title": .object(["type": "string", "description": .string("When match=new: a short \(L10n.current.promptName) title naming the course/project and the goal")]),
                        "goal": .object(["type": "string", "description": .string("Required when match=new: one \(L10n.current.promptName) sentence on what the task is for (with its context: company, course, project, event, deadline, etc.)")]),
                    ]),
                    "required": .array(["ref", "match"]),
                ])]),
                "rows": .object(["type": "array", "description": "Every row you received, none left out", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "rows": rowRange,
                        "task": .object(["type": "string", "description": "A ref from tasks, or \"off\" when the row fits no goal"]),
                        "reason": .object(["type": "string", "description": .string("A few \(L10n.current.promptName) words on what this row contributes to that goal")]),
                    ]),
                    "required": .array(["rows", "task", "reason"]),
                ])]),
            ]),
            "required": .array(["tasks", "rows"]),
        ]))
    }

    public static var describe: ToolSpec {
        ToolSpec(name: "describe_work", description: "Mark resources and describe the work done per task.", parameters: .object([
            "type": "object",
            "properties": .object([
                "resources": .object(["type": "array", "description": "Every row, none left out", "items": .object([
                    "type": "object",
                    "properties": .object(["rows": rowRange, "resource": .object(["type": "boolean"])]),
                    "required": .array(["rows", "resource"]),
                ])]),
                "work": .object(["type": "array", "description": "One per task", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "task": .object(["type": "string", "description": "A ref from TASKS"]),
                        "summary": .object(["type": "string", "description": .string("What the user did in these rows. One \(L10n.current.promptName) sentence of at most 100 characters, written with the specific object (file, document section, page) and the verb the rows show (wrote, edited or submitted only when the evidence shows it)")]),
                        "topics": .object(["type": "array", "items": .object(["type": "string"]), "description": .string("1-4 \(L10n.current.promptName) topics on what the work is about (concepts, technologies, course subjects, problem domains; technology names keep their original spelling). Not app, site, platform or project names, and no filler")]),
                        "task_type": .object(["type": "string", "enum": .array(TBox.leafTaskTypes.map { .string($0) }), "description": "Required for a NEW task"]),
                    ]),
                    "required": .array(["task", "summary", "topics"]),
                ])]),
                "problems": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": rowNumber, "kind": .object(["type": "string", "description": "build, runtime, network, config, etc."]),
                                           "message": .object(["type": "string", "description": .string("What failed or got stuck, in one \(L10n.current.promptName) sentence")]), "resolved_by_row": rowNumber]),
                    "required": .array(["row", "kind", "message"]),
                ])]),
                "later_items": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": rowNumber, "text": .object(["type": "string", "description": .string("A request or todo that was not handled, one \(L10n.current.promptName) sentence")])]),
                    "required": .array(["row", "text"]),
                ])]),
            ]),
            "required": .array(["resources", "work"]),
        ]))
    }
}

/// 단계 응답 해석. 작은 모델의 흔들림(중첩 JSON 문자열, 숫자 행 번호, 대소문자)을 받아 준다
public enum StageDecode {
    static func object(_ data: Data) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return AssignmentPatch.unwrapStrings(parsed) as? [String: Any]
    }

    /// 행 번호: 7, "7", "5-12", 그리고 늘어놓은 목록 ("1, 3, 5-7", "1 3", [5, "6-7"]). 받지 않은 행은 단계 쪽에서 거른다
    static func numbers(_ value: Any?) -> [Int] {
        if let number = value as? Int { return [number] }
        if let list = value as? [Any] { return list.flatMap { numbers($0) } }
        guard let text = value as? String else { return [] }
        var result: [Int] = []
        for part in text.split(separator: ",") {
            let parsed = AssignmentPatch.RowRef(rows: String(part), task: nil).numbers
            if !parsed.isEmpty { result += parsed; continue }
            for word in part.split(whereSeparator: \.isWhitespace) { result += AssignmentPatch.RowRef(rows: String(word), task: nil).numbers }
        }
        return result
    }

    static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? Int { return String(number) }
        return nil
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func classify(_ data: Data) -> [Int: RowVerdict] {
        var result: [Int: RowVerdict] = [:]
        for entry in object(data)?["rows"] as? [[String: Any]] ?? [] {
            guard let raw = text(entry["kind"])?.lowercased(), let kind = RowKind(rawValue: raw) else { continue }
            let reason = text(entry["reason"]) ?? ""
            for number in numbers(entry["rows"]) { result[number] = RowVerdict(kind: kind, reason: reason) }
        }
        return result
    }

    public static func assign(_ data: Data) -> AssignResult {
        var result = AssignResult()
        guard let root = object(data) else { return result }
        result.tasks = decode([AssignmentPatch.TaskDef].self, root["tasks"]) ?? []
        for entry in root["rows"] as? [[String: Any]] ?? [] {
            let task = text(entry["task"]) ?? ""
            // 업무 없음(null·빈 값·"none")은 어느 목표에도 안 맞는다는 답이라 업무 외로 본다
            let noGoal = task.isEmpty || ["null", "none", AssignmentPatch.offTask].contains(task.lowercased())
            let choice = TaskChoice(task: noGoal ? AssignmentPatch.offTask : task, reason: text(entry["reason"]) ?? "")
            for number in numbers(entry["rows"]) { result.rows[number] = choice }
        }
        return result
    }

    public static func describe(_ data: Data) -> DescribeResult {
        var result = DescribeResult()
        guard let root = object(data) else { return result }
        for entry in root["resources"] as? [[String: Any]] ?? [] {
            guard let flag = entry["resource"] as? Bool else { continue }
            for number in numbers(entry["rows"]) { result.resources[number] = flag }
        }
        for entry in root["work"] as? [[String: Any]] ?? [] {
            guard let task = text(entry["task"]), !task.isEmpty else { continue }
            result.work.append(AssignmentPatch.Work(task: task, summary: text(entry["summary"]) ?? "", topics: entry["topics"] as? [String] ?? []))
            if let type = text(entry["task_type"]), !type.isEmpty { result.taskTypes[task] = type }
        }
        result.problems = decode([AssignmentPatch.ProblemRef].self, root["problems"]) ?? []
        result.laterItems = decode([AssignmentPatch.LaterRef].self, root["later_items"]) ?? []
        return result
    }
}
