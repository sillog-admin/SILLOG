import Foundation
import GRDB

/// 녹음 기록 저장소. 받아쓴 글은 trigram 색인(recordings_fts)으로 채팅에서 찾는다
public struct RecordingStore: Sendable {
    /// 받아쓰기가 끝난 녹음 파일을 두는 기간 (일)
    public static let audioKeepDays: Double = 7
    /// 받아쓴 글이 있는지 (SQL). Recording.hasTranscript 와 같은 기준: 빈칸·탭·줄바꿈만 있으면 없음
    static let hasTranscriptSQL = "trim(transcript, ' ' || char(9) || char(10) || char(13)) != ''"

    let db: WGDatabase
    public init(_ db: WGDatabase) { self.db = db }

    static func migrate(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16-recordings") { conn in
            try conn.execute(sql: """
                CREATE TABLE recordings (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  started_at REAL NOT NULL,
                  ended_at REAL,
                  duration REAL NOT NULL DEFAULT 0,
                  audio_path TEXT NOT NULL,
                  audio_deleted_at REAL,
                  text_path TEXT,
                  title TEXT,
                  summary TEXT,
                  transcript TEXT NOT NULL DEFAULT '',
                  status TEXT NOT NULL,
                  error TEXT,
                  ready_at REAL,
                  batch_id INTEGER,
                  task_id INTEGER,
                  suggestion_id INTEGER
                );
                CREATE INDEX idx_recordings_status ON recordings(status, batch_id, ended_at);
                CREATE INDEX idx_recordings_text_path ON recordings(text_path);
                CREATE VIRTUAL TABLE recordings_fts USING fts5(title, summary, transcript, content='recordings', content_rowid='id', tokenize='trigram');
                CREATE TRIGGER recordings_ai AFTER INSERT ON recordings BEGIN
                  INSERT INTO recordings_fts(rowid, title, summary, transcript) VALUES (new.id, new.title, new.summary, new.transcript);
                END;
                CREATE TRIGGER recordings_ad AFTER DELETE ON recordings BEGIN
                  INSERT INTO recordings_fts(recordings_fts, rowid, title, summary, transcript) VALUES ('delete', old.id, old.title, old.summary, old.transcript);
                END;
                CREATE TRIGGER recordings_au AFTER UPDATE OF title, summary, transcript ON recordings BEGIN
                  INSERT INTO recordings_fts(recordings_fts, rowid, title, summary, transcript) VALUES ('delete', old.id, old.title, old.summary, old.transcript);
                  INSERT INTO recordings_fts(rowid, title, summary, transcript) VALUES (new.id, new.title, new.summary, new.transcript);
                END;
                """)
        }
    }

    @discardableResult
    public func insert(_ recording: Recording) throws -> Recording {
        try db.writer.write { conn in var copy = recording; try copy.insert(conn); return copy }
    }

    public func update(_ recording: Recording) throws {
        try db.writer.write { try recording.update($0) }
    }

    /// 녹음을 시작하지 못했을 때 만든 기록을 지운다
    public func delete(id: Int64) throws {
        _ = try db.writer.write { try Recording.deleteOne($0, key: id) }
    }

    /// 보관함 [녹음 삭제]: 그래프의 recording:<id> 자료 노드와 그 모든 엣지, 그리고 이 행을 한 트랜잭션에서 지운 뒤
    /// (FTS 삭제 트리거가 색인도 함께 지운다) 녹음 파일을 지운다. 받아쓴 글(text_path)은 사용자 파일이라 손대지 않는다
    public func remove(id: Int64) throws {
        let audioPath = try find(id: id)?.audioPath
        try db.writer.write { conn in
            if let nodeId = try GraphTx(conn).node(label: NodeLabel.resource, key: "recording:\(id)")?.id {
                try conn.execute(sql: "DELETE FROM edges WHERE src = ? OR dst = ?", arguments: [nodeId, nodeId])
                try conn.execute(sql: "DELETE FROM nodes WHERE id = ?", arguments: [nodeId])
            }
            _ = try Recording.deleteOne(conn, key: id)
        }
        if let audioPath, FileManager.default.fileExists(atPath: audioPath) {
            try? FileManager.default.removeItem(atPath: audioPath)
        }
    }

    public func find(id: Int64) throws -> Recording? {
        try db.writer.read { try Recording.fetchOne($0, key: id) }
    }

    public func find(textPath: String) throws -> Recording? {
        try db.writer.read { try Recording.fetchOne($0, sql: "SELECT * FROM recordings WHERE text_path = ? ORDER BY id DESC LIMIT 1", arguments: [textPath]) }
    }

    /// 최신순 전부 (보관함)
    public func all() throws -> [Recording] {
        try db.writer.read { try Recording.fetchAll($0, sql: "SELECT * FROM recordings ORDER BY started_at DESC, id DESC") }
    }

    /// 앱이 꺼진 동안 끝나지 않은 것 (녹음 중·받아쓰는 중), 오래된 것부터
    public func unfinished() throws -> [Recording] {
        try db.writer.read { try Recording.fetchAll($0, sql: "SELECT * FROM recordings WHERE status IN ('recording', 'transcribing') ORDER BY started_at, id") }
    }

    /// 정리 대기: ready 이고 받아쓴 글이 있으며 아직 어느 배치에도 안 들어간 것 중 [notOlderThan, upTo] 안에 끝난 것
    public func unprocessed(upTo: Double, notOlderThan: Double) throws -> [Recording] {
        try db.writer.read { conn in
            try Recording.fetchAll(conn, sql: """
                SELECT * FROM recordings WHERE status = 'ready' AND batch_id IS NULL AND \(Self.hasTranscriptSQL)
                  AND ended_at <= ? AND ended_at >= ? ORDER BY started_at, id
                """, arguments: [upTo, notOlderThan])
        }
    }

    public static func mark(_ conn: Database, ids: [Int64], batchId: Int64) throws {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE recordings SET batch_id = ? WHERE id IN (\(list))", arguments: [batchId])
    }

    public static func assign(_ conn: Database, ids: [Int64], taskId: Int64?) throws {
        guard !ids.isEmpty else { return }
        let list = ids.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE recordings SET task_id = ? WHERE id IN (\(list))", arguments: [taskId])
    }

    /// ready 가 된 지 7일 지났고 아직 녹음 파일을 지우지 않은 것 (받아쓰기에 실패한 녹음은 다시 받아쓸 수 있게 뺀다)
    public func expiredAudio(now: Double) throws -> [Recording] {
        try db.writer.read { conn in
            try Recording.fetchAll(conn, sql: """
                SELECT * FROM recordings WHERE status = 'ready' AND audio_deleted_at IS NULL AND ready_at IS NOT NULL AND ready_at <= ?
                ORDER BY ready_at, id
                """, arguments: [now - Self.audioKeepDays * 86_400])
        }
    }

    /// 7일 지난 녹음 파일을 지우고 지운 시각을 남긴다. 지우지 못한 것은 다음에 다시 해 본다. 지운 개수
    @discardableResult
    public func deleteExpiredAudio(now: Double) throws -> Int {
        var count = 0
        for var recording in try expiredAudio(now: now) {
            if FileManager.default.fileExists(atPath: recording.audioPath) {
                do { try FileManager.default.removeItem(atPath: recording.audioPath) } catch { continue }
            }
            recording.audioDeletedAt = now
            try update(recording)
            count += 1
        }
        return count
    }

    /// 받아쓴 글 파일이 옮겨졌을 때 (폴더 제안 수락·되돌리기). 바꾼 기록이 있으면 true
    @discardableResult
    public func moveText(from old: String, to new: String) throws -> Bool {
        try db.writer.write { conn in
            try conn.execute(sql: "UPDATE recordings SET text_path = ? WHERE text_path = ?", arguments: [new, old])
            return conn.changesCount > 0
        }
    }
}
