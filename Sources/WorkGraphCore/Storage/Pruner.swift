import Foundation
import GRDB

/// 보관 기간이 지난 원문의 종류
public enum PruneCategory: String, CaseIterable, Codable, Sendable {
    case screenText, batchLog, observations, screenCards, aiRequests, fileEvents

    public var item: RetentionPolicy.Item {
        switch self {
        case .screenText: .screenText
        case .batchLog: .batchLog
        case .observations: .observations
        case .screenCards: .screenCards
        case .aiRequests: .aiRequests
        case .fileEvents: .fileEvents
        }
    }

    var stateKey: String {
        switch self {
        case .screenText: ConsolidationStore.Key.textPrunedUntil
        case .batchLog: ConsolidationStore.Key.batchesPrunedUntil
        case .observations: ConsolidationStore.Key.observationsPrunedUntil
        case .screenCards: ConsolidationStore.Key.cardsPrunedUntil
        case .aiRequests: ConsolidationStore.Key.aiRequestsPrunedUntil
        case .fileEvents: ConsolidationStore.Key.filesPrunedUntil
        }
    }
}

/// 지울 날과 항목. 앱의 미리보기와 wgctl consolidate --dry-run 이 같은 계획을 본다
public struct PrunePlan: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let day: String
        public let categories: [PruneCategory]
        public init(day: String, categories: [PruneCategory]) { self.day = day; self.categories = categories }
    }
    public var days: [Day] = []
    /// 지우거나 비울 행 수
    public var counts: [PruneCategory: Int] = [:]
    public var estimatedBytes: Int64 = 0
    /// 더 지우지 못하게 막은 이유 (가장 오래된 것 하나)
    public var blockedReason: String?
    /// 요약이 검증을 통과하지 못해 원문을 남기고 건너뛴 주(ISO 주)와 그 이유. 그 뒤 날짜는 계속 정리한다
    public var keptWeeks: [String] = []
    public var keptReasons: [String] = []
    /// 첫 정리 동의가 아직 없다
    public var consentNeeded = false
    public init() {}
    public var isEmpty: Bool { days.isEmpty }
    public var firstDay: String? { days.first?.day }
    public var lastDay: String? { days.last?.day }
}

public struct PruneResult: Equatable, Sendable {
    public var days = 0
    public var counts: [PruneCategory: Int] = [:]
    public var sealedUntil: String?
}

public struct ReclaimResult: Equatable, Sendable {
    public var before: Int64 = 0
    public var after: Int64 = 0
    public var vacuumed = false
    public var note: String?
    public var reclaimed: Int64 { max(0, before - after) }
}

public enum PruneError: Error, Equatable, CustomStringConvertible {
    case consentRequired
    public var description: String { "처음 정리하기 전에 사용자의 동의가 필요합니다." }
}

/// 원문 정리. 하루 D 의 원문은 그 주의 다이제스트가 활동한 모든 업무에 대해 검증(또는 수정)되고,
/// 검증 뒤 유예 기간이 지났고, 사용자가 첫 정리에 동의했을 때만 지운다. 지우기 전에 그날 사용 시간 기록을 동결한다.
/// 아직 준비되지 않은 주에서는 멈추고, 요약이 검증을 통과하지 못한 주는 원문을 남긴 채 건너뛴다(핀이 걸린 날처럼)
public struct Pruner {
    /// 주의 다이제스트가 원문을 대신할 준비가 됐는지
    enum WeekState: Equatable {
        case ready
        /// 아직 아님: 이 주와 그 뒤 날짜를 기다린다
        case wait(String)
        /// 요약이 검증을 통과하지 못함: 이 주 원문은 남기고 다음 주로 넘어간다
        case keep(String)
    }

    public let db: WGDatabase
    public let ledger: LedgerBuilder
    /// 기간을 닫기 전에 기다리는 시간 (늦게 도착하는 배치와 사용자 수정)
    public static let closeDelay: Double = 48 * 3600

    public init(db: WGDatabase, ledger: LedgerBuilder) {
        self.db = db; self.ledger = ledger
    }

    var calendar: PeriodCalendar { ledger.calendar }

    // MARK: 계획

    public func plan(now: Double, policy: RetentionPolicy? = nil) throws -> PrunePlan {
        try db.writer.read { conn in try plan(conn, now: now, policy: policy ?? RetentionPolicy.load(conn)) }
    }

    func plan(_ conn: Database, now: Double, policy: RetentionPolicy) throws -> PrunePlan {
        var plan = PrunePlan()
        plan.consentNeeded = try ConsolidationStore.value(ConsolidationStore.Key.firstPruneConsentedAt, conn) == nil
        let pins = try ConsolidationStore.pins(conn)
        let pinnedTasks = try pinnedTaskIds(conn, pins: pins)

        // 항목별로 이날 끝이 이 시각 전이면 보관 기간이 지났다
        var cutoffs: [PruneCategory: Double] = [:]
        for category in PruneCategory.allCases {
            if let days = policy.days(category.item) { cutoffs[category] = now - Double(days) * 86_400 }
        }
        guard let latestCutoff = cutoffs.values.max() else { return plan }
        var earliest: Double?
        for category in cutoffs.keys {
            if let first = try earliestData(category, conn) { earliest = min(earliest ?? first, first) }
        }
        guard let earliest, earliest < latestCutoff else { return plan }

        var weekStates: [String: WeekState] = [:]
        days: for day in calendar.days(from: earliest, to: latestCutoff) {
            guard let start = calendar.dayStart(day), let end = calendar.dayEnd(day) else { continue }
            var categories: [PruneCategory] = []
            for (category, cutoff) in cutoffs where end <= cutoff {
                let count = try self.count(category, conn, start: start, end: end, pinnedTasks: pinnedTasks)
                if count > 0 { categories.append(category); plan.counts[category, default: 0] += count }
            }
            guard !categories.isEmpty else { continue }
            if pins.contains(where: { $0.covers(day: day) }) {
                for category in categories { plan.counts[category, default: 0] -= try self.count(category, conn, start: start, end: end, pinnedTasks: pinnedTasks) }
                continue
            }
            let week = calendar.week(containing: start)
            if weekStates[week.id] == nil { weekStates[week.id] = try state(week, conn, now: now, policy: policy) }
            switch weekStates[week.id] ?? .ready {
            case .ready: break
            case .keep(let reason):
                for category in categories { plan.counts[category, default: 0] -= try self.count(category, conn, start: start, end: end, pinnedTasks: pinnedTasks) }
                if !plan.keptWeeks.contains(week.id) { plan.keptWeeks.append(week.id); plan.keptReasons.append(reason) }
                continue days
            case .wait(let reason):
                for category in categories { plan.counts[category, default: 0] -= try self.count(category, conn, start: start, end: end, pinnedTasks: pinnedTasks) }
                plan.blockedReason = reason
                break days
            }
            plan.days.append(.init(day: day, categories: categories.sorted { $0.rawValue < $1.rawValue }))
            plan.estimatedBytes += try estimate(categories, conn, start: start, end: end, pinnedTasks: pinnedTasks)
        }
        plan.counts = plan.counts.filter { $0.value > 0 }
        return plan
    }

    /// 주의 다이제스트가 원문을 대신할 준비가 됐는지. 검증에 실패한 요약이 하나라도 있으면 그 주는 남기고 건너뛴다
    func state(_ week: PeriodCalendar.Period, _ conn: Database, now: Double, policy: RetentionPolicy) throws -> WeekState {
        if now < week.end + Self.closeDelay { return .wait("\(week.id) 주가 아직 닫히지 않았어요") }
        let active = try DigestInput.activeTasks(conn, period: week, ledger: ledger)
        let digests = try DigestStore.byTask(conn, level: .week, period: week.id)
        var verifiedAt: [Double] = [], failed: [String] = [], waiting: String?
        for key in active {
            guard let digest = digests[key] else { waiting = waiting ?? "\(week.id) 주의 요약을 아직 만들지 않았어요"; continue }
            if digest.status != .draft, let at = digest.verifiedAt { verifiedAt.append(at) }
            else if digest.status == .draft, digest.attempts >= DigestBuilder.maxAttempts { failed.append(key) }
            else { waiting = waiting ?? "\(week.id) 주의 요약이 아직 초안이에요" }
        }
        if let key = failed.first {
            let title = try String.fetchOne(conn, sql: "SELECT title FROM nodes WHERE label = 'Task' AND key = ?", arguments: [key]) ?? key
            let others = failed.count > 1 ? " 외 \(failed.count - 1)개" : ""
            return .keep("\(week.id) 주 '\(title.prefix(30))'\(others) 요약이 검증을 통과하지 못해 이 주 원문은 남겨 뒀어요. 업무 탭 요약의 '고치기'에서 확인하고 저장하면 유예 기간 뒤 정리돼요")
        }
        if let waiting { return .wait(waiting) }
        let ready = (verifiedAt.max() ?? week.end + Self.closeDelay) + Double(policy.graceDays) * 86_400
        return now < ready ? .wait("\(week.id) 주는 요약 확인 뒤 유예 기간(\(policy.graceDays)일) 중이에요") : .ready
    }

    // MARK: 실행

    @discardableResult
    public func execute(_ plan: PrunePlan, now: Double) throws -> PruneResult {
        var result = PruneResult()
        guard !plan.days.isEmpty else { return result }
        try db.writer.read { conn in
            if try ConsolidationStore.value(ConsolidationStore.Key.firstPruneConsentedAt, conn) == nil { throw PruneError.consentRequired }
        }
        for item in plan.days {
            guard let start = calendar.dayStart(item.day), let end = calendar.dayEnd(item.day) else { continue }
            let counts = try db.writer.write { conn -> [PruneCategory: Int] in
                let pins = try ConsolidationStore.pins(conn)
                guard !pins.contains(where: { $0.covers(day: item.day) }) else { return [:] }
                let pinned = try pinnedTaskIds(conn, pins: pins)
                // 원문을 지우기 전에 그날 사용 시간을 마지막으로 계산해 동결하고, 재구성에서 그날 세션을 보호한다
                if item.categories.contains(where: { $0 != .batchLog }) {
                    try ledger.freeze(conn, day: item.day)
                    try ConsolidationStore.advance(ConsolidationStore.Key.sealedUntil, to: item.day, conn)
                }
                let sealed = (try ConsolidationStore.value(ConsolidationStore.Key.sealedUntil, conn)).map { $0 >= item.day } ?? false
                var counts: [PruneCategory: Int] = [:]
                for category in item.categories {
                    counts[category] = try prune(category, conn, start: start, end: end, pinnedTasks: pinned, sealed: sealed, pins: pins,
                                                 keptWeeks: Set(plan.keptWeeks))
                    try ConsolidationStore.advance(category.stateKey, to: item.day, conn)
                }
                return counts
            }
            guard !counts.isEmpty else { continue }
            result.days += 1
            for (category, count) in counts { result.counts[category, default: 0] += count }
        }
        result.sealedUntil = try db.writer.read { try ConsolidationStore.value(ConsolidationStore.Key.sealedUntil, $0) }
        return result
    }

    /// 그날 그 항목을 지운다. 참조하는 쪽을 먼저 비우고 지운다 (외래 키). keptWeeks 는 원문을 남기고 건너뛴 주다
    func prune(_ category: PruneCategory, _ conn: Database, start: Double, end: Double, pinnedTasks: [Int64], sealed: Bool, pins: [RetentionPin],
               keptWeeks: Set<String> = []) throws -> Int {
        let keep = Self.notPinned("task_id", pinnedTasks)
        switch category {
        case .screenText:
            let ids = try Int64.fetchAll(conn, sql: "SELECT DISTINCT text_id FROM observations WHERE ts >= ? AND ts < ? AND text_id IS NOT NULL\(keep)", arguments: [start, end])
            try conn.execute(sql: "UPDATE observations SET text_id = NULL WHERE ts >= ? AND ts < ? AND text_id IS NOT NULL\(keep)", arguments: [start, end])
            return try deleteUnreferencedTexts(ids, conn)
        case .batchLog:
            try conn.execute(sql: """
                UPDATE batches SET user_prompt = NULL, raw_response = NULL, system_prompt = NULL,
                       llm_patch = CASE WHEN ? THEN NULL ELSE llm_patch END
                WHERE started_at >= ? AND started_at < ?
                  AND (user_prompt IS NOT NULL OR raw_response IS NOT NULL OR system_prompt IS NOT NULL OR (? AND llm_patch IS NOT NULL))
                """, arguments: [sealed, start, end, sealed])
            return conn.changesCount
        case .observations:
            let filter = "ts >= ? AND ts < ?\(keep)"
            try conn.execute(sql: "UPDATE file_events SET observation_id = NULL WHERE observation_id IN (SELECT id FROM observations WHERE \(filter))", arguments: [start, end])
            let texts = try Int64.fetchAll(conn, sql: "SELECT DISTINCT text_id FROM observations WHERE \(filter) AND text_id IS NOT NULL", arguments: [start, end])
            try conn.execute(sql: "DELETE FROM observations WHERE \(filter)", arguments: [start, end])
            let deleted = conn.changesCount
            _ = try deleteUnreferencedTexts(texts, conn)
            // 그날 끝난 유휴 구간 (기간 핀이 걸린 날이나 원문을 남긴 주에 시작한 것은 남긴다)
            for span in try IdleSpan.fetchAll(conn, sql: "SELECT * FROM idle_spans WHERE COALESCE(end_ts, start_ts) >= ? AND COALESCE(end_ts, start_ts) < ?", arguments: [start, end]) {
                guard let id = span.id, !pins.contains(where: { $0.covers(day: calendar.day(span.startTs)) }),
                      !keptWeeks.contains(calendar.week(containing: span.startTs).id) else { continue }
                try conn.execute(sql: "DELETE FROM idle_spans WHERE id = ?", arguments: [id])
            }
            return deleted
        case .screenCards:
            let protected = pinnedTasks.isEmpty ? ""
                : " AND NOT EXISTS (SELECT 1 FROM observations o WHERE o.card_id = screen_cards.id AND o.task_id IN (\(pinnedTasks.map(String.init).joined(separator: ","))))"
            let ids = try Int64.fetchAll(conn, sql: "SELECT id FROM screen_cards WHERE ts_start >= ? AND ts_start < ?\(protected)", arguments: [start, end])
            guard !ids.isEmpty else { return 0 }
            let list = ids.map(String.init).joined(separator: ",")
            try conn.execute(sql: "UPDATE observations SET card_id = NULL WHERE card_id IN (\(list))")
            try conn.execute(sql: "DELETE FROM screen_cards WHERE id IN (\(list))")
            return ids.count
        case .aiRequests:
            try conn.execute(sql: "DELETE FROM chat_messages WHERE ts >= ? AND ts < ?\(keep)", arguments: [start, end])
            return conn.changesCount
        case .fileEvents:
            try conn.execute(sql: "DELETE FROM file_events WHERE ts >= ? AND ts < ?", arguments: [start, end])
            var deleted = conn.changesCount
            try conn.execute(sql: "DELETE FROM file_suggestions WHERE ts >= ? AND ts < ?", arguments: [start, end])
            deleted += conn.changesCount
            return deleted
        }
    }

    /// 다른 날(보관 기간 안이거나 핀이 걸린)이 같은 텍스트를 참조하면 남긴다 (해시로 중복을 없애서 여러 날이 공유할 수 있다)
    private func deleteUnreferencedTexts(_ ids: [Int64], _ conn: Database) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var deleted = 0
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            try conn.execute(sql: """
                DELETE FROM text_snapshots WHERE id IN (\(chunk.map(String.init).joined(separator: ",")))
                  AND NOT EXISTS (SELECT 1 FROM observations WHERE text_id = text_snapshots.id)
                """)
            deleted += conn.changesCount
        }
        return deleted
    }

    // MARK: 공간 회수

    /// 지운 자리를 파일에서 돌려준다. 처음 한 번은 auto_vacuum 을 INCREMENTAL 로 바꾸려고 전체 VACUUM 을 한다 (DB 크기만큼 임시 공간 필요)
    @discardableResult
    public func reclaimSpace(freeDiskBytes: Int64? = nil) throws -> ReclaimResult {
        var result = ReclaimResult(before: fileBytes())
        let mode = try db.writer.read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } ?? 0
        if mode != 2 {
            let size = fileBytes()
            let free = freeDiskBytes ?? volumeFreeBytes()
            if free.map({ $0 >= 2 * size }) ?? true {
                try db.writer.writeWithoutTransaction { conn in
                    try conn.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                    try conn.execute(sql: "VACUUM")
                }
                result.vacuumed = true
            } else {
                result.note = "디스크 여유가 DB 크기의 두 배보다 적어 전체 정리를 다음으로 미뤘어요"
            }
        } else {
            try db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA incremental_vacuum") }
        }
        for index in ["text_snapshots_chat_fts", "nodes_chat_fts", "chat_messages_chat_fts", "screen_cards_fts", "app_messages_fts", "digests_fts", "recordings_fts"] {
            try db.writer.write { try $0.execute(sql: "INSERT INTO \(index)(\(index)) VALUES ('optimize')") }
        }
        if db.path != nil {
            try db.writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        result.after = fileBytes()
        return result
    }

    func fileBytes() -> Int64 {
        guard let path = db.path else { return 0 }
        return [path, path + "-wal"].reduce(Int64(0)) { total, file in
            total + ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    func volumeFreeBytes() -> Int64? {
        guard let path = db.path else { return nil }
        let values = try? URL(fileURLWithPath: path).deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: 집계

    private func pinnedTaskIds(_ conn: Database, pins: [RetentionPin]) throws -> [Int64] {
        let keys = pins.filter { $0.kind == .task }.map(\.key)
        guard !keys.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ",")
        return try Int64.fetchAll(conn, sql: "SELECT id FROM nodes WHERE label = 'Task' AND key IN (\(marks))", arguments: StatementArguments(keys))
    }

    static func notPinned(_ column: String, _ pinned: [Int64]) -> String {
        pinned.isEmpty ? "" : " AND (\(column) IS NULL OR \(column) NOT IN (\(pinned.map(String.init).joined(separator: ","))))"
    }

    private func earliestData(_ category: PruneCategory, _ conn: Database) throws -> Double? {
        switch category {
        case .screenText: try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations WHERE text_id IS NOT NULL")
        case .batchLog: try Double.fetchOne(conn, sql: "SELECT MIN(started_at) FROM batches WHERE user_prompt IS NOT NULL OR raw_response IS NOT NULL OR system_prompt IS NOT NULL OR llm_patch IS NOT NULL")
        case .observations: try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations")
        case .screenCards: try Double.fetchOne(conn, sql: "SELECT MIN(ts_start) FROM screen_cards")
        case .aiRequests: try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM chat_messages")
        case .fileEvents: try Double.fetchOne(conn, sql: "SELECT MIN(m) FROM (SELECT MIN(ts) AS m FROM file_events UNION ALL SELECT MIN(ts) FROM file_suggestions)")
        }
    }

    private func count(_ category: PruneCategory, _ conn: Database, start: Double, end: Double, pinnedTasks: [Int64]) throws -> Int {
        let keep = Self.notPinned("task_id", pinnedTasks)
        let args: StatementArguments = [start, end]
        switch category {
        case .screenText:
            return try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts >= ? AND ts < ? AND text_id IS NOT NULL\(keep)", arguments: args) ?? 0
        case .batchLog:
            return try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM batches WHERE started_at >= ? AND started_at < ?
                  AND (user_prompt IS NOT NULL OR raw_response IS NOT NULL OR system_prompt IS NOT NULL)
                """, arguments: args) ?? 0
        case .observations:
            return try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM observations WHERE ts >= ? AND ts < ?\(keep)", arguments: args) ?? 0
        case .screenCards:
            return try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM screen_cards WHERE ts_start >= ? AND ts_start < ?", arguments: args) ?? 0
        case .aiRequests:
            return try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM chat_messages WHERE ts >= ? AND ts < ?\(keep)", arguments: args) ?? 0
        case .fileEvents:
            return try Int.fetchOne(conn, sql: "SELECT (SELECT COUNT(*) FROM file_events WHERE ts >= ?1 AND ts < ?2) + (SELECT COUNT(*) FROM file_suggestions WHERE ts >= ?1 AND ts < ?2)",
                                    arguments: args) ?? 0
        }
    }

    /// 대략의 회수 바이트: 원문 길이에 색인 몫을 더한다 (trigram 색인이 원문의 약 3배)
    private func estimate(_ categories: [PruneCategory], _ conn: Database, start: Double, end: Double, pinnedTasks: [Int64]) throws -> Int64 {
        let keep = Self.notPinned("o.task_id", pinnedTasks)
        var bytes: Int64 = 0
        for category in categories {
            switch category {
            case .screenText:
                bytes += 4 * (try Int64.fetchOne(conn, sql: """
                    SELECT COALESCE(SUM(LENGTH(t.text)), 0) FROM text_snapshots t WHERE t.id IN (
                      SELECT o.text_id FROM observations o WHERE o.ts >= ? AND o.ts < ? AND o.text_id IS NOT NULL\(keep))
                      AND NOT EXISTS (SELECT 1 FROM observations x WHERE x.text_id = t.id AND x.ts >= ?)
                    """, arguments: [start, end, end]) ?? 0)
            case .batchLog:
                bytes += try Int64.fetchOne(conn, sql: """
                    SELECT COALESCE(SUM(COALESCE(LENGTH(user_prompt), 0) + COALESCE(LENGTH(raw_response), 0) + COALESCE(LENGTH(system_prompt), 0)), 0)
                    FROM batches WHERE started_at >= ? AND started_at < ?
                    """, arguments: [start, end]) ?? 0
            case .observations:
                bytes += try Int64.fetchOne(conn, sql: """
                    SELECT COALESCE(SUM(80 + COALESCE(LENGTH(o.window_title), 0) + COALESCE(LENGTH(o.url), 0) + COALESCE(LENGTH(o.doc_path), 0)
                                        + COALESCE(LENGTH(o.task_reason), 0) + COALESCE(LENGTH(o.screenshot_path), 0)), 0)
                    FROM observations o WHERE o.ts >= ? AND o.ts < ?\(keep)
                    """, arguments: [start, end]) ?? 0
            case .screenCards:
                bytes += 2 * (try Int64.fetchOne(conn, sql: """
                    SELECT COALESCE(SUM(LENGTH(activity) + LENGTH(content) + LENGTH(entities) + COALESCE(LENGTH(window_title), 0)), 0)
                    FROM screen_cards WHERE ts_start >= ? AND ts_start < ?
                    """, arguments: [start, end]) ?? 0)
            case .aiRequests:
                bytes += 4 * (try Int64.fetchOne(conn, sql: "SELECT COALESCE(SUM(LENGTH(text)), 0) FROM chat_messages WHERE ts >= ? AND ts < ?",
                                                 arguments: [start, end]) ?? 0)
            case .fileEvents:
                bytes += 200 * Int64(try count(.fileEvents, conn, start: start, end: end, pinnedTasks: []))
            }
        }
        return bytes
    }
}
