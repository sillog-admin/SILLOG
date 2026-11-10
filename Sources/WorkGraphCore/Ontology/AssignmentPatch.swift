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
        let row: JSONValue = .object(["type": "integer", "description": "ROWS의 행 번호"])
        return ToolSpec(name: functionName,
                        description: "Assign every activity row to the task it belongs to, and describe the work done per task.",
                        parameters: .object([
            "type": "object",
            "properties": .object([
                "tasks": .object(["type": "array", "description": "이번 답에서 쓰는 업무들. rows 와 work 는 ref 로 가리킨다", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "ref": .object(["type": "string", "description": "이 답 안에서만 쓰는 짧은 이름 (A, B, …). \"off\" 는 업무가 아니라 쓰지 않는다"]),
                        "match": .object(["type": "string", "enum": .array(["existing", "new"])]),
                        "id": .object(["type": "string", "description": "match=existing 일 때 OPEN_TASKS 의 id"]),
                        "title": .object(["type": "string", "description": "match=new 일 때: 과목·프로젝트와 만들거나 배우는 것을 담은 짧은 한국어 제목"]),
                        "goal": .object(["type": "string", "description": "match=new 일 때 필수: 이 업무가 무엇을 위한 것인지 한국어 한 문장 (회사·과목·프로젝트, 행사·마감 등 맥락 포함. 예: 애커튼 테크놀로지 면접에서 발표할 직무 PT 준비). 목표를 말할 수 없으면 업무를 만들지 말고 그 행을 off 로. existing 인데 OPEN_TASKS 에 goal 이 없으면 채워도 됨"]),
                        "task_type": .object(["type": "string", "enum": .array(TBox.leafTaskTypes.map { .string($0) })]),
                    ]),
                    "required": .array(["ref", "match"]),
                ])]),
                "rows": .object(["type": "array", "description": "모든 행을 빠짐없이. 연속 행이 같은 업무·같은 resource 값이면 \"5-12\" 처럼 범위로", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "rows": .object(["type": "string", "description": "행 번호 \"7\" 또는 범위 \"5-12\""]),
                        "task": .object(["type": "string", "description": "tasks 의 ref. 어떤 목표에도 기여하지 않는 행(오락, 목적 없는 탐색)은 \"off\". 아무것도 아닌 행(잠금 화면, 앱 전환, 앱 이름이 Sillog 인 기록 앱 창)은 null"]),
                        "resource": .object(["type": "boolean", "description": "이 행의 파일·페이지를 그 업무의 자료로 남길지. true: 읽거나 쓰거나 만든 것, 나중에 다시 찾을 것 (문서, 코드, 노트북, 문서 페이지, 논문, Q&A, 영상, AI 대화). false: 보이기만 한 탭·창, 검색 결과, 빈 탭, 로그인, 스쳐 간 목록·프로필·탐색 페이지, 알림·설정·사용량 페이지, 잠깐 본 채널. 애매하면 false"]),
                        "reason": .object(["type": "string", "description": "이 행이 그 목표에 무엇으로 기여하는지 한국어 몇 단어 (예: 템플릿 문법 확인). 이탈이면 왜 어떤 목표에도 안 쓰이는지, 없음이면 '내용 없음'"]),
                    ]),
                    "required": .array(["rows", "task", "resource", "reason"]),
                ])]),
                "work": .object(["type": "array", "description": "쓰인 업무마다 하나", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "task": .object(["type": "string", "description": "tasks 의 ref"]),
                        "summary": .object(["type": "string", "description": "이 행들에서 그 업무로 한 일, 한국어 한 문장"]),
                        "topics": .object(["type": "array", "items": .object(["type": "string"]), "description": "무엇에 관한 일인지 1~4개 (개념·기술·과목·문제 영역). 앱·사이트·플랫폼·프로젝트 이름과 '기타' 같은 채움말은 아님"]),
                    ]),
                    "required": .array(["task", "summary", "topics"]),
                ])]),
                "problems": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object([
                        "row": row,
                        "kind": .object(["type": "string", "description": "build, runtime, network, config 등"]),
                        "message": .object(["type": "string"]),
                        "resolved_by_row": row,
                    ]),
                    "required": .array(["row", "kind", "message"]),
                ])]),
                "later_items": .object(["type": "array", "items": .object([
                    "type": "object",
                    "properties": .object(["row": row, "text": .object(["type": "string"])]),
                    "required": .array(["row", "text"]),
                ])]),
            ]),
            "required": .array(["tasks", "rows", "work"]),
        ]))
    }
}
