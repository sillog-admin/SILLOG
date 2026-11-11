import Foundation
import GRDB

/// 원시 기록 지우기 (TaskEraser·NodeEraser 가 함께 쓴다): 원시 행·AI 대화·녹음과, 그 행에만 쓰인 글 조각·화면 카드, 그 행에서 나온 일정 제안.
/// 그 행이 들어간 정리 기록은 원문(프롬프트·응답)을 비운다 (통계는 남긴다). 스크린샷·녹음 파일은 DB 밖이라 report.files 로 돌려주고 호출자가 지운다
enum RecordEraser {
    struct Rows {
        var observations: [Int64] = []
        var chats: [Int64] = []
        var recordings: [Int64] = []
        /// 행과 상관없이 지울 화면 카드 (자료·앱의 카드)
        var cards: [Int64] = []
        /// 행과 상관없이 원문을 비울 정리 기록 (업무 이름이 나온 것)
        var batches: [Int64] = []
    }

    /// report 에 수를 더하고, dry 가 아니면 지운다. 열린 트랜잭션 안에서 부른다
    static func apply(_ rows: Rows, conn: Database, report: inout TaskEraser.Report, dry: Bool) throws {
        func list(_ ids: [Int64]) -> String { ids.isEmpty ? "0" : ids.map(String.init).joined(separator: ",") }   // id 는 1부터라 0 은 아무것도 안 고른다
        func ints(_ sql: String) throws -> [Int64] { try Int64.fetchAll(conn, sql: sql) }
        let obs = list(rows.observations), chats = list(rows.chats), recs = list(rows.recordings)
        // 그 행에만 쓰인 글 조각·화면 카드 (다른 행이 같이 쓰면 남긴다)
        let texts = try ints("""
            SELECT DISTINCT text_id FROM observations WHERE id IN (\(obs)) AND text_id IS NOT NULL
              AND text_id NOT IN (SELECT text_id FROM observations WHERE id NOT IN (\(obs)) AND text_id IS NOT NULL)
            """)
        let rowCards = try ints("""
            SELECT DISTINCT card_id FROM observations WHERE id IN (\(obs)) AND card_id IS NOT NULL
              AND card_id NOT IN (SELECT card_id FROM observations WHERE id NOT IN (\(obs)) AND card_id IS NOT NULL)
            """)
        let cards = Array(Set(rowCards + rows.cards)).sorted()
        let batches = Array(Set(try ints("""
            SELECT batch_id FROM observations WHERE id IN (\(obs)) AND batch_id IS NOT NULL
            UNION SELECT batch_id FROM chat_messages WHERE id IN (\(chats)) AND batch_id IS NOT NULL
            UNION SELECT batch_id FROM recordings WHERE id IN (\(recs)) AND batch_id IS NOT NULL
            """) + rows.batches)).sorted()
        var files = try String.fetchAll(conn, sql: "SELECT screenshot_path FROM observations WHERE id IN (\(obs)) AND screenshot_path IS NOT NULL")
        files += try String.fetchAll(conn, sql: "SELECT screenshot_path FROM screen_cards WHERE id IN (\(list(cards))) AND screenshot_path IS NOT NULL")
        files += try String.fetchAll(conn, sql: "SELECT audio_path FROM recordings WHERE id IN (\(recs)) AND audio_path IS NOT NULL")
        let kept = Set(try String.fetchAll(conn, sql: """
            SELECT screenshot_path FROM observations WHERE id NOT IN (\(obs)) AND screenshot_path IS NOT NULL
            UNION SELECT screenshot_path FROM screen_cards WHERE id NOT IN (\(list(cards))) AND screenshot_path IS NOT NULL
            """))
        report.observations += rows.observations.count
        report.chats += rows.chats.count
        report.recordings += rows.recordings.count
        report.texts += texts.count
        report.cards += cards.count
        report.suggestions += try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM event_suggestions WHERE evidence_id IN (\(obs))") ?? 0
        report.batches += batches.count
        report.files = Array(Set(report.files + files).subtracting(kept)).sorted()
        guard !dry else { return }

        try conn.execute(sql: "DELETE FROM event_suggestions WHERE evidence_id IN (\(obs))")
        // 내려받은 파일 기록은 그 행을 가리키는 연결만 끊는다 (파일 정리 제안이 쓴다. 가리키는 채로는 외래 키가 삭제를 막는다)
        try conn.execute(sql: "UPDATE file_events SET observation_id = NULL WHERE observation_id IN (\(obs))")
        try conn.execute(sql: "DELETE FROM observations WHERE id IN (\(obs))")
        try conn.execute(sql: "DELETE FROM text_snapshots WHERE id IN (\(list(texts)))")
        try conn.execute(sql: "DELETE FROM screen_cards WHERE id IN (\(list(cards)))")
        try conn.execute(sql: "DELETE FROM chat_messages WHERE id IN (\(chats))")
        try conn.execute(sql: "DELETE FROM recordings WHERE id IN (\(recs))")
        try conn.execute(sql: "UPDATE batches SET user_prompt = NULL, raw_response = NULL, llm_patch = NULL, applied_patch = NULL WHERE id IN (\(list(batches)))")
    }
}
