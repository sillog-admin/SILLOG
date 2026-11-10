import Foundation
import GRDB

public struct ContextSearch: Sendable {
    let db: WGDatabase
    let projectID: String?
    /// 대화의 초점(고른 업무·분야). 있으면 그 업무들의 기록만 찾는다
    let focus: [ChatFocus]
    let includeActivity: Bool
    /// 검색 허용 범위: nodes·tasks 가 nil 이면 제한 없음. strict 면 허용 업무 밖(업무 없는 정리 전 기록 포함)은 뺀다
    typealias Access = (nodes: Set<Int64>?, tasks: Set<Int64>?, strict: Bool)

    /// Args: db는 수집 기록과 그래프가 저장된 DB, focus는 대화의 초점이다.
    /// Returns: 읽기 전용 컨텍스트 검색기.
    /// Raises: 없음.
    public init(_ db: WGDatabase, projectID: String? = nil, focus: [ChatFocus] = [], includeActivity: Bool = true) {
        self.db = db; self.projectID = projectID; self.focus = focus; self.includeActivity = includeActivity
    }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14-complete-chat-search") { conn in
            let content = "COALESCE(json_extract(payload, '$.text'), '') || char(10) || COALESCE((SELECT group_concat(json_extract(value, '$.title') || char(10) || json_extract(value, '$.content'), char(10)) FROM json_each(payload, '$.artifacts')), '')"
            try conn.execute(sql: """
                CREATE VIRTUAL TABLE app_messages_fts USING fts5(message_id UNINDEXED, text, tokenize='trigram');
                INSERT INTO app_messages_fts SELECT id, \(content) FROM app_messages WHERE json_extract(payload, '$.status') = 'complete';
                CREATE TRIGGER app_message_search_ai AFTER INSERT ON app_messages BEGIN
                  INSERT INTO app_messages_fts SELECT id, \(content) FROM app_messages WHERE id = new.id AND json_extract(payload, '$.status') = 'complete';
                END;
                CREATE TRIGGER app_message_search_ad AFTER DELETE ON app_messages BEGIN
                  DELETE FROM app_messages_fts WHERE message_id = old.id;
                END;
                CREATE TRIGGER app_message_search_au AFTER UPDATE ON app_messages BEGIN
                  DELETE FROM app_messages_fts WHERE message_id = old.id;
                  INSERT INTO app_messages_fts SELECT id, \(content) FROM app_messages WHERE id = new.id AND json_extract(payload, '$.status') = 'complete';
                END;
                """)
        }
    }

    private func conversationFilter(_ conn: Database) throws -> (String, StatementArguments) {
        if let projectID, try ProjectStore.projects(conn).first(where: { $0.id == projectID })?.memoryMode == .projectOnly {
            return ("c.project_id = ?", [projectID])
        }
        return ("(c.project_id IS NULL OR c.project_id NOT IN (SELECT id FROM app_projects WHERE json_extract(payload, '$.memoryMode') = 'projectOnly'))", [])
    }

    /// 초점이 있으면 고른 업무·분야가 하나라도 겹치는 대화만 다시 찾는다 (c 는 app_conversations)
    private var focusFilter: (String, StatementArguments) {
        guard !focus.isEmpty else { return ("1", []) }
        let match = focus.map { _ in "(json_extract(f.value, '$.kind') = ? AND json_extract(f.value, '$.key') = ?)" }.joined(separator: " OR ")
        return ("EXISTS (SELECT 1 FROM json_each(c.payload, '$.scope.focuses') f WHERE \(match))",
                StatementArguments(focus.flatMap { [$0.kind.rawValue, $0.key] }))
    }

    /// 프로젝트에 명시적으로 공유한 자료도 기억 범위에 포함한다. 대화 전용 첨부는 포함하지 않는다.
    func projectSourceIDs() throws -> [String] {
        try db.writer.read { conn in
            let filter = try conversationFilter(conn)
            return try String.fetchAll(conn, sql: "SELECT DISTINCT c.item_id FROM library_project_sources c WHERE \(filter.0)", arguments: filter.1)
        }
    }

    /// 초점을 고르면 프로젝트가 허용한 범위 안에서 그 업무들만 남긴다 (focused 가 false 면 프로젝트 범위만: 범위 메뉴의 고를 거리)
    func access(_ conn: Database, focused: Bool = true) throws -> Access {
        let base = try projectAccess(conn)
        guard focused, !focus.isEmpty else { return base }
        var tasks = Set(try focus.flatMap { try Self.focusTasks($0, conn) })
        if let allowed = base.tasks { tasks.formIntersection(allowed) }
        var nodes = try Self.nodeIDs(tasks: tasks, conn)
        if let allowed = base.nodes { nodes.formIntersection(allowed) }
        return (nodes, tasks, true)
    }

    /// 전용 프로젝트는 대화뿐 아니라 그 업무의 화면·원문·그래프에서도 제외한다.
    private func projectAccess(_ conn: Database) throws -> Access {
        let projects = try ProjectStore.projects(conn)
        if let projectID, projects.first(where: { $0.id == projectID })?.memoryMode == .projectOnly {
            let tasks = Set(try Int64.fetchAll(conn, sql: "SELECT task_id FROM project_tasks WHERE project_id = ?", arguments: [projectID]))
            return (try Self.nodeIDs(tasks: tasks, conn), tasks, true)
        }
        let privateProjects = projects.filter { $0.memoryMode == .projectOnly }
        guard !privateProjects.isEmpty else { return (nil, nil, false) }
        var hiddenNodes: Set<Int64> = [], hiddenTasks: Set<Int64> = []
        for project in privateProjects {
            let tasks = Set(try Int64.fetchAll(conn, sql: "SELECT task_id FROM project_tasks WHERE project_id = ?", arguments: [project.id]))
            hiddenNodes.formUnion(try Self.nodeIDs(tasks: tasks, conn))
            hiddenTasks.formUnion(tasks)
        }
        let tasks = Set(try Int64.fetchAll(conn, sql: "SELECT id FROM nodes WHERE label = 'Task'")).subtracting(hiddenTasks)
        let publicMembers = tasks.union(try Int64.fetchAll(conn, sql: "SELECT src FROM edges WHERE type = 'PART_OF'\(Self.restriction("dst", tasks))"))
        let publicNodes = publicMembers.union(try Int64.fetchAll(conn, sql: "SELECT id FROM nodes WHERE label NOT IN ('Task', 'Session') AND (id IN (SELECT dst FROM edges WHERE 1\(Self.restriction("src", publicMembers))) OR id IN (SELECT src FROM edges WHERE 1\(Self.restriction("dst", publicMembers))))"))
        let nodes = Set(try Int64.fetchAll(conn, sql: "SELECT id FROM nodes")).subtracting(hiddenNodes.subtracting(publicNodes))
        return (nodes, tasks, false)
    }

    private static func taskRestriction(_ column: String, _ access: Access) -> String {
        guard let tasks = access.tasks else { return "" }
        if access.strict { return restriction(column, tasks) }
        let list = tasks.sorted().map(String.init).joined(separator: ",")
        return " AND (\(column) IS NULL\(list.isEmpty ? "" : " OR \(column) IN (\(list))"))"
    }

    private static func cardRestriction(_ access: Access) -> String {
        guard access.tasks != nil else { return "" }
        let condition = String(taskRestriction("task_id", access).dropFirst(5))
        let forbidden = access.strict ? "(task_id IS NULL OR NOT (\(condition)))" : "NOT (\(condition))"
        return " AND EXISTS (SELECT 1 FROM observations WHERE card_id = screen_cards.id AND \(condition)) AND NOT EXISTS (SELECT 1 FROM observations WHERE card_id = screen_cards.id AND \(forbidden))"
    }

    /// 업무들과 직접 연결된 세션·자료만 허용한다. 공유 자료를 통해 다른 업무로 검색 범위를 넓히지 않는다.
    static func nodeIDs(tasks: Set<Int64>, _ conn: Database) throws -> Set<Int64> {
        guard !tasks.isEmpty else { return [] }
        let list = tasks.sorted().map(String.init).joined(separator: ",")
        return Set(try Int64.fetchAll(conn, sql: """
            WITH members(id) AS (
              SELECT id FROM nodes WHERE id IN (\(list))
              UNION SELECT src FROM edges WHERE dst IN (\(list)) AND type = 'PART_OF'
            )
            SELECT id FROM nodes WHERE id IN (SELECT id FROM members)
              OR (label NOT IN ('Task', 'Session') AND id IN (
                SELECT dst FROM edges WHERE src IN (SELECT id FROM members)
                UNION SELECT src FROM edges WHERE dst IN (SELECT id FROM members)
              ))
            """))
    }

    static func restriction(_ column: String, _ ids: Set<Int64>?) -> String {
        guard let ids else { return "" }
        return ids.isEmpty ? " AND 0" : " AND \(column) IN (\(ids.sorted().map(String.init).joined(separator: ",")))"
    }

    /// 짧은 한국어 검색어는 trigram 색인에 없으므로 부분 문자열 검색을 쓴다.
    /// Args: query는 검색어, 나머지는 코드에 정의된 테이블·열 이름이다.
    /// Returns: SQL 조건과 바인딩할 검색 값.
    /// Raises: 없음.
    static func match(_ query: String, index: String, row: String, fallback: String) -> (String, String) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if !words.isEmpty, words.allSatisfy({ $0.count >= 3 }) {
            let phrase = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
            return ("\(row) IN (SELECT rowid FROM \(index) WHERE \(index) MATCH ?)", phrase)
        }
        return ("instr(lower(\(fallback)), lower(?)) > 0", query)
    }

    /// Args: query는 핵심어, from·to는 검색 기간의 Unix 시각이다.
    /// Returns: 업무·요약·원문·사용자 요청에서 찾은 출처 목록.
    /// Raises: DB 검색 오류.
    public func search(query: String, from: Double = 0, to: Double = Date().timeIntervalSince1970) throws -> [ChatSource] {
        try db.writer.read { conn in
            var results: [ChatSource] = []
            let access = try access(conn), allowedNodes = access.nodes
            let activity = includeActivity ? "" : " AND 0"
            let needle = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            let node = Self.match(needle, index: "nodes_chat_fts", row: "id", fallback: "title || ' ' || key || ' ' || props")
            let nodes = try Row.fetchAll(conn, sql: "SELECT id, label, title, key, props FROM nodes WHERE label NOT IN ('TaskType', 'ResourceType') AND updated_at >= ? AND created_at <= ? AND (\(node.0))\(Self.restriction("id", allowedNodes))\(activity) ORDER BY updated_at DESC LIMIT 12", arguments: [from, to, node.1])
            for row in nodes {
                results.append(.init(id: "node:\(row["id"] as Int64)", title: "\(row["label"] as String) · \(row["title"] as String)", location: row["key"], excerpt: String((row["props"] as String).prefix(1200))))
            }
            let card = Self.match(needle, index: "screen_cards_fts", row: "id", fallback: "activity || ' ' || content || ' ' || COALESCE(uri, '')")
            let cards = Self.cardRestriction(access)
            for row in try Row.fetchAll(conn, sql: "SELECT * FROM screen_cards WHERE ts_end >= ? AND ts_start <= ? AND (\(card.0))\(cards)\(activity) ORDER BY ts_start DESC LIMIT 10", arguments: [from, to, card.1]) {
                results.append(.init(id: "card:\(row["id"] as Int64)", title: "화면 요약 · \(row["activity"] as String)", location: row["uri"] ?? "", excerpt: "\(Self.date(row["ts_start"])) (AI 요약)\n" + String((row["content"] as String).prefix(1600))))
            }
            // 주간·월간 요약: 원문이 정리된 기간을 대신한다. 업무 접근 범위를 그대로 따른다
            let digest = Self.match(needle, index: "digests_fts", row: "d.id", fallback: "d.title || ' ' || d.body")
            for row in try Row.fetchAll(conn, sql: """
                SELECT d.id, d.title, d.body FROM digests d JOIN nodes t ON t.label = 'Task' AND t.key = d.task_key
                WHERE d.period_end > ? AND d.period_start <= ? AND (\(digest.0))\(Self.taskRestriction("t.id", access))\(activity)
                ORDER BY d.period_start DESC, d.level DESC LIMIT 8
                """, arguments: [from, to, digest.1]) {
                results.append(.init(id: "digest:\(row["id"] as Int64)", title: row["title"], location: "",
                                     excerpt: "AI 요약 (수치는 사용 시간 기록)\n" + String((row["body"] as String).prefix(1600))))
            }
            let snapshot = Self.match(needle, index: "text_snapshots_chat_fts", row: "o.text_id", fallback: "COALESCE(t.text, '')")
            for row in try Row.fetchAll(conn, sql: """
                SELECT o.id, o.ts, o.app_name, o.window_title, o.url, o.doc_path, t.text
                FROM observations o LEFT JOIN text_snapshots t ON t.id = o.text_id
                WHERE o.ts >= ? AND o.ts <= ? AND ((\(snapshot.0)) OR instr(lower(COALESCE(o.window_title, '') || ' ' || COALESCE(o.url, '') || ' ' || COALESCE(o.doc_path, '')), lower(?)) > 0)
                \(Self.taskRestriction("o.task_id", access))\(activity) ORDER BY o.ts DESC LIMIT 10
                """, arguments: [from, to, snapshot.1, needle]) {
                results.append(.init(id: "observation:\(row["id"] as Int64)", title: "\(row["app_name"] as String) · \(row["window_title"] as String? ?? "활동")", location: row["url"] ?? row["doc_path"] ?? "", excerpt: "\(Self.date(row["ts"]))\n" + String((row["text"] as String? ?? "화면 텍스트 없음").prefix(1600))))
            }
            let chat = Self.match(needle, index: "chat_messages_chat_fts", row: "id", fallback: "text || ' ' || COALESCE(cwd, '')")
            for row in try Row.fetchAll(conn, sql: "SELECT * FROM chat_messages WHERE ts >= ? AND ts <= ? AND (\(chat.0))\(Self.taskRestriction("task_id", access))\(activity) ORDER BY ts DESC LIMIT 8", arguments: [from, to, chat.1]) {
                results.append(.init(id: "chat:\(row["id"] as Int64)", title: "\(row["tool"] as String) 사용자 메시지", location: row["cwd"] ?? "", excerpt: "\(Self.date(row["ts"]))\n" + String((row["text"] as String).prefix(1600))))
            }
            // 받아쓴 녹음: 제목·요약·받아쓴 글. 업무 접근 범위를 AI 도구 대화처럼 따른다
            let recording = Self.match(needle, index: "recordings_fts", row: "id", fallback: "COALESCE(title, '') || ' ' || COALESCE(summary, '') || ' ' || transcript")
            for row in try Row.fetchAll(conn, sql: """
                SELECT id, started_at, duration, title, summary, transcript, text_path FROM recordings
                WHERE status = 'ready' AND \(RecordingStore.hasTranscriptSQL) AND started_at <= ? AND COALESCE(ended_at, started_at) >= ?
                  AND (\(recording.0))\(Self.taskRestriction("task_id", access))\(activity)
                ORDER BY started_at DESC LIMIT 6
                """, arguments: [to, from, recording.1]) {
                results.append(Self.recordingSource(row, needle: needle))
            }
            let filter = try conversationFilter(conn)
            let words = needle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).prefix(24)
            let match = words.allSatisfy { $0.count >= 3 } && !words.isEmpty
                ? "m.id IN (SELECT message_id FROM app_messages_fts WHERE app_messages_fts MATCH ?)"
                : "(" + (words.isEmpty ? ["1"] : words.map { _ in "instr(lower(f.text || ' ' || json_extract(c.payload, '$.title')), lower(?)) > 0" }).joined(separator: " OR ") + ")"
            var arguments: StatementArguments = [from, to]
            if words.allSatisfy({ $0.count >= 3 }) && !words.isEmpty { arguments += [words.map { "\"\($0)\"" }.joined(separator: " OR ")] }
            else { arguments += StatementArguments(Array(words)) }
            arguments += [needle]
            arguments += filter.1; arguments += focusFilter.1; arguments += [projectID]
            let conversations = try Row.fetchAll(conn, sql: """
                SELECT m.id, json_extract(c.payload, '$.title') AS title, f.text
                FROM app_messages m JOIN app_conversations c ON c.id = m.conversation_id
                JOIN app_messages_fts f ON f.message_id = m.id
                WHERE m.created_at >= ? AND m.created_at <= ? AND json_extract(m.payload, '$.status') = 'complete'
                  AND (\(match) OR instr(lower(json_extract(c.payload, '$.title')), lower(?)) > 0) AND \(filter.0) AND \(focusFilter.0)
                ORDER BY CASE WHEN c.project_id = ? THEN 0 ELSE 1 END, m.created_at DESC, m.rowid DESC LIMIT 8
                """, arguments: arguments)
            for row in conversations {
                let text: String = row["text"]
                let range = words.compactMap { text.range(of: $0, options: .caseInsensitive) }.first
                let start = range.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
                results.append(.init(id: "message:\(row["id"] as String)", title: "대화 · \(row["title"] as String)", location: "", excerpt: String(text.dropFirst(max(0, start - 200)).prefix(1600))))
            }
            return results
        }
    }

    /// Args: sourceID는 검색 결과에 포함된 출처 식별자이다.
    /// Returns: 상세 원문. 노드이면 연결된 자료도 반환한다.
    /// Raises: DB 조회 오류.
    public func read(_ sourceID: String, start: Int = 1) throws -> [ChatSource] {
        let pieces = sourceID.split(separator: ":")
        guard pieces.count >= 2 else { return [] }
        if pieces[0] == "conversation" || pieces[0] == "message" {
            return try db.writer.read { conn in
                let filter = try conversationFilter(conn)
                if pieces[0] == "message" {
                    var args: StatementArguments = [String(pieces[1])]; args += filter.1; args += focusFilter.1
                    guard let row = try Row.fetchOne(conn, sql: "SELECT f.text, c.payload FROM app_messages_fts f JOIN app_messages m ON m.id = f.message_id JOIN app_conversations c ON c.id = m.conversation_id WHERE m.id = ? AND \(filter.0) AND \(focusFilter.0)", arguments: args) else { return [] }
                    let text: String = row["text"], offset = max(1, start), page = String(text.dropFirst(offset - 1).prefix(18000))
                    let title = try JSONDecoder().decode(ChatConversation.self, from: Data((row["payload"] as String).utf8)).title
                    return [.init(id: "message:\(pieces[1]):\(offset)", title: "대화 · \(title)", location: "", excerpt: page + "\n[전체 \(text.count)자 · 다음 시작 위치 \(offset + page.count)]")]
                }
                var args: StatementArguments = [String(pieces[1])]; args += filter.1; args += focusFilter.1
                guard let row = try Row.fetchOne(conn, sql: "SELECT c.payload FROM app_conversations c WHERE c.id = ? AND \(filter.0) AND \(focusFilter.0)", arguments: args) else { return [] }
                let title = try JSONDecoder().decode(ChatConversation.self, from: Data((row["payload"] as String).utf8)).title
                let rows = try Row.fetchAll(conn, sql: "SELECT m.id, f.text FROM app_messages m JOIN app_messages_fts f ON f.message_id = m.id WHERE conversation_id = ? ORDER BY created_at, m.rowid LIMIT 20 OFFSET ?", arguments: [String(pieces[1]), max(0, start - 1)])
                let text = rows.map { "[message:\($0["id"] as String)]\n\(String(($0["text"] as String).prefix(700)))" }.joined(separator: "\n\n")
                return [.init(id: "conversation:\(pieces[1]):\(max(1, start))", title: "대화 · \(title)", location: "", excerpt: text + "\n[다음 메시지 위치 \(max(1, start) + rows.count). 메시지 원문은 message ID로 조회하세요.]" )]
            }
        }
        guard includeActivity, let id = Int64(pieces[1]) else { return [] }
        return try db.writer.read { conn in
            let access = try access(conn), allowedNodes = access.nodes
            if access.tasks != nil {
                let allowed: Bool
                switch pieces[0] {
                case "node": allowed = allowedNodes?.contains(id) == true
                case "observation": allowed = try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM observations WHERE id = ?\(Self.taskRestriction("task_id", access)))", arguments: [id]) == true
                case "card": allowed = try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM screen_cards WHERE id = ?\(Self.cardRestriction(access)))", arguments: [id]) == true
                case "chat": allowed = try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM chat_messages WHERE id = ?\(Self.taskRestriction("task_id", access)))", arguments: [id]) == true
                case "recording":
                    allowed = try Bool.fetchOne(conn, sql: "SELECT EXISTS(SELECT 1 FROM recordings WHERE id = ?\(Self.taskRestriction("task_id", access)))", arguments: [id]) == true
                case "digest":
                    allowed = try Bool.fetchOne(conn, sql: """
                        SELECT EXISTS(SELECT 1 FROM digests d JOIN nodes t ON t.label = 'Task' AND t.key = d.task_key WHERE d.id = ?\(Self.taskRestriction("t.id", access)))
                        """, arguments: [id]) == true
                default: allowed = false
                }
                guard allowed else { return [] }
            }
            switch pieces[0] {
            case "node":
                let rows = try Row.fetchAll(conn, sql: """
                    SELECT * FROM nodes WHERE (id = ? OR id IN (
                      SELECT dst FROM edges WHERE src = ? UNION SELECT src FROM edges WHERE dst = ?
                    ))\(Self.restriction("id", allowedNodes)) ORDER BY CASE WHEN id = ? THEN 0 ELSE 1 END, updated_at DESC LIMIT 25
                    """, arguments: [id, id, id, id])
                return rows.map { row in .init(id: "node:\(row["id"] as Int64)", title: "\(row["label"] as String) · \(row["title"] as String)", location: row["key"], excerpt: String((row["props"] as String).prefix(2500))) }
            case "observation":
                guard let row = try Row.fetchOne(conn, sql: "SELECT o.*, t.text FROM observations o LEFT JOIN text_snapshots t ON t.id = o.text_id WHERE o.id = ?", arguments: [id]) else { return [] }
                return [.init(id: sourceID, title: row["window_title"] ?? "활동 기록", location: row["url"] ?? row["doc_path"] ?? "", excerpt: "\(Self.date(row["ts"]))\n" + String((row["text"] as String? ?? "텍스트 없음").prefix(18000)))]
            case "card":
                guard let row = try Row.fetchOne(conn, sql: "SELECT * FROM screen_cards WHERE id = ?", arguments: [id]) else { return [] }
                return [.init(id: sourceID, title: row["activity"], location: row["uri"] ?? "", excerpt: "AI 화면 요약 (원문 아님)\n\(row["content"] as String)\n\(row["entities"] as String)")]
            case "chat":
                guard let row = try Row.fetchOne(conn, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]) else { return [] }
                return [.init(id: sourceID, title: "사용자의 요청 (실행 완료 증거 아님)", location: row["cwd"] ?? "", excerpt: String((row["text"] as String).prefix(18000)))]
            case "digest":
                guard let digest = try DigestStore.digest(conn, id: id) else { return [] }
                var header = "AI 요약 · 수치는 사용 시간 기록에서 계산"
                if let pruned = try ConsolidationStore.value(ConsolidationStore.Key.textPrunedUntil, conn),
                   let boundary = PeriodCalendar().dayEnd(pruned), digest.periodStart < boundary {
                    header += " · 원문은 \(pruned) 이전 정리됨"
                }
                if digest.status == .draft { header += " · 초안(서술 생성 실패로 기록을 나열함)" }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let metrics = (try? encoder.encode(digest.metrics)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                return [.init(id: sourceID, title: digest.title, location: "",
                              excerpt: "\(header)\n\(digest.body)\n\n수치: \(metrics)\n근거 key: \(digest.anchors.joined(separator: ", "))")]
            case "recording":
                guard let row = try Row.fetchOne(conn, sql: "SELECT * FROM recordings WHERE id = ? AND status = 'ready'", arguments: [id]) else { return [] }
                let transcript: String = row["transcript"]
                let title: String? = row["title"]
                let offset = max(1, start)
                let page = String(transcript.dropFirst(offset - 1).prefix(18000))
                let footer = "[전체 \(transcript.count)자 · 다음 시작 위치 \(offset + page.count)]"
                return [.init(id: sourceID, title: "녹음 · \(title ?? "제목 없음")", location: row["text_path"] ?? "",
                              excerpt: Self.recordingHeader(row) + "\n\n" + page + "\n" + footer)]
            default: return []
            }
        }
    }

    /// 원문(화면 텍스트)이 남아 있는 첫 날. 정리한 적이 없으면 nil
    public func rawRecordsSince() throws -> String? {
        try db.writer.read { conn in
            try ConsolidationStore.value(ConsolidationStore.Key.textPrunedUntil, conn).map { PeriodCalendar().addDays($0, 1) }
        }
    }

    /// 기간 집계: 업무별 시간, 자주 쓴 자료, 앱 분포(사용 시간 기록), 문제·할 일 변화(그래프). 원문이 정리된 기간도 같은 수치를 낸다
    /// Args: from·to는 Unix 시각 [from, to), task는 업무 key 또는 제목 일부(없으면 전체)이다.
    /// Returns: 결정적으로 계산한 집계 한 건.
    /// Raises: DB 오류.
    public func summarize(from: Double, to: Double, task: String?, calendar: PeriodCalendar = PeriodCalendar()) throws -> [ChatSource] {
        guard includeActivity else { return [] }
        let days = calendar.days(from: from, to: to)
        guard let firstDay = days.first, let lastDay = days.last else { return [] }
        guard days.count <= 400 else { throw ChatToolError.unavailable("집계 기간은 400일 이내로 지정하세요.") }
        return try db.writer.read { conn in
            let access = try access(conn)
            var tasks: [String: (id: Int64, title: String)] = [:]
            for row in try Row.fetchAll(conn, sql: "SELECT id, key, title FROM nodes WHERE label = 'Task'") { tasks[row["key"]] = (row["id"], row["title"]) }
            func allowed(_ key: String) -> Bool {
                if key.isEmpty { return !access.strict }
                guard let id = tasks[key]?.id else { return false }
                return access.tasks.map { $0.contains(id) } ?? true
            }
            var wanted: Set<String>?
            if let task = task?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty {
                wanted = Set(tasks.filter { $0.key == task || $0.value.title.localizedCaseInsensitiveContains(task) }.map(\.key))
            }
            let ledger = LedgerBuilder(calendar: calendar)
            let rows = try ledger.rows(conn, days: days).filter { row in allowed(row.taskKey) && (wanted?.contains(row.taskKey) ?? true) }
            let frozenDays = try LedgerBuilder.frozenDays(conn, among: days)

            var perTask: [String: (seconds: Double, days: Set<String>)] = [:], perResource: [String: Double] = [:], perApp: [String: Double] = [:]
            for row in rows {
                switch row.kind {
                case .task: perTask[row.taskKey, default: (0, [])].seconds += row.seconds; if row.seconds > 0 { perTask[row.taskKey, default: (0, [])].days.insert(row.day) }
                case .resource: perResource[row.target, default: 0] += row.seconds
                case .app: if !row.taskKey.isEmpty { perApp[row.target, default: 0] += row.seconds }
                case .project: break
                }
            }
            func title(_ label: String, _ key: String) throws -> String {
                try String.fetchOne(conn, sql: "SELECT title FROM nodes WHERE label = ? AND key = ?", arguments: [label, key]).flatMap { $0.isEmpty ? nil : $0 } ?? key
            }
            var lines = ["기간: \(firstDay) ~ \(lastDay) (사용 시간 기록 기준 추정, 유휴 시간 제외" + (frozenDays.isEmpty ? ")" : ", 그중 \(frozenDays.count)일은 원문이 정리돼 동결된 수치)")]
            let assigned = perTask.filter { !$0.key.isEmpty }.sorted { $0.value.seconds > $1.value.seconds }
            lines.append("업무별 시간 (합계 \(TimePhrase.approx(assigned.reduce(0) { $0 + $1.value.seconds }))):")
            for (key, value) in assigned.prefix(30) {
                lines.append("- \(tasks[key]?.title ?? key): \(TimePhrase.approx(value.seconds)), \(value.days.count)일 [node:\(tasks[key]?.id ?? 0)]")
            }
            if assigned.isEmpty { lines.append("- 기록 없음") }
            if wanted == nil, let off = perTask[""], off.seconds > 0 { lines.append("업무 외·미배정: \(TimePhrase.approx(off.seconds))") }
            if !perResource.isEmpty {
                lines.append("많이 쓴 자료:")
                for (key, seconds) in perResource.sorted(by: { $0.value > $1.value }).prefix(10) {
                    lines.append("- \(try title(NodeLabel.resource, key)) — \(TimePhrase.approx(seconds)) (\(key))")
                }
            }
            if !perApp.isEmpty {
                lines.append("업무 중 앱:")
                for (key, seconds) in perApp.sorted(by: { $0.value > $1.value }).prefix(8) { lines.append("- \(try title(NodeLabel.app, key)) — \(TimePhrase.approx(seconds))") }
            }
            // 문제·나중에 할 일의 변화 (그래프에 남아 있다)
            let taskOf = { (id: Int64) -> String? in tasks.first { $0.value.id == id }?.key }
            var newProblems = Set<Int64>(), resolvedProblems = Set<Int64>()
            for row in try Row.fetchAll(conn, sql: """
                SELECT p.id, pt.dst AS task_id, EXISTS(SELECT 1 FROM edges r WHERE r.src = p.id AND r.type = 'RESOLVED_BY') AS resolved
                FROM nodes p JOIN edges h ON h.dst = p.id AND h.type = 'HIT' JOIN edges pt ON pt.src = h.src AND pt.type = 'PART_OF'
                WHERE p.label = 'Problem' AND json_extract(p.props, '$.at') >= ? AND json_extract(p.props, '$.at') < ?
                """, arguments: [from, to]) {
                guard let key = taskOf(row["task_id"]), allowed(key), wanted.map({ $0.contains(key) }) ?? true else { continue }
                newProblems.insert(row["id"])
                if (row["resolved"] as Int) == 1 { resolvedProblems.insert(row["id"]) }
            }
            var newLater = 0, openLater = 0
            for row in try Row.fetchAll(conn, sql: """
                SELECT l.props, f.dst AS task_id FROM nodes l JOIN edges f ON f.src = l.id AND f.type = 'FOR'
                WHERE l.label = 'LaterItem' AND json_extract(l.props, '$.at') >= ? AND json_extract(l.props, '$.at') < ?
                """, arguments: [from, to]) {
                guard let key = taskOf(row["task_id"]), allowed(key), wanted.map({ $0.contains(key) }) ?? true else { continue }
                newLater += 1
                if JSONValue.decodeObject(row["props"])["done"]?.boolValue != true { openLater += 1 }
            }
            lines.append("문제: 새로 생김 \(newProblems.count)건, 그중 해결 \(resolvedProblems.count)건 · 나중에 할 일: 새로 생김 \(newLater)건, 남음 \(openLater)건")
            let scope = wanted.map { set in ":" + set.sorted().joined(separator: ",") } ?? ""
            return [.init(id: "usage:\(firstDay)..\(lastDay)\(scope)", title: "사용 시간 집계 · \(firstDay) ~ \(lastDay)", location: "",
                          excerpt: lines.joined(separator: "\n"))]
        }
    }

    /// 녹음 출처 머리: 녹음 시각·길이, 받아쓴 글이라는 표시, 요약
    private static func recordingHeader(_ row: Row) -> String {
        let startedAt: Double = row["started_at"], duration: Double = row["duration"]
        let summary: String? = row["summary"]
        var header = "\(date(startedAt)) 녹음 (\(RecordingText.duration(duration))) · 이 Mac 의 음성 인식으로 받아쓴 글 (잘못 들은 단어가 있을 수 있음)"
        if let summary, !summary.isEmpty { header += "\n요약: \(summary)" }
        return header
    }

    /// 녹음 검색 결과: 받아쓴 글에서 검색어가 처음 나온 곳 앞뒤
    private static func recordingSource(_ row: Row, needle: String) -> ChatSource {
        let transcript: String = row["transcript"]
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        let range = words.compactMap { transcript.range(of: $0, options: .caseInsensitive) }.first
        let start = range.map { transcript.distance(from: transcript.startIndex, to: $0.lowerBound) } ?? 0
        let id: Int64 = row["id"]
        let title: String? = row["title"]
        let body = String(transcript.dropFirst(max(0, start - 200)).prefix(1400))
        return .init(id: "recording:\(id)", title: "녹음 · \(title ?? "제목 없음")", location: row["text_path"] ?? "",
                     excerpt: recordingHeader(row) + "\n" + body)
    }

    /// Args: time은 Unix 시각이다.
    /// Returns: 현지 시간으로 표시한 기록 시각.
    /// Raises: 없음.
    private static func date(_ time: Double) -> String { Date(timeIntervalSince1970: time).formatted(date: .numeric, time: .shortened) }
}
