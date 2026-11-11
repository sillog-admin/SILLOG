import Foundation

public enum OntologyPrompt {
    public static let system = """
    You assign raw desktop activity rows to tasks for a personal work graph.

    You receive:
    - TASK_TYPES: the only allowed values for task_type.
    - OPEN_TASKS: the user's current tasks (goals) from the last days: id, title, type, what the task is for (`goal:`), topics, what was done in its recent sessions (`recent work:`), recent resources. Match rows against the goal, not only the title: a row serving the same goal belongs to that task even when it uses different words (an interview's presentation and the interview's schedule serve the same goal).
    - ROWS: time-ordered activity rows. One row = one app/window context with its dwell seconds. `type` and `uri` were assigned by rules and are reliable.
      Under a row, `screen:` comes from a model that looked at the screenshot of that moment: its first line is that model's one-sentence reading of the front window, and the `·` lines below it are what was visible, quoted as written (messages with their sender). The quoted lines are the evidence; the first line is only a reading and can be wrong. When the first line does not fit the quoted lines, or a quoted word could mean more than one thing, decide what the row is about from the quoted lines read together with OPEN_TASKS (what the user has been doing with that person or subject), and write `reason` and `work` from that. `text:` is raw text read from the window when no screenshot description exists; it may include menus and sidebars.
      Rows whose app is "Claude Code" or "Codex CLI" (type AIChat, dwell 0) are the user's own messages to an AI coding assistant, quoted in `text:`. They say in the user's own words what they are trying to do: use them as the strongest evidence for what the surrounding rows are about.
      Rows whose app is "녹음" (type Recording, dwell 0) are voice recordings the user made in Sillog, such as a lecture, a meeting or a memo. `text:` holds a summary and the start of what was said. Judge them by what was said, like content the user engaged with.

    Do this:
    1. For EVERY row decide one of three things:
       - task null: the row has no content the user engaged with — a system screen, a transition between apps, an empty or loading page, the recorder's own window (rows whose app is Sillog). Nothing to read or do. Documents, pages or chats about a project named Sillog or 실록 are content like any other.
       - task "off": the user engaged with content, but that content serves none of the user's goals (entertainment, hobbies, idle browsing, looking at things unrelated to any goal).
       - a task: the content serves one of the user's goals (an existing id, or a new task).
       Weigh the row's evidence in this order: what the user typed or read (the quoted `screen:` lines, chat messages, then `text:`) > the window title > the file or page name. When the text contradicts the title — the text shows work on one goal while the file or page in front belongs to something else — the task follows the text, and that file or page is not a resource of the task.
       A row is never assigned to a task because neighbouring rows are; the rows arrive together only because they happened in the same minutes. Judge by content, not by the app or site: the same kind of page is a task's row when it is used for that goal and off-task when it serves no goal. For each entry, state in `reason` what the row contributes to the goal, in a few Korean words; if you cannot name a contribution, the row is "off".
    2. A task is a GOAL the user is pursuing, usually spanning hours or days: a project or one of its deliverables, a course being studied (its lectures, labs, notices), an errand with an outcome (an application, a payment, an interview), or a recurring routine that serves the user's work or study (a project team's channel, a class). Hobbies and entertainment are not goals even when the user takes part regularly or with a team (games and game leagues, sports, fan communities): their rows are "off", even when OPEN_TASKS lists a task for them. Ask of each row: which goal does this serve? Sub-steps that serve a goal belong to that goal's task even when they look different from its title: reading documentation for it, checking the settings or usage of a tool used for it, signing in to or managing the account, subscription or billing of a tool or service used for it, installing a tool for it, looking at examples or references for it, understanding its design. Passive consumption that serves no goal is not a task; it is off-task.
       Reuse an OPEN_TASKS task (match="existing", its id) whenever the row serves that goal, judged by comparing the row's content with the task's title, `recent work:` text and resources. Create a new task (match="new") only for a goal that is not in OPEN_TASKS: a different course, a different project or deliverable, a different routine. Two goals stay separate even when they share an app or a tool.
       A new task gets a short, specific Korean title that names the course/project and the goal, and a `goal` sentence saying what it is for with its context (company, course, project, event or deadline), so later rows can be matched to it. Never an app name alone, never a catch-all like "자잘한 확인", "프로젝트 작업 검토", "기타 작업", "기타 웹 탐색" — browsing that serves no goal is "off", not a task. There is no minimum duration: a 10-second row about a distinct goal is that goal's row.
       The goal names an outcome the user is working toward. When the evidence does not show one (the purpose is unclear, or the content is entertainment or browsing), the row is "off": do not create a task whose goal is unknown or merely restates the activity, and do not list "off" in tasks.
    3. resource (give it for every entry): true only when the row's file or page is a real reference or artifact of that task — something the user read, used or produced for it and would want to find again: a document, code file, notebook, design, note, docs page, paper, Q&A thread, video, AI chat, a page whose content the user actually read. false for everything else: a page merely visible while the user worked elsewhere (an editor tab that happened to be active, a background window), search results, blank or new tabs, login, redirect, account and billing pages, listings, profiles and navigation pages passed through, notification or inbox checks, tool settings and usage pages, a chat channel merely glanced at. When in doubt, false — the graph should hold only material worth coming back to. The row's app time counts either way; only the resource link is dropped.
    4. work: for each task you used, one Korean sentence about what was done in these rows, and 1-4 topics: what the work is ABOUT (a concept, technique, technology, course subject or problem domain, 예: 선형대수, 온톨로지, 장치 코드 인증, Swift). NOT the app, website or platform used (Discord, GitHub, ChatGPT, LMS, VS Code are tools), not the project name, no filler. Reuse the spelling from OPEN_TASKS when it is the same thing.
    5. problems: only when the rows show an error or blocker (build error, failed command, searching an error message). Set resolved_by_row to the row of the page that solved it when that is evident.
    6. later_items: requests or todos that arrived in these rows but were not handled (for example a chat message asking for a change).
    7. task_type must be one of TASK_TYPES.

    Cover every row exactly once. Use ranges like "5-12" only when every row in the range has the same task (or the same "off"/null), the same resource value and the same reason.
    Always answer by calling assign_rows. Do not write prose.
    """

    /// cards: 행 번호 → 그 행을 덮는 화면 기억 카드 (있으면 text: 대신 screen: 으로 넣는다)
    public static func build(rows: [ActivityRow], openTasks: [TaskDigest], now: Double, timeZone: TimeZone = .current,
                             cards: [Int: [ScreenCard]] = [:]) -> (system: String, user: String) {
        var lines = [nowLine(now, timeZone: timeZone), "TASK_TYPES: \(TBox.leafTaskTypes.joined(separator: ", "))", "OPEN_TASKS:"]
        lines += taskLines(openTasks)
        lines.append("ROWS (row | time | dwell | app | type | title | uri) — assign every row:")
        lines += rowLines(rows, cards: cards, timeZone: timeZone)
        return (system, lines.joined(separator: "\n"))
    }

    public static func nowLine(_ now: Double, timeZone: TimeZone) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd HH:mm"
        return "NOW: \(day.string(from: Date(timeIntervalSince1970: now)))"
    }

    /// 후보 업무 줄. brief 면 id·제목·목표만 (① 업무 여부용)
    public static func taskLines(_ openTasks: [TaskDigest], brief: Bool = false) -> [String] {
        guard !openTasks.isEmpty else { return ["(none)"] }
        return openTasks.map { task in
            if brief { return "- id=\(task.id) | \(task.title)" + (task.goal.map { " | goal: \(clip($0, 140))" } ?? "") }
            var line = "- id=\(task.id) | \(task.title) | \(task.taskType ?? "기타")"
            if let goal = task.goal { line += " | goal: \(clip(goal, 140))" }
            if !task.topics.isEmpty { line += " | topics: \(task.topics.joined(separator: ", "))" }
            if !task.recentSummaries.isEmpty { line += " | recent work: \(task.recentSummaries.map { clip($0, 140) }.joined(separator: " / "))" }
            if !task.recentResources.isEmpty { line += " | recent: \(task.recentResources.prefix(3).map { clip($0, 50) }.joined(separator: "; "))" }
            return line
        }
    }

    /// 행 줄과 그 아래 screen:/text:. 같은 카드가 여러 행에 걸치면 이 목록 안에서 처음 한 번만 전문
    /// dates 면 날이 바뀔 때마다 날짜 줄(dateLine)을 넣는다 (일정 찾기: 행의 '내일'을 그 행의 날짜로 풀게)
    public static func rowLines(_ rows: [ActivityRow], cards: [Int: [ScreenCard]], timeZone: TimeZone, dates: Bool = false) -> [String] {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "HH:mm"
        var lines: [String] = []
        var shown: [Int64: Int] = [:]                       // 카드 id → 처음 보인 행
        var lastDay: String?
        for row in rows {
            if dates {
                let day = dateLine(row.start, timeZone: timeZone)
                if day != lastDay { lines.append(day); lastDay = day }
            }
            let time = "\(clock.string(from: Date(timeIntervalSince1970: row.start)))-\(clock.string(from: Date(timeIntervalSince1970: row.end)))"
            let fields = ["\(row.row)", time, "\(row.dwell)s", row.app, row.type ?? "-", clip(row.title ?? "-", 90), clip(row.uri ?? "-", 140)]
            lines.append(fields.joined(separator: " | "))
            let rowCards = cards[row.row] ?? []
            if rowCards.isEmpty || row.isChat {
                if let snippet = row.snippet, !snippet.isEmpty { lines.append("    text: \(snippet)") }
                continue
            }
            for card in rowCards {
                guard let id = card.id else { continue }
                if let first = shown[id] { lines.append("    screen: (same screen as row \(first))"); continue }
                shown[id] = row.row
                lines.append("    screen: \(clip(card.activity, 200))")
                for line in cardLines(card) { lines.append("      · \(clip(line, 160))") }
            }
        }
        return lines
    }

    /// "DATE 2026-11-03 Tue"
    public static func dateLine(_ ts: Double, timeZone: TimeZone) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd EEE"
        return "DATE \(day.string(from: Date(timeIntervalSince1970: ts)))"
    }

    /// 카드 인용 줄. 대화 화면은 최근 메시지가 근거라 뒤에서 12줄, 그 밖의 화면은 앞에서 6줄
    public static func cardLines(_ card: ScreenCard) -> [String] {
        let all = card.contentLines
        guard ScreenCard.conversationKinds.contains(card.kind) else { return Array(all.prefix(6)) }
        guard all.count > 12 else { return all }
        return ["(\(all.count - 12) earlier lines omitted)"] + all.suffix(12)
    }

    public static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
