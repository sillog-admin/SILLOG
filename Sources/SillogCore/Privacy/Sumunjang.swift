import Foundation
import GRDB

/// SUMUNJANG (수문장): finds screen records that show a living person's sensitive information
/// (thought and belief, union or party, political view, health, sex life) before they reach a model.
/// The scoring runs on this Mac with `SumunjangModel`.
public struct Sumunjang: Sendable {
    /// One screen record in the shape the model was trained on.
    public struct Record: Hashable, Sendable {
        public var app: String
        public var appKind: String
        public var captureSource: String
        public var windowTitle: String?
        public var url: String?
        public var docPath: String?
        public var text: String

        /// Args: observation is the screen row, source is its text snapshot's capture source, text its screen text.
        /// Returns: the record with identifiers already masked, as the model expects.
        public init(_ observation: Observation, source: String?, text: String?) {
            app = observation.appName
            appKind = Self.kind(observation.appBundle)
            captureSource = source ?? "ax"
            windowTitle = observation.windowTitle.map(Sumunjang.masked)
            url = observation.url.map(Sumunjang.masked)
            docPath = observation.docPath.map(Sumunjang.masked)
            self.text = Sumunjang.masked(text ?? "")
        }

        /// For records that are already masked, such as the synthetic check records.
        public init(app: String, appKind: String, captureSource: String, windowTitle: String?, url: String?, docPath: String?, text: String) {
            (self.app, self.appKind, self.captureSource) = (app, appKind, captureSource)
            (self.windowTitle, self.url, self.docPath, self.text) = (windowTitle, url, docPath, text)
        }

        // The app kinds the training records used.
        static func kind(_ bundle: String) -> String {
            if ResumePlanner.browsers.contains(bundle) { return "browser" }
            if bundle == "com.apple.finder" { return "file_browser" }
            if ["com.openai.chat", "com.anthropic.claudefordesktop", "com.google.GeminiMacOS"].contains(bundle) { return "assistant" }
            if ["com.kakao.KakaoTalkMac", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
                "net.whatsapp.WhatsApp", "com.microsoft.teams2", "us.zoom.xos", "com.linecorp.line"].contains(bundle) { return "chat" }
            return "application"
        }
    }

    /// The renewal test's operating point.
    public static let threshold = 0.8
    /// What a blocked row's title becomes in the prompt.
    public static let placeholder = "[민감 정보]"
    /// Set from the app setting. On, chat search serves only screen rows a batch has scored.
    nonisolated(unsafe) public static var enabled = false

    private let score: @Sendable ([Record]) async throws -> [Double]

    /// Args: score returns one score per record; tests pass a stub, the app the downloaded model.
    public init(score: @escaping @Sendable ([Record]) async throws -> [Double] = { try await SumunjangModel.shared.scores($0) }) {
        self.score = score
    }

    /// Args: observations are screen rows, db holds their text snapshots.
    /// Returns: the ids scored at or above `threshold`. A periodic row has no text of its own,
    /// so it is scored with the last text of the same window, or a long sensitive screen would pass after its first row.
    /// Raises: SumunjangError when the model is not downloaded or cannot run.
    public func sensitiveIDs(_ observations: [Observation], db: SillogDatabase) async throws -> Set<Int64> {
        let texts = try await db.writer.read { conn -> [Int64: (source: String, text: String)] in
            var textOf: [Int64: Int64] = [:], last: [String: Int64?] = [:]
            for o in observations {
                guard let id = o.id else { continue }
                if let textId = o.textId { textOf[id] = textId; continue }
                let key = [o.appBundle, o.windowTitle ?? "", o.url ?? "", o.docPath ?? ""].joined(separator: "\u{1}")
                if last[key] == nil {
                    last[key] = try Int64.fetchOne(conn, sql: """
                        SELECT text_id FROM observations WHERE app_bundle = ? AND window_title IS ? AND url IS ? AND doc_path IS ?
                          AND text_id IS NOT NULL AND ts <= ? ORDER BY ts DESC LIMIT 1
                        """, arguments: [o.appBundle, o.windowTitle, o.url, o.docPath, o.ts])
                }
                if let textId = last[key] ?? nil { textOf[id] = textId }
            }
            let list = Set(textOf.values).map(String.init).joined(separator: ",")
            let snapshots = try Row.fetchAll(conn, sql: "SELECT id, source, text FROM text_snapshots WHERE id IN (\(list))")
                .reduce(into: [Int64: (source: String, text: String)]()) { $0[$1["id"]] = ($1["source"], $1["text"]) }
            return textOf.compactMapValues { snapshots[$0] }
        }
        // Periodic rows repeat the same screen, so each distinct record is scored once.
        var records: [Record] = [], slot: [Record: Int] = [:], recordOf: [Int64: Int] = [:]
        for o in observations {
            guard let id = o.id else { continue }
            let record = Record(o, source: texts[id]?.source, text: texts[id]?.text)
            if slot[record] == nil { slot[record] = records.count; records.append(record) }
            recordOf[id] = slot[record]
        }
        guard !records.isEmpty else { return [] }
        let scores = try await score(records)
        return Set(recordOf.filter { scores[$0.value] >= Self.threshold }.keys)
    }

    // The Korean placeholders of the training masker, so the model sees the input it learned from.
    // Rules missing here are foreign IDs, which the training masker called [식별번호].
    static let tags = [
        "private-key": "[개인키]", "api-key": "[API키]", "api-key-redacted": "[API키]", "jwt": "[토큰]", "bearer": "[비밀값]",
        "url-secret": "[비밀값]", "console-id": "[비밀값]", "url-credentials": "[비밀값]", "key-value": "[비밀값]", "kr-key-value": "[비밀값]",
        "otp": "[비밀값]", "otp-before": "[비밀값]", "tokenish": "[비밀값]",
        "email": "[이메일]", "email-partial": "[이메일]", "handle": "[계정]", "labeled-handle": "[계정]", "mac-hostname": "[사용자]",
        "iban": "[계좌번호]", "kr-account": "[계좌번호]", "kr-account-label": "[계좌번호]", "card": "[카드번호]", "card-partial": "[카드번호]",
        "intl-phone": "[전화번호]", "kr-phone": "[전화번호]", "kr-phone-variant": "[전화번호]", "kr-phone-partial": "[전화번호]", "nanp-phone": "[전화번호]",
        "kr-rrn": "[주민번호]", "kr-rrn-bare": "[주민번호]", "kr-driver": "[면허번호]", "kr-driver-bare": "[면허번호]", "kr-passport": "[여권번호]",
        "birth-date": "[생년월일]", "ipv4": "[IP주소]", "ipv6": "[IP주소]", "labeled-id": "[식별번호]", "kr-member-id": "[식별번호]",
        "kr-road-address": "[주소]", "kr-district-address": "[주소]", "kr-road-unit": "[주소]", "kr-jibun": "[주소]", "kr-apartment": "[주소]",
        "kr-unit": "[주소]", "kr-road-number": "[주소]", "kr-zip": "[주소]", "address": "[주소]", "kr-road-roman": "[주소]",
    ]

    private static let homeFolder = try! NSRegularExpression(pattern: #"(?:/Users/|/home/)([^/\s\[\]]+)"#)

    /// Args: text is any record field.
    /// Returns: the text composed to NFC, with identifiers, the home folder name and the account name replaced by the training placeholders.
    /// Masks even when the "개인정보 가리기" setting is off, because the model only ever saw masked text.
    static func masked(_ text: String) -> String {
        // Composed like PIIMasker.mask, so decomposed file names meet the Korean rules.
        let text = text.precomposedStringWithCanonicalMapping
        let result = NSMutableString(string: text)
        for item in replacements(in: text).reversed() { result.replaceCharacters(in: item.range, with: item.tag) }
        return result as String
    }

    /// Args: text is any record field.
    /// Returns: the non-overlapping ranges `masked` replaces, in text order, each with its placeholder.
    static func replacements(in text: String) -> [(range: NSRange, tag: String)] {
        var found = PIIMasker.matches(in: text).map { (range: $0.range, tag: tags[$0.rule] ?? "[식별번호]") }
        func claim(_ range: NSRange) {
            guard range.length > 0, !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            found.append((range, "[사용자]"))
        }
        let source = text as NSString
        for match in homeFolder.matches(in: text, range: NSRange(location: 0, length: source.length)) { claim(match.range(at: 1)) }
        for name in [NSFullUserName(), NSUserName()] where name.count >= 2 {
            var from = 0
            while case let range = source.range(of: name, range: NSRange(location: from, length: source.length - from)), range.location != NSNotFound {
                claim(range)
                from = NSMaxRange(range)
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }
}

public enum SumunjangError: LocalizedError {
    case notReady, download(String), model(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return tr("수문장 모델을 아직 받지 못했어요.")
        case .download: return tr("모델을 받지 못했어요. 인터넷 연결을 확인해 주세요.")
        case .model: return tr("수문장 모델을 실행하지 못했어요.")
        }
    }
}
