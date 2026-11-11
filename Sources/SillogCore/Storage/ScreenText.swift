import Foundation
import GRDB

/// 화면 글자(text_snapshots)를 덜 저장하는 규칙
///   - 편집기(VS Code, Cursor, Xcode …)는 앞 editorLimit 자만: 편집기 내용은 파일에 있고, 화면 글자는 정리할 때 앞부분만 쓴다 (11/06: 평균 1.5만 자)
///   - 업무 외로 판정된 행의 글자는 사용자가 동의하고 보관 기간이 지난 뒤 지운다. 시간 기록은 남는다.
///     업무 행이 같이 쓰는 글과, 남겨 두기로 한 기간의 글은 남긴다
public enum ScreenText {
    public static let editorLimit = 3_000

    public static func trimmed(_ text: String, appBundle: String, appName: String) -> String {
        guard RuleClassifier.isEditor(bundle: appBundle, name: appName), text.count > editorLimit else { return text }
        return String(text.prefix(editorLimit))
    }

    /// 업무 외로 판정된 행 중 before 보다 앞선 것의 글자를 지운다 (기간 핀이 덮는 날은 남긴다). Returns: 지운 글 수. 열린 트랜잭션 안에서 부른다
    @discardableResult
    public static func dropOffTask(_ conn: Database, before: Double, calendar: PeriodCalendar = PeriodCalendar()) throws -> Int {
        let pins = try ConsolidationStore.pins(conn).filter { $0.kind == .period }
        let rows = try Row.fetchAll(conn, sql: "SELECT id, ts FROM observations WHERE off_task = 1 AND text_id IS NOT NULL AND ts < ?", arguments: [before])
        let ids: [Int64] = rows.compactMap { row in
            let day = calendar.day(row["ts"])
            return pins.contains { $0.covers(day: day) } ? nil : row["id"]
        }
        return try dropOffTask(conn, observationIds: ids)
    }

    /// 업무 외 행들의 글 연결을 끊고, 이제 아무 행도 안 쓰는 글을 지운다. Returns: 지운 글 수. 열린 트랜잭션 안에서 부른다
    @discardableResult
    public static func dropOffTask(_ conn: Database, observationIds: [Int64]) throws -> Int {
        guard !observationIds.isEmpty else { return 0 }
        let list = observationIds.map(String.init).joined(separator: ",")
        let rows = "id IN (\(list)) AND off_task = 1 AND text_id IS NOT NULL"
        let texts = try Int64.fetchAll(conn, sql: "SELECT DISTINCT text_id FROM observations WHERE \(rows)")
        guard !texts.isEmpty else { return 0 }
        try conn.execute(sql: "UPDATE observations SET text_id = NULL WHERE \(rows)")
        let candidates = texts.map(String.init).joined(separator: ",")
        let orphans = try Int64.fetchAll(conn, sql: """
            SELECT id FROM text_snapshots WHERE id IN (\(candidates)) AND id NOT IN (SELECT text_id FROM observations WHERE text_id IS NOT NULL)
            """)
        guard !orphans.isEmpty else { return 0 }
        try conn.execute(sql: "DELETE FROM text_snapshots WHERE id IN (\(orphans.map(String.init).joined(separator: ",")))")
        return orphans.count
    }
}
