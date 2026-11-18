import CryptoKit
import Foundation

/// LLM 의 답: 행마다 어느 업무인가. 묶음(배치)은 호출 단위일 뿐이고 판단 단위는 행 하나다.
///   tasks — 이번 답에서 쓰는 업무들 (기존 id 또는 새 업무 정의), ref 로 가리킨다
///   rows  — 행(또는 같은 업무·같은 자료 여부인 연속 행 범위 "5-12") → 업무 ref. null 이면 일이 아닌 행
///   work  — 업무별로 이 행들에서 한 일 한 문장과 주제
///   problems / later_items — 행 번호로 가리킨다
public struct AssignmentPatch: Codable, Equatable, Sendable {
    public struct TaskDef: Codable, Equatable, Sendable {
        public var ref: String
        /// existing | new
        public var match: String
        public var id: String?
        public var title: String?
        /// 이 업무가 무엇을 위한 것인지 한 문장 (회사·과목·프로젝트, 마감·상대 등 맥락 포함)
        public var goal: String?
        public var taskType: String?

        enum CodingKeys: String, CodingKey { case ref, match, id, title, goal, taskType = "task_type" }

        public init(ref: String, match: String, id: String? = nil, title: String? = nil, taskType: String? = nil) {
            self.ref = ref; self.match = match; self.id = id; self.title = title; self.taskType = taskType
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = (try? c.lenientString(.ref)) ?? ""
            match = (try? c.decodeIfPresent(String.self, forKey: .match)) ?? (((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) == nil ? "new" : "existing")
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            goal = try? c.decodeIfPresent(String.self, forKey: .goal)
            taskType = try? c.decodeIfPresent(String.self, forKey: .taskType)
        }
    }

    public struct RowRef: Codable, Equatable, Sendable {
        /// "7" 또는 "5-12"
        public var rows: String
        public var task: String?
        /// false 면 파일·페이지가 보이기만 했음
        public var resource: Bool?
        /// 이 행이 그 목표에 무엇으로 기여하는지 (한 구절). 이탈이면 왜 어떤 목표에도 안 쓰이는지
        public var reason: String?

        public init(rows: String, task: String?, resource: Bool? = nil, reason: String? = nil) { self.rows = rows; self.task = task; self.resource = resource; self.reason = reason }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rows = (try? c.lenientString(.rows)) ?? ""
            task = try? c.lenientString(.task)
            resource = try? c.decodeIfPresent(Bool.self, forKey: .resource)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        }

        /// 범위를 행 번호 목록으로
        public var numbers: [Int] {
            let text = rows.trimmingCharacters(in: .whitespaces)
            let parts = text.split(whereSeparator: { $0 == "-" || $0 == "~" || $0 == "–" }).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let low = parts[0], let high = parts[1], low <= high, high - low < 10_000 { return Array(low...high) }
            if parts.count == 1, let one = parts[0] { return [one] }
            return []
        }
    }

    public struct Work: Codable, Equatable, Sendable {
        public var task: String
        public var summary: String
        public var topics: [String]

        public init(task: String, summary: String, topics: [String]) { self.task = task; self.summary = summary; self.topics = topics }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            task = (try? c.lenientString(.task)) ?? ""
            summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            topics = (try? c.decodeIfPresent([String].self, forKey: .topics)) ?? []
        }
    }

    public struct ProblemRef: Codable, Equatable, Sendable {
        public var row: Int
        public var kind: String
        public var message: String
        public var resolvedByRow: Int?

        enum CodingKeys: String, CodingKey { case row, kind, message, resolvedByRow = "resolved_by_row" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            row = try c.lenientInt(.row) ?? 0
            kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "error"
            message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
            resolvedByRow = try c.lenientInt(.resolvedByRow)
        }
    }

    public struct LaterRef: Codable, Equatable, Sendable {
        public var row: Int
        public var text: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            row = try c.lenientInt(.row) ?? 0
            text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        }
    }

    public var tasks: [TaskDef]
    public var rows: [RowRef]
    public var work: [Work]
    public var problems: [ProblemRef]?
    public var laterItems: [LaterRef]?

    enum CodingKeys: String, CodingKey { case tasks, rows, work, problems, laterItems = "later_items" }

    public init(tasks: [TaskDef], rows: [RowRef], work: [Work], problems: [ProblemRef]? = nil, laterItems: [LaterRef]? = nil) {
        self.tasks = tasks; self.rows = rows; self.work = work; self.problems = problems; self.laterItems = laterItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try? c.decodeIfPresent([TaskDef].self, forKey: .tasks)) ?? []
        rows = (try? c.decodeIfPresent([RowRef].self, forKey: .rows)) ?? []
        work = (try? c.decodeIfPresent([Work].self, forKey: .work)) ?? []
        problems = try? c.decodeIfPresent([ProblemRef].self, forKey: .problems)
        laterItems = try? c.decodeIfPresent([LaterRef].self, forKey: .laterItems)
    }

    /// 이탈(어떤 목표에도 기여하지 않음)을 뜻하는 task 값
    public static let offTask = "off"

    /// 행 번호 → (업무 ref 또는 "off", 자료 여부: nil 이면 LLM 이 안 정한 것, 이유). 같은 행이 두 번 나오면 뒤의 것
    public func byRow() -> [Int: (task: String?, resource: Bool?, reason: String?)] {
        var result: [Int: (task: String?, resource: Bool?, reason: String?)] = [:]
        for ref in rows {
            let raw = ref.task?.trimmingCharacters(in: .whitespaces) ?? ""
            let task: String? = raw.isEmpty || raw.lowercased() == "null" ? nil : (raw.lowercased() == Self.offTask ? Self.offTask : raw)
            let reason = ref.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            for number in ref.numbers { result[number] = (task, ref.resource, (reason?.isEmpty ?? true) ? nil : reason) }
        }
        return result
    }

    /// 사람이 읽는 용도의 JSON (들여쓰기, 키 정렬, 한글 그대로).
    public var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 작은 모델의 흔들림을 바로잡고 디코딩한다: 중첩 값을 JSON 문자열로 감싼 경우, rows 가 숫자인 경우
    public static func decodeLenient(from data: Data) -> AssignmentPatch? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let root = unwrapStrings(parsed)
        guard JSONSerialization.isValidJSONObject(root), let normalized = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return try? JSONDecoder().decode(AssignmentPatch.self, from: normalized)
    }

    static func unwrapStrings(_ value: Any) -> Any {
        if let dict = value as? [String: Any] { return dict.mapValues(unwrapStrings) }
        if let list = value as? [Any] { return list.map(unwrapStrings) }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmed.first, first == "{" || first == "[", let data = trimmed.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: data) {
                return unwrapStrings(inner)
            }
        }
        return value
    }
}

extension KeyedDecodingContainer {
    /// 3, 3.0, "3" 모두 3 으로 읽는다.
    func lenientInt(_ key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// "A", 3, 3.0 모두 문자열로
    func lenientString(_ key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(Int(value)) }
        return nil
    }
}

enum StableHash {
    /// 키로 쓰는 짧은 결정적 해시 (SHA256 앞 8자리).
    static func short(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AssignmentSchema {
    public static let functionName = "assign_rows"

    public static var tool: ToolSpec {
        let row: JSONValue = .object(["type": "integer", "description": "Row number from ROWS"])
        return ToolSpec(name: functionName,
                        description: "Assign every activity row to the task it belongs to, and describe the work done per task.",
                        parameters: .object([
            "type": "object",
            "properties": .object([
                "tasks": .object(["type": "array", "description": "The tasks used in this answer. rows and work refer to them by ref", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "ref": .object(["type": "string", "description": "A short name used only within this answer (A, B, …). \"off\" is not a task, so do not use it as one"]),
                        "match": .object(["type": "string", "enum": .array(["existing", "new"])]),
                        "id": .object(["type": "string", "description": "When match=existing: the id from OPEN_TASKS"]),
                        "title": .object(["type": "string", "description": .string("When match=new: a short \(L10n.current.promptName) title that names the course or project and what is being made or learned")]),
                        "goal": .object(["type": "string", "description": .string("Required when match=new: one \(L10n.current.promptName) sentence saying what this task is for, with its context, such as the company, course or project, event or deadline (e.g. 애커튼 테크놀로지 면접에서 발표할 직무 PT 준비). If no goal can be named, do not create the task; mark the row off. For an existing task whose OPEN_TASKS entry has no goal, you may fill it in")]),
                        "task_type": .object(["type": "string", "enum": .array(TBox.leafTaskTypes.map { .string($0) })]),
                    ]),
                    "required": .array(["ref", "match"]),
                ])]),
                "rows": .object(["type": "array", "description": "Every row, none left out. Consecutive rows with the same task and the same resource value go in one range like \"5-12\"", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "rows": .object(["type": "string", "description": "A row number \"7\" or a range \"5-12\""]),
                        "task": .object(["type": "string", "description": "A ref from tasks. \"off\" for a row that contributes to no goal (entertainment, aimless browsing). null for a row that is nothing (a lock screen, an app switch, the recorder app's own window, whose app name is SILLOG, or Sillog in older records)"]),
                        "resource": .object(["type": "boolean", "description": "Whether to keep this row's file or page as a resource of that task. true: something read, written or made; something to find again later (a document, code, notebook, docs page, paper, Q&A, video, AI chat). false: a tab or window that was only visible, search results, a blank tab, sign-in, listing, profile or navigation pages passed through, notification, settings or usage pages, a channel glanced at briefly. When unsure, false"]),
                        "reason": .object(["type": "string", "description": .string("A few \(L10n.current.promptName) words on what this row contributes to that goal (e.g. 템플릿 문법 확인). If off, why it serves no goal; if null, '\(tr("내용 없음"))'")]),
                    ]),
                    "required": .array(["rows", "task", "resource", "reason"]),
                ])]),
                "work": .object(["type": "array", "description": "One per task used", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "task": .object(["type": "string", "description": "A ref from tasks"]),
                        "summary": .object(["type": "string", "description": .string("What was done for that task in these rows, in one \(L10n.current.promptName) sentence")]),
                        "topics": .object(["type": "array", "items": .object(["type": "string"]), "description": .string("1-4 \(L10n.current.promptName) topics saying what the work is about (concepts, technologies, course subjects, problem domains; technology names in their original spelling). Not app, site, platform or project names, and no filler like '기타'")]),
                    ]),
                    "required": .array(["task", "summary", "topics"]),
                ])]),
                "problems": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "row": row,
                        "kind": .object(["type": "string", "description": "build, runtime, network, config, etc."]),
                        "message": .object(["type": "string", "description": .string("What failed or got stuck, in one \(L10n.current.promptName) sentence")]),
                        "resolved_by_row": row,
                    ]),
                    "required": .array(["row", "kind", "message"]),
                ])]),
                "later_items": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": row, "text": .object(["type": "string", "description": .string("A request or todo that was not handled, in one \(L10n.current.promptName) sentence")])]),
                    "required": .array(["row", "text"]),
                ])]),
            ]),
            "required": .array(["tasks", "rows", "work"]),
        ]))
    }
}
