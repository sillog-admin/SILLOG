import AppKit
import SillogCollectors
import SillogCore

/// 하루 한 번 정리 제안: 정리해 둔 그래프 전체를 다시 보고(WeeklyReview) 합칠 업무·주제·문제, 끝낼·지울 할 일, 붙일 짧은 세션을 제안한다.
/// 오늘 아직 안 만들었으면 자리를 비운 사이에 만들고(기록 정리와 같은 조건), 새 제안이 있을 때만 알림. 사용자가 시트에서 고른 것만 반영한다
extension AppState {
    nonisolated static let reviewDayKey = "review_day"
    /// 마지막으로 만들기에 실패한 때. 하루 동안 다시 부르지 않는다
    nonisolated static let reviewFailedKey = "review_failed_at"
    nonisolated static let reviewRetry: Double = 24 * 3_600

    /// 오늘 제안을 만들 때인지: 오늘 아직 안 만들었고, 하루 안에 실패하지 않았으면
    nonisolated static func reviewDue(day: String, done: String?, failedAt: Double?, now: Double) -> Bool {
        done != day && (failedAt.map { now - $0 >= reviewRetry } ?? true)
    }

    /// "2026-11-06" (현지 날짜)
    nonisolated static func reviewDay(_ ts: Double, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 종류 이름 (시트 묶음 제목, 알림 글)
    static func reviewKindName(_ kind: ReviewProposal.Kind) -> String {
        switch kind {
        case .mergeTasks: "업무 합치기"
        case .retireTask: "업무 외로 돌리기"
        case .mergeTopics: "주제 합치기"
        case .laterDone: "끝난 할 일"
        case .laterDrop: "할 일이 아닌 것 지우기"
        case .mergeProblems: "같은 문제 합치기"
        case .joinSessions: "짧은 세션 붙이기"
        }
    }

    func loadReview() {
        reviewProposals = (try? db.map { try ReviewStore($0).pending() }) ?? []
    }

    func openReview() {
        WindowOpener.shared.openMain()
        selectedTab = .graph
        loadReview()
        if !reviewProposals.isEmpty { reviewSheetOpen = true }
    }

    /// 오늘 아직 안 만들었으면 만든다 (자리를 비웠을 때, 전원이 넉넉할 때. 실패하면 하루 뒤에 다시)
    func reviewIfDue() async {
        guard let db, !reviewRunning, !batchRunning, !consolidating, !status.paused else { return }
        let now = Date().timeIntervalSince1970
        let (done, failed) = (try? await db.writer.read { conn in
            (try ConsolidationStore.value(Self.reviewDayKey, conn), try ConsolidationStore.value(Self.reviewFailedKey, conn).flatMap(Double.init))
        }) ?? (nil, nil)
        guard Self.reviewDue(day: Self.reviewDay(now), done: done, failedAt: failed, now: now),
              IdleMonitor.secondsSinceLastInput() >= Self.consolidationIdleSeconds, PowerState.allowsMaintenance() else { return }
        await runReview()
    }

    /// 제안을 만든다 (설정의 '지금 다시 정리'는 날과 상관없이). AI 호출 2번. 시트를 보고 있는 동안은 갈아 끼우지 않는다
    func runReview() async {
        guard let db, !reviewRunning, !reviewSheetOpen else { return }
        reviewRunning = true
        defer { reviewRunning = false }
        let now = Date().timeIntervalSince1970
        var fresh = 0
        do {
            let proposals = try await WeeklyReview.plan(db: db, llm: makeClient(), now: now)
            guard !reviewSheetOpen else { return }                      // 만드는 사이에 시트를 열었으면 다음에
            fresh = try ReviewStore(db).replacePending(with: proposals, now: now)
            let day = Self.reviewDay(now)
            try await db.writer.write { try ConsolidationStore.set(Self.reviewDayKey, day, $0) }
        } catch {
            AppLog.write("정리 제안 만들기 실패: \("\(error)")")
            try? await db.writer.write { try ConsolidationStore.set(Self.reviewFailedKey, String(now), $0) }
            return
        }
        loadReview()
        AppLog.write("정리 제안 \(reviewProposals.count)개 (새로 \(fresh)개)")
        if fresh > 0 { notifier.notifyReview(fresh: fresh, summary: Self.reviewSummary(reviewProposals)) }   // 어제와 같은 제안뿐이면 알리지 않는다
    }

    /// "업무 합치기 1 · 주제 합치기 24 · 끝난 할 일 26"
    static func reviewSummary(_ proposals: [ReviewProposal]) -> String {
        ReviewProposal.Kind.allCases.compactMap { kind in
            let count = proposals.filter { $0.kind == kind }.count
            return count > 0 ? "\(reviewKindName(kind)) \(count)" : nil
        }.joined(separator: " · ")
    }

    /// 고른 제안만 반영하고, 보여 준 것 중 안 고른 것은 다시 묻지 않게 접어 둔다 ('더 보기'에 접혀 안 본 것은 그대로 둔다).
    /// 반영과 표시는 한 트랜잭션. 반영하는 동안은 정리를 멈춘다 (도는 정리가 합친 업무를 다시 만들지 않게)
    func applyReview(selected: Set<Int64>, shown: Set<Int64>) async {
        guard let db, !erasing else { return }
        erasing = true
        defer { erasing = false }
        while batchRunning { try? await Task.sleep(nanoseconds: 200_000_000) }
        let chosen = reviewProposals.filter { $0.id.map { selected.contains($0) && shown.contains($0) } ?? false }
        let rest = reviewProposals.compactMap(\.id).filter { shown.contains($0) && !selected.contains($0) }
        let now = Date().timeIntervalSince1970
        do {
            let applied = try await db.writer.write { conn in try ReviewStore.apply(conn, chosen: chosen, dismissed: rest, now: now) }
            AppLog.write("정리 제안 반영: \(applied)/\(chosen.count)개, 접어 둠: \(rest.count)개")
        } catch {
            AppLog.write("정리 제안 반영 실패: \(error.localizedDescription)")
            eraseError = "정리 제안을 반영하지 못했어요. 아무것도 바꾸지 않았어요.\n(\(String(error.localizedDescription.prefix(160))))"
            return
        }
        reviewSheetOpen = false
        loadReview()
        graphVersion += 1
        refreshTasks()
        refresh()
    }
}
