import Foundation
import GRDB

/// 메뉴 막대에서 녹음한 것 한 건. status: recording → transcribing → ready | failed
/// 녹음 파일(audioPath)은 앱 데이터 폴더에 두었다가 ready 가 되고 7일 뒤 지운다. 받아쓴 글(textPath)은 사용자 파일이라 지우지 않는다
public struct Recording: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public enum Status: String, Codable, Sendable { case recording, transcribing, ready, failed }

    public static let databaseTableName = "recordings"
    public var id: Int64?
    public var startedAt: Double
    public var endedAt: Double?
    /// 녹음 길이(초)
    public var duration: Double
    public var audioPath: String
    public var audioDeletedAt: Double?
    /// 받아쓴 글 .md. 받아쓴 글이 없으면 nil
    public var textPath: String?
    public var title: String?
    public var summary: String?
    /// 발화마다 한 줄
    public var transcript: String
    public var status: Status
    public var error: String?
    /// ready 가 된 시각 (녹음 파일 7일 규칙의 기준)
    public var readyAt: Double?
    public var batchId: Int64?
    public var taskId: Int64?
    public var suggestionId: Int64?

    public init(id: Int64? = nil, startedAt: Double, endedAt: Double? = nil, duration: Double = 0, audioPath: String,
                audioDeletedAt: Double? = nil, textPath: String? = nil, title: String? = nil, summary: String? = nil,
                transcript: String = "", status: Status = .recording, error: String? = nil, readyAt: Double? = nil,
                batchId: Int64? = nil, taskId: Int64? = nil, suggestionId: Int64? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.duration = duration; self.audioPath = audioPath
        self.audioDeletedAt = audioDeletedAt; self.textPath = textPath; self.title = title; self.summary = summary
        self.transcript = transcript; self.status = status; self.error = error; self.readyAt = readyAt
        self.batchId = batchId; self.taskId = taskId; self.suggestionId = suggestionId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at", endedAt = "ended_at", duration
        case audioPath = "audio_path", audioDeletedAt = "audio_deleted_at", textPath = "text_path"
        case title, summary, transcript, status, error
        case readyAt = "ready_at", batchId = "batch_id", taskId = "task_id", suggestionId = "suggestion_id"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var hasTranscript: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 발화별 문장 (빈 줄은 뺀다)
    public var utterances: [String] {
        transcript.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 목록에 보일 이름: 제목, 없으면 상태
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch status {
        case .recording: return "녹음 중"
        case .transcribing: return "받아쓰는 중인 녹음"
        case .ready, .failed: return "제목 없는 녹음"
        }
    }
}
