import Foundation
import GRDB

/// 업무를 기록째 지운다 (사용자가 지우라고 한 업무: 회사 자료 같은 것). TaskMerger.retire 는 그래프만 정리하고 행을 업무 외로 남기지만,
/// 여기서는 그 업무로 판정된 원시 행과 그 행에만 쓰인 글 조각·화면 카드, AI 대화·녹음, 요약·시간 기록, 그 행에서 나온 일정 제안까지 지우고,
/// 그 행이 들어간 정리 기록과 업무 목록으로 그 업무(이름·목표·최근 작업)를 AI 에 보낸 정리 기록의 원문(프롬프트·응답)을 비운다 (통계는 남긴다).
/// 파일 정리 제안에 적어 둔 '하던 업무'도 그 업무면 비운다. 그래프 정리는 retire 에 맡긴다:
/// 세션, 이제 아무 데도 안 걸린 주제·문제·자료, 빈 분야. 그 세션만 쓰던 앱 노드는 여기서 지운다.
/// 지운 내용이 DB 파일에 남지 않게 하려면 커밋 뒤 compact 를 부른다
public enum TaskEraser {
    /// 검색 색인 (지운 글이 색인 조각에 남지 않게 다시 쓴다)
    static let searchIndexes = ["screen_cards_fts", "nodes_chat_fts", "text_snapshots_chat_fts", "chat_messages_chat_fts", "digests_fts", "recordings_fts"]

    /// 지운 내용이 DB 파일에 남지 않게: 검색 색인을 다시 쓰고, 빈 페이지를 비우고(VACUUM), WAL 을 비운다. 큰 DB 는 몇 초 걸린다
    public static func compact(_ db: SillogDatabase) throws {
        try db.writer.writeWithoutTransaction { conn in
            for index in searchIndexes { try conn.execute(sql: "INSERT INTO \(index)(\(index)) VALUES('optimize')") }
        }
        try db.writer.vacuum()
        if db.writer is DatabasePool { try db.writer.writeWithoutTransaction { try $0.checkpoint(.truncate) } }
    }

    /// 지운 기록의 스크린샷·녹음 파일을 지운다. 그 DB 의 데이터 폴더(directory) 안의 것만 (DB 사본으로 시험할 때 진짜 파일을 지우지 않게).
    /// Returns: 지운 수, 폴더 밖이라 건너뛴 수 (이미 없는 파일은 어느 쪽에도 안 센다)
    public static func removeFiles(_ files: [String], within directory: String) -> (removed: Int, skipped: Int) {
        let root = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath().path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        var removed = 0, skipped = 0
        for file in files {
            let url = URL(fileURLWithPath: file)
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            guard parent.path == root || parent.path.hasPrefix(rootPrefix) else { skipped += 1; continue }
            let resolved = parent.appendingPathComponent(url.lastPathComponent)
            guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if (try? FileManager.default.removeItem(at: resolved)) != nil { removed += 1 }
        }
        return (removed, skipped)
    }

    public struct Report: Equatable, Sendable {
        public var tasks: [String] = []
        public var observations = 0
        public var cards = 0
        public var texts = 0
        public var chats = 0
        public var recordings = 0
        public var digests = 0
        public var suggestions = 0
        public var batches = 0
        /// 지울 스크린샷·녹음 파일 (DB 밖이라 호출자가 지운다)
        public var files: [String] = []
        /// 지우는 노드의 이름 (확인 창 제목). 없는 노드면 빈 글
        public var title = ""
        /// 같이 지우는 그래프 노드 수 (업무·분야는 세션과 나중에 할 일, 노드는 그 노드와 그 노드에서만 내려가는 하위 노드)
        public var nodes = 0
        /// 지울 수 있는 노드인지 (업무 종류 같은 클래스는 안 된다)
        public var erasable = true
        public init() {}
    }

    /// 지울 것: 업무 하나, 또는 분야째
    public enum Target: Equatable, Sendable {
        case task(key: String)
        case theme(String)
    }

    public static func erase(_ target: Target, conn: Database, now: Double, dry: Bool) throws -> Report {
        switch target {
        case .task(let key): try erase(taskKeys: [key], conn: conn, now: now, dry: dry)
        case .theme(let title): try erase(theme: title, conn: conn, now: now, dry: dry)
        }
    }

    /// 분야 이름으로: 그 분야의 업무 전부 (분야 노드는 업무가 다 빠지면 retire 가 지운다). 그런 분야가 없으면 아무것도 안 한다
    public static func erase(theme title: String, conn: Database, now: Double, dry: Bool) throws -> Report {
        guard let theme = try GraphTx(conn).nodes(label: NodeLabel.theme).first(where: { $0.title == title }) else { return Report() }
        let keys = try String.fetchAll(conn, sql: """
            SELECT n.key FROM edges e JOIN nodes n ON n.id = e.src AND n.label = ? WHERE e.dst = ? AND e.type = ? ORDER BY n.id
            """, arguments: [NodeLabel.task, theme.id, EdgeType.partOf])
        return try erase(taskKeys: keys, conn: conn, now: now, dry: dry)
    }

    /// Returns: 지운 것(dry 면 지울 것)의 수. Raises: DB 오류 (열린 트랜잭션 안에서 부른다)
    public static func erase(taskKeys: [String], conn: Database, now: Double, dry: Bool) throws -> Report {
        let tx = GraphTx(conn)
        let tasks = try taskKeys.compactMap { try tx.node(label: NodeLabel.task, key: $0) }
        var report = Report()
        report.tasks = tasks.map(\.title)
        report.title = tasks.map(\.title).joined(separator: ", ")
        guard !tasks.isEmpty else { return report }
        let ids = tasks.map { String($0.id) }.joined(separator: ",")
        let keys = tasks.map(\.key)
        let keyList = keys.map { _ in "?" }.joined(separator: ",")
        let mine = "task_id IN (\(ids))"
        func ints(_ sql: String) throws -> [Int64] { try Int64.fetchAll(conn, sql: sql) }

        // 업무 목록으로 그 업무(이름·목표·최근 작업)를 AI 에 보낸 정리 기록도 원문을 비운다
        let needles = tasks.flatMap { [$0.key, $0.title] }.filter { !$0.isEmpty }
        var mentioned: [Int64] = []
        for needle in needles {
            mentioned += try Int64.fetchAll(conn, sql: """
                SELECT id FROM batches WHERE instr(COALESCE(user_prompt, ''), ?) > 0 OR instr(COALESCE(raw_response, ''), ?) > 0
                  OR instr(COALESCE(llm_patch, ''), ?) > 0 OR instr(COALESCE(applied_patch, ''), ?) > 0
                """, arguments: [needle, needle, needle, needle])
        }
        let rows = RecordEraser.Rows(observations: try ints("SELECT id FROM observations WHERE \(mine)"),
                                     chats: try ints("SELECT id FROM chat_messages WHERE \(mine)"),
                                     recordings: try ints("SELECT id FROM recordings WHERE \(mine)"),
                                     batches: mentioned)
        report.digests = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM digests WHERE task_key IN (\(keyList))", arguments: StatementArguments(keys)) ?? 0
        report.nodes = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges WHERE dst IN (\(ids)) AND type IN ('\(EdgeType.partOf)', '\(EdgeType.forTask)')") ?? 0
        try RecordEraser.apply(rows, conn: conn, report: &report, dry: dry)
        guard !dry else { return report }

        // 시간 기록은 업무 외로 옮기지 않고 지운다 (retire 는 옮긴 뒤 지우므로 먼저 지운다)
        try conn.execute(sql: "DELETE FROM usage_ledger WHERE task_key IN (\(keyList))", arguments: StatementArguments(keys))
        let contextMatch = needles.map { _ in "instr(context, ?) > 0" }.joined(separator: " OR ")
        try conn.execute(sql: "UPDATE file_suggestions SET context = NULL WHERE context IS NOT NULL AND (\(contextMatch))", arguments: StatementArguments(needles))
        let apps = try ints("""
            SELECT DISTINCT e.dst FROM edges e WHERE e.type = '\(EdgeType.used)'
              AND e.src IN (SELECT src FROM edges WHERE type = '\(EdgeType.partOf)' AND dst IN (\(ids)))
            """)
        for key in keys { _ = try TaskMerger.retire(key, conn: conn, now: now) }     // 요약·원문 보존 표시도 여기서 지운다
        for app in apps where try (Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM edges WHERE src = ? OR dst = ?", arguments: [app, app]) ?? 0) == 0 {
            try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [app])
        }
        return report
    }
}
