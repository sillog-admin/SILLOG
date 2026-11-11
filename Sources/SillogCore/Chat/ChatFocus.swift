import Foundation
import GRDB

/// 채팅의 초점 항목: 업무 하나 또는 분야 하나. 대화는 여러 항목을 고를 수 있다 (없으면 모든 기록)
public struct ChatFocus: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case task, theme }
    public var kind: Kind
    /// 업무·분야 노드의 key. 업무가 합쳐지면 남는 업무의 key 로 바뀐다 (TaskMerger)
    public var key: String
    /// 고를 때의 이름: 칩과 대화 목록에 보인다
    public var title: String

    public init(kind: Kind, key: String, title: String) {
        self.kind = kind; self.key = key; self.title = title
    }
}

/// 범위 메뉴에 보일 분야와 업무: 이 대화에서 볼 수 있는 업무만, 최근에 일한 순
public struct ChatFocusChoices: Equatable, Sendable {
    public struct ThemeItem: Equatable, Identifiable, Sendable {
        public var focus: ChatFocus
        public var taskCount: Int
        public var id: String { focus.key }
    }

    public struct TaskItem: Equatable, Identifiable, Sendable {
        public var focus: ChatFocus
        /// 업무가 속한 분야 이름과 key (없으면 nil). 고르기 목록에서 분야 아래로 묶는다
        public var theme: String?
        public var themeKey: String?
        /// 분야 이름: 분야(theme)가 있으면 그것, 없으면 업무 종류의 최상위 분류 (그래프, 업무 탭 분야 막대와 같은 기준)
        public var field: String? = nil
        public var id: String { focus.key }
    }

    public var themes: [ThemeItem] = []
    public var tasks: [TaskItem] = []

    public init(themes: [ThemeItem] = [], tasks: [TaskItem] = []) {
        self.themes = themes; self.tasks = tasks
    }
}

extension ContextSearch {
    /// 초점이 가리키는 업무들: 업무면 그 하나, 분야면 그 분야의 업무 전체 (나중에 늘어난 업무도 들어간다)
    static func focusTasks(_ focus: ChatFocus, _ conn: Database) throws -> Set<Int64> {
        switch focus.kind {
        case .task:
            return Set(try Int64.fetchAll(conn, sql: "SELECT id FROM nodes WHERE label = 'Task' AND key = ?", arguments: [focus.key]))
        case .theme:
            return Set(try Int64.fetchAll(conn, sql: """
                SELECT t.id FROM nodes t
                JOIN edges e ON e.src = t.id AND e.type = 'PART_OF'
                JOIN nodes th ON th.id = e.dst AND th.label = 'Theme'
                WHERE t.label = 'Task' AND th.key = ?
                """, arguments: [focus.key]))
        }
    }

    /// 고른 업무·분야가 아직 있는지. 합쳐지거나 정리돼 사라지면 false
    public static func exists(_ focus: ChatFocus, in db: SillogDatabase) throws -> Bool {
        try db.writer.read { conn in
            try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM nodes WHERE label = ? AND key = ?)",
                              arguments: [focus.kind == .task ? "Task" : "Theme", focus.key]) == true
        }
    }

    /// 범위 메뉴의 고를 거리. 업무 목록처럼 세션이 있는 업무만, 프로젝트가 허용한 것만
    /// Args: 없음.
    /// Returns: 최근에 일한 순의 업무와, 그 순서대로 처음 나온 분야(업무 수 포함).
    /// Raises: DB 오류.
    public func focusChoices() throws -> ChatFocusChoices {
        try db.writer.read { conn in
            let access = try access(conn, focused: false)
            let rows = try Row.fetchAll(conn, sql: """
                SELECT t.id, t.key, t.title, COALESCE(json_extract(t.props, '$.last_active'), t.updated_at) AS last,
                  (SELECT th.key FROM edges e JOIN nodes th ON th.id = e.dst AND th.label = 'Theme' WHERE e.src = t.id AND e.type = 'PART_OF' LIMIT 1) AS theme_key,
                  (SELECT th.title FROM edges e JOIN nodes th ON th.id = e.dst AND th.label = 'Theme' WHERE e.src = t.id AND e.type = 'PART_OF' LIMIT 1) AS theme_title
                FROM nodes t
                WHERE t.label = 'Task' AND EXISTS (SELECT 1 FROM edges s JOIN nodes n ON n.id = s.src AND n.label = 'Session' WHERE s.dst = t.id AND s.type = 'PART_OF')
                ORDER BY last DESC, t.id DESC
                """)
            var choices = ChatFocusChoices()
            let tx = GraphTx(conn)
            for row in rows {
                let id: Int64 = row["id"]
                if let allowed = access.tasks, !allowed.contains(id) { continue }
                let themeTitle: String? = row["theme_title"]
                let themeKey: String? = row["theme_key"]
                var top = try tx.edges(from: id, type: EdgeType.instanceOf).first.flatMap { try tx.node(id: $0.dst) }
                while let cur = top, let up = try tx.edges(from: cur.id, type: EdgeType.subclassOf).first.flatMap({ try tx.node(id: $0.dst) }), up.id != cur.id { top = up }
                choices.tasks.append(.init(focus: ChatFocus(kind: .task, key: row["key"], title: row["title"]), theme: themeTitle, themeKey: themeKey,
                                           field: themeTitle ?? top?.title))
                guard let themeKey, let themeTitle else { continue }
                if let index = choices.themes.firstIndex(where: { $0.focus.key == themeKey }) {
                    choices.themes[index].taskCount += 1
                } else {
                    choices.themes.append(.init(focus: ChatFocus(kind: .theme, key: themeKey, title: themeTitle), taskCount: 1))
                }
            }
            return choices
        }
    }

    /// 시스템 프롬프트의 <focus> 블록: 무엇을 골랐고 어떤 업무가 들어가는지 (업무마다 누적 시간·세션 수·마지막 활동)
    /// Args: 없음.
    /// Returns: 초점이 없으면 nil.
    /// Raises: DB 오류.
    public func focusOutline() throws -> String? {
        guard !focus.isEmpty else { return nil }
        return try db.writer.read { conn in
            let access = try access(conn)
            let rows = try Row.fetchAll(conn, sql: """
                SELECT t.title, COALESCE(json_extract(t.props, '$.active_seconds'), 0) AS seconds,
                  COALESCE(json_extract(t.props, '$.last_active'), t.updated_at) AS last,
                  (SELECT COUNT(*) FROM edges s JOIN nodes n ON n.id = s.src AND n.label = 'Session' WHERE s.dst = t.id AND s.type = 'PART_OF') AS sessions,
                  (SELECT th.title FROM edges e JOIN nodes th ON th.id = e.dst AND th.label = 'Theme' WHERE e.src = t.id AND e.type = 'PART_OF' LIMIT 1) AS theme
                FROM nodes t WHERE t.label = 'Task'\(Self.restriction("t.id", access.tasks))
                ORDER BY last DESC, t.id DESC
                """)
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
            let shown = 30
            let selected = focus.map { "\($0.kind == .task ? "업무" : "분야") \($0.title)" }.joined(separator: ", ")
            var lines = ["selected: \(selected)", rows.isEmpty ? "tasks: none (찾을 수 없음)" : "tasks:"]
            for row in rows.prefix(shown) {
                let theme: String? = row["theme"]
                let facts = [theme.map { "분야 \($0)" }, "누적 \(Self.approximate(row["seconds"]))", "세션 \(row["sessions"] as Int)개",
                             "마지막 활동 \(day.string(from: Date(timeIntervalSince1970: row["last"])))"].compactMap { $0 }
                lines.append("- \(row["title"] as String) (\(facts.joined(separator: ", ")))")
            }
            if rows.count > shown { lines.append("- 외 \(rows.count - shown)개") }
            return lines.joined(separator: "\n")
        }
    }

    /// 사용 시간 근사: 약 2시간 40분, 약 51분
    static func approximate(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "약 \(minutes)분" }
        return "약 \(minutes / 60)시간" + (minutes % 60 > 0 ? " \(minutes % 60)분" : "")
    }
}
