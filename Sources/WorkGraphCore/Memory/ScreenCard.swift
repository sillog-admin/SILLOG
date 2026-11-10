import Foundation
import GRDB

/// 화면 기억 카드: 대표 화면 한 장을 멀티모달 LLM 이 읽은 결과. 사실만 담고 업무 판정은 없다.
public struct ScreenCard: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public static let databaseTableName = "screen_cards"
    public static let kinds: [String] = ["document", "code", "web", "ai_chat", "message", "video", "tool", "none"]
    /// 대화 화면: 내용이 보낸 사람과 함께 인용한 메시지들이다 (최근이 마지막)
    public static let conversationKinds: Set<String> = ["message", "ai_chat"]

    public var id: Int64?
    public var tsStart: Double
    public var tsEnd: Double
    public var screenHash: Int64
    public var screenshotPath: String?
    public var appBundle: String
    public var appName: String
    public var windowTitle: String?
    public var uri: String?
    /// 무엇을 하고 있었나 (한 문장)
    public var activity: String
    /// 화면 내용 (줄바꿈으로 구분. 대화 화면은 최근 메시지 12줄까지, 그 밖은 2~6줄)
    public var content: String
    public var kind: String
    /// 이름 붙은 것들 (JSON): {"documents":[], "people":[], "code":[], "errors":[], "numbers":[], "links":[]}
    public var entities: String
    public var batchId: Int64?
    public var createdAt: Double

    public init(id: Int64? = nil, tsStart: Double, tsEnd: Double, screenHash: Int64, screenshotPath: String?, appBundle: String, appName: String,
                windowTitle: String?, uri: String?, activity: String, content: String, kind: String, entities: String = "{}", batchId: Int64? = nil, createdAt: Double) {
        self.id = id; self.tsStart = tsStart; self.tsEnd = tsEnd; self.screenHash = screenHash; self.screenshotPath = screenshotPath
        self.appBundle = appBundle; self.appName = appName; self.windowTitle = windowTitle; self.uri = uri
        self.activity = activity; self.content = content; self.kind = kind; self.entities = entities; self.batchId = batchId; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, tsStart = "ts_start", tsEnd = "ts_end", screenHash = "screen_hash", screenshotPath = "screenshot_path"
        case appBundle = "app_bundle", appName = "app_name", windowTitle = "window_title", uri, activity, content, kind, entities
        case batchId = "batch_id", createdAt = "created_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public var contentLines: [String] { content.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}

public struct ScreenCardStore: Sendable {
    let db: WGDatabase
    public init(_ db: WGDatabase) { self.db = db }

    @discardableResult
    public static func insert(_ conn: Database, _ card: ScreenCard) throws -> ScreenCard {
        var copy = card
        try copy.insert(conn)
        return copy
    }

    public static func link(_ conn: Database, observationIds: [Int64], cardId: Int64) throws {
        guard !observationIds.isEmpty else { return }
        let list = observationIds.map(String.init).joined(separator: ",")
        try conn.execute(sql: "UPDATE observations SET card_id = ? WHERE id IN (\(list))", arguments: [cardId])
    }

    /// 재사용 후보: since 이후 같은 앱·제목·주소로 만든 카드
    public static func recentCards(_ conn: Database, appBundle: String, title: String?, uri: String?, since: Double) throws -> [ScreenCard] {
        try ScreenCard.fetchAll(conn, sql: """
            SELECT * FROM screen_cards WHERE app_bundle = ? AND COALESCE(window_title, '') = ? AND COALESCE(uri, '') = ? AND ts_end >= ?
            ORDER BY ts_end DESC LIMIT 20
            """, arguments: [appBundle, title ?? "", uri ?? "", since])
    }

    /// 이 관측들이 이미 연결된 카드 (가장 많이 연결된 것). 재생성 때 카드를 다시 만들지 않게 한다
    public static func linkedCard(_ conn: Database, observationIds: [Int64]) throws -> ScreenCard? {
        guard !observationIds.isEmpty else { return nil }
        let list = observationIds.map(String.init).joined(separator: ",")
        guard let id = try Int64.fetchOne(conn, sql: """
            SELECT card_id FROM observations WHERE id IN (\(list)) AND card_id IS NOT NULL GROUP BY card_id ORDER BY COUNT(*) DESC LIMIT 1
            """) else { return nil }
        return try ScreenCard.fetchOne(conn, key: id)
    }

    public static func extend(_ conn: Database, cardId: Int64, to end: Double) throws {
        try conn.execute(sql: "UPDATE screen_cards SET ts_end = MAX(ts_end, ?) WHERE id = ?", arguments: [end, cardId])
    }

    public func card(id: Int64) throws -> ScreenCard? { try db.writer.read { try ScreenCard.fetchOne($0, key: id) } }

    public func cards(from: Double, to: Double, limit: Int = 500) throws -> [ScreenCard] {
        try db.writer.read { try ScreenCard.fetchAll($0, sql: "SELECT * FROM screen_cards WHERE ts_end >= ? AND ts_start <= ? ORDER BY ts_start LIMIT ?", arguments: [from, to, limit]) }
    }

    /// 한 세션(업무의 행들)이 덮는 카드
    public func cards(ofTask taskId: Int64, from: Double, to: Double) throws -> [ScreenCard] {
        try db.writer.read {
            try ScreenCard.fetchAll($0, sql: """
                SELECT DISTINCT c.* FROM screen_cards c JOIN observations o ON o.card_id = c.id
                WHERE o.task_id = ? AND o.ts >= ? AND o.ts <= ? ORDER BY c.ts_start
                """, arguments: [taskId, from, to])
        }
    }
}
