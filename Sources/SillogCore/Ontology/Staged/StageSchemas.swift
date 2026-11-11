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
    static let rowRange: JSONValue = .object(["type": "string", "description": "행 번호 \"7\" 또는 범위 \"5-12\""])
    static let rowNumber: JSONValue = .object(["type": "integer", "description": "행 번호"])

    public static var classify: ToolSpec {
        ToolSpec(name: "classify_rows", description: "For every activity row: work toward a goal, off-task, or no content.", parameters: .object([
            "type": "object",
            "properties": .object(["rows": .object(["type": "array", "description": "모든 행을 빠짐없이. 연속 행이 같은 판정·같은 이유면 \"5-12\" 처럼 범위로", "items": .object([
                "type": "object",
                "properties": .object([
                    "rows": rowRange,
                    "kind": .object(["type": "string", "enum": .array(["work", "off", "none"])]),
                    "reason": .object(["type": "string", "description": "한국어 몇 단어: 업무면 무엇에 쓰였는지, 업무 외면 왜 어떤 목표에도 안 쓰이는지, 없음이면 '내용 없음'"]),
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
                "tasks": .object(["type": "array", "description": "이번 답에서 쓰는 업무들. rows 는 ref 로 가리킨다", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "ref": .object(["type": "string", "description": "이 답 안에서만 쓰는 짧은 이름 (A, B, …). \"off\" 는 쓰지 않는다"]),
                        "match": .object(["type": "string", "enum": .array(["existing", "new"])]),
                        "id": .object(["type": "string", "description": "match=existing 일 때 OPEN_TASKS 의 id"]),
                        "title": .object(["type": "string", "description": "match=new 일 때: 과목·프로젝트와 목표를 담은 짧은 한국어 제목"]),
                        "goal": .object(["type": "string", "description": "match=new 일 때 필수: 무엇을 위한 업무인지 한국어 한 문장 (회사·과목·프로젝트, 행사·마감 등 맥락 포함)"]),
                    ]),
                    "required": .array(["ref", "match"]),
                ])]),
                "rows": .object(["type": "array", "description": "받은 행을 빠짐없이", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "rows": rowRange,
                        "task": .object(["type": "string", "description": "tasks 의 ref, 또는 어느 목표에도 안 맞으면 \"off\""]),
                        "reason": .object(["type": "string", "description": "이 행이 그 목표에 무엇으로 기여하는지 한국어 몇 단어"]),
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
                "resources": .object(["type": "array", "description": "모든 행을 빠짐없이", "items": .object([
                    "type": "object",
                    "properties": .object(["rows": rowRange, "resource": .object(["type": "boolean"])]),
                    "required": .array(["rows", "resource"]),
                ])]),
                "work": .object(["type": "array", "description": "업무마다 하나", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "task": .object(["type": "string", "description": "TASKS 의 ref"]),
                        "summary": .object(["type": "string", "description": "이 행들에서 사용자가 한 일. 구체적인 대상(파일·문서 부분·페이지)과 행이 보여 주는 동사(작성·수정·제출은 근거가 보일 때만)로 쓴 한국어 한 문장, 100자 이내"]),
                        "topics": .object(["type": "array", "items": .object(["type": "string"]), "description": "무엇에 관한 일인지 1~4개 (개념·기술·과목·문제 영역). 앱·사이트·플랫폼·프로젝트 이름과 채움말은 아님"]),
                        "task_type": .object(["type": "string", "enum": .array(TBox.leafTaskTypes.map { .string($0) }), "description": "NEW 업무일 때 필수"]),
                    ]),
                    "required": .array(["task", "summary", "topics"]),
                ])]),
                "problems": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": rowNumber, "kind": .object(["type": "string", "description": "build, runtime, network, config 등"]),
                                           "message": .object(["type": "string"]), "resolved_by_row": rowNumber]),
                    "required": .array(["row", "kind", "message"]),
                ])]),
                "later_items": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": rowNumber, "text": .object(["type": "string"])]),
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
