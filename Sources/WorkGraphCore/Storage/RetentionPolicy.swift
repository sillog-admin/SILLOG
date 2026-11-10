import Foundation
import GRDB

/// 항목별 원문 보관일. nil 은 지우지 않는다. 앱과 wgctl 이 같은 값을 쓰도록 DB(consolidation_state)에 둔다
public struct RetentionPolicy: Codable, Equatable, Sendable {
    public enum Item: String, CaseIterable, Codable, Sendable {
        case screenText, batchLog, observations, screenCards, aiRequests, fileEvents

        public var title: String {
            switch self {
            case .screenText: "화면 텍스트"
            case .batchLog: "정리 기록 원문"
            case .observations: "활동 기록(앱·창 제목·주소)"
            case .screenCards: "화면 카드"
            case .aiRequests: "AI 도구 요청"
            case .fileEvents: "파일 기록과 정리 제안"
            }
        }

        public var detail: String {
            switch self {
            case .screenText: "화면에서 읽은 글자와 검색 색인. 지운 뒤에는 주간 요약과 화면 카드가 남아요."
            case .batchLog: "정리할 때 AI와 주고받은 프롬프트·응답 전문. 토큰·오류 같은 통계는 남아요."
            case .observations: "언제 어떤 앱·창·주소를 봤는지. 지운 뒤에도 업무별 사용 시간은 남아요."
            case .screenCards: "대표 화면을 AI가 읽은 요약. 지운 뒤에는 월간 요약이 남아요."
            case .aiRequests: "Claude Code·Codex에 보낸 요청. 지운 뒤에는 주간 요약의 요청 목록이 남아요."
            case .fileEvents: "내려받은 파일 기록과 폴더 제안."
            }
        }

        /// 사용자가 고를 수 있는 보관일 범위
        public var range: ClosedRange<Int> {
            switch self {
            case .screenText, .batchLog: 7...365
            case .observations: 7...1095
            case .screenCards, .aiRequests, .fileEvents: 30...1095
            }
        }
    }

    /// 화면 텍스트 보관일을 고르는 프리셋. 나머지 항목은 고급에서 따로 고친다
    public enum Preset: String, CaseIterable, Codable, Sendable {
        case light, standard, long, keepRaw

        public var title: String {
            switch self {
            case .light: "가볍게"
            case .standard: "기본"
            case .long: "길게"
            case .keepRaw: "원문 무기한"
            }
        }

        public var screenTextDays: Int? {
            switch self {
            case .light: 14
            case .standard: 30
            case .long: 90
            case .keepRaw: nil
            }
        }
    }

    public var screenTextDays: Int?
    public var batchLogDays: Int?
    public var observationDays: Int?
    public var screenCardDays: Int?
    public var aiRequestDays: Int?
    public var fileEventDays: Int?
    /// 요약을 검증한 뒤 원문을 지우기까지 기다리는 날
    public var graceDays: Int
    /// 다이제스트 문장을 정리용 LLM 으로 쓴다. 끄면 수치와 세션 요약만으로 만든다
    public var narrateDigests: Bool

    public static let graceRange = 1...30

    /// 팀 결정 기본값: 화면 텍스트 30일, 관측 90일, 화면 카드 180일, 유예 7일
    public static let standard = RetentionPolicy(screenTextDays: 30, batchLogDays: 14, observationDays: 90, screenCardDays: 180,
                                                 aiRequestDays: 365, fileEventDays: 365, graceDays: 7, narrateDigests: true)

    public init(screenTextDays: Int?, batchLogDays: Int?, observationDays: Int?, screenCardDays: Int?,
                aiRequestDays: Int?, fileEventDays: Int?, graceDays: Int, narrateDigests: Bool) {
        self.screenTextDays = screenTextDays; self.batchLogDays = batchLogDays; self.observationDays = observationDays
        self.screenCardDays = screenCardDays; self.aiRequestDays = aiRequestDays; self.fileEventDays = fileEventDays
        self.graceDays = graceDays; self.narrateDigests = narrateDigests
    }

    /// 예전에 저장한 값에 없는 항목은 기본값으로 채운다
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.standard
        func days(_ key: CodingKeys, _ fallback: Int?) throws -> Int? {
            guard c.contains(key) else { return fallback }
            return try c.decodeIfPresent(Int.self, forKey: key)
        }
        screenTextDays = try days(.screenTextDays, d.screenTextDays)
        batchLogDays = try days(.batchLogDays, d.batchLogDays)
        observationDays = try days(.observationDays, d.observationDays)
        screenCardDays = try days(.screenCardDays, d.screenCardDays)
        aiRequestDays = try days(.aiRequestDays, d.aiRequestDays)
        fileEventDays = try days(.fileEventDays, d.fileEventDays)
        graceDays = try c.decodeIfPresent(Int.self, forKey: .graceDays) ?? d.graceDays
        narrateDigests = try c.decodeIfPresent(Bool.self, forKey: .narrateDigests) ?? d.narrateDigests
    }

    /// nil 도 명시적으로 남겨야 "무기한"이 기본값으로 되돌아가지 않는다
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenTextDays, forKey: .screenTextDays)
        try c.encode(batchLogDays, forKey: .batchLogDays)
        try c.encode(observationDays, forKey: .observationDays)
        try c.encode(screenCardDays, forKey: .screenCardDays)
        try c.encode(aiRequestDays, forKey: .aiRequestDays)
        try c.encode(fileEventDays, forKey: .fileEventDays)
        try c.encode(graceDays, forKey: .graceDays)
        try c.encode(narrateDigests, forKey: .narrateDigests)
    }

    private enum CodingKeys: String, CodingKey {
        case screenTextDays, batchLogDays, observationDays, screenCardDays, aiRequestDays, fileEventDays, graceDays, narrateDigests
    }

    public func days(_ item: Item) -> Int? {
        switch item {
        case .screenText: screenTextDays
        case .batchLog: batchLogDays
        case .observations: observationDays
        case .screenCards: screenCardDays
        case .aiRequests: aiRequestDays
        case .fileEvents: fileEventDays
        }
    }

    public mutating func setDays(_ item: Item, _ value: Int?) {
        switch item {
        case .screenText: screenTextDays = value
        case .batchLog: batchLogDays = value
        case .observations: observationDays = value
        case .screenCards: screenCardDays = value
        case .aiRequests: aiRequestDays = value
        case .fileEvents: fileEventDays = value
        }
        self = normalized(changed: item)
    }

    /// 지금 값에 맞는 프리셋. 화면 텍스트 보관일만 본다 (나머지는 고급 항목)
    public var preset: Preset? { Preset.allCases.first { $0.screenTextDays == screenTextDays } }

    public mutating func apply(_ preset: Preset) {
        screenTextDays = preset.screenTextDays
        self = normalized(changed: .screenText)
    }

    /// 범위를 맞추고, 관측은 화면 텍스트보다 먼저 지우지 않는다 (화면 텍스트는 관측을 통해서만 찾을 수 있다).
    /// changed: 방금 사용자가 바꾼 항목. 그 값을 지키는 쪽으로 다른 항목을 맞춘다
    public func normalized(changed: Item? = nil) -> RetentionPolicy {
        var copy = self
        for item in Item.allCases {
            if let days = copy.days(item) { copy.setRaw(item, min(max(days, item.range.lowerBound), item.range.upperBound)) }
        }
        copy.graceDays = min(max(copy.graceDays, Self.graceRange.lowerBound), Self.graceRange.upperBound)
        let text = copy.screenTextDays, observations = copy.observationDays
        let observationsTooShort = text == nil ? observations != nil : (observations.map { $0 < text! } ?? false)
        if observationsTooShort {
            if changed == .observations { copy.screenTextDays = observations } else { copy.observationDays = text }
        }
        return copy
    }

    private mutating func setRaw(_ item: Item, _ value: Int?) {
        switch item {
        case .screenText: screenTextDays = value
        case .batchLog: batchLogDays = value
        case .observations: observationDays = value
        case .screenCards: screenCardDays = value
        case .aiRequests: aiRequestDays = value
        case .fileEvents: fileEventDays = value
        }
    }

    public static func load(_ conn: Database) throws -> RetentionPolicy {
        guard let text = try ConsolidationStore.value(ConsolidationStore.Key.policy, conn),
              let policy = try? JSONDecoder().decode(RetentionPolicy.self, from: Data(text.utf8)) else { return .standard }
        return policy.normalized()
    }

    public func save(_ conn: Database) throws {
        let data = try JSONEncoder().encode(normalized())
        try ConsolidationStore.set(ConsolidationStore.Key.policy, String(decoding: data, as: UTF8.self), conn)
    }
}
