import Foundation
import IOKit.ps
import WorkGraphCollectors
import WorkGraphCore

/// '지금 정리' 미리보기: 지울 날·항목·회수량과 그 기간을 대신할 요약
struct CleanupPreview: Identifiable {
    let id = UUID()
    let plan: PrunePlan
    let digests: [Digest]
    let consentNeeded: Bool
}

/// 전원 연결 중이거나 배터리가 절반 이상일 때만 자동 정리를 돌린다
enum PowerState {
    static func allowsMaintenance() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(), (source as String) == kIOPMACPowerKey { return true }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return Double(current) / Double(maximum) >= 0.5
        }
        return true
    }
}

extension AppState {
    /// 자동 정리 조건: 하루가 지났고, 5분 이상 자리를 비웠고, 일시정지가 아니고, 전원이 충분하다
    static let consolidationIdleSeconds: Double = 300

    func loadRetentionState() {
        guard let db else { return }
        let loaded = try? db.writer.read { conn -> (RetentionPolicy, [RetentionPin], Bool, String?, Consolidator.Report?) in
            let report = try ConsolidationStore.value(ConsolidationStore.Key.lastReport, conn)
                .flatMap { try? JSONDecoder().decode(Consolidator.Report.self, from: Data($0.utf8)) }
            return (try RetentionPolicy.load(conn), try ConsolidationStore.pins(conn),
                    try ConsolidationStore.value(ConsolidationStore.Key.firstPruneConsentedAt, conn) != nil,
                    try ConsolidationStore.value(ConsolidationStore.Key.textPrunedUntil, conn), report)
        }
        guard let loaded else { return }
        retention = loaded.0
        retentionPins = loaded.1
        pruneConsented = loaded.2
        rawRecordsSince = loaded.3.map { PeriodCalendar().addDays($0, 1) }
        if consolidationReport == nil { consolidationReport = loaded.4 }
    }

    func updateRetention(_ policy: RetentionPolicy) {
        guard let db else { return }
        let saved = policy.normalized()
        try? db.writer.write { try saved.save($0) }
        if saved != retention { retention = saved }
    }

    func consolidateIfDue() async {
        guard let consolidator, !consolidating, !batchRunning, !status.paused else { return }
        guard await consolidator.isDue(), IdleMonitor.secondsSinceLastInput() >= Self.consolidationIdleSeconds,
              PowerState.allowsMaintenance() else { return }
        await runConsolidation(prune: true)
    }

    /// 정리 한 번. prune: false 면 요약까지만 만든다
    func runConsolidation(prune: Bool) async {
        guard let consolidator, !consolidating else { return }
        consolidating = true
        defer { consolidating = false }
        let report = await consolidator.run(prune: prune)
        consolidationReport = report
        loadRetentionState()
        refreshStorage()
        if report.prunedDays > 0 { graphVersion += 1 }
    }

    /// '지금 정리': 먼저 요약을 최신으로 만들고, 지울 것을 보여 준다 (첫 정리면 동의를 받는다)
    func prepareCleanup() async {
        await runConsolidation(prune: false)
        guard let db, let plan = try? Pruner(db: db, ledger: LedgerBuilder()).plan(now: Date().timeIntervalSince1970) else { return }
        let calendar = PeriodCalendar()
        var digests: [Digest] = []
        if let first = plan.firstDay, let last = plan.lastDay, let start = calendar.dayStart(first), let end = calendar.dayEnd(last) {
            digests = ((try? await db.writer.read { try DigestStore.recent($0, limit: 200) }) ?? [])
                .filter { $0.level == .week && $0.periodEnd > start && $0.periodStart < end }
        }
        cleanupPreview = CleanupPreview(plan: plan, digests: digests, consentNeeded: plan.consentNeeded)
    }

    /// 미리보기에서 확인: 처음이면 동의를 기록하고 정리한다
    func confirmCleanup() async {
        guard let db else { return }
        if cleanupPreview?.consentNeeded == true {
            let now = Date().timeIntervalSince1970
            try? await db.writer.write { try ConsolidationStore.set(ConsolidationStore.Key.firstPruneConsentedAt, String(now), $0) }
            AppLog.write("첫 원문 정리 동의")
        }
        cleanupPreview = nil
        await runConsolidation(prune: true)
    }

    /// 저장 공간 측정은 폴더를 훑으므로 메인 스레드 밖에서
    func refreshStorage() {
        guard let db else { return }
        let captures = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
        Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { try? StorageUsage.measure(db: db, capturesDir: captures) }.value
            self?.storageUsage = usage
        }
    }

    // MARK: 다이제스트

    func digests(forTask key: String) -> [Digest] {
        (try? db?.writer.read { try DigestStore.list($0, taskKey: key) }) ?? []
    }

    func editDigest(id: Int64, body: String) {
        try? db?.writer.write { try DigestStore.edit($0, id: id, body: body, now: Date().timeIntervalSince1970) }
        graphVersion += 1
    }

    // MARK: 보존 핀

    func isTaskPinned(_ key: String) -> Bool { retentionPins.contains { $0.kind == .task && $0.key == key } }

    func toggleTaskPin(_ key: String) {
        setPin(.task, key: key, on: !isTaskPinned(key))
    }

    func isDayPinned(_ ts: Double) -> Bool {
        let day = PeriodCalendar().day(ts)
        return retentionPins.contains { $0.covers(day: day) }
    }

    /// 그날 하루를 보존한다 (이미 그날을 덮는 기간 핀이 있으면 그 핀을 푼다)
    func toggleDayPin(_ ts: Double) {
        let day = PeriodCalendar().day(ts)
        if let pin = retentionPins.first(where: { $0.covers(day: day) }) {
            removePin(pin)
        } else {
            setPin(.period, key: RetentionPin.periodKey(from: day, to: day), on: true)
        }
    }

    func removePin(_ pin: RetentionPin) { setPin(pin.kind, key: pin.key, on: false) }

    private func setPin(_ kind: RetentionPin.Kind, key: String, on: Bool) {
        guard let db else { return }
        try? db.writer.write { conn in
            if on { try ConsolidationStore.pin(kind, key: key, at: Date().timeIntervalSince1970, conn) } else { try ConsolidationStore.unpin(kind, key: key, conn) }
        }
        loadRetentionState()
    }
}
