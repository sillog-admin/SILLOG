import Foundation
import GRDB

/// 업무 하나·기간 하나의 다이제스트를 만든다. 수치는 코드가, 문장은 LLM 이 쓰고, 검증을 통과해야 저장한다.
/// 서술을 끄거나 짧은 업무는 수치와 세션 요약을 나열한 결정적 요약으로 확정한다.
/// 서술이 검증에 실패하거나 LLM 이 없으면 결정적 요약을 초안으로 두고, 초안인 주의 원문은 지우지 않는다
public struct DigestBuilder {
    public enum Outcome: Equatable, Sendable {
        case verified
        /// 서술 실패로 결정적 요약을 초안으로 둠 (원문을 지우지 않는다)
        case draft
        /// 사용자가 고친 것이라 그대로 둠
        case edited
        /// 입력이 그대로라 다시 만들지 않음 (검증에 계속 실패한 초안 포함)
        case unchanged
        /// 그 업무가 없거나 기간에 활동이 없음
        case skipped
    }

    /// 이보다 짧게 활동한 업무는 LLM 없이 한 줄 요약만 만든다
    public static let minNarratedSeconds: Double = 600
    /// 같은 입력으로 서술이 이만큼 검증에 실패하면 더 부르지 않는다. 요약은 초안으로 남아 그 주 원문을 지우지 않고,
    /// 입력이나 프롬프트 버전이 바뀌면 다시 시도한다. 사용자가 고쳐 저장하면(edited) 정리할 수 있다
    public static let maxAttempts = 3

    public let ledger: LedgerBuilder

    public init(ledger: LedgerBuilder) { self.ledger = ledger }

    /// llm 이 nil 이면 서술 없이 만든다. llmFailed: LLM 연결이 실패하면 true 로 바꿔 이번 실행의 나머지 서술을 건너뛰게 한다
    public func build(db: WGDatabase, period: PeriodCalendar.Period, taskKey: String, llm: (any LLMClient)?, narrate: Bool, now: Double,
                      llmFailed: inout Bool) async throws -> Outcome {
        let prepared: (input: DigestInput, existing: Digest?)? = try await db.writer.read { conn in
            guard let input = try DigestInput.build(conn, period: period, taskKey: taskKey, ledger: ledger) else { return nil }
            return (input, try DigestStore.find(conn, level: period.level, period: period.id, taskKey: taskKey))
        }
        guard let prepared else { return .skipped }
        let (input, existing) = prepared
        if existing?.status == .edited { return .edited }
        let hash = input.hash(promptVersion: DigestPrompt.version)
        if let existing, existing.inputHash == hash, existing.status == .verified { return .unchanged }
        let sameInputAttempts = existing?.inputHash == hash ? existing?.attempts ?? 0 : 0

        var content = Self.deterministic(input)
        var status = Digest.Status.verified
        var model: String?
        var attempts = 0
        let wantsNarration = narrate && input.metrics.activeSeconds >= Self.minNarratedSeconds
        if wantsNarration {
            // 같은 입력으로 이미 여러 번 실패: 초안을 그대로 두고 이번 실행의 처리 한도도 쓰지 않는다
            if sameInputAttempts >= Self.maxAttempts { return .unchanged }
            if let llm, !llmFailed {
                var narrated: DigestContent?
                var rejected = false
                for _ in 0..<2 {
                    do {
                        let result = try await llm.callFunction(system: DigestPrompt.system, user: DigestPrompt.user(input), tool: DigestPrompt.tool)
                        let candidate = try JSONDecoder().decode(DigestContent.self, from: Self.normalized(result.arguments))
                        let issues = DigestValidator.problems(candidate, input: input)
                        if issues.isEmpty { narrated = candidate; model = result.model; break }
                        rejected = true
                        AppLog.write("다이제스트 검증 실패 (\(input.task.title.prefix(30)) \(period.id)): \(issues.prefix(3).joined(separator: "; "))")
                    } catch is DecodingError {
                        rejected = true
                    } catch {
                        // 연결·로그인 문제: 이번 실행에서는 서술을 더 시도하지 않고, 실패 횟수도 세지 않는다
                        llmFailed = true
                        AppLog.write("다이제스트 서술 실패 (LLM 연결): \((error as? LLMError)?.description.prefix(160) ?? "\(error)".prefix(160))")
                        break
                    }
                }
                if let narrated {
                    content = narrated
                } else {
                    attempts = sameInputAttempts + (rejected ? 1 : 0)
                    status = .draft
                }
            } else {
                attempts = sameInputAttempts
                status = .draft
            }
        }
        let digest = Digest(id: existing?.id, level: period.level, period: period.id, periodStart: period.start, periodEnd: period.end,
                            tz: ledger.calendar.timeZone.identifier, taskKey: taskKey,
                            title: Digest.title(level: period.level, task: input.task.title, period: period.id),
                            body: DigestRenderer.body(content, metrics: input.metrics), content: content, metrics: input.metrics,
                            anchors: input.anchors, status: status, model: model, promptVersion: DigestPrompt.version, inputHash: hash,
                            attempts: attempts, createdAt: existing?.createdAt ?? now, verifiedAt: status == .verified ? now : nil)
        try await db.writer.write { conn in _ = try DigestStore.save(conn, digest) }
        return status == .verified ? .verified : .draft
    }

    /// 중첩 값을 JSON 문자열로 감싼 답도 읽는다 (작은 모델의 흔들림)
    static func normalized(_ data: Data) -> Data {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return data }
        let root = AssignmentPatch.unwrapStrings(parsed)
        guard JSONSerialization.isValidJSONObject(root), let fixed = try? JSONSerialization.data(withJSONObject: root) else { return data }
        return fixed
    }

    /// LLM 없이: 입력에 있던 문장만 옮긴다. 수치는 렌더러가 붙인다
    public static func deterministic(_ input: DigestInput) -> DigestContent {
        var lines: [String] = []
        for line in input.sessions.flatMap(\.summaries) + input.weeks.map(\.summary) where !line.isEmpty && !lines.contains(line) { lines.append(line) }
        let short = input.metrics.activeSeconds < minNarratedSeconds
        var summary = "\(input.task.title) 업무 기록이 \(input.time) 있습니다."
        if let first = lines.first { summary += " " + first }
        let progress = lines.prefix(short ? 3 : 8).map { DigestContent.Item(text: String($0.prefix(300)), status: "in_progress", anchors: [input.task.key]) }
        let problems = input.problems.prefix(8).map { DigestContent.Item(text: $0.text, state: $0.state, anchors: [$0.key]) }
        let open = input.laterItems.filter { $0.state == "open" }.prefix(8).map { DigestContent.Item(text: $0.text, anchors: [$0.key]) }
        return DigestContent(summary: String(summary.prefix(DigestValidator.summaryLimit)), progress: Array(progress), problems: Array(problems),
                             openItems: Array(open), numbersUsed: [.init(name: "active_seconds", value: input.metrics.activeSeconds)])
    }
}
