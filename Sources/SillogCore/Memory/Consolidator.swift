import Foundation
import GRDB

/// 기록 정리 한 번: 사용 시간 기록 갱신 → 주간 다이제스트 → 월간 다이제스트 → (동의했으면) 원문 정리 → 공간 회수.
/// 언제 중단돼도 안전하다: 단계마다 멱등이고 다음 실행이 이어서 처리한다
public actor Consolidator {
    public struct Report: Codable, Equatable, Sendable {
        public var startedAt: Double
        public var finishedAt: Double?
        public var ledgerDays = 0
        public var weekly = 0
        public var weeklyDrafts = 0
        public var monthly = 0
        public var monthlyDrafts = 0
        public var prunedDays = 0
        public var pruned: [String: Int] = [:]
        public var reclaimedBytes: Int64 = 0
        public var notes: [String] = []

        public init(startedAt: Double) { self.startedAt = startedAt }

        /// 설정 화면·로그 한 줄
        public var summary: String {
            var parts: [String] = []
            if weekly + weeklyDrafts > 0 { parts.append("주간 요약 \(weekly)개" + (weeklyDrafts > 0 ? " (초안 \(weeklyDrafts)개)" : "")) }
            if monthly + monthlyDrafts > 0 { parts.append("월간 요약 \(monthly)개" + (monthlyDrafts > 0 ? " (초안 \(monthlyDrafts)개)" : "")) }
            if prunedDays > 0 { parts.append("\(prunedDays)일치 원문 정리") }
            if reclaimedBytes > 0 { parts.append("\(ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)) 회수") }
            return parts.isEmpty ? "새로 정리할 것 없음" : parts.joined(separator: ", ")
        }
    }

    public static let maxWeeksPerRun = 2
    public static let maxMonthsPerRun = 1
    /// 하루 한 번
    public static let interval: Double = 24 * 3600

    private let db: SillogDatabase
    private var llm: (any LLMClient)?
    private let ledger: LedgerBuilder
    private let clock: @Sendable () -> Double
    private var running = false

    public init(db: SillogDatabase, llm: (any LLMClient)?, ledger: LedgerBuilder = LedgerBuilder(),
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.db = db; self.llm = llm; self.ledger = ledger; self.clock = clock
    }

    public func setLLM(_ client: (any LLMClient)?) { llm = client }

    public var isRunning: Bool { running }

    /// 마지막 실행에서 하루가 지났는지
    public func isDue() -> Bool {
        let last = (try? db.writer.read { try ConsolidationStore.value(ConsolidationStore.Key.lastRunAt, $0) }).flatMap { $0 }.flatMap(Double.init) ?? 0
        return clock() - last >= Self.interval
    }

    /// prune: false 면 요약까지만 (원문은 지우지 않는다). ledgerOnly: 사용 시간 기록만 갱신.
    /// narrate: 이번 실행만 요약 서술 설정을 바꾼다 (nil 이면 보관 정책을 따른다)
    public func run(prune: Bool = true, ledgerOnly: Bool = false, narrate narrateOverride: Bool? = nil) async -> Report {
        var report = Report(startedAt: clock())
        guard !running else { report.notes.append("이미 실행 중"); return report }
        running = true
        defer { running = false }
        let now = clock()

        // 1. 사용 시간 기록
        do { report.ledgerDays = try refreshLedger(now: now) } catch { report.notes.append("사용 시간 기록 실패: \(error)") }
        if ledgerOnly { return finish(report) }

        let policy = (try? await db.writer.read { try RetentionPolicy.load($0) }) ?? .standard
        let narrate = narrateOverride ?? policy.narrateDigests
        var llmFailed = false
        let builder = DigestBuilder(ledger: ledger)

        // 2. 주간 다이제스트: 닫힌 주 중 요약이 없거나, 초안이거나, 입력이 바뀐 주 (원문이 남은 주만)
        do {
            var processed = 0
            for week in try weeksToCheck(now: now) where processed < Self.maxWeeksPerRun {
                guard try isClosable(week, now: now) else { break }
                let tasks = try await db.writer.read { [ledger] in try DigestInput.activeTasks($0, period: week, ledger: ledger) }
                var touched = false
                for task in tasks {
                    let outcome = try await builder.build(db: db, period: week, taskKey: task, llm: llm, narrate: narrate, now: now, llmFailed: &llmFailed)
                    switch outcome {
                    case .verified: report.weekly += 1; touched = true
                    case .draft: report.weeklyDrafts += 1; touched = true
                    default: break
                    }
                }
                if touched { processed += 1 }
                try await db.writer.write { try ConsolidationStore.advance(ConsolidationStore.Key.weekUntil, to: week.days.last ?? week.id, $0) }
            }
        } catch {
            report.notes.append("주간 요약 실패: \(error)")
        }

        // 3. 월간 다이제스트: 그 달에 걸친 주가 모두 닫히고 주간 요약이 있는 달
        do {
            var processed = 0
            for month in try monthsToCheck(now: now) where processed < Self.maxMonthsPerRun {
                guard try isMonthReady(month, now: now) else { break }
                let tasks = try await db.writer.read { [ledger] in try DigestInput.activeTasks($0, period: month, ledger: ledger) }
                var touched = false
                for task in tasks {
                    let outcome = try await builder.build(db: db, period: month, taskKey: task, llm: llm, narrate: narrate, now: now, llmFailed: &llmFailed)
                    switch outcome {
                    case .verified: report.monthly += 1; touched = true
                    case .draft: report.monthlyDrafts += 1; touched = true
                    default: break
                    }
                }
                if touched { processed += 1 }
                try await db.writer.write { try ConsolidationStore.advance(ConsolidationStore.Key.monthUntil, to: month.days.last ?? month.id, $0) }
            }
        } catch {
            report.notes.append("월간 요약 실패: \(error)")
        }
        if llmFailed { report.notes.append("정리용 AI 연결이 안 돼 일부 요약을 초안으로 두었어요") }

        // 4. 원문 정리 (첫 정리 동의와 화면 글자 보관 기간을 확인한다)
        if prune {
            do {
                let calendar = ledger.calendar
                let dropped = try await db.writer.write { conn in
                    guard try ConsolidationStore.value(ConsolidationStore.Key.firstPruneConsentedAt, conn) != nil,
                          let days = try RetentionPolicy.load(conn).screenTextDays else { return 0 }
                    return try ScreenText.dropOffTask(conn, before: now - Double(days) * 86_400, calendar: calendar)
                }
                if dropped > 0 { report.notes.append("업무 외 화면 글자 \(dropped)개 지움") }
            } catch {
                report.notes.append("업무 외 화면 글자 지우기 실패: \(error)")
            }
            let pruner = Pruner(db: db, ledger: ledger)
            do {
                let plan = try pruner.plan(now: now, policy: policy)
                if plan.consentNeeded {
                    if !plan.isEmpty { report.notes.append("정리할 원문이 있지만 아직 동의하지 않았어요") }
                } else if !plan.isEmpty {
                    let result = try pruner.execute(plan, now: now)
                    report.prunedDays = result.days
                    for (category, count) in result.counts { report.pruned[category.rawValue] = count }
                    if result.days > 0 {
                        // 5. 공간 회수
                        let reclaimed = try pruner.reclaimSpace()
                        report.reclaimedBytes = reclaimed.reclaimed
                        if let note = reclaimed.note { report.notes.append(note) }
                    }
                }
                report.notes += plan.keptReasons
                if let reason = plan.blockedReason { report.notes.append(reason) }
            } catch {
                report.notes.append("원문 정리 실패: \(error)")
            }
        }
        return finish(report)
    }

    private func finish(_ report: Report) -> Report {
        var done = report
        done.finishedAt = clock()
        let encoded = (try? JSONEncoder().encode(done)).map { String(decoding: $0, as: UTF8.self) }
        try? db.writer.write { conn in
            try ConsolidationStore.set(ConsolidationStore.Key.lastRunAt, String(done.startedAt), conn)
            try ConsolidationStore.set(ConsolidationStore.Key.lastReport, encoded, conn)
        }
        AppLog.write("기록 정리: \(done.summary)" + (done.notes.isEmpty ? "" : " (\(done.notes.prefix(3).joined(separator: "; ")))"))
        return done
    }

    // MARK: 단계

    /// 마지막으로 계산한 날 앞 사흘부터 어제까지 다시 계산한다 (처음이면 정리된 첫 관측부터). 일주일씩 끊어 쓴다
    private func refreshLedger(now: Double) throws -> Int {
        let calendar = ledger.calendar
        let yesterday = calendar.addDays(calendar.day(now), -1)
        let start: String? = try db.writer.read { conn in
            if let until = try ConsolidationStore.value(ConsolidationStore.Key.ledgerUntil, conn) { return calendar.addDays(until, -3) }
            return try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations WHERE batch_id IS NOT NULL").map(calendar.day)
        }
        guard let start, start <= yesterday, let from = calendar.dayStart(start), let to = calendar.dayEnd(yesterday) else { return 0 }
        let days = calendar.days(from: from, to: to)
        var refreshed = 0
        for chunk in stride(from: 0, to: days.count, by: 7).map({ Array(days[$0..<min($0 + 7, days.count)]) }) {
            refreshed += try db.writer.write { [ledger] conn in try ledger.refresh(conn, days: chunk) }
        }
        try db.writer.write { try ConsolidationStore.advance(ConsolidationStore.Key.ledgerUntil, to: yesterday, $0) }
        return refreshed
    }

    /// 원문이 남은(봉인되지 않은) 첫 주부터 지금까지
    private func weeksToCheck(now: Double) throws -> [PeriodCalendar.Period] {
        let calendar = ledger.calendar
        guard let first = try firstUnsealedActivity() else { return [] }
        var weeks: [PeriodCalendar.Period] = []
        var week = calendar.week(containing: first)
        while week.end + Pruner.closeDelay <= now {
            weeks.append(week)
            week = calendar.next(week)
        }
        return weeks
    }

    private func monthsToCheck(now: Double) throws -> [PeriodCalendar.Period] {
        let calendar = ledger.calendar
        guard let first = try firstUnsealedActivity() else { return [] }
        var months: [PeriodCalendar.Period] = []
        var month = calendar.month(containing: first)
        while month.end + Pruner.closeDelay <= now {
            months.append(month)
            month = calendar.next(month)
        }
        return months
    }

    private func firstUnsealedActivity() throws -> Double? {
        try db.writer.read { conn in
            let boundary = try GraphRebuilder.sealBoundary(conn, calendar: ledger.calendar)
            return try Double.fetchOne(conn, sql: "SELECT MIN(ts) FROM observations WHERE batch_id IS NOT NULL AND ts >= ?", arguments: [boundary])
        }
    }

    /// 기간을 닫을 수 있는지: 끝에서 48시간이 지났고, 그 기간의 관측이 모두 정리 배치에 들어갔다
    private func isClosable(_ period: PeriodCalendar.Period, now: Double) throws -> Bool {
        guard now >= period.end + Pruner.closeDelay else { return false }
        let pending = try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM observations WHERE batch_id IS NULL AND ts < ?", arguments: [period.end]) } ?? 0
        return pending == 0
    }

    /// 그 달에 걸친 주가 모두 닫혔고, 활동한 업무마다 주간 요약이 있다
    private func isMonthReady(_ month: PeriodCalendar.Period, now: Double) throws -> Bool {
        guard try isClosable(month, now: now) else { return false }
        for week in ledger.calendar.weeks(overlapping: month) {
            guard try isClosable(week, now: now) else { return false }
            let ready = try db.writer.read { [ledger] conn -> Bool in
                let digests = try DigestStore.byTask(conn, level: .week, period: week.id)
                return try DigestInput.activeTasks(conn, period: week, ledger: ledger).allSatisfy { digests[$0] != nil }
            }
            if !ready { return false }
        }
        return true
    }
}
