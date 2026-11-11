import Foundation

/// 데모용 가짜 LLM. 실제 모델을 부르지 않고, DemoScenarios 의 활동을 키워드 규칙으로 나눠
/// 진짜 LLM 과 같은 형식(record_activity 인자)의 답을 돌려준다.
/// 용도: LLM 없이 전체 흐름 시연, 통합 테스트. 실제 분류 품질과는 무관하다.
public final class DemoLLM: LLMClient, @unchecked Sendable {
    public let modelName = "demo-llm (규칙 기반 가짜)"

    public init() {}

    struct Row { let number: Int; var text: String; let uri: String }

    struct Profile { let title: String; let type: String; let topics: [String]; let summary: String }

    static let profiles: [String: Profile] = [
        "study": Profile(title: "AI기초수학 3주차 복습", type: "복습", topics: ["선형대수", "고유값 분해"],
                         summary: "3주차 강의 자료와 영상을 보고 고유값 분해를 노트와 Colab 실습으로 정리"),
        "paperwork": Profile(title: "프로젝트 중간보고서 작성", type: "문서작성", topics: ["팀 프로젝트", "중간보고서"],
                             summary: "양식 공지를 확인하고 중간보고서 본문을 작성"),
        "frontend": Profile(title: "대시보드 카드 UI 구현", type: "코드작성", topics: ["React", "shadcn/ui"],
                            summary: "TaskCard 컴포넌트를 구현하고 key prop 경고를 해결"),
        "filter": Profile(title: "대시보드 필터 UI 구현", type: "코드작성", topics: ["React", "shadcn/ui"],
                          summary: "FilterBar 컴포넌트를 shadcn Select 로 구현"),
        "drift": Profile(title: "유튜브 시청", type: "기타", topics: [], summary: "업무와 무관한 영상 시청"),
    ]

    static let keywords: [(task: String, words: [String])] = [
        ("drift", ["플레이리스트"]),
        ("filter", ["filterbar", "components/select"]),
        ("study", ["week3", "eigen", "3주차", "colab", "고유값", "claude.ai"]),
        ("paperwork", ["중간보고서", "lms.example.com", "팀 일정표", "프로젝트 팀방", "mail.google", "gmail"]),
        ("frontend", ["taskcard", "tasklist", "npm run dev", "key prop", "unique key", "stackoverflow", "디자인팀"]),
    ]

    public func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        let (rows, openTasks, mostRecent) = Self.parse(user)
        var assigned: [String?] = rows.map { row in
            let haystack = (row.text + " " + row.uri).lowercased()
            return Self.keywords.first { $0.words.contains { haystack.contains($0) } }?.task
        }
        // shadcn 문서나 localhost 처럼 어느 업무에나 쓰이는 행은 앞(없으면 뒤) 업무를 따라간다.
        // 창 안에 단서가 전혀 없으면 가장 최근에 하던 업무(OPEN_TASKS 첫 줄)를 이어간다.
        let recentKey = mostRecent.flatMap { title in Self.profiles.first { $0.value.title == title }?.key }
        for index in assigned.indices where assigned[index] == nil {
            assigned[index] = index > 0 ? assigned[index - 1] : (assigned.dropFirst(index).compactMap { $0 }.first ?? recentKey)
        }

        // 행마다 정해진 업무를 assign_rows 형식으로. 같은 업무의 연속 행은 범위로 줄인다
        var tasks: [[String: Any]] = [], refByKey: [String: String] = [:]
        func ref(for key: String) -> String {
            if let known = refByKey[key] { return known }
            let profile = Self.profiles[key] ?? Self.profiles["frontend"]!
            let name = "T\(tasks.count + 1)"
            var def: [String: Any] = ["ref": name, "match": "new", "title": profile.title, "task_type": profile.type]
            if let id = openTasks[profile.title] { def = ["ref": name, "match": "existing", "id": id] }
            tasks.append(def); refByKey[key] = name
            return name
        }
        var rowRefs: [[String: Any]] = []
        var start = 0
        while start < rows.count {
            var end = start
            while end + 1 < rows.count, assigned[end + 1] == assigned[start] { end += 1 }
            let key = assigned[start] ?? "frontend"
            rowRefs.append(["rows": start == end ? "\(rows[start].number)" : "\(rows[start].number)-\(rows[end].number)", "task": ref(for: key), "resource": true])
            start = end + 1
        }
        var work: [[String: Any]] = []
        for (key, name) in refByKey {
            let profile = Self.profiles[key] ?? Self.profiles["frontend"]!
            work.append(["task": name, "summary": profile.summary, "topics": profile.topics])
        }
        var problems: [[String: Any]] = []
        if let bad = rows.first(where: { $0.text.contains("LinAlgError") }) {
            var problem: [String: Any] = ["row": bad.number, "kind": "runtime", "message": "LinAlgError: Last 2 dimensions of the array must be square"]
            if let fix = rows.first(where: { $0.number > bad.number && $0.uri.contains("claude.ai") }) { problem["resolved_by_row"] = fix.number }
            problems.append(problem)
        }
        if let bad = rows.first(where: { $0.text.lowercased().contains("npm run dev") || $0.text.lowercased().contains("key\" prop") }) {
            var problem: [String: Any] = ["row": bad.number, "kind": "build", "message": "React key prop warning"]
            if let fix = rows.first(where: { $0.uri.contains("stackoverflow") }) { problem["resolved_by_row"] = fix.number }
            problems.append(problem)
        }
        var later: [[String: Any]] = []
        if let row = rows.first(where: { $0.text.contains("16px") }) { later.append(["row": row.number, "text": "카드 간격 16px로 조정"]) }
        if let row = rows.first(where: { $0.text.contains("구조도") }) { later.append(["row": row.number, "text": "보고서 3장 시스템 구조도 받기 (준호)"]) }

        var payload: [String: Any] = ["tasks": tasks, "rows": rowRefs, "work": work.sorted { ($0["task"] as? String ?? "") < ($1["task"] as? String ?? "") }]
        if !problems.isEmpty { payload["problems"] = problems }
        if !later.isEmpty { payload["later_items"] = later }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return LLMResult(arguments: data, model: modelName, promptTokens: 0, completionTokens: 0,
                         raw: String(data: data, encoding: .utf8) ?? "")
    }

    /// OntologyPrompt 가 만든 user 메시지에서 행과 열린 업무를 다시 읽는다.
    static func parse(_ user: String) -> (rows: [Row], openTasks: [String: String], mostRecent: String?) {
        var rows: [Row] = []
        var openTasks: [String: String] = [:]
        var mostRecent: String?
        var inRows = false
        for line in user.components(separatedBy: "\n") {
            if line.hasPrefix("ROWS") { inRows = true; continue }
            if !inRows {
                guard line.hasPrefix("- id=") else { continue }
                let parts = line.dropFirst(5).components(separatedBy: " | ")
                if parts.count >= 2 {
                    openTasks[parts[1]] = parts[0]
                    if mostRecent == nil { mostRecent = parts[1] }
                }
                continue
            }
            if line.hasPrefix("    text: "), !rows.isEmpty {
                rows[rows.count - 1].text += " " + line.dropFirst(10)
                continue
            }
            let parts = line.components(separatedBy: " | ")
            guard parts.count >= 7, let number = Int(parts[0]) else { continue }
            rows.append(Row(number: number, text: parts[3] + " " + parts[5], uri: parts[6]))
        }
        return (rows, openTasks, mostRecent)
    }
}
