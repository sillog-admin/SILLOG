import Foundation
import ImageIO
import GRDB
import WorkGraphCore
import WorkGraphCollectors

// wgctl — 권한이나 GUI 없이 파이프라인을 돌려보는 개발용 CLI.

setvbuf(stdout, nil, _IOLBF, 0)      // 파이프·파일로 보내도 줄 단위로 바로 출력 (로그인 코드가 버퍼에 갇히지 않게)

let usage = """
wgctl [--db PATH] <command>

  seed-demo [--day YYYY-MM-DD]          하루치 데모 활동을 L0 에 넣는다
  codex-login [--no-open]               ChatGPT 계정으로 로그인 (기기 코드 방식, 브라우저에서 코드 입력)
  codex-status | codex-logout           로그인 상태 확인 / 로그아웃
  codex-models                          로그인한 계정에서 쓸 수 있는 모델 목록
  codex-usage                           구독 한도 대비 Codex 사용률 (5시간 창, 주간 창)
  batch [--provider codex|openai] [--model M] [--base-url URL] [--api-key K] [--force] [--all] [--demo-llm]
                                        미처리 행을 LLM 으로 온톨로지화한다
                                        (--demo-llm: 모델 없이 데모 시드를 규칙으로 분류하는 가짜 LLM)
  llm-test [--provider codex|openai] [--model M] [--base-url URL]
                                        LLM 연결과 로그인이 유효한지 실제 호출로 확인
  collect [--seconds N] [--no-screenshots]
                                        수집기를 N초(기본 20) 돌리며 생기는 행을 출력한다
                                        (권한은 이 명령을 실행한 터미널 앱 기준으로 적용된다)
  rebuild-graph --yes                   그래프를 지우고 원시 행 전체를 미처리로 되돌린다 (이후 batch --all 로 다시 정리).
                                        원시 행과 스크린샷은 그대로다. 분류 로직을 바꾼 뒤 결과를 다시 만들 때 쓴다. 앱을 끄고 실행할 것
  rebuild-graph --from-assignments      LLM 없이: 행마다 기록된 업무 판단은 그대로 두고 세션·앱·자료·흐름·프로젝트만 다시 계산한다
                                        (세션 규칙을 바꿨을 때. 업무·주제·문제·할 일 노드는 유지)
  rows [--last N] [--text]              최근 관측 행 (원시 데이터). --text 면 화면 텍스트 앞부분도
  batches [--last N] | batch-show ID     정리 기록 목록 / 한 배치가 LLM 에 보낸 것과 받은 것 전문
  dump FILE.md [--since-hours N] [--text]
                                        원시 행 + 정리 기록(프롬프트·응답) 전체를 마크다운 한 파일로
  stats                                 행·노드·엣지 수
  export-graph FILE [--tbox] [--since-hours N]
  export-cypher FILE [--tbox]
  export-rdf FILE                       PROV-O·SKOS 에 매핑한 Turtle(RDF). 표준 RDF 도구(rdflib, Protégé, GraphDB)로 읽힌다
  schema                                클래스와 관계 정의 (정의역·치역, 표준 어휘 대응)
  neighbors LABEL KEY [--hops N]        한 노드에서 N 다리 안의 부분 그래프
  suggest FILE [--origin URL] [--context "제목|제목"] [--screen "화면 텍스트"] [--roots ~/Desktop,~/Documents] [--dry]
                                        내려받은 파일을 어느 폴더에 둘지 제안 (후보 목록과 LLM 의 선택을 출력. --dry 면 기록하지 않음)
  suggestions [--last N]                파일 정리 제안 기록
  tasks [--last N]                      업무 목록 (id, 시간, 세션 수) / sessions TASK_ID  그 업무의 세션 목록
  resume-plan TASK_ID | --session ID    그 업무·세션을 "다시 열기" 하면 무엇을 열지 (열지는 않음)
  clean-topics [--yes]                  주제 노드 중 앱·플랫폼·프로젝트 이름·채움말을 찾아 보여 주고, --yes 면 지운다 (앱을 끄고 실행)
  rebind-projects                       업무 ↔ 프로젝트를 1:1 로 다시 맞춘다 (기존 ON 엣지의 시간을 근거로. 앱을 끄고 실행)
  merge-tasks [--dry] [--days N]        제목만 다른 같은 목표의 업무를 합치고, 목표가 아닌 업무는 업무 외로 돌린다 (LLM 판단. --dry: 묻기만. 앱을 끄고 실행)
  retire-task TASK_ID [TASK_ID…]        업무를 업무 외로 돌린다: 그 행은 업무 외(이유는 남김), 세션은 지운다 (앱을 끄고 실행)
  eval-assign SCENARIO.json [--out result.json] [--runs N]
                                        정답이 붙은 가짜 하루를 LLM 에 보내 행 판정(업무/이탈/없음, 자료 여부)을 채점한다 (기록 안 함)
  backfill-screen-hash                  예전 스크린샷 파일에서 차이 해시를 계산해 원시 행에 채운다 (화면 기억 카드의 재료)
  cards [--last N]                      화면 기억 카드 (무엇을 했나, 화면 내용, 이름 붙은 것들)
  recard [--ids 1,2] [--kind message]   카드를 저장된 스크린샷으로 지금 규칙에 맞춰 다시 만든다 (12장씩 한 호출)
  topic-audit [--last N]                지난 배치들의 LLM 응답에서 주제 태그를 모아 필터가 거를 것을 센다 (프롬프트 대 필터 평가)
  replay-batch ID [ID…]                 저장된 배치의 입력을 지금 프롬프트로 다시 보내 응답을 비교한다 (기록하지 않음. 배치당 LLM 호출 1번)
  find-events ID [ID…]                  저장된 배치의 행에서 일정 찾기를 돌려 찾은 일정을 보여 준다 (제안을 만들지 않음. 배치당 LLM 호출 1번)
  erase-theme 분야이름 [--yes]          그 분야의 업무를 원시 기록·화면 카드·요약까지 지운다 (기본은 세기만, --yes 는 앱을 끄고. 지운 뒤 VACUUM)
  erase-node 종류 키 [--yes]            노드 하나를 하위 노드·원시 기록까지 지운다 (종류: Session, Resource, App, Topic …. 기본은 세기만)
  weekly-review                          정리 제안(하루 한 번)을 만들어 보여 준다 (반영하지 않음. LLM 호출 2번)
  rejudge ID [ID…]                      배치들의 행을 지금 규칙으로 다시 판정해 기록을 바꾸고 세션을 다시 계산한다 (카드는 연결된 것을 쓴다. 앱을 끄고 실행)
  gold-candidates --from YYYY-MM-DD [--to YYYY-MM-DD] [--limit N] [--model M] [--reasoning high] [--out FILE]
                                        정답 세트 재료: 그 기간 배치의 행을 앱과 같은 방식으로 다시 만들어 판정만 받고(기록 안 함),
                                        지금 판정과 행마다 비교해 쓴다 (기본: 데이터 폴더/eval/gold-candidates.json)
  gold-score [--gold FILE] [--predictions FILE]
                                        사람이 확정한 정답 세트로 지금 판정·다시 판정·예측("배치:행" → 판정)의 정확도를 잰다
  gold-run --from YYYY-MM-DD [--pipeline single|staged] [--runs N] [--model M] [--reasoning R] [--out FILE]
                                        정답 세트 배치를 고른 판정 방식으로 다시 판정만 받아(기록 안 함) 채점하고, 두 번 이상이면 흔들림도 낸다
  pipeline-graph                        3단계 판정 흐름도를 Mermaid 로 출력
  themes                                분야별 업무 목록
  assign-themes [--retype] [--dry-run]  분야가 없거나 종류가 옛 판인 업무에 분야·종류를 붙인다 (앱을 끄고 실행.
                                        --retype: 모든 업무의 종류를 다시, --dry-run: 판정만 보고 기록 안 함)
  theme-eval [--gold FILE] [--runs N]   정답 세트 업무를 빈 분야 목록에서 판정만 받아(기록 안 함) 분야·종류 정확도, 새 분야 수, 흔들림을 낸다
  set-theme TASK_ID (분야이름 | --clear)   업무의 분야를 바꾸거나 뺀다 (앱을 끄고 실행)
  storage                               저장 공간: 범주별 크기, 최근 30일 하루 평균 증가량, 빈 페이지 수
  retention [--preset light|standard|long|keepRaw] [--set 항목=일수|none] [--grace N] [--narrate on|off]
                                        원문 보관 기간 보기·바꾸기 (항목: screenText, batchLog, observations, screenCards, aiRequests, fileEvents)
  pins [--add|--remove task:업무KEY | period:YYYY-MM-DD..YYYY-MM-DD]
                                        원문을 지우지 않고 남길 업무·기간
  consolidate [--dry-run] [--ledger-only] [--no-prune] [--no-llm] [--consent]
                                        기록 정리: 사용 시간 기록 → 주간·월간 요약 → (동의했으면) 보관 기간이 지난 원문 정리 → 공간 회수.
                                        --dry-run: 지울 날·건수·예상 회수량만, --ledger-only: 사용 시간 기록만 갱신하고 업무 시간과 비교,
                                        --no-llm: 요약을 수치와 세션 요약으로만, --consent: 첫 정리 동의를 기록 (앱을 끄고 실행)
  digest list [--task KEY] | digest show --week 2026-W40 | --month 2026-10 [--task KEY]
                                        업무별 주간·월간 요약

기본 DB: \(WGDatabase.defaultPath())
기본 LLM: ChatGPT 로그인(codex), 모델 \(CodexResponsesClient.defaultModel). --base-url 을 주면 OpenAI 호환 서버(openai)로 간주한다
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let index = args.firstIndex(of: name) else { return false }
    args.remove(at: index)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let dbPath = option("--db") ?? WGDatabase.defaultPath()
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

let db: WGDatabase
do {
    db = try WGDatabase(path: dbPath)
    try db.writer.write { try TBox.seed(GraphTx($0), at: Date().timeIntervalSince1970) }
} catch {
    fail("DB 를 열 수 없음 (\(dbPath)): \(error)")
}
let store = EventStore(db)

let codexAuth = CodexAuthManager()

/// --provider 가 없으면: --base-url 이 있을 때 openai, 없으면 codex.
func makeClient() -> (client: any LLMClient, pingable: OpenAICompatClient?) {
    let base = option("--base-url")
    let provider = option("--provider") ?? (base == nil ? "codex" : "openai")
    let model = option("--model") ?? (provider == "openai" ? "gpt-5.4-mini" : CodexResponsesClient.defaultModel)
    if provider == "openai" {
        let address = base ?? "http://localhost:5010/v1"
        guard let url = URL(string: address) else { fail("잘못된 --base-url: \(address)") }
        let client = OpenAICompatClient(baseURL: url, model: model, apiKey: option("--api-key"))
        return (client, client)
    }
    return (CodexResponsesClient(auth: codexAuth, model: model, reasoningEffort: option("--reasoning") ?? "medium"), nil)
}

/// 정답 세트 재료: 배치 하나를 앱이 보낸 것과 같은 방식으로 다시 만든 것
struct GoldJob {
    let batchId: Int64
    let input: JudgeInput
    let current: [Int: (label: String, reason: String)]
    let evidence: [Int: String]
    var rows: [ActivityRow] { input.rows }
}

/// 판정 이름표: task:키 / new:제목 / off / none
struct GoldLabels {
    let titleByKey: [String: String]
    let keyByTitle: [String: String]

    init(tasks: [GraphNode]) {
        titleByKey = Dictionary(tasks.map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
        keyByTitle = Dictionary(tasks.map { (AssignmentApplier.normalizeTitle($0.title).lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    func name(_ label: String) -> String {
        if label.hasPrefix("task:") { return titleByKey[String(label.dropFirst(5))] ?? label }
        if label.hasPrefix("new:") { return "새 업무: " + label.dropFirst(4) }
        return label == "off" ? "업무 외" : label == "none" ? "없음" : label
    }

    func label(_ patch: AssignmentPatch, decided: [Int: (task: String?, resource: Bool?, reason: String?)], row: Int) -> (label: String, reason: String) {
        guard let decision = decided[row] else { return ("missing", "") }
        let reason = decision.reason ?? ""
        guard let ref = decision.task else { return ("none", reason) }
        if ref == AssignmentPatch.offTask { return ("off", reason) }
        guard let definition = patch.tasks.first(where: { $0.ref == ref }) else { return ("missing", reason) }
        let title = AssignmentApplier.normalizeTitle(definition.title ?? "")
        if definition.match == "existing", let id = definition.id, titleByKey[id] != nil { return ("task:\(id)", reason) }
        if let key = keyByTitle[title.lowercased()] { return ("task:\(key)", reason) }
        if AssignmentApplier.isCategory(title) { return ("off", reason) }
        return ("new:\(title)", reason)
    }
}

/// 정답 세트용: 그 기간의 배치를 앱이 보낸 것과 같은 방식으로 다시 만든다 (행·카드·후보 업무·지금 판정)
/// tasksBefore: 이 시각 뒤에 생긴 업무는 후보에서 뺀다 (정답을 매길 때 없던 후보)
func goldJobs(from: Double, until: Double, limit: Int, tasksBefore: Double = .infinity) throws -> [GoldJob] {
    let config = BatchConfig(), home = NSHomeDirectory()
    let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    let observations = try store.assignedObservations()
    let chats = try store.assignedChatMessages()
    let byBatch = Dictionary(grouping: observations, by: { $0.batchId ?? -1 })
    let chatsByBatch = Dictionary(grouping: chats, by: { $0.batchId ?? -1 })
    let batches = try store.recentBatches(limit: 100_000).filter { batch in
        guard batch.status == "ok", let id = batch.id, let first = byBatch[id]?.first else { return false }
        return first.ts >= from && first.ts < until
    }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }.prefix(limit)
    let taskNodes = try db.writer.read { try GraphTx($0).nodes(label: NodeLabel.task) }
    let keyById = Dictionary(taskNodes.map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
    let newer = Set(taskNodes.filter { $0.createdAt > tasksBefore }.map(\.key))
    var jobs: [GoldJob] = []
    for batch in batches {
        guard let batchId = batch.id, let window = byBatch[batchId], let first = window.first, let last = window.last else { continue }
        let windowEnd = try store.nextObservationTs(after: last) ?? (last.ts + config.maxGap)
        let idle = try store.idleSpans(from: first.ts, to: windowEnd)
        let texts = try store.texts(ids: window.compactMap(\.textId))
        let rows = EventCompressor.merge(
            EventCompressor.compress(window, idle: idle, texts: texts, windowEnd: windowEnd, home: home, fileExists: exists,
                                     maxRows: config.maxRows, maxGap: config.maxGap, snippetChars: config.snippetChars, snippetTopN: config.snippetTopN),
            chats: chatsByBatch[batchId] ?? [], home: home, fileExists: exists, snippetChars: config.snippetChars)
        let cardOf = Dictionary(window.compactMap { obs in obs.id.flatMap { id in obs.cardId.map { (id, $0) } } }, uniquingKeysWith: { first, _ in first })
        let cards: [Int: [ScreenCard]] = try db.writer.read { conn in
            var result: [Int: [ScreenCard]] = [:]
            for row in rows where !row.isChat {
                let ids = Array(Set(row.observationIds.compactMap { cardOf[$0] }))
                let found = try ScreenCard.fetchAll(conn, keys: ids).sorted { $0.tsStart < $1.tsStart }
                if !found.isEmpty { result[row.row] = found }
            }
            return result
        }
        let openTasks = try db.writer.read { try GraphTx($0).openTasks(limit: 40, since: first.ts - 7 * 86_400) }.filter { !newer.contains($0.id) }
        let decided = Dictionary(window.compactMap { obs in obs.id.map { ($0, obs) } }, uniquingKeysWith: { first, _ in first })
        let chatTask = Dictionary((chatsByBatch[batchId] ?? []).compactMap { chat in chat.id.map { ($0, chat.taskId) } }, uniquingKeysWith: { first, _ in first })
        var current: [Int: (label: String, reason: String)] = [:], evidence: [Int: String] = [:]
        for row in rows {
            var votes: [String: Int] = [:], reason = ""
            if row.isChat {
                let task = row.chatMessageIds.compactMap { chatTask[$0] ?? nil }.first.flatMap { keyById[$0] }
                votes[task.map { "task:\($0)" } ?? "none", default: 0] += 1
            } else {
                for id in row.observationIds {
                    guard let obs = decided[id] else { continue }
                    votes[obs.taskId.flatMap { keyById[$0] }.map { "task:\($0)" } ?? (obs.offTask ? "off" : "none"), default: 0] += 1
                    if reason.isEmpty, let text = obs.taskReason { reason = text }
                }
            }
            current[row.row] = (votes.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? "none", reason)
            var lines: [String] = []
            if let rowCards = cards[row.row] {
                for card in rowCards { lines.append("screen: \(card.activity)"); lines += OntologyPrompt.cardLines(card).map { "· \($0)" } }
            } else if let snippet = row.snippet, !snippet.isEmpty {
                lines.append("text: \(OntologyPrompt.clip(snippet, 300))")
            }
            evidence[row.row] = lines.joined(separator: "\n")
        }
        jobs.append(GoldJob(batchId: batchId, input: JudgeInput(rows: rows, openTasks: openTasks, cards: cards, now: batch.startedAt),
                            current: current, evidence: evidence))
    }
    return jobs
}

/// 배치 하나를 판정만 받는다. 실패면 이유와, 기다렸다 다시 하면 되는 실패(요청 한도·서버 과부하·연결)인지를 함께 돌려준다
func judgeOnce(_ input: JudgeInput, pipeline: BatchPipeline, client: any LLMClient) async -> (patch: AssignmentPatch?, calls: Int, failure: String?, transient: Bool, stages: [StageCall]) {
    func transient(_ error: Error) -> Bool {
        switch error as? LLMError {
        case .http(let status, _): return status == 429 || status >= 500
        case .backend, .transport: return true
        default: return false
        }
    }
    switch pipeline {
    case .single:
        let prompt = OntologyPrompt.build(rows: input.rows, openTasks: input.openTasks, now: input.now, cards: input.cards)
        do {
            let result = try await client.callFunction(system: prompt.system, user: prompt.user, tool: AssignmentSchema.tool)
            let patch = AssignmentPatch.decodeLenient(from: result.arguments)
            return (patch, 1, patch == nil ? "응답을 해석할 수 없음" : nil, false, [])
        } catch {
            return (nil, 1, "\(error)", transient(error), [])
        }
    case .staged:
        do {
            let (patch, stageCalls) = try await StagedPipeline.run(input, llm: client)
            return (patch, stageCalls.count, nil, false, stageCalls)
        } catch let error as PipelineError {
            if case .stageFailed(_, let underlying, _) = error { return (nil, error.calls.count, error.description, transient(underlying), error.calls) }
            return (nil, error.calls.count, error.description, false, error.calls)
        } catch {
            return (nil, 0, "\(error)", transient(error), [])
        }
    }
}

/// 배치들을 고른 방식으로 판정만 받는다 (3개씩 동시에, 기록 안 함). 요청 한도·과부하는 30·60·90초 기다렸다 그 배치를 처음부터 다시 하고,
/// 앱이 반영 전에 거부할 판정(빠진 행, 모르는 업무)은 실패한 배치로 센다
func judgeGold(_ jobs: [GoldJob], pipeline: BatchPipeline, client: any LLMClient) async -> (patches: [Int64: AssignmentPatch], failed: [Int64], calls: Int) {
    var patches: [Int64: AssignmentPatch] = [:], failed: [Int64] = [], calls = 0
    await withTaskGroup(of: (Int64, AssignmentPatch?, Int, String?).self) { group in
        var next = 0
        func add() {
            guard next < jobs.count else { return }
            let id = jobs[next].batchId, input = jobs[next].input
            next += 1
            group.addTask {
                var spent = 0
                for attempt in 1...4 {
                    let result = await judgeOnce(input, pipeline: pipeline, client: client)
                    spent += result.calls
                    guard result.transient, attempt < 4 else {
                        if let patch = result.patch, let reason = AssignmentCheck.rejection(patch, rows: input.rows, openTasks: input.openTasks, now: input.now) {
                            // 3단계면 원인을 볼 수 있게 ②의 답 앞부분을 붙인다
                            let answer = result.stages.last { $0.stage == "assign" }.map { " — ② 답: \($0.arguments.prefix(500))" } ?? ""
                            return (id, nil, spent, "앱이 거부: \(reason)\(answer)")
                        }
                        return (id, result.patch, spent, result.failure)
                    }
                    print("  배치 \(id): \(result.failure ?? "") — \(30 * attempt)초 뒤 다시")
                    try? await Task.sleep(nanoseconds: UInt64(30 * attempt) * 1_000_000_000)
                }
                return (id, nil, spent, "다시 해도 실패")
            }
        }
        for _ in 0..<3 { add() }
        while let (id, patch, count, failure) = await group.next() {
            calls += count
            if let patch { patches[id] = patch } else { failed.append(id) }
            print("  \(patches.count + failed.count)/\(jobs.count)\(failure.map { " — 배치 \(id) 실패: \($0)" } ?? "")")
            add()
        }
    }
    return (patches, failed, calls)
}

/// 업무 기준 이름표: 없음·업무 외는 "업무 아님" 하나로, 새 업무는 제목과 상관없이 "new"
func goldTaskLevel(_ label: String?) -> String? {
    guard let label else { return nil }
    if label == "none" || label == "off" || label == "not-task" || label == "missing" { return "not-task" }
    return label.hasPrefix("new:") ? "new" : label
}

/// 정답 세트로 채점해 한 줄 출력 (업무 기준 + 없음·업무 외까지 구분한 엄격 점수)
func printGoldScore(_ title: String, graded: [[String: Any]], predict: ([String: Any]) -> String?) {
    func strict(_ label: String?) -> String? { label.map { $0.hasPrefix("new:") ? "new" : $0 } }
    func kind(_ label: String) -> String { label.hasPrefix("task:") ? "업무" : label.hasPrefix("new:") ? "새 업무" : "업무 아님" }
    var correct = 0, strictCorrect = 0, strictTotal = 0, perKind: [String: (ok: Int, total: Int)] = [:]
    for row in graded {
        let gold = row["gold"] as! String, guess = predict(row)
        let ok = goldTaskLevel(guess) == goldTaskLevel(gold)
        if ok { correct += 1 }
        perKind[kind(gold), default: (0, 0)].total += 1
        if ok { perKind[kind(gold), default: (0, 0)].ok += 1 }
        if gold != "not-task" { strictTotal += 1; if strict(guess) == strict(gold) { strictCorrect += 1 } }
    }
    let detail = perKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.ok)/\($0.value.total)" }.joined(separator: ", ")
    print(String(format: "  %@: 업무 기준 %d/%d (%.1f%%) — %@ | 없음·업무 외까지 구분 %d/%d (%.1f%%)", title, correct, graded.count,
                 100.0 * Double(correct) / Double(max(1, graded.count)), detail, strictCorrect, strictTotal,
                 100.0 * Double(strictCorrect) / Double(max(1, strictTotal))))
}

/// 정답 세트 (정답이 있는 행만)
func loadGoldRows(_ path: String) -> [[String: Any]]? {
    guard let data = FileManager.default.contents(atPath: path),
          let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = file["rows"] as? [[String: Any]] else { return nil }
    return rows.filter { $0["gold"] is String }
}

/// 분야 이름 비교용 키 (기본 분야 표기로 맞춘 뒤 공백·대소문자 무시)
func themeKey(_ name: String?) -> String { ThemeCatalog.matchKey(ThemeCatalog.canonical(name ?? "")) }

/// 명령 안에서 트랜잭션을 되돌리며 멈출 때
struct CommandError: Error, CustomStringConvertible { let description: String }

/// 정답 세트 파일이 놓이는 곳 (개인 기록이라 저장소 밖, DB 옆)
var evalDirectory: String { (dbPath as NSString).deletingLastPathComponent + "/eval" }

func describe(_ status: CodexAuthStatus) -> String {
    switch status {
    case .loggedOut: return "로그인 안 됨 (wgctl codex-login)"
    case .loggedIn(let email, let plan, let expiresAt):
        let until = expiresAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "?"
        return "로그인됨: \(email ?? "이메일 없음") (\(plan ?? "플랜 정보 없음")), 액세스 토큰 만료 \(until) — 만료 전에 자동 갱신됨"
    }
}

func printStats() throws {
    let pending = try store.counts(since: 0)
    let counts = try db.writer.read { try GraphTx($0).counts() }
    print("observations: \(pending.total) (미처리 \(pending.unprocessed))")
    print("nodes: " + counts.nodesByLabel.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    print("edges: " + counts.edgesByType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
    for batch in try store.recentBatches(limit: 5).reversed() {
        print("batch #\(batch.id ?? 0) \(batch.status) rows=\(batch.rowCount) model=\(batch.model ?? "-") "
              + "tokens=\(batch.promptTokens)+\(batch.completionTokens)\(batch.error.map { " error=\($0.prefix(160))" } ?? "")")
    }
}

do {
    switch command {
    case "seed-demo":
        var calendar = Calendar.current
        calendar.timeZone = .current
        var day = calendar.startOfDay(for: Date())
        if let text = option("--day") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current
            guard let parsed = formatter.date(from: text) else { fail("--day 형식은 YYYY-MM-DD") }
            day = parsed
        }
        let count = try DemoScenarios.seed(into: store, dayStart: day.timeIntervalSince1970, home: NSHomeDirectory())
        print("데모 관측 행 \(count)개 추가")

    case "codex-login":
        let code = try await codexAuth.beginDeviceLogin()
        print("""

        1. 브라우저에서 이 주소를 열고 ChatGPT 계정으로 로그인: \(code.verificationURL.absoluteString)
        2. 이 코드를 입력 (15분 안에): \(code.userCode)

        직접 시작한 로그인일 때만 입력하세요. 승인을 기다리는 중… (Ctrl+C 로 취소)
        """)
        if !flag("--no-open") {
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            opener.arguments = [code.verificationURL.absoluteString]
            try? opener.run()
        }
        print(describe(try await codexAuth.completeDeviceLogin(code)))
        print("토큰 위치: \(CodexAuthStore.defaultURL().path)")

    case "codex-models":
        for model in try await CodexResponsesClient.listModels(auth: codexAuth) {
            print("\(model.slug)\t\(model.displayName)\t기본 추론 강도: \(model.defaultEffort ?? "-")")
        }

    case "codex-usage":
        let usage = try await CodexResponsesClient.fetchUsage(auth: codexAuth)
        print("요금제: \(usage.planType ?? "-")")
        for window in [usage.primary, usage.secondary].compactMap({ $0 }) {
            let reset = Date(timeIntervalSince1970: window.resetAt).formatted(date: .abbreviated, time: .shortened)
            print("\(window.label) 한도: \(Int(window.usedPercent.rounded()))% 사용, \(reset) 에 초기화")
        }
        print("자세히: \(CodexResponsesClient.usagePage.absoluteString)")

    case "codex-status":
        print(describe(await codexAuth.status()))

    case "codex-logout":
        try await codexAuth.logout()
        print("로그아웃했습니다")

    case "batch":
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱이 직접 정리하므로 CLI 배치는 앱을 끈 뒤에 실행하세요.") }
        defer { instance.release() }
        let force = flag("--force"), all = flag("--all")
        let demo = flag("--demo-llm")
        let client: any LLMClient = demo ? DemoLLM() : makeClient().client
        var batchConfig = BatchConfig()
        // 데모 LLM 은 한 번 호출 형식으로만 답하고 분야 도구·일정 찾기는 모른다
        if demo { batchConfig.pipeline = .single; batchConfig.themes = false; batchConfig.findEvents = false }
        let batcher = OntologyBatcher(db: db, llm: client, config: batchConfig)
        var round = 0
        repeat {
            round += 1
            let outcome = await batcher.runIfDue(force: force || all)
            print("[\(round)] \(outcome)")
            if case .ok = outcome { continue }
            break
        } while all && round < 50
        try printStats()

    case "llm-test":
        let (client, pingable) = makeClient()
        if let pingable {
            print("서버 응답(/models): \(await pingable.ping() ? "OK" : "실패")")
        } else {
            print(describe(await codexAuth.status()))
        }
        switch await client.selfTest() {
        case .success(let message): print("함수 호출: \(message)")
        case .failure(let error): fail("함수 호출 실패 — \(error)")
        }

    case "collect":
        let seconds = option("--seconds").flatMap(Double.init) ?? 20
        var settings = CollectorSettings()
        settings.captureScreenshots = !flag("--no-screenshots")
        settings.settleDelay = 1
        let captures = URL(fileURLWithPath: (dbPath as NSString).deletingLastPathComponent).appendingPathComponent("captures")
        print("권한 — 손쉬운 사용: \(Permissions.accessibility(prompt: false) ? "허용" : "없음"), 화면 기록: \(Permissions.screenRecording() ? "허용" : "없음")")
        let coordinator = CollectorCoordinator(store: store, capturesDir: captures, settings: settings)
        await coordinator.start()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await coordinator.stop()
        let status = await coordinator.currentStatus()
        print("행 \(status.observations)개, 스크린샷 \(status.screenshots)장")
        for row in try store.recent(limit: 10).reversed() {
            let time = Date(timeIntervalSince1970: row.ts).formatted(date: .omitted, time: .standard)
            let text = try row.textId.flatMap { try store.texts(ids: [$0])[$0] }.map { " text=\($0.count)자" } ?? ""
            print("  \(time) [\(row.trigger)] \(row.appName) | \(row.windowTitle ?? "-") | \(row.url ?? row.docPath ?? "-")\(text)\(row.screenshotPath == nil ? "" : " +shot")")
        }

    case "rebuild-graph" where flag("--from-assignments"):
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { instance.release() }
        let stats = try GraphRebuilder(db: db, store: store).rebuildFromAssignments(now: Date().timeIntervalSince1970)
        print("세션 \(stats.sessions)개, 자료 \(stats.resources)개를 행 판단에서 다시 만들었습니다 (업무 \(stats.tasks)개, 행 \(stats.rows)개)")
        try printStats()

    case "rebuild-graph":
        guard flag("--yes") else { fail("그래프(파생 데이터)를 지우고 원시 행을 전부 미처리로 되돌립니다. 원시 행·스크린샷은 남습니다. 진행하려면 --yes 를 붙이세요.") }
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        try db.writer.write { conn in
            // 카드 연결(card_id)은 남긴다: 화면 카드는 판정과 무관한 사실이라 다시 만들 필요가 없다
            try conn.execute(sql: "UPDATE observations SET batch_id = NULL, task_id = NULL, resource_relevant = 1, off_task = 0, task_reason = NULL")
            try conn.execute(sql: "UPDATE chat_messages SET batch_id = NULL, task_id = NULL")
            try conn.execute(sql: "UPDATE recordings SET batch_id = NULL, task_id = NULL")
            try conn.execute(sql: "DELETE FROM edges")
            try conn.execute(sql: "DELETE FROM nodes")
            try TBox.seed(GraphTx(conn), at: Date().timeIntervalSince1970)
        }
        instance.release()
        print("그래프를 비웠습니다. 이어서: wgctl batch --all")
        try printStats()

    case "rows":
        let limit = option("--last").flatMap(Int.init) ?? 50
        let withText = flag("--text")
        let rows = try store.recent(limit: limit).reversed()
        let texts = withText ? try store.texts(ids: rows.compactMap(\.textId)) : [:]
        for row in rows {
            let time = Date(timeIntervalSince1970: row.ts).formatted(date: .numeric, time: .standard)
            let marks = [row.textId == nil ? nil : "텍스트", row.screenshotPath == nil ? nil : "캡처", row.batchId.map { "정리#\($0)" } ?? "미처리"].compactMap { $0 }.joined(separator: ",")
            print("#\(row.id ?? 0) \(time) [\(row.trigger)] \(row.appName) | \(row.windowTitle ?? "-") | \(row.url ?? row.docPath ?? "-") (\(marks))")
            if withText, let id = row.textId, let text = texts[id] {
                print("    " + text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
            }
        }

    case "batches":
        let limit = option("--last").flatMap(Int.init) ?? 20
        for batch in try store.recentBatches(limit: limit).reversed() {
            let time = Date(timeIntervalSince1970: batch.startedAt).formatted(date: .numeric, time: .standard)
            print("#\(batch.id ?? 0) \(time) \(batch.status) rows=\(batch.rowCount) model=\(batch.model ?? "-") tokens=\(batch.promptTokens)+\(batch.completionTokens)"
                  + (batch.error.map { " error=\($0.prefix(120))" } ?? "") + (batch.userPrompt == nil ? " (프롬프트 미저장)" : ""))
        }

    case "batch-show":
        guard let id = args.first.flatMap(Int64.init) else { fail("사용법: batch-show ID") }
        guard let batch = try store.batch(id: id) else { fail("배치 #\(id) 없음") }
        print("=== 배치 #\(id) \(batch.status) \(batch.model ?? "-") 행 \(batch.rowCount) 토큰 \(batch.promptTokens)+\(batch.completionTokens)")
        if let error = batch.error { print("오류: \(error)") }
        print("\n--- LLM 이 받은 것: 시스템 프롬프트 ---\n\(batch.systemPrompt ?? "(미저장)")")
        print("\n--- LLM 이 받은 것: 활동 행 ---\n\(batch.userPrompt ?? "(미저장)")")
        print("\n--- LLM 이 돌려준 것 ---\n\(batch.llmPatch ?? "(없음)")")
        if let applied = batch.appliedPatch, applied != batch.llmPatch { print("\n--- 다듬은 뒤 반영한 것 ---\n\(applied)") }

    case "dump":
        guard let file = args.first else { fail("출력 파일 경로가 필요함") }
        let since = option("--since-hours").flatMap(Double.init).map { Date().timeIntervalSince1970 - $0 * 3600 } ?? 0
        let withText = flag("--text")
        let rows = try store.recent(limit: 100_000).filter { $0.ts >= since }.reversed()
        let texts = withText ? try store.texts(ids: rows.compactMap(\.textId)) : [:]
        let batches = try store.recentBatches(limit: 10_000).filter { $0.startedAt >= since }.reversed()
        let clock = Date.FormatStyle(date: .numeric, time: .standard)
        var md = ["# Sillog 데이터 덤프 (\(Date().formatted(clock)))", "", "## 1. 원시 데이터 — 관측 행 \(rows.count)개", "",
                  "| # | 시각 | 계기 | 앱 | 창 제목 | URL / 문서 | 텍스트 | 캡처 | 정리 |", "|---|---|---|---|---|---|---|---|---|"]
        func cell(_ text: String?) -> String { (text ?? "").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        for row in rows {
            md.append("| \(row.id ?? 0) | \(Date(timeIntervalSince1970: row.ts).formatted(clock)) | \(row.trigger) | \(cell(row.appName)) | \(cell(row.windowTitle)) | \(cell(row.url ?? row.docPath)) | \(row.textId == nil ? "" : "있음") | \(row.screenshotPath == nil ? "" : "있음") | \(row.batchId.map { "#\($0)" } ?? "대기") |")
            if withText, let id = row.textId, let text = texts[id] { md.append("| | | | | 텍스트 | \(cell(String(text.prefix(500)))) | | | |") }
        }
        md += ["", "## 2. 정리 기록 — 배치 \(batches.count)개 (LLM 이 받은 것과 돌려준 것)", ""]
        for batch in batches {
            md += ["### 배치 #\(batch.id ?? 0) — \(batch.status), \(batch.model ?? "-"), 행 \(batch.rowCount), 토큰 \(batch.promptTokens)+\(batch.completionTokens), \(Date(timeIntervalSince1970: batch.startedAt).formatted(clock))", ""]
            if let error = batch.error { md += ["오류: `\(error)`", ""] }
            if let user = batch.userPrompt { md += ["<details><summary>LLM 이 받은 것 (활동 행)</summary>", "", "```text", user, "```", "", "</details>", ""] }
            if let patch = batch.llmPatch { md += ["**LLM 이 돌려준 것**", "", "```json", patch, "```", ""] }
            if let applied = batch.appliedPatch, applied != batch.llmPatch { md += ["**다듬은 뒤 반영한 것**", "", "```json", applied, "```", ""] }
        }
        md += ["", "## 3. 시스템 프롬프트 (고정 지시문)", "", "```text", OntologyPrompt.system, "```", ""]
        try md.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
        print("관측 행 \(rows.count)개, 배치 \(batches.count)개 → \(file)")

    case "stats":
        try printStats()

    case "schema":
        print("클래스 (\(ClassSchema.classes.count))")
        for cls in ClassSchema.classes { print("  \(cls.label.padding(toLength: 13, withPad: " ", startingAt: 0)) \(cls.name.padding(toLength: 9, withPad: " ", startingAt: 0)) ⊂ \(cls.standardSuperclass.padding(toLength: 19, withPad: " ", startingAt: 0)) \(cls.meaning)") }
        print("관계 (\(RelationSchema.rules.count))")
        for rule in RelationSchema.rules {
            let pairs = rule.pairs.map { "\($0.from) → \($0.to)" }.sorted().joined(separator: ", ")
            print("  \(rule.type.padding(toLength: 15, withPad: " ", startingAt: 0)) \(pairs)\n    \(rule.meaning)  [\(rule.standard)]")
        }

    case "export-rdf":
        guard let file = args.first else { fail("출력 파일 경로가 필요함") }
        let graph = try db.writer.read { try GraphTx($0).subgraph(since: nil, includeTBox: true) }
        try RDFExporter.export(graph).write(toFile: file, atomically: true, encoding: .utf8)
        print("노드 \(graph.nodes.count)개, 엣지 \(graph.edges.count)개 → \(file)")

    case "export-graph", "export-cypher":
        let includeTBox = flag("--tbox")
        let since = option("--since-hours").flatMap(Double.init).map { Date().timeIntervalSince1970 - $0 * 3600 }
        guard let file = args.first else { fail("출력 파일 경로가 필요함") }
        let graph = try db.writer.read { try GraphTx($0).subgraph(since: since, includeTBox: includeTBox) }
        if command == "export-graph" {
            try GraphJSONExporter.export(graph).write(to: URL(fileURLWithPath: file))
        } else {
            try CypherExporter.export(graph).write(toFile: file, atomically: true, encoding: .utf8)
        }
        print("노드 \(graph.nodes.count)개, 엣지 \(graph.edges.count)개 → \(file)")

    case "suggest":
        let home = NSHomeDirectory()
        let origin = option("--origin")
        let roots = (option("--roots") ?? "~/Desktop,~/Documents").split(separator: ",").map { FolderSuggester.expand(String($0).trimmingCharacters(in: .whitespaces), home: home) }
        let titles = (option("--context") ?? "").split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let screen = option("--screen")
        let dry = flag("--dry")
        guard args.count >= 1 else { fail("사용법: suggest FILE [--origin URL] [--context \"제목|제목\"] [--roots a,b] [--dry]") }
        let file = FolderSuggester.expand(args[0], home: home)
        guard FileManager.default.fileExists(atPath: file) else { fail("파일이 없음: \(file)") }
        let started = Date()
        let index = FolderIndex.scan(roots: roots, home: home)
        print("폴더 색인: \(index.folders.count)개 (\(String(format: "%.1f", Date().timeIntervalSince(started)))초)")
        let openTasks = try db.writer.read { try GraphTx($0).openTasks(limit: 6) }
        let fileName = (file as NSString).lastPathComponent
        var contextStrings = titles + openTasks.flatMap { [$0.title] + $0.topics }
        if let origin { contextStrings.append(origin) }
        print("후보 (문맥 점수 순):")
        for folder in index.rank(fileName: fileName, context: contextStrings, limit: 25) {
            print("  \(folder.relativePath)  — \(folder.sampleFiles.prefix(4).joined(separator: ", "))")
        }
        let target: WGDatabase = dry ? try WGDatabase.inMemory() : db
        let suggester = FolderSuggester(db: target, llm: makeClient().client, home: home)
        let context = FolderSuggester.Context(recentTitles: titles, screenText: screen, openTasks: openTasks, now: Date().timeIntervalSince1970)
        let llmStarted = Date()
        if let suggestion = try await suggester.suggest(filePath: file, originURL: origin, index: index, context: context) {
            print("제안: \(suggestion.suggestedFolder)  (\(suggestion.source), 신뢰도 \(Int(suggestion.confidence * 100))%, \(String(format: "%.1f", Date().timeIntervalSince(llmStarted)))초)")
            print("이유: \(suggestion.reason ?? "-")")
            if !dry { print("기록됨 #\(suggestion.id ?? 0) — 앱의 파일 탭에서 옮길 수 있다") }
        } else {
            print("제안 없음 (후보가 없거나 LLM 이 확신하지 못함, \(String(format: "%.1f", Date().timeIntervalSince(llmStarted)))초)")
        }

    case "clean-topics":
        let apply = flag("--yes")
        let victims: [(GraphNode, String)] = try db.writer.read { conn in
            let tx = GraphTx(conn)
            let apps = Set(try tx.nodes(label: NodeLabel.app).map(\.title))
            let projects = Set(try tx.nodes(label: NodeLabel.project).map(\.title))
            return try tx.nodes(label: NodeLabel.topic).compactMap { node in
                TopicFilter.rejection(node.title, apps: apps, projects: projects).map { (node, $0) }
            }
        }
        if victims.isEmpty { print("거를 주제가 없습니다."); break }
        for (node, why) in victims { print("  \(node.title)  — \(why)") }
        guard apply else { print("\(victims.count)개. 지우려면 --yes 를 붙이세요 (앱을 끈 뒤)."); break }
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        try db.writer.write { conn in
            for (node, _) in victims {
                try conn.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [node.id, node.id])
                try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [node.id])
            }
        }
        instance.release()
        print("주제 \(victims.count)개를 지웠습니다.")

    case "merge-tasks":
        let dry = flag("--dry")
        let days = option("--days").flatMap(Double.init) ?? 7
        let instance = InstanceLock(databasePath: dbPath)
        guard dry || instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { if !dry { instance.release() } }
        let now = Date().timeIntervalSince1970
        let titles: [String: String] = try db.writer.read { conn in
            Dictionary(try GraphTx(conn).nodes(label: NodeLabel.task).map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
        let outcome = try await TaskMerger.run(db: db, llm: makeClient().client, since: now - days * 86_400, now: now, dry: dry)
        if outcome.groups.isEmpty && outcome.notGoals.isEmpty { print("합치거나 고칠 업무가 없습니다."); break }
        for group in outcome.groups {
            print("  남김: \(titles[group.keep] ?? group.keep)\(group.title.map { " → \($0)" } ?? "")\(group.goal.map { " (목표: \($0))" } ?? "")")
            for key in group.merge { print("    ← \(titles[key] ?? key)") }
        }
        for key in outcome.notGoals { print("  목표 아님 → 업무 외: \(titles[key] ?? key)") }
        print(dry ? "(--dry: 반영하지 않음)" : "업무 \(outcome.merged)개를 합치고 \(outcome.retired)개를 업무 외로 돌렸습니다.")

    case "retire-task":
        let keys = args
        guard !keys.isEmpty else { fail("사용법: retire-task TASK_ID [TASK_ID…]") }
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { instance.release() }
        let now = Date().timeIntervalSince1970
        for key in keys {
            let title = try db.writer.read { try GraphTx($0).node(label: NodeLabel.task, key: key)?.title }
            let done = try db.writer.write { try TaskMerger.retire(key, conn: $0, now: now) }
            print(done ? "업무 외로 돌림: \(title ?? key)" : "업무 없음: \(key)")
        }

    case "rebind-projects":
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        let chosen: [(String, String, Double)] = try db.writer.write { conn in
            let tx = GraphTx(conn)
            // 예전 방식(행마다 ON, 가중치 = 초)으로 쌓인 엣지를 시간 집계로 옮긴다
            for edge in try Row.fetchAll(conn, sql: "SELECT * FROM edges WHERE type = 'ON'").map(GraphTx.edge) {
                guard let task = try tx.node(id: edge.src), let project = try tx.node(id: edge.dst) else { continue }
                let known = task.props["project_seconds"]?.objectValue?[project.key]?.doubleValue ?? 0
                if edge.weight > known { try tx.addProjectSeconds(taskId: task.id, projectKey: project.key, seconds: edge.weight - known, at: edge.lastAt) }
            }
            return try tx.rebindProjects(at: Date().timeIntervalSince1970).compactMap { item in
                guard let task = try tx.node(id: item.taskId), let project = try tx.node(id: item.projectId) else { return nil }
                return (task.title, project.title, item.seconds)
            }
        }
        instance.release()
        for (task, project, seconds) in chosen { print("  \(task) → \(project)  (\(Int(seconds))초)") }
        print("업무 ↔ 프로젝트 \(chosen.count)쌍. 나머지 연결은 지웠습니다.")

    case "eval-assign":
        let outPath = option("--out")
        let runs = option("--runs").flatMap(Int.init) ?? 1
        guard let file = args.first, let data = FileManager.default.contents(atPath: file),
              let scenario = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rowSpecs = scenario["rows"] as? [[String: Any]] else { fail("사용법: eval-assign SCENARIO.json") }
        let base = 1_790_000_000.0                                   // 가짜 하루의 시작 시각
        var rows: [ActivityRow] = []
        for (index, spec) in rowSpecs.enumerated() {
            let start = base + (spec["min"] as? Double ?? 0) * 60, dur = (spec["dur"] as? Double ?? 0) * 60
            var row = ActivityRow(row: index + 1, start: start, end: start + dur, dwell: Int(dur),
                                  app: spec["app"] as? String ?? "?", appBundle: spec["bundle"] as? String ?? "?",
                                  title: spec["title"] as? String, uri: spec["uri"] as? String, type: spec["type"] as? String,
                                  projectKey: spec["project"] as? String, projectTitle: (spec["project"] as? String).map { ($0 as NSString).lastPathComponent },
                                  snippet: spec["text"] as? String, observationIds: [Int64(index + 1)])
            row.isChat = spec["chat"] as? Bool ?? false
            rows.append(row)
        }
        let openTasks = (scenario["open_tasks"] as? [[String: Any]] ?? []).map { task in
            TaskDigest(id: task["id"] as? String ?? "", title: task["title"] as? String ?? "", taskType: task["type"] as? String,
                       topics: task["topics"] as? [String] ?? [], recentResources: task["resources"] as? [String] ?? [], lastActive: base,
                       recentSummaries: task["recent"] as? [String] ?? [])
        }
        let prompt = OntologyPrompt.build(rows: rows, openTasks: openTasks, now: base + 7_200)
        let effort = option("--reasoning")                               // low | medium | high
        let client: any LLMClient = effort.map { CodexResponsesClient(auth: codexAuth, model: option("--model") ?? CodexResponsesClient.defaultModel, reasoningEffort: $0) } ?? makeClient().client
        var results: [[String: Any]] = []
        for run in 1...max(1, runs) {
            let started = Date()
            let answer = try await client.callFunction(system: prompt.system, user: prompt.user, tool: AssignmentSchema.tool)
            guard let patch = AssignmentPatch.decodeLenient(from: answer.arguments) else { fail("응답 해석 실패: \(answer.raw.prefix(300))") }
            let elapsed = Date().timeIntervalSince(started)
            // ref → 사람이 읽는 이름과 정답 비교용 키
            var refName: [String: String] = [:], refKey: [String: String] = [:]
            for def in patch.tasks {
                if def.match == "existing", let id = def.id { refName[def.ref] = openTasks.first { $0.id == id }?.title ?? id; refKey[def.ref] = id }
                else { refName[def.ref] = "새: " + (def.title ?? "?"); refKey[def.ref] = "new:" + (def.title ?? "") }
            }
            let decided = patch.byRow()
            var correct = 0, resourceCorrect = 0, resourceJudged = 0
            var rowResults: [[String: Any]] = []
            for (index, spec) in rowSpecs.enumerated() {
                let number = index + 1
                let expect = spec["expect"] as? [String: Any] ?? [:]
                let expectedTasks: [String?] = (expect["task"] as? [Any]).map { $0.map { $0 as? String } } ?? [expect["task"] as? String]   // "t_x" | "new:라벨" | "off" | nil, 여러 개면 그중 하나
                let expectedTask = expectedTasks.first ?? nil
                let expectedResource = expect["resource"]                // true | false | "any"
                let decision = decided[number]
                let actualRef = decision?.task
                let actualKey: String? = actualRef.flatMap { $0 == AssignmentPatch.offTask ? "off" : refKey[$0] }
                let actualName: String = actualRef.map { $0 == AssignmentPatch.offTask ? "이탈" : (refName[$0] ?? $0) } ?? (decision == nil ? "(언급 없음)" : "없음")
                func matches(_ wanted: String?) -> Bool {
                    guard let wanted else { return actualKey == nil && decision != nil }
                    if wanted == "off" { return actualKey == "off" }
                    if wanted.hasPrefix("new:") { return actualKey?.hasPrefix("new:") ?? false }
                    return actualKey == wanted
                }
                let taskOK = expectedTasks.contains(where: matches)
                let resourceActual = decision?.resource ?? AssignmentApplier.defaultResource(rows[index])
                var resourceOK: Bool? = nil
                if let wanted = expectedResource as? Bool, expectedTask != nil, expectedTask != "off" {
                    resourceOK = resourceActual == wanted; resourceJudged += 1; if resourceOK == true { resourceCorrect += 1 }
                }
                if taskOK { correct += 1 }
                rowResults.append(["row": number, "app": spec["app"] ?? "", "title": spec["title"] ?? NSNull(), "uri": spec["uri"] ?? NSNull(), "reason": decision?.reason ?? NSNull(),
                                   "text": spec["text"] ?? NSNull(), "min": spec["min"] ?? 0, "dur": spec["dur"] ?? 0, "why": spec["why"] ?? "",
                                   "expected_task": expectedTask ?? NSNull(), "expected_tasks": expectedTasks.map { $0 ?? "null" }, "expected_resource": expectedResource ?? NSNull(),
                                   "actual_task": actualKey ?? NSNull(), "actual_name": actualName, "actual_resource": resourceActual,
                                   "task_ok": taskOK, "resource_ok": resourceOK ?? NSNull()])
            }
            let work = patch.work.map { ["task": refName[$0.task] ?? $0.task, "summary": $0.summary, "topics": $0.topics] }
            let problems = (patch.problems ?? []).map { ["row": $0.row, "kind": $0.kind, "message": $0.message, "resolved_by_row": $0.resolvedByRow ?? NSNull()] as [String: Any] }
            print("run \(run): 업무 판정 \(correct)/\(rowSpecs.count), 자료 판정 \(resourceCorrect)/\(resourceJudged), \(String(format: "%.1f", elapsed))초, 토큰 \(answer.promptTokens)+\(answer.completionTokens)")
            for r in rowResults where !(r["task_ok"] as? Bool ?? false) || (r["resource_ok"] as? Bool) == false {
                print("  ✗ \(r["row"] ?? 0) \(r["title"] ?? "") — 기대 \(r["expected_task"] ?? "없음")/\(r["expected_resource"] ?? "-") 실제 \(r["actual_name"] ?? "")/\(r["actual_resource"] ?? "")")
            }
            results.append(["run": run, "elapsed": elapsed, "model": answer.model, "prompt_tokens": answer.promptTokens, "completion_tokens": answer.completionTokens,
                            "task_correct": correct, "resource_correct": resourceCorrect, "resource_judged": resourceJudged,
                            "tasks": patch.tasks.map { ["ref": $0.ref, "match": $0.match, "id": $0.id ?? NSNull(), "title": $0.title ?? NSNull(), "task_type": $0.taskType ?? NSNull()] as [String: Any] },
                            "work": work, "problems": problems, "rows": rowResults])
        }
        if let outPath {
            let payload: [String: Any] = ["scenario": file, "persona": scenario["persona"] ?? "", "open_tasks": scenario["open_tasks"] ?? [],
                                          "system_prompt": prompt.system, "user_prompt": prompt.user, "runs": results]
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: outPath))
            print("결과 → \(outPath)")
        }

    case "backfill-screen-hash":
        let rows: [(Int64, String)] = try db.writer.read { conn in
            try Row.fetchAll(conn, sql: "SELECT id, screenshot_path FROM observations WHERE screenshot_path IS NOT NULL AND screen_hash IS NULL")
                .map { ($0["id"] as Int64, $0["screenshot_path"] as String) }
        }
        var filled = 0, missing = 0
        for (id, path) in rows {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { missing += 1; continue }
            try store.attachScreen(observationId: id, path: nil, hash: ScreenCapturer.differenceHash(image))
            filled += 1
        }
        print("해시 \(filled)개 채움, 파일 없음 \(missing)개")

    case "recard":
        let ids = (option("--ids") ?? "").split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
        let kind = option("--kind")
        var targets: [ScreenCard] = try db.writer.read { conn in
            if !ids.isEmpty { return try ScreenCard.fetchAll(conn, keys: ids) }
            if let kind { return try ScreenCard.fetchAll(conn, sql: "SELECT * FROM screen_cards WHERE kind = ? ORDER BY ts_start", arguments: [kind]) }
            return []
        }
        targets = targets.filter { $0.screenshotPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
        guard !targets.isEmpty else { fail("다시 만들 카드가 없음 (--ids 또는 --kind, 스크린샷이 남아 있어야 함)") }
        guard let vision = makeClient().client as? any VisionLLMClient else { fail("이미지를 받는 LLM 이 아님") }
        var updated = 0
        for start in stride(from: 0, to: targets.count, by: CardMaker.maxImages) {
            let chunk = Array(targets[start..<min(start + CardMaker.maxImages, targets.count)])
            let groups = chunk.map { card in
                KeyframeSelector.Group(appBundle: card.appBundle, appName: card.appName, title: card.windowTitle, uri: card.uri,
                                       shots: [KeyframeSelector.Shot(observationId: 0, ts: card.tsStart, path: card.screenshotPath!, hash: UInt64(bitPattern: card.screenHash))],
                                       seconds: card.tsEnd - card.tsStart, rows: [], observationIds: [], start: card.tsStart, end: card.tsEnd)
            }
            let (drafts, result) = try await CardMaker.make(groups, llm: vision)
            try await db.writer.write { conn in
                for (index, draft) in drafts.enumerated() {
                    guard let draft, let id = chunk[index].id else { continue }
                    try conn.execute(sql: "UPDATE screen_cards SET activity = ?, content = ?, kind = ?, entities = ? WHERE id = ?",
                                     arguments: [draft.activity, draft.content.joined(separator: "\n"), draft.kind, CardMaker.entitiesJSON(draft.entities), id])
                }
            }
            for (index, draft) in drafts.enumerated() {
                guard let draft else { continue }
                updated += 1
                print("#\(chunk[index].id ?? 0) 전: \(chunk[index].activity)")
                print("      후: \(draft.activity)")
            }
            if let result { print("  (토큰 \(result.promptTokens)+\(result.completionTokens))") }
        }
        print("카드 \(updated)/\(targets.count)장을 다시 만들었습니다.")

    case "cards":
        let last = option("--last").flatMap(Int.init) ?? 20
        let cards = try db.writer.read { try ScreenCard.fetchAll($0, sql: "SELECT * FROM screen_cards ORDER BY ts_start DESC LIMIT ?", arguments: [last]) }
        for card in cards.reversed() {
            let start = Date(timeIntervalSince1970: card.tsStart).formatted(date: .numeric, time: .shortened)
            print("#\(card.id ?? 0) \(start) [\(card.kind)] \(card.appName) | \(card.windowTitle ?? "-")")
            print("   \(card.activity)")
            for line in card.contentLines { print("   · \(line)") }
            if card.entities != "{}" { print("   entities: \(card.entities)") }
        }

    case "topic-audit":
        let last = option("--last").flatMap(Int.init) ?? 200
        let (apps, projects) = try db.writer.read { conn -> (Set<String>, Set<String>) in
            let tx = GraphTx(conn)
            return (Set(try tx.nodes(label: NodeLabel.app).map(\.title)), Set(try tx.nodes(label: NodeLabel.project).map(\.title)))
        }
        var total = 0, rejected: [String: Int] = [:], examples: [String: Set<String>] = [:], batchesWithRejects = 0
        for batch in try store.recentBatches(limit: last).reversed() where batch.status == "ok" {
            guard let raw = batch.llmPatch, let patch = AssignmentPatch.decodeLenient(from: Data(raw.utf8)) else { continue }
            var hit = false
            for work in patch.work {
                for topic in work.topics {
                    total += 1
                    if let why = TopicFilter.rejection(topic, apps: apps, projects: projects) {
                        rejected[why, default: 0] += 1
                        examples[why, default: []].insert(topic)
                        hit = true
                    }
                }
            }
            if hit { batchesWithRejects += 1 }
        }
        let rejectedTotal = rejected.values.reduce(0, +)
        print("주제 태그 \(total)개 중 필터가 거르는 것 \(rejectedTotal)개 (\(total == 0 ? 0 : rejectedTotal * 100 / total)%), 배치 \(batchesWithRejects)개에서")
        for (why, count) in rejected.sorted(by: { $0.value > $1.value }) {
            print("  \(why): \(count)  예) \(examples[why, default: []].sorted().prefix(12).joined(separator: ", "))")
        }

    case "rejudge":
        let ids = args.compactMap(Int64.init)
        guard !ids.isEmpty else { fail("사용법: rejudge BATCH_ID [BATCH_ID…]") }
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { instance.release() }
        let (reopened, lastTs) = try store.reopenBatches(ids)
        guard let lastTs else { fail("그 배치들에 행이 없음") }
        print("배치 \(ids.count)개의 행 \(reopened)개를 지금 규칙으로 다시 판정합니다")
        var rejudgeConfig = BatchConfig()
        rejudgeConfig.findEvents = false                 // 지난 행을 다시 판정할 뿐: 일정은 처음 정리할 때 이미 찾았다
        let batcher = OntologyBatcher(db: db, llm: makeClient().client, config: rejudgeConfig)
        var round = 0
        while round < 20, let oldest = try store.oldestUnprocessedTs(), oldest <= lastTs {
            round += 1
            let outcome = await batcher.runIfDue(force: true)
            print("[\(round)] \(outcome)")
            guard case .ok = outcome else { break }
        }
        let rebuilt = try GraphRebuilder(db: db, store: store).rebuildFromAssignments(now: Date().timeIntervalSince1970)
        print("세션 \(rebuilt.sessions)개를 행 판단에서 다시 계산했습니다")
        try printStats()

    case "gold-candidates":
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
        guard let fromText = option("--from"), let from = day.date(from: fromText)?.timeIntervalSince1970 else {
            fail("사용법: gold-candidates --from YYYY-MM-DD [--to YYYY-MM-DD] [--limit N] [--model M] [--reasoning high] [--out FILE]")
        }
        let until = option("--to").flatMap { day.date(from: $0)?.timeIntervalSince1970 }.map { $0 + 86_400 } ?? .infinity
        let limit = option("--limit").flatMap(Int.init) ?? Int.max
        let out = option("--out") ?? evalDirectory + "/gold-candidates.json"
        let model = option("--model") ?? CodexResponsesClient.defaultModel
        let client = makeClient().client
        let jobs = try goldJobs(from: from, until: until, limit: limit)
        let labels = GoldLabels(tasks: try db.writer.read { try GraphTx($0).nodes(label: NodeLabel.task) })
        print("배치 \(jobs.count)개, 행 \(jobs.reduce(0) { $0 + $1.rows.count })개를 다시 판정합니다 (모델 \(model), 기록하지 않음)")
        let (patches, failedBatches, _) = await judgeGold(jobs, pipeline: .single, client: client)
        var items: [[String: Any]] = [], disagree = 0
        for job in jobs {
            guard let patch = patches[job.batchId] else { continue }
            let decided = patch.byRow()
            for row in job.rows {
                guard let current = job.current[row.row] else { continue }
                let judge = labels.label(patch, decided: decided, row: row.row)
                let agree = judge.label == current.label
                if !agree { disagree += 1 }
                items.append([
                    "batch": job.batchId, "row": row.row, "start": row.start, "dwell": row.dwell, "app": row.app,
                    "title": row.title ?? "", "uri": row.uri ?? "", "evidence": job.evidence[row.row] ?? "",
                    "current": ["label": current.label, "name": labels.name(current.label), "reason": current.reason],
                    "judge": ["label": judge.label, "name": labels.name(judge.label), "reason": judge.reason],
                    "agree": agree, "gold": agree ? current.label as Any : NSNull(),
                ])
            }
        }
        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let payload: [String: Any] = ["from": fromText, "model": model, "created": Date().timeIntervalSince1970, "failed_batches": failedBatches, "rows": items]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: out))
        print("행 \(items.count)개 중 갈린 행 \(disagree)개\(failedBatches.isEmpty ? "" : ", 실패한 배치 \(failedBatches)") → \(out)")

    case "gold-score":
        let path = option("--gold") ?? evalDirectory + "/gold.json"
        guard let graded = loadGoldRows(path) else { fail("정답 세트를 읽을 수 없음: \(path)") }
        var predictions: [String: String] = [:]
        if let predictionPath = option("--predictions") {
            guard let raw = FileManager.default.contents(atPath: predictionPath), let map = try? JSONSerialization.jsonObject(with: raw) as? [String: String] else {
                fail("예측 파일을 읽을 수 없음: \(predictionPath)")
            }
            predictions = map
        }
        print("정답 세트 \(graded.count)행 (사람이 고른 행 \(graded.filter { ($0["source"] as? String) == "human" }.count)개) — \(path)")
        printGoldScore("지금 판정", graded: graded) { ($0["current"] as? [String: Any])?["label"] as? String }
        printGoldScore("다시 판정", graded: graded) { ($0["judge"] as? [String: Any])?["label"] as? String }
        if !predictions.isEmpty { printGoldScore("예측", graded: graded) { predictions["\($0["batch"] ?? ""):\($0["row"] ?? "")"] } }

    case "gold-run":
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
        guard let fromText = option("--from"), let from = day.date(from: fromText)?.timeIntervalSince1970,
              let pipeline = BatchPipeline(rawValue: option("--pipeline") ?? "staged") else {
            fail("사용법: gold-run --from YYYY-MM-DD [--to YYYY-MM-DD] [--pipeline single|staged] [--runs N] [--limit N] [--model M] [--reasoning R] [--out FILE]")
        }
        let until = option("--to").flatMap { day.date(from: $0)?.timeIntervalSince1970 }.map { $0 + 86_400 } ?? .infinity
        let limit = option("--limit").flatMap(Int.init) ?? Int.max
        let runs = max(1, option("--runs").flatMap(Int.init) ?? 1)
        let out = option("--out") ?? evalDirectory + "/gold-run-\(pipeline.rawValue).json"
        let client = makeClient().client
        let goldPath = evalDirectory + "/gold.json"
        let gold = loadGoldRows(goldPath)
        // 정답 세트가 있으면 그 배치만, 정답 세트를 만들 때 있던 업무만 후보로 판정한다
        let goldBatches = gold.map { Set($0.compactMap { ($0["batch"] as? NSNumber)?.int64Value }) }
        let goldCreated = FileManager.default.contents(atPath: goldPath)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["created"] as? Double ?? .infinity
        let jobs = try goldJobs(from: from, until: until, limit: limit, tasksBefore: goldCreated).filter { goldBatches?.contains($0.batchId) ?? true }
        let labels = GoldLabels(tasks: try db.writer.read { try GraphTx($0).nodes(label: NodeLabel.task) })
        print("배치 \(jobs.count)개, 행 \(jobs.reduce(0) { $0 + $1.rows.count })개 — \(pipeline.rawValue) × \(runs)회 (기록하지 않음)")
        var predictionRuns: [[String: String]] = []
        for run in 1...runs {
            let started = Date()
            let (patches, failed, calls) = await judgeGold(jobs, pipeline: pipeline, client: client)
            var predictions: [String: String] = [:]
            for job in jobs {
                guard let patch = patches[job.batchId] else { continue }
                let decided = patch.byRow()
                for row in job.rows { predictions["\(job.batchId):\(row.row)"] = labels.label(patch, decided: decided, row: row.row).label }
            }
            predictionRuns.append(predictions)
            print(String(format: "  %d회: 호출 %d번 (배치당 %.1f), 실패 배치 %d개, %d초", run, calls, Double(calls) / Double(max(1, jobs.count)),
                         failed.count, Int(Date().timeIntervalSince(started))))
        }
        try FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let payload: [String: Any] = ["from": fromText, "pipeline": pipeline.rawValue, "created": Date().timeIntervalSince1970, "runs": predictionRuns]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
        print("→ \(out)")
        if let graded = gold {
            for (index, predictions) in predictionRuns.enumerated() {
                printGoldScore("\(pipeline.rawValue) \(index + 1)회", graded: graded) { predictions["\($0["batch"] ?? ""):\($0["row"] ?? "")"] }
            }
        }
        if predictionRuns.count >= 2 {
            let first = predictionRuns[0], second = predictionRuns[1]
            let shared = Set(first.keys).intersection(second.keys)
            let flipped = shared.filter { goldTaskLevel(first[$0]) != goldTaskLevel(second[$0]) }.count
            print(String(format: "  흔들림: 두 실행에서 업무 기준 판정이 달라진 행 %d/%d (%.1f%%)", flipped, shared.count, 100.0 * Double(flipped) / Double(max(1, shared.count))))
        }

    case "themes":
        let rows = try db.writer.read { conn -> [(theme: String, tasks: [String])] in
            let tx = GraphTx(conn)
            var byTheme: [String: [String]] = [:], none: [String] = []
            for task in try tx.nodes(label: NodeLabel.task) {
                if let theme = try ThemeGraph.theme(ofTask: task.id, tx) { byTheme[theme.title, default: []].append(task.title) } else { none.append(task.title) }
            }
            var rows = byTheme.sorted { $0.key < $1.key }.map { (theme: $0.key, tasks: $0.value) }
            if !none.isEmpty { rows.append((theme: "(분야 없음)", tasks: none)) }
            return rows
        }
        if rows.isEmpty { print("업무가 없습니다") }
        for row in rows {
            print("\(row.theme) (\(row.tasks.count))")
            for title in row.tasks { print("  - \(title)") }
        }

    case "assign-themes":
        let retype = flag("--retype"), dryRun = flag("--dry-run")
        let client = makeClient().client
        if dryRun {
            let loaded = try db.writer.read { try ThemeStep.load(GraphTx($0), retypeAll: retype) }
            guard !loaded.targets.isEmpty else { print("분야·종류를 붙일 업무가 없습니다"); break }
            print("업무 \(loaded.targets.count)개를 판정만 합니다 (기록하지 않음)")
            let answers = try await ThemeStep.judge(targets: loaded.targets, themes: loaded.themes, llm: client)
            for target in loaded.targets {
                let answer = answers[target.key]
                let theme = target.needsTheme ? (answer?.theme ?? "(답 없음)") : "(그대로)"
                let type = target.needsType ? (answer?.taskType ?? "(답 없음)") : "(그대로)"
                print("  \(target.title) → 분야 \(theme), 종류 \(type)")
            }
            break
        }
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱이 직접 분야를 붙이므로 앱을 종료한 뒤 다시 실행하세요.") }
        defer { instance.release() }
        guard let outcome = try await ThemeStep.run(db: db, llm: client, now: Date().timeIntervalSince1970, retypeAll: retype) else {
            print("분야·종류를 붙일 업무가 없습니다"); break
        }
        var line = "분야 \(outcome.themed)개, 종류 \(outcome.retyped)개"
        if !outcome.created.isEmpty { line += ", 새 분야 \(outcome.created.joined(separator: ", "))" }
        if outcome.skipped > 0 { line += ", 건너뜀 \(outcome.skipped)개" }
        print(line)

    case "theme-eval":
        let path = option("--gold") ?? evalDirectory + "/themes-gold.json"
        let runs = max(1, option("--runs").flatMap(Int.init) ?? 2)
        guard let raw = FileManager.default.contents(atPath: path),
              let file = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let gold = file["tasks"] as? [[String: String]] else { fail("정답 파일을 읽을 수 없음: \(path)") }
        let digests = try db.writer.read { try GraphTx($0).openTasks(limit: 10_000) }
        let byKey = Dictionary(digests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = gold.compactMap { item -> ThemeStep.Target? in
            guard let key = item["key"], let digest = byKey[key] else { return nil }
            return ThemeStep.Target(key: key, title: digest.title, goal: digest.goal, taskType: digest.taskType,
                                    recent: digest.recentSummaries, needsTheme: true, needsType: true)
        }
        guard targets.count == gold.count else { fail("정답의 업무 \(gold.count - targets.count)개를 DB 에서 찾지 못함") }
        let client = makeClient().client
        let defaultKeys = Set(ThemeCatalog.defaults.map(ThemeCatalog.matchKey))
        print("업무 \(targets.count)개 — 빈 분야 목록에서 \(runs)번 판정 (기록하지 않음)")
        var results: [[String: ThemeStep.Answer]] = []
        for run in 1...runs {
            let answers = try await ThemeStep.judge(targets: targets, themes: [], llm: client)
            results.append(answers)
            var themeOK = 0, typeOK = 0, misses: [String] = []
            for item in gold {
                let answer = answers[item["key"] ?? ""]
                let themeHit = themeKey(answer?.theme) == themeKey(item["theme"])
                let typeHit = answer?.taskType != nil && answer?.taskType == TBox.leafType(item["type"] ?? "")
                if themeHit { themeOK += 1 }
                if typeHit { typeOK += 1 }
                if !themeHit || !typeHit {
                    misses.append("    \(item["title"] ?? "") — 정답 \(item["theme"] ?? "")/\(item["type"] ?? ""), 답 \(answer?.theme ?? "-")/\(answer?.taskType ?? "-")")
                }
            }
            let created = Set(answers.values.compactMap(\.theme).map { ThemeCatalog.canonical($0) }.filter { !defaultKeys.contains(ThemeCatalog.matchKey($0)) })
            print("  \(run)회: 분야 \(themeOK)/\(gold.count), 종류 \(typeOK)/\(gold.count), 새 분야 \(created.count)" + (created.isEmpty ? "" : " (\(created.sorted().joined(separator: ", ")))"))
            for line in misses { print(line) }
        }
        if results.count >= 2 {
            let flipped = gold.filter { item in
                let key = item["key"] ?? ""
                return themeKey(results[0][key]?.theme) != themeKey(results[1][key]?.theme) || results[0][key]?.taskType != results[1][key]?.taskType
            }.count
            print("  흔들림: 두 번의 결과가 다른 업무 \(flipped)/\(gold.count)")
        }

    case "set-theme":
        let clear = flag("--clear")
        guard let key = args.first, clear || args.count > 1 else { fail("사용법: set-theme TASK_ID 분야이름 | set-theme TASK_ID --clear") }
        let name = args.dropFirst().joined(separator: " ")
        let instance = InstanceLock(databasePath: dbPath)
        guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { instance.release() }
        let now = Date().timeIntervalSince1970
        do {
            let message = try db.writer.write { conn -> String in
                let tx = GraphTx(conn)
                guard let task = try tx.node(label: NodeLabel.task, key: key) else { throw CommandError(description: "업무 없음: \(key)") }
                let before = try ThemeGraph.theme(ofTask: task.id, tx)?.title ?? "(분야 없음)"
                try ThemeGraph.detach(taskId: task.id, tx)
                if clear { return "\(task.title): \(before) → (분야 없음)" }
                let stamp = task.props["last_active"]?.doubleValue ?? task.updatedAt
                guard let attached = try ThemeGraph.attach(taskId: task.id, to: name, tx, now: now, linkedAt: stamp) else {
                    throw CommandError(description: "붙일 수 없음: 이름이 비었거나 \(ThemeCatalog.nameLimit)자를 넘거나, 분야가 \(ThemeCatalog.limit)개로 찼습니다")
                }
                return "\(task.title): \(before) → \(attached.node.title)"
            }
            print(message)
        } catch let error as CommandError {
            fail(error.description)
        }

    case "pipeline-graph":
        print(StagedPipeline.graph.mermaid())

    case "replay-batch":
        let ids = args.compactMap(Int64.init)
        guard !ids.isEmpty else { fail("사용법: replay-batch ID [ID…]") }
        let client = makeClient().client
        let (apps, projects) = try db.writer.read { conn -> (Set<String>, Set<String>) in
            let tx = GraphTx(conn)
            return (Set(try tx.nodes(label: NodeLabel.app).map(\.title)), Set(try tx.nodes(label: NodeLabel.project).map(\.title)))
        }
        func describe(_ patch: AssignmentPatch) -> [String] {
            let names = Dictionary(patch.tasks.map { ($0.ref, "\($0.match)\($0.id.map { "(\($0))" } ?? "") \($0.title ?? "")") }, uniquingKeysWith: { first, _ in first })
            var lines = patch.rows.map { "  rows \($0.rows) → \($0.task.flatMap { names[$0] } ?? "(없음)")\(($0.resource ?? true) ? "" : " [보이기만]")" }
            for work in patch.work {
                let flagged = work.topics.map { topic in TopicFilter.rejection(topic, apps: apps, projects: projects).map { "\(topic)✗(\($0))" } ?? topic }
                lines.append("  work \(names[work.task] ?? work.task): \(work.summary) — topics: \(flagged.joined(separator: ", "))")
            }
            return lines
        }
        for id in ids {
            guard let batch = try store.batch(id: id), let userPrompt = batch.userPrompt else { print("#\(id): 배치 없음 또는 프롬프트 미저장"); continue }
            print("=== 배치 #\(id) (\(batch.rowCount)행, \(Date(timeIntervalSince1970: batch.startedAt).formatted(date: .omitted, time: .shortened))) ===")
            if let raw = batch.llmPatch, let old = AssignmentPatch.decodeLenient(from: Data(raw.utf8)) {
                print("이전 응답 (배정 \(old.rows.count)줄):"); describe(old).forEach { print($0) }
            }
            let started = Date()
            let result = try await client.callFunction(system: OntologyPrompt.system, user: userPrompt, tool: AssignmentSchema.tool)
            guard let fresh = AssignmentPatch.decodeLenient(from: result.arguments) else { print("새 응답: 해석 실패\n\(result.raw.prefix(300))"); continue }
            print("지금 프롬프트 (배정 \(fresh.rows.count)줄, \(String(format: "%.1f", Date().timeIntervalSince(started)))초, 토큰 \(result.promptTokens)+\(result.completionTokens)):")
            describe(fresh).forEach { print($0) }
        }

    case "erase-theme":
        guard let title = args.first, !title.hasPrefix("--") else { fail("사용법: erase-theme 분야이름 [--yes]") }
        let yes = flag("--yes")
        let instance = InstanceLock(databasePath: dbPath)
        if yes, !instance.acquire() { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { if yes { instance.release() } }
        let now = Date().timeIntervalSince1970
        let report = yes ? try db.writer.write { try TaskEraser.erase(theme: title, conn: $0, now: now, dry: false) }
                         : try db.writer.read { try TaskEraser.erase(theme: title, conn: $0, now: now, dry: true) }
        guard !report.tasks.isEmpty else { fail("'\(title)' 분야나 그 분야의 업무가 없습니다") }
        print("분야 '\(title)'의 업무 \(report.tasks.count)개: \(report.tasks.joined(separator: " / "))")
        print("원시 행 \(report.observations), 화면 카드 \(report.cards), 글 조각 \(report.texts), AI 대화 \(report.chats), 녹음 \(report.recordings), 요약 \(report.digests), 일정 제안 \(report.suggestions), 원문을 비울 정리 기록 \(report.batches), 파일 \(report.files.count)")
        guard yes else { print("세기만 했습니다. 지우려면 앱을 끄고 --yes 를 붙이세요."); break }
        let files = TaskEraser.removeFiles(report.files, within: URL(fileURLWithPath: dbPath).deletingLastPathComponent().path)
        if files.skipped > 0 { print("이 DB 의 데이터 폴더 밖 파일 \(files.skipped)개는 지우지 않았습니다 (DB 사본이면 진짜 파일이라서)") }
        let removed = files.removed
        try TaskEraser.compact(db)
        print("지웠습니다 (파일 \(removed)개). DB 를 VACUUM 했습니다.")

    case "weekly-review":
        let started = Date()
        let proposals = try await WeeklyReview.plan(db: db, llm: makeClient().client, now: Date().timeIntervalSince1970)
        print("제안 \(proposals.count)개 (\(String(format: "%.1f", Date().timeIntervalSince(started)))초)")
        for kind in ReviewProposal.Kind.allCases {
            let items = proposals.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            print("== \(kind.rawValue) \(items.count)")
            for item in items { print("  · \(item.summary)") }
        }

    case "erase-node":
        guard args.count >= 2, !args[0].hasPrefix("--") else { fail("사용법: erase-node 종류 키 [--yes]") }
        let (label, key, yes) = (args[0], args[1], flag("--yes"))
        let instance = InstanceLock(databasePath: dbPath)
        if yes, !instance.acquire() { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱을 종료한 뒤 다시 실행하세요.") }
        defer { if yes { instance.release() } }
        let now = Date().timeIntervalSince1970, started = Date()
        let report = yes ? try db.writer.write { try NodeEraser.erase(label: label, key: key, conn: $0, now: now, dry: false) }
                         : try db.writer.read { try NodeEraser.erase(label: label, key: key, conn: $0, now: now, dry: true) }
        guard !report.title.isEmpty else { fail("\(label) '\(key)' 노드가 없습니다") }
        guard report.erasable else { fail("'\(report.title)'은 클래스라 지우지 않습니다") }
        print("\(label) '\(report.title)': 노드 \(report.nodes), 원시 행 \(report.observations), 화면 카드 \(report.cards), 글 조각 \(report.texts), AI 대화 \(report.chats), 녹음 \(report.recordings), 원문을 비울 정리 기록 \(report.batches), 파일 \(report.files.count) (\(String(format: "%.2f", Date().timeIntervalSince(started)))초)")
        guard yes else { print("세기만 했습니다. 지우려면 앱을 끄고 --yes 를 붙이세요."); break }
        let files = TaskEraser.removeFiles(report.files, within: URL(fileURLWithPath: dbPath).deletingLastPathComponent().path)
        if files.skipped > 0 { print("이 DB 의 데이터 폴더 밖 파일 \(files.skipped)개는 지우지 않았습니다 (DB 사본이면 진짜 파일이라서)") }
        let removed = files.removed
        try TaskEraser.compact(db)
        print("지웠습니다 (파일 \(removed)개). DB 를 VACUUM 했습니다.")

    case "find-events":
        let ids = args.compactMap(Int64.init)
        guard !ids.isEmpty else { fail("사용법: find-events ID [ID…]") }
        let client = makeClient().client
        let known = try EventSuggestionStore(db).upcoming(from: Calendar.current.startOfDay(for: Date()))
            .map { EventFinder.Known(title: $0.title, start: Date(timeIntervalSince1970: $0.start), allDay: $0.allDay) }
        let rejected = try EventSuggestionStore(db).dismissed()
        for id in ids {
            guard let batch = try store.batch(id: id), let prompt = batch.userPrompt else { print("#\(id): 배치 없음 또는 프롬프트 미저장"); continue }
            // 3단계 배치면 ① 업무 여부 단계의 행 줄: ROWS 머리줄 다음부터 다음 단계 표시([assign]) 전까지
            let lines = prompt.components(separatedBy: "\n")
            guard let header = lines.firstIndex(where: { $0.hasPrefix("ROWS (row | time") }) else { print("#\(id): 행 줄 없음"); continue }
            let rows = lines[(header + 1)...].prefix { !($0.hasPrefix("[") && $0.hasSuffix("]") && !$0.contains(" ")) }
            // 저장된 행 줄에는 시각만 있어 배치 날짜를 날짜 줄로 붙인다 (자정을 넘긴 배치는 하루 어긋날 수 있다)
            let dated = [OntologyPrompt.dateLine(batch.startedAt, timeZone: .current)] + rows
            print("=== 배치 #\(id) (\(batch.rowCount)행, \(Date(timeIntervalSince1970: batch.startedAt).formatted(date: .abbreviated, time: .shortened))) ===")
            let started = Date()
            let result = try await client.callFunction(system: EventFinder.system,
                                                       user: EventFinder.prompt(rowLines: dated, known: known, rejected: rejected, now: batch.startedAt, timeZone: .current),
                                                       tool: EventFinder.tool)
            let found = EventFinder.decode(result.arguments)
            print("  \(String(format: "%.1f", Date().timeIntervalSince(started)))초, 토큰 \(result.promptTokens)+\(result.completionTokens)\(found.isEmpty ? ", 일정 없음" : "")")
            for event in found {
                let mark = event.wanted ? "제안" : "  뺌"
                print("  \(mark) 행 \(event.row) | \(event.whose ?? "-") | \(event.date) \(event.startTime ?? "종일")\(event.endTime.map { "-\($0)" } ?? "") | \(event.title) | “\(event.evidence)”")
            }
        }

    case "tasks":
        let last = option("--last").flatMap(Int.init) ?? 20
        let rows: [(GraphNode, Int)] = try db.writer.read { conn in
            let tx = GraphTx(conn)
            return try tx.nodes(label: NodeLabel.task).map { ($0, try tx.edges(to: $0.id, type: EdgeType.partOf).count) }
        }
        for (node, sessions) in rows.sorted(by: { ($0.0.props["last_active"]?.doubleValue ?? 0) > ($1.0.props["last_active"]?.doubleValue ?? 0) }).prefix(last) {
            let minutes = Int((node.props["active_seconds"]?.doubleValue ?? 0) / 60)
            let last = Date(timeIntervalSince1970: node.props["last_active"]?.doubleValue ?? 0).formatted(date: .numeric, time: .shortened)
            print("#\(node.id)  \(node.title)  — \(minutes)분, 세션 \(sessions)개, 마지막 \(last)  [\(node.key)]")
        }

    case "sessions":
        guard let taskId = args.first.flatMap(Int64.init) else { fail("사용법: sessions TASK_ID") }
        let sessions: [GraphNode] = try db.writer.read { conn in
            let tx = GraphTx(conn)
            return try tx.edges(to: taskId, type: EdgeType.partOf).compactMap { try tx.node(id: $0.src) }
        }
        for node in sessions.sorted(by: { ($0.props["start"]?.doubleValue ?? 0) > ($1.props["start"]?.doubleValue ?? 0) }) {
            let start = Date(timeIntervalSince1970: node.props["start"]?.doubleValue ?? 0).formatted(date: .numeric, time: .shortened)
            let end = Date(timeIntervalSince1970: node.props["end"]?.doubleValue ?? 0).formatted(date: .omitted, time: .shortened)
            print("#\(node.id)  \(start) – \(end)  \(node.title)")
        }

    case "resume-plan":
        let sessionId = option("--session").flatMap(Int64.init)
        let nodeId = sessionId ?? args.first.flatMap(Int64.init)
        guard let nodeId else { fail("사용법: resume-plan TASK_ID | --session SESSION_ID") }
        let home = NSHomeDirectory()
        let plan: ResumePlan? = try db.writer.read { conn in
            let tx = GraphTx(conn)
            guard let node = try tx.node(id: nodeId) else { return nil }
            let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
            if node.label == NodeLabel.task { return try ResumePlanner.plan(task: node, tx: tx, home: home, fileExists: exists) }
            if node.label == NodeLabel.session { return try ResumePlanner.plan(session: node, tx: tx, home: home, fileExists: exists) }
            return nil
        }
        guard let plan else { fail("업무나 세션 노드가 아님: #\(nodeId)") }
        print("다시 열기: \(plan.title)  ([x] = 기본으로 켜는 것)")
        for item in plan.items {
            let target = item.target.hasPrefix(home) ? "~" + item.target.dropFirst(home.count) : item.target
            let when = Date(timeIntervalSince1970: item.lastAt).formatted(date: .omitted, time: .shortened)
            print("  \(item.selected ? "[x]" : "[ ]") [\(item.kind.rawValue)] \(item.title)  → \(target)\(item.appBundle.map { "  (\($0))" } ?? "")  \(Int(item.seconds / 60))분, 마지막 \(when)")
        }
        if plan.items.isEmpty { print("  (열 것이 없음)") }

    case "suggestions":
        let last = option("--last").flatMap(Int.init) ?? 20
        for item in try FileSuggestionStore(db).recent(limit: last).reversed() {
            let time = Date(timeIntervalSince1970: item.ts).formatted(date: .numeric, time: .shortened)
            print("#\(item.id ?? 0) \(time) [\(item.status)] \(item.fileName) → \(item.suggestedFolder) (\(item.source) \(Int(item.confidence * 100))%)\(item.movedTo.map { " 옮긴 곳: \($0)" } ?? "")")
        }

    case "neighbors":
        let hops = option("--hops").flatMap(Int.init) ?? 2
        guard args.count >= 2 else { fail("사용법: neighbors LABEL KEY [--hops N]") }
        let graph = try db.writer.read { conn -> Subgraph in
            let tx = GraphTx(conn)
            guard let node = try tx.node(label: args[0], key: args[1]) else { return Subgraph() }
            return try tx.neighbors(of: node.id, hops: hops)
        }
        for node in graph.nodes { print("(\(node.label)\(node.subtype.map { ":\($0)" } ?? "")) \(node.title)  [\(node.key)]") }
        let titles = Dictionary(graph.nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for edge in graph.edges { print("  \(titles[edge.src] ?? "?") -[\(edge.type) w=\(Int(edge.weight))]-> \(titles[edge.dst] ?? "?")") }

    case "storage":
        let captures = URL(fileURLWithPath: dbPath).deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
        let usage = try StorageUsage.measure(db: db, capturesDir: captures)
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        print("측정 방식: \(usage.measuredWithDBStat ? "SQLite dbstat" : "내용 길이로 어림 (dbstat 없음)")")
        for category in StorageUsage.Category.allCases {
            guard let bytes = usage.bytes[category], bytes > 0 else { continue }
            let growth = (usage.dailyGrowth[category] ?? 0) > 0 ? "  (최근 30일 하루 평균 +\(size(usage.dailyGrowth[category]!)))" : ""
            print("  \(category.title): \(size(bytes))\(growth)")
        }
        print("합계 \(size(usage.total)) · DB 파일(+WAL) \(size(usage.databaseFileBytes)) · 빈 페이지 \(usage.freePages)개 (\(size(Int64(usage.freePages * usage.pageSize))))")
        print("최근 30일 DB 하루 평균 증가: \(size(usage.totalDailyGrowth))")

    case "retention":
        var policy = try db.writer.read { try RetentionPolicy.load($0) }
        var changed = false
        if let name = option("--preset") {
            guard let preset = RetentionPolicy.Preset(rawValue: name) else { fail("프리셋: \(RetentionPolicy.Preset.allCases.map(\.rawValue).joined(separator: ", "))") }
            policy.apply(preset); changed = true
        }
        while let assignment = option("--set") {
            let parts = assignment.split(separator: "=").map(String.init)
            guard parts.count == 2, let item = RetentionPolicy.Item(rawValue: parts[0]), parts[1] == "none" || Int(parts[1]) != nil else {
                fail("--set 항목=일수|none (항목: \(RetentionPolicy.Item.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            policy.setDays(item, Int(parts[1])); changed = true
        }
        if let grace = option("--grace").flatMap(Int.init) { policy.graceDays = grace; changed = true }
        if let narrate = option("--narrate") { policy.narrateDigests = narrate == "on"; changed = true }
        if changed {
            let saved = policy.normalized()
            try db.writer.write { try saved.save($0) }
            policy = saved
        }
        print("프리셋: \(policy.preset?.title ?? "사용자 지정")")
        for item in RetentionPolicy.Item.allCases { print("  \(item.rawValue) (\(item.title)): \(policy.days(item).map { "\($0)일" } ?? "무기한")") }
        print("  유예 \(policy.graceDays)일 · 요약 서술 \(policy.narrateDigests ? "AI" : "끔")")
        let consented = try db.writer.read { try ConsolidationStore.value(ConsolidationStore.Key.firstPruneConsentedAt, $0) }
        print("첫 정리 동의: \(consented.flatMap(Double.init).map { Date(timeIntervalSince1970: $0).formatted() } ?? "아직 없음 (consolidate --consent)")")

    case "pins":
        let now = Date().timeIntervalSince1970
        for (name, add) in [("--add", true), ("--remove", false)] {
            while let value = option(name) {
                let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let kind = RetentionPin.Kind(rawValue: parts[0]) else { fail("pins --add|--remove task:업무KEY | period:YYYY-MM-DD..YYYY-MM-DD") }
                try db.writer.write { conn in
                    if add { try ConsolidationStore.pin(kind, key: parts[1], at: now, conn) } else { try ConsolidationStore.unpin(kind, key: parts[1], conn) }
                }
            }
        }
        let pins = try db.writer.read { try ConsolidationStore.pins($0) }
        if pins.isEmpty { print("보존 핀 없음") }
        for pin in pins { print("\(pin.kind.rawValue): \(pin.key)") }

    case "consolidate":
        let dry = flag("--dry-run"), ledgerOnly = flag("--ledger-only"), noPrune = flag("--no-prune"), consent = flag("--consent"), noLLM = flag("--no-llm")
        let now = Date().timeIntervalSince1970
        if dry {
            let plan = try Pruner(db: db, ledger: LedgerBuilder()).plan(now: now)
            if plan.isEmpty {
                print("지금 지울 원문 없음")
            } else {
                print("정리할 날: \(plan.firstDay ?? "-") ~ \(plan.lastDay ?? "-") (\(plan.days.count)일)")
                for (category, count) in plan.counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { print("  \(category.item.title): \(count)건") }
                print("예상 회수: 약 \(ByteCountFormatter.string(fromByteCount: plan.estimatedBytes, countStyle: .file))")
            }
            for reason in plan.keptReasons { print("원문을 남기고 건너뛴 주: \(reason)") }
            if let reason = plan.blockedReason { print("멈춘 이유: \(reason)") }
            if plan.consentNeeded { print("첫 정리 동의가 아직 없습니다. 실제로 지우려면 consolidate --consent") }
        } else {
            let instance = InstanceLock(databasePath: dbPath)
            guard instance.acquire() else { fail("이 DB 를 쓰는 Sillog 앱이 실행 중입니다. 앱이 직접 정리하므로 앱을 끈 뒤에 실행하세요.") }
            defer { instance.release() }
            if consent { try db.writer.write { try ConsolidationStore.set(ConsolidationStore.Key.firstPruneConsentedAt, String(now), $0) } }
            let consolidator = Consolidator(db: db, llm: noLLM ? nil : makeClient().client)
            let report = await consolidator.run(prune: !noPrune, ledgerOnly: ledgerOnly, narrate: noLLM ? false : nil)
            print("사용 시간 기록 \(report.ledgerDays)일 갱신 · \(report.summary)")
            for note in report.notes { print("  - \(note)") }
            if ledgerOnly {
                // 업무 화면의 시간(업무 노드)과 사용 시간 기록 합계 비교. 실시간 정리는 창 끝을 조금 다르게 잡아 몇 초 어긋날 수 있다
                let (totals, tasks) = try db.writer.read { conn in
                    (try LedgerBuilder().taskTotals(conn, now: now), try GraphTx(conn).nodes(label: NodeLabel.task))
                }
                var differ = 0
                for task in tasks {
                    let shown = task.props["active_seconds"]?.doubleValue ?? 0, ledger = totals[task.key]?.seconds ?? 0
                    if abs(shown - ledger) >= 60 { differ += 1; print("  \(task.title): 업무 화면 \(Int(shown))초 / 사용 시간 기록 \(Int(ledger))초") }
                }
                print("업무 \(tasks.count)개 중 1분 이상 다른 것 \(differ)개")
            }
        }

    case "digest":
        let sub = args.first ?? "list"
        if !args.isEmpty { args.removeFirst() }
        let task = option("--task")
        let period = option("--week") ?? option("--month")
        let digests = try db.writer.read { conn in
            try DigestStore.recent(conn, period: sub == "show" ? period : nil, limit: 100).filter { task == nil || $0.taskKey == task }
        }
        if sub == "show" && period == nil { fail("사용법: digest show --week 2026-W40 | --month 2026-10 [--task 업무KEY]") }
        if digests.isEmpty { print("다이제스트 없음") }
        for digest in digests {
            print("== \(digest.title) [\(digest.status.rawValue)\(digest.model.map { ", \($0)" } ?? "")] key=\(digest.taskKey)")
            if sub == "show" { print(digest.body + "\n") }
        }

    default:
        print(usage)
        exit(command == "help" || command == "--help" ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
