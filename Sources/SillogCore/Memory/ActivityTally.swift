import Foundation
import GRDB

/// 행 판단이 기록된 관측을 배치 창마다 행으로 다시 만들고, 행마다 업무·자료 여부를 정한다.
/// 그래프 재구성(세션)과 사용 시간 기록(날·업무·대상별 초)이 이 계산을 함께 써서 두 합계가 항상 같다
public struct ActivityTally {
    /// 정리된 배치 하나의 창
    public struct Window {
        public let batchId: Int64
        /// loadBatches 로 읽었을 때만 (재구성에서 세션 요약을 되찾는 데 쓴다)
        public let batch: BatchRecord?
        public let observations: [Observation]
        public let idle: [IdleSpan]
        public let windowEnd: Double
        public let assignments: [RowAssignment]
        /// 관측 id → 체류 구간 (EventCompressor 와 같은 규칙)
        let intervals: [Int64: (start: Double, end: Double)]
    }

    public let config: BatchConfig
    public let home: String
    public let fileExists: (String) -> Bool

    public init(config: BatchConfig = BatchConfig(), home: String = NSHomeDirectory(),
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.config = config; self.home = home; self.fileExists = fileExists
    }

    private struct Span { let id: Int64; let first: Double; let last: Double }

    /// 정리된(ok) 배치의 관측 시간 범위, 시간순
    private static func spans(_ conn: Database) throws -> [Span] {
        try Row.fetchAll(conn, sql: """
            SELECT b.id, MIN(o.ts) AS first_ts, MAX(o.ts) AS last_ts
            FROM batches b JOIN observations o ON o.batch_id = b.id
            WHERE b.status = 'ok' GROUP BY b.id
            """).map { Span(id: $0["id"], first: $0["first_ts"], last: $0["last_ts"]) }
            .sorted { ($0.first, $0.id) < ($1.first, $1.id) }
    }

    /// range 와 겹치는 배치 창 (nil 이면 전부). startingAt 을 주면 그 시각 이후에 시작한 배치만.
    /// 창의 끝은 다음 배치의 첫 관측, 마지막 배치는 마지막 관측 + maxGap (재구성과 같은 규칙)
    public func windows(_ conn: Database, overlapping range: Range<Double>? = nil, startingAt: Double? = nil,
                        loadBatches: Bool = false) throws -> [Window] {
        let spans = try Self.spans(conn)
        var selected: [(span: Span, end: Double)] = []
        for (index, span) in spans.enumerated() {
            let end = index + 1 < spans.count ? spans[index + 1].first : span.last + config.maxGap
            if let startingAt, span.first < startingAt { continue }
            if let range, !(span.first < range.upperBound && end > range.lowerBound) { continue }
            selected.append((span, end))
        }
        guard !selected.isEmpty else { return [] }
        let ids = selected.map { String($0.span.id) }.joined(separator: ",")      // 정수만 들어간다
        let observations = Dictionary(grouping: try Observation.fetchAll(conn, sql: "SELECT * FROM observations WHERE batch_id IN (\(ids)) ORDER BY ts, id"),
                                      by: { $0.batchId ?? -1 })
        let chats = Dictionary(grouping: try ChatMessage.fetchAll(conn, sql: "SELECT * FROM chat_messages WHERE batch_id IN (\(ids)) ORDER BY ts, id"),
                               by: { $0.batchId ?? -1 })
        let recordings = Dictionary(grouping: try Recording.fetchAll(conn, sql: "SELECT * FROM recordings WHERE batch_id IN (\(ids)) ORDER BY started_at, id"),
                                    by: { $0.batchId ?? -1 })
        var batches: [Int64: BatchRecord] = [:]
        if loadBatches {
            for batch in try BatchRecord.fetchAll(conn, sql: "SELECT * FROM batches WHERE id IN (\(ids))") {
                if let id = batch.id { batches[id] = batch }
            }
        }
        return try selected.compactMap { item in
            guard let window = observations[item.span.id], let first = window.first else { return nil }
            let idle = try EventStore.idleSpans(conn, from: first.ts, to: item.end)
            let batchChats = chats[item.span.id] ?? []
            let batchRecordings = recordings[item.span.id] ?? []
            let rows = EventCompressor.merge(
                EventCompressor.compress(window, idle: idle, texts: [:], windowEnd: item.end, home: home, fileExists: fileExists,
                                         maxRows: config.maxRows, maxGap: config.maxGap, snippetChars: 0, snippetTopN: 0),
                chats: batchChats, recordings: batchRecordings, home: home, fileExists: fileExists, snippetChars: 0)
            return Window(batchId: item.span.id, batch: batches[item.span.id], observations: window, idle: idle, windowEnd: item.end,
                          assignments: Self.assign(rows, window: window, chats: batchChats, recordings: batchRecordings),
                          intervals: Self.intervals(window, windowEnd: item.end, maxGap: config.maxGap))
        }
    }

    /// 행마다 업무: 대화·녹음 행은 그 기록의 업무, 나머지는 행을 이루는 관측들의 다수결. 하나라도 자료가 아니면 자료가 아니다
    static func assign(_ rows: [ActivityRow], window: [Observation], chats: [ChatMessage], recordings: [Recording] = []) -> [RowAssignment] {
        let taskOfObservation = Dictionary(window.compactMap { obs in obs.id.map { ($0, (obs.taskId, obs.resourceRelevant)) } }, uniquingKeysWith: { first, _ in first })
        let taskOfChat = Dictionary(chats.compactMap { chat in chat.id.map { ($0, chat.taskId) } }, uniquingKeysWith: { first, _ in first })
        let taskOfRecording = Dictionary(recordings.compactMap { recording in recording.id.map { ($0, recording.taskId) } }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            var taskId: Int64?, resource = true
            if row.isChat {
                taskId = row.chatMessageIds.compactMap { taskOfChat[$0] ?? nil }.first ?? row.recordingIds.compactMap { taskOfRecording[$0] ?? nil }.first
            } else {
                var votes: [Int64: Int] = [:]
                for id in row.observationIds {
                    guard let decision = taskOfObservation[id] else { continue }
                    if let task = decision.0 { votes[task, default: 0] += 1 }
                    if !decision.1 { resource = false }
                }
                taskId = votes.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
            }
            return RowAssignment(row: row, taskId: taskId, resource: resource)
        }
    }

    /// 관측마다 체류 구간: 다음 관측까지, 최대 maxGap (EventCompressor.compress 와 같은 규칙)
    static func intervals(_ window: [Observation], windowEnd: Double, maxGap: Double) -> [Int64: (start: Double, end: Double)] {
        let sorted = window.sorted { ($0.ts, $0.id ?? 0) < ($1.ts, $1.id ?? 0) }
        var result: [Int64: (start: Double, end: Double)] = [:]
        for (index, obs) in sorted.enumerated() {
            guard let id = obs.id else { continue }
            let rawEnd = index + 1 < sorted.count ? sorted[index + 1].ts : max(windowEnd, obs.ts)
            result[id] = (obs.ts, min(rawEnd, obs.ts + maxGap))
        }
        return result
    }

    /// 행의 체류 시간을 현지 날짜별로 나눈다. 자정을 넘긴 행은 관측 구간의 실제 활동 시간 비율로 나누고, 합은 행의 dwell 과 같다
    public func dayShares(_ row: ActivityRow, in window: Window, calendar: PeriodCalendar) -> [(day: String, seconds: Double)] {
        guard row.dwell > 0 else { return [(calendar.day(row.start), 0)] }
        var weights: [String: Double] = [:]
        for id in row.observationIds {
            guard let span = window.intervals[id], span.end > span.start else { continue }
            var cursor = span.start
            while cursor < span.end {
                let day = calendar.day(cursor)
                let dayEnd = calendar.dayEnd(day) ?? span.end
                let pieceEnd = min(span.end, dayEnd)
                weights[day, default: 0] += EventCompressor.activeSeconds(from: cursor, to: pieceEnd, idle: window.idle, openEnd: window.windowEnd)
                guard pieceEnd > cursor else { break }
                cursor = pieceEnd
            }
        }
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [(calendar.day(row.start), Double(row.dwell))] }
        return weights.sorted { $0.key < $1.key }.map { ($0.key, Double(row.dwell) * $0.value / total) }
    }
}
