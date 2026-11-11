import Foundation

/// 3단계 판정의 프롬프트. 규칙은 OntologyPrompt.system 에서 단계별로 나눠 옮겼다
public enum StagePrompt {
    /// ③에 넘기는 업무 묶음
    public struct Group: Sendable {
        public var ref: String
        public var isNew: Bool
        public var title: String
        public var goal: String?
        public var rows: [ActivityRow]
        /// 기존 업무가 이미 쓰는 주제 (같은 뜻이면 그 이름을 다시 쓰게)
        public var topics: [String]
        public init(ref: String, isNew: Bool, title: String, goal: String?, rows: [ActivityRow], topics: [String] = []) {
            self.ref = ref; self.isNew = isNew; self.title = title; self.goal = goal; self.rows = rows; self.topics = topics
        }
    }

    static let rowsHeader = "ROWS (row | time | dwell | app | type | title | uri)"

    static let rowsGuide = """
    - ROWS: time-ordered activity rows. One row = one app/window context with its dwell seconds. `type` and `uri` were assigned by rules and are reliable.
      Under a row, `screen:` comes from a model that looked at the screenshot of that moment: its first line is that model's one-sentence reading of the front window, and the `·` lines below it are what was visible, quoted as written (messages with their sender). The quoted lines are the evidence; the first line is only a reading and can be wrong. When the first line does not fit the quoted lines, or a quoted word could mean more than one thing, decide from the quoted lines read together with the user's goals. `text:` is raw text read from the window when no screenshot description exists; it may include menus and sidebars.
      Rows whose app is "Claude Code" or "Codex CLI" (type AIChat, dwell 0) are the user's own messages to an AI coding assistant, quoted in `text:`. They say in the user's own words what they are trying to do: use them as the strongest evidence for what the surrounding rows are about.
      Rows whose app is "녹음" (type Recording, dwell 0) are voice recordings the user made in Sillog, such as a lecture, a meeting or a memo. `text:` holds a summary and the start of what was said. Judge them by what was said, like content the user engaged with.
    """

    public static let classifySystem = """
    You decide, for each raw desktop activity row, whether the user was working toward one of their goals, for a personal work graph.

    You receive:
    - GOALS: the user's current tasks from the last days: id, title and what the task is for (`goal:`). They show what the user is working toward; you do not assign rows to them here.
    \(rowsGuide)

    For EVERY row decide one kind:
    - none: the row has no content the user engaged with — a system screen, a transition between apps, an empty or loading page, the recorder's own window (rows whose app is Sillog). Nothing to read or do. Documents, pages or chats about a project named Sillog or 실록 are content like any other.
    - off: the user engaged with content, but it serves none of the user's goals: entertainment, hobbies, idle browsing, things unrelated to any goal. Hobbies and entertainment are not goals even when the user takes part regularly or with a team (games and game leagues, sports, fan communities), even when GOALS lists a task for them.
    - work: the content serves a goal, listed in GOALS or not yet listed. A goal is a project or one of its deliverables, a course being studied (its lectures, labs, notices), an errand with an outcome (an application, a payment, an interview), or a recurring routine that serves the user's work or study (a project team's channel, a class). Sub-steps are work for the goal they serve: reading documentation for it, checking the settings or usage of a tool used for it, signing in to or managing the account, subscription or billing of a tool or service used for it, installing a tool for it, looking at examples or references for it.
    Weigh the evidence in this order: what the user typed or read (the quoted `screen:` lines, chat messages, then `text:`) > the window title > the file or page name. A row is never judged by its neighbours; the rows arrive together only because they happened in the same minutes. Judge by content, not by the app or site.
    When a row could be work or off and the evidence does not settle it, choose work; the next step can still decide that it fits no goal.
    State in `reason`, in a few Korean words, what the row is used for (work), why it serves no goal (off), or '내용 없음' (none).

    Cover every row exactly once. Use ranges like "5-12" only when every row in the range has the same kind and reason.
    Always answer by calling classify_rows. Do not write prose.
    """

    public static let assignSystem = """
    You assign activity rows to the user's goals (tasks), for a personal work graph. Every row you receive was already judged to be work toward some goal.

    You receive:
    - OPEN_TASKS: the user's current tasks (goals) from the last days: id, title, type, what the task is for (`goal:`), topics, what was done in its recent sessions (`recent work:`), recent resources. Match rows against the goal, not only the title: a row serving the same goal belongs to that task even when it uses different words.
    \(rowsGuide)

    For each row decide which goal it serves:
    - an existing task (match="existing", its id): reuse it whenever the row serves that goal, judged by comparing the row's content with the task's title, goal, `recent work:` and resources. Sub-steps belong to the goal they serve: reading documentation for it, checking the settings or usage of a tool used for it, signing in to or managing the account, subscription or billing of a tool or service used for it, installing a tool for it, looking at examples or references for it, understanding its design.
    - a new task (match="new"): only for a goal that is not in OPEN_TASKS: a different course, a different project or deliverable, a different errand, a different routine. Two goals stay separate even when they share an app or a tool. A new task gets a short, specific Korean title that names the course/project and the goal, and a `goal` sentence saying what it is for with its context (company, course, project, event or deadline). Never an app name alone, never a catch-all title, never a bare category name. The goal names an outcome the user is working toward.
    - "off": the row turns out to serve no goal (the purpose is unclear, or it is entertainment, a hobby or browsing). Hobbies and entertainment are never goals, even when OPEN_TASKS lists a task for them. Do not list "off" in tasks.
    There is no minimum duration: a 10-second row about a distinct goal is that goal's row. A row is never assigned because neighbouring rows are.
    State in `reason`, in a few Korean words, what the row contributes to the goal.

    Assign every row you receive exactly once, by its row number. Use a range like "5-12" only when every number in it is a row you received and they share the task and reason.
    Always answer by calling assign_tasks. Do not write prose.
    """

    public static let describeSystem = """
    You describe the work the user did on their tasks, for a personal work graph. Every row you receive was already assigned to a task.

    You receive:
    - TASK_TYPES: the only allowed values for task_type.
    - TASKS: each task with its ref, whether it is NEW or existing, its title and goal, followed by the rows assigned to it.
    \(rowsGuide)

    Do this:
    1. resources (every row): true only when the row's file or page is a real reference or artifact of its task — something the user read, used or produced for it and would want to find again: a document, code file, notebook, design, note, docs page, paper, Q&A thread, video, AI chat, a page whose content the user actually read. false for everything else: a page merely visible while the user worked elsewhere, search results, blank or new tabs, login, redirect, account and billing pages, listings, profiles and navigation pages passed through, notification or inbox checks, tool settings and usage pages, a chat channel merely glanced at. When in doubt, false.
    2. work (every task): a summary, 1-4 topics, and for a NEW task its task_type, one of TASK_TYPES.
       The summary is saved on the session. The user reads it to recall what they did, an assistant reads it to answer questions and write reports about the work, and later passes read it as `recent work:` to match new rows to tasks. Write one Korean sentence under 100 characters that names up to three things the user did, in the order they happened, so a reader knows what was done without opening the records.
       - Name the specific object: the file, document section, page, function, assignment or posting. Use only names and details that appear in the rows. Don't repeat the task's title or goal; spend the sentence on what is particular to these rows.
       - Choose the verb from what the rows show, so a reader can tell what the user produced from what they only looked at. 작성·수정·추가 need the user's own text being added or changed (a document that grows or changes between rows, a message they sent, edited code); 제출·신청 need a visible confirmation. Otherwise say what the rows show: 읽었다, 검토했다, 검색했다, 비교했다. For a message to an AI assistant, say what the user asked for (요청했다), and say it was done only when later rows show the result. When the rows can't tell writing from reading, use the weaker verb. Use 확인했다 only for looking up a specific fact, and name the fact (마감일을 확인했다).
       - Never copy passwords, keys, tokens or other secrets.
       Vague → specific:
       - "보고서 관련 내용을 확인했다." → "중간보고서 3장(실험 방법) 초안을 작성하고 결과 표 2개를 추가했다."
       - "물리학 노트를 확인했다." → "물리학 3강 노트에서 열역학 제1법칙 예제를 읽었다."
       - "로그인 기능 작업을 확인했다." → "로그인 API의 토큰 만료 오류 수정을 AI에게 요청하고 관련 Stack Overflow 답변을 읽었다."
       Topics: what the work is ABOUT (a concept, technique, technology, course subject or problem domain). NOT the app, website or platform used, not the project name, no filler.
       When the task has `topics in use`, reuse one of those names whenever it is the same concept, even if the rows word it differently (with "그래프 시각화" in use, write "그래프 시각화", not "3D 그래프 시각화" or "인터랙티브 그래프 시각화"). Add a new topic only for a different concept.
    3. problems: only when the rows show an error or blocker (build error, failed command, searching an error message). Set resolved_by_row to the row of the page that solved it when that is evident.
    4. later_items: requests or todos that arrived in these rows but were not handled.

    Cover every row exactly once in resources. Use ranges like "5-12" only for consecutive rows of one task with the same value.
    Always answer by calling describe_work. Do not write prose.
    """

    public static func classify(rows: [ActivityRow], openTasks: [TaskDigest], cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone) -> String {
        var lines: [String] = [OntologyPrompt.nowLine(now, timeZone: timeZone), "GOALS:"]
        lines += OntologyPrompt.taskLines(openTasks, brief: true)
        lines.append("\(rowsHeader) — judge every row:")
        lines += OntologyPrompt.rowLines(rows, cards: cards, timeZone: timeZone)
        return lines.joined(separator: "\n")
    }

    public static func assign(rows: [ActivityRow], openTasks: [TaskDigest], cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone) -> String {
        var lines: [String] = [OntologyPrompt.nowLine(now, timeZone: timeZone), "OPEN_TASKS:"]
        lines += OntologyPrompt.taskLines(openTasks)
        lines.append("\(rowsHeader) — assign every row:")
        lines += OntologyPrompt.rowLines(rows, cards: cards, timeZone: timeZone)
        return lines.joined(separator: "\n")
    }

    public static func describe(groups: [Group], cards: [Int: [ScreenCard]], now: Double, timeZone: TimeZone) -> String {
        var lines: [String] = [OntologyPrompt.nowLine(now, timeZone: timeZone), "TASK_TYPES: \(TBox.leafTaskTypes.joined(separator: ", "))",
                               "TASKS (each followed by its rows: row | time | dwell | app | type | title | uri):"]
        for group in groups {
            var head = "## \(group.ref) | \(group.isNew ? "NEW" : "existing") | \(OntologyPrompt.clip(group.title, 90))"
            if let goal = group.goal { head += " | goal: \(OntologyPrompt.clip(goal, 140))" }
            if !group.topics.isEmpty { head += " | topics in use: \(group.topics.map { OntologyPrompt.clip($0, 30) }.joined(separator: ", "))" }
            lines.append(head)
            lines += OntologyPrompt.rowLines(group.rows, cards: cards, timeZone: timeZone)
        }
        return lines.joined(separator: "\n")
    }
}
