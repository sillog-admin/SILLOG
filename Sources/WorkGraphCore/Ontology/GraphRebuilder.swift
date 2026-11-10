import Foundation
import GRDB

/// LLM 없이 그래프의 시간 층(세션·앱·자료·흐름·프로젝트)을 행 판단(observations.task_id)에서 다시 만든다.
/// 업무·주제·문제·나중에 할 일 노드는 그대로 둔다. 세션 규칙을 바꿨을 때 쓴다.
/// 원문을 정리한 기간(sealed_until 까지)의 세션은 다시 만들 수 없으므로 지우지 않고, 업무 시간은 사용 시간 기록에서 채운다
public struct GraphRebuilder {
    public struct Stats: Equatable, Sendable {
        public var batches = 0, rows = 0, tasks = 0, sessions = 0, resources = 0
        public init() {}
    }

    let db: WGDatabase
    let store: EventStore
    let config: BatchConfig
    let home: String
    let fileExists: (String) -> Bool
    let calendar: PeriodCalendar

    public init(db: WGDatabase, store: EventStore, config: BatchConfig = BatchConfig(), home: String = NSHomeDirectory(),
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }, calendar: PeriodCalendar = PeriodCalendar()) {
        self.db = db; self.store = store; self.config = config; self.home = home; self.fileExists = fileExists; self.calendar = calendar
    }

    /// 이 시각 전에 시작한 세션은 원문이 정리된 기간이라 지우지 않는다
    static func sealBoundary(_ conn: Database, calendar: PeriodCalendar) throws -> Double {
        guard let day = try ConsolidationStore.value(ConsolidationStore.Key.sealedUntil, conn) else { return 0 }
        return calendar.dayEnd(day) ?? 0
    }

    public func rebuildFromAssignments(now: Double) throws -> Stats {
        var stats = Stats()
        let tally = ActivityTally(config: config, home: home, fileExists: fileExists)
        let ledger = LedgerBuilder(tally: tally, calendar: calendar)

        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let boundary = try Self.sealBoundary(conn, calendar: calendar)
            // 1. 시간 층을 지운다: 봉인 뒤 세션과 거기 닿은 엣지, 업무 → 프로젝트
            let unsealed = "SELECT id FROM nodes WHERE label = 'Session' AND COALESCE(json_extract(props, '$.start'), created_at) >= ?"
            try conn.execute(sql: "DELETE FROM edges WHERE src IN (\(unsealed)) OR dst IN (\(unsealed))", arguments: [boundary, boundary])
            try conn.execute(sql: "DELETE FROM nodes WHERE id IN (\(unsealed))", arguments: [boundary])
            try conn.execute(sql: "DELETE FROM edges WHERE type = 'ON'")
            for task in try tx.nodes(label: NodeLabel.task) {
                try conn.execute(sql: "UPDATE nodes SET props = json_set(json_remove(props, '$.project_seconds'), '$.active_seconds', 0) WHERE id = ?", arguments: [task.id])
            }

            // 2. 봉인 뒤 배치만 시간순으로 행을 다시 만들고 세션을 계산한다 (다시 판정한 배치는 그 행들의 시각에 놓인다)
            var taskIds = Set<Int64>()
            var sessionStats = SessionBuilder.Stats()
            for window in try tally.windows(conn, startingAt: boundary, loadBatches: true) {
                let summaries = window.batch.map { Self.summaries(from: $0, tx: tx) } ?? [:]
                try SessionBuilder().apply(window.assignments, summaries: summaries, tx: tx, stats: &sessionStats)
                taskIds.formUnion(window.assignments.compactMap(\.taskId))
                stats.batches += 1; stats.rows += window.assignments.count
            }
            // 업무 시간: 사용 시간 기록의 합계 (동결된 날 + 원문이 남은 날). 세션을 만든 계산과 같은 계산이라 세션 합과 같다
            var idOfKey: [String: Int64] = [:]
            for task in try tx.nodes(label: NodeLabel.task) { idOfKey[task.key] = task.id }
            for (key, total) in try ledger.taskTotals(conn, now: now) {
                guard let taskId = idOfKey[key] else { continue }
                var props: [String: JSONValue] = ["active_seconds": .number(total.seconds), "last_active": .number(total.lastAt > 0 ? total.lastAt : now)]
                if !total.projects.isEmpty { props["project_seconds"] = .object(total.projects.mapValues { .number($0) }) }
                try tx.setProps(nodeId: taskId, props, at: total.lastAt > 0 ? total.lastAt : now)
            }
            // 3. 문제·파일을 시간으로 세션에 다시 잇는다
            for problem in try tx.nodes(label: NodeLabel.problem) {
                let at = problem.props["at"]?.doubleValue ?? problem.createdAt
                if let session = try tx.latestSession(startedBefore: at + 1, excluding: nil) {
                    try tx.upsertEdge(src: session.id, dst: problem.id, type: EdgeType.hit, props: [:], addWeight: 0, at: at)
                }
            }
            try tx.rebindProjects(at: now)
            try tx.pruneOrphanResources()                                   // 이제 아무 세션도 안 만지는 자료는 뺀다
            stats.tasks = taskIds.count; stats.sessions = sessionStats.sessions; stats.resources = sessionStats.resources
        }
        return stats
    }

    /// 배치가 저장한 LLM 답(work)에서 업무별 요약을 되찾는다
    static func summaries(from batch: BatchRecord, tx: GraphTx) -> [Int64: String] {
        guard let raw = batch.llmPatch, let patch = AssignmentPatch.decodeLenient(from: Data(raw.utf8)) else { return [:] }
        var byRef: [String: Int64] = [:]
        for def in patch.tasks {
            if let id = def.id, let node = try? tx.node(label: NodeLabel.task, key: id) { byRef[def.ref] = node.id; continue }
            if let title = def.title {
                let wanted = AssignmentApplier.normalizeTitle(title).lowercased()
                if let node = try? tx.nodes(label: NodeLabel.task).first(where: { AssignmentApplier.normalizeTitle($0.title).lowercased() == wanted }) { byRef[def.ref] = node.id }
            }
        }
        var result: [Int64: String] = [:]
        for work in patch.work { if let id = byRef[work.task], !work.summary.isEmpty { result[id] = work.summary } }
        return result
    }
}
