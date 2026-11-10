import Foundation
import GRDB

/// 저장 공간: 범주별 크기와 최근 30일 하루 평균 증가량
public struct StorageUsage: Equatable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case screenshots, screenText, batchLog, observations, screenCards, aiRequests, digests, graph, chatLibrary, recordings, other

        public var title: String {
            switch self {
            case .screenshots: "스크린샷"
            case .screenText: "화면 텍스트(검색 색인 포함)"
            case .batchLog: "정리 기록"
            case .observations: "활동 기록"
            case .screenCards: "화면 카드"
            case .aiRequests: "AI 도구 요청"
            case .digests: "요약·사용 시간 기록"
            case .graph: "업무 그래프"
            case .chatLibrary: "채팅·보관함"
            case .recordings: "녹음"
            case .other: "기타"
            }
        }
    }

    public var bytes: [Category: Int64] = [:]
    /// DB 범주의 최근 30일 하루 평균 증가 (스크린샷은 보관 기간에 묶여 있어 넣지 않는다)
    public var dailyGrowth: [Category: Int64] = [:]
    public var databaseFileBytes: Int64 = 0
    public var freePages = 0
    public var pageSize = 0
    /// SQLite dbstat 으로 잰 값이면 true, 아니면 내용 길이로 어림한 값
    public var measuredWithDBStat = false

    public var total: Int64 { bytes.values.reduce(0, +) }
    public var totalDailyGrowth: Int64 { dailyGrowth.values.reduce(0, +) }

    public init() {}

    /// 테이블·색인·검색 색인 보조 테이블 이름 → 범주
    static func category(of name: String) -> Category {
        let prefixes: [(String, Category)] = [
            ("text_snapshots", .screenText), ("sqlite_autoindex_text_snapshots", .screenText),
            ("batches", .batchLog), ("prompt_blobs", .batchLog), ("sqlite_autoindex_prompt_blobs", .batchLog),
            ("observations", .observations), ("idx_observations", .observations), ("idle_spans", .observations),
            ("screen_cards", .screenCards), ("idx_screen_cards", .screenCards),
            ("chat_messages", .aiRequests), ("idx_chat_messages", .aiRequests), ("chat_cursors", .aiRequests), ("sqlite_autoindex_chat_messages", .aiRequests),
            ("usage_ledger", .digests), ("idx_usage_ledger", .digests), ("sqlite_autoindex_usage_ledger", .digests),
            ("digests", .digests), ("idx_digests", .digests), ("sqlite_autoindex_digests", .digests),
            ("consolidation_state", .digests), ("retention_pins", .digests),
            ("nodes", .graph), ("idx_nodes", .graph), ("sqlite_autoindex_nodes", .graph), ("edges", .graph), ("idx_edges", .graph), ("sqlite_autoindex_edges", .graph),
            ("app_", .chatLibrary), ("idx_app_", .chatLibrary), ("sqlite_autoindex_app_", .chatLibrary), ("library_", .chatLibrary),
            ("sqlite_autoindex_library_", .chatLibrary), ("project_", .chatLibrary), ("sqlite_autoindex_project_", .chatLibrary),
            ("recordings", .recordings), ("idx_recordings", .recordings),
        ]
        return prefixes.first { name.hasPrefix($0.0) }?.1 ?? .other
    }

    public static func measure(db: WGDatabase, capturesDir: URL?, now: Double = Date().timeIntervalSince1970) throws -> StorageUsage {
        var usage = StorageUsage()
        try db.writer.read { conn in
            usage.pageSize = try Int.fetchOne(conn, sql: "PRAGMA page_size") ?? 4096
            usage.freePages = try Int.fetchOne(conn, sql: "PRAGMA freelist_count") ?? 0
            if let rows = try? Row.fetchAll(conn, sql: "SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name") {
                usage.measuredWithDBStat = true
                for row in rows { usage.bytes[category(of: row["name"]), default: 0] += row["bytes"] as Int64? ?? 0 }
            } else {
                for (name, bytes) in try estimateTables(conn) { usage.bytes[category(of: name), default: 0] += bytes }
                let pages = Int64(try Int.fetchOne(conn, sql: "PRAGMA page_count") ?? 0)
                let used = (pages - Int64(usage.freePages)) * Int64(usage.pageSize)
                let counted = usage.bytes.values.reduce(0, +)
                if used > counted { usage.bytes[.other, default: 0] += used - counted }    // 색인 등 길이로 못 잰 몫
            }
            usage.dailyGrowth = try growth(conn, bytes: usage.bytes, since: now - 30 * 86_400)
        }
        usage.bytes[.chatLibrary, default: 0] += folderBytes(db.libraryDirectory)
        usage.bytes[.recordings, default: 0] += folderBytes(db.recordingsDirectory)
        if let capturesDir { usage.bytes[.screenshots] = folderBytes(capturesDir) }
        if let path = db.path {
            usage.databaseFileBytes = [path, path + "-wal"].reduce(Int64(0)) { total, file in
                total + ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
        return usage
    }

    /// dbstat 이 없을 때: 테이블마다 열 길이의 합 (가상 테이블 자체는 저장 공간이 없고 보조 테이블에 담긴다)
    static func estimateTables(_ conn: Database) throws -> [(String, Int64)] {
        var result: [(String, Int64)] = []
        for row in try Row.fetchAll(conn, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'table'") {
            let name: String = row["name"]
            if (row["sql"] as String? ?? "").uppercased().hasPrefix("CREATE VIRTUAL") { continue }
            let columns = try Row.fetchAll(conn, sql: "SELECT name FROM pragma_table_info(?)", arguments: [name]).map { $0["name"] as String }
            guard !columns.isEmpty else { continue }
            let sum = columns.map { "COALESCE(LENGTH(\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"), 0)" }.joined(separator: " + ")
            let quoted = "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let bytes = try Int64.fetchOne(conn, sql: "SELECT COALESCE(SUM(\(sum)), 0) + COUNT(*) * 8 FROM \(quoted)") ?? 0
            result.append((name, bytes))
        }
        return result
    }

    /// 범주 크기 × (최근 30일에 생긴 내용의 비율) / 30
    static func growth(_ conn: Database, bytes: [Category: Int64], since: Double) throws -> [Category: Int64] {
        let probes: [(Category, String, String)] = [
            (.screenText, "text_snapshots", "created_at|LENGTH(text)"),
            (.batchLog, "batches", "started_at|COALESCE(LENGTH(user_prompt), 0) + COALESCE(LENGTH(raw_response), 0) + COALESCE(LENGTH(llm_patch), 0) + 200"),
            (.observations, "observations", "ts|80 + COALESCE(LENGTH(window_title), 0) + COALESCE(LENGTH(url), 0) + COALESCE(LENGTH(doc_path), 0)"),
            (.screenCards, "screen_cards", "created_at|LENGTH(content) + LENGTH(activity)"),
            (.aiRequests, "chat_messages", "ts|LENGTH(text)"),
            (.digests, "digests", "created_at|LENGTH(body) + LENGTH(structured)"),
            (.graph, "nodes", "created_at|LENGTH(props) + LENGTH(title)"),
            (.chatLibrary, "app_messages", "created_at|LENGTH(payload)"),
        ]
        var result: [Category: Int64] = [:]
        for (category, table, spec) in probes {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            guard let row = try Row.fetchOne(conn, sql: "SELECT COALESCE(SUM(\(parts[1])), 0) AS total, COALESCE(SUM(CASE WHEN \(parts[0]) >= ? THEN \(parts[1]) END), 0) AS recent FROM \(table)",
                                             arguments: [since]) else { continue }
            let total: Double = row["total"], recent: Double = row["recent"]
            guard total > 0 else { continue }
            result[category] = Int64(Double(bytes[category] ?? 0) * (recent / total) / 30)
        }
        return result
    }

    static func folderBytes(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileAllocatedSize ?? 0) }
        }
        return total
    }
}
