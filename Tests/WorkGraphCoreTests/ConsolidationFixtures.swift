import XCTest
import GRDB
@testable import WorkGraphCore

/// 정리 단계(assign_rows)에서는 받은 행을 전부 한 업무로 배정하고(title 이 nil 이면 업무 외),
/// 다이제스트(write_digest)에는 digest 가 정한 답을 돌려주는 가짜 LLM
final class AllRowsLLM: LLMClient, @unchecked Sendable {
    let modelName = "all-rows"
    private let lock = NSLock()
    private let title: String?
    var digest: (@Sendable (String) -> Result<String, LLMError>)?
    private(set) var digestCalls = 0

    init(title: String?, digest: (@Sendable (String) -> Result<String, LLMError>)? = nil) {
        self.title = title; self.digest = digest
    }

    func callFunction(system: String, user: String, tool: ToolSpec) async throws -> LLMResult {
        if tool.name == "write_digest" {
            let answer: Result<String, LLMError> = lock.withLock {
                digestCalls += 1
                return digest?(user) ?? .failure(.transport("다이제스트 답 없음"))
            }
            let json = try answer.get()
            return LLMResult(arguments: Data(json.utf8), model: modelName, promptTokens: 10, completionTokens: 10, raw: json)
        }
        let regex = try NSRegularExpression(pattern: #"(?m)^(\d+) \| \d{2}:\d{2}-"#)
        let numbers = regex.matches(in: user, range: NSRange(user.startIndex..., in: user)).compactMap { match in
            Range(match.range(at: 1), in: user).flatMap { Int(user[$0]) }
        }
        let last = numbers.max() ?? 1
        let json: String
        if let title {
            json = """
            {"tasks":[{"ref":"A","match":"new","title":"\(title)","task_type":"코드작성"}],"rows":[{"rows":"1-\(last)","task":"A","resource":true}],
             "work":[{"task":"A","summary":"\(title) 3장 초안 작성","topics":["테스트"]}]}
            """
        } else {
            json = #"{"tasks":[],"rows":[{"rows":"1-\#(last)","task":"off"}],"work":[]}"#
        }
        return LLMResult(arguments: Data(json.utf8), model: modelName, promptTokens: 10, completionTokens: 10, raw: json)
    }
}

enum ConsolidationFixtures {
    static let zone = TimeZone(identifier: "Asia/Seoul")!
    static let calendar = PeriodCalendar(timeZone: zone)
    static let home = "/Users/me"

    static func at(_ day: String, _ hour: Double, _ minute: Double = 0) -> Double {
        calendar.dayStart(day)! + hour * 3600 + minute * 60
    }

    static var tally: ActivityTally { ActivityTally(home: home, fileExists: { _ in false }) }
    static var ledger: LedgerBuilder { LedgerBuilder(tally: tally, calendar: calendar) }

    static func makeDB() throws -> WGDatabase {
        let db = try WGDatabase.inMemory()
        try db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        return db
    }

    static func makeFileDB() throws -> WGDatabase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sillog-test-\(UUID().uuidString)", isDirectory: true)
        let db = try WGDatabase(path: directory.appendingPathComponent("workgraph.sqlite").path)
        try db.writer.write { try TBox.seed(GraphTx($0), at: 0) }
        return db
    }

    static func consolidator(_ db: WGDatabase, llm: (any LLMClient)? = nil, clock: TestClock) -> Consolidator {
        Consolidator(db: db, llm: llm, ledger: ledger, clock: { clock.now })
    }

    /// minutes 분 동안 1분마다 같은 창을 본 기록을 넣고, 배치로 정리해 task 업무(nil 이면 업무 외)에 배정한다
    @discardableResult
    static func work(_ db: WGDatabase, task: String?, day: String, hour: Double, minute: Double = 0, minutes: Int,
                     app: String = "Cursor", window: String? = nil, url: String? = nil, text: String? = nil) async throws -> [Int64] {
        let store = EventStore(db)
        let start = at(day, hour, minute)
        let textId = try text.map { try store.upsertText($0, source: "ax", at: start) }
        var ids: [Int64] = []
        for step in 0..<minutes {
            var observation = Observation(ts: start + Double(step) * 60, trigger: "periodic", appBundle: "com.test.\(app)", appName: app,
                                          windowTitle: window ?? "\(task ?? "영상") 화면", url: url)
            observation.textId = textId
            ids.append(try store.insert(observation))
        }
        let clock = TestClock(start + Double(minutes) * 60 + 3600)
        let batcher = OntologyBatcher(db: db, llm: AllRowsLLM(title: task), config: .singleCall, home: home, fileExists: { _ in false }, clock: { clock.now })
        for _ in 0..<50 {
            guard case .ok = await batcher.runIfDue(force: true) else { break }
        }
        return ids
    }

    /// 다이제스트로 받아들여질 서술 (입력에 있는 앵커만 쓴다)
    static func groundedDigestJSON(taskKey: String) -> String {
        """
        {"summary":"이번 주에는 보고서 초안 작업을 이어 갔다.","progress":[{"text":"보고서 초안을 작성했다.","status":"in_progress","anchors":["\(taskKey)"]}],
         "problems":[],"open_items":[],"decisions":[],"numbers_used":[]}
        """
    }

    static func taskKey(_ db: WGDatabase, title: String) throws -> String {
        try db.writer.read { try String.fetchOne($0, sql: "SELECT key FROM nodes WHERE label = 'Task' AND title = ?", arguments: [title]) } ?? ""
    }
}
