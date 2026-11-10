import Foundation

/// 구글 캘린더 API (맥에 구글 계정을 안 붙인 사람용): 캘린더 목록, 기간의 일정, 일정 넣기.
/// 로그인(토큰)은 앱이 맡는다 (ConnectorAuth 의 구글 로그인, 권한은 캘린더 목록 읽기와 일정 읽기·쓰기)
public struct GoogleCalendarClient: Sendable {
    /// 요청 하나 보내기: (본문, HTTP 상태)
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    public struct Calendar: Equatable, Sendable {
        public let id: String
        public let title: String
        /// "#RRGGBB"
        public let color: String
        /// 일정을 넣을 수 있는지 (owner·writer)
        public let writable: Bool
        public let primary: Bool

        public init(id: String, title: String, color: String, writable: Bool, primary: Bool) {
            self.id = id; self.title = title; self.color = color; self.writable = writable; self.primary = primary
        }
    }

    public struct Event: Equatable, Sendable {
        public let id: String
        public let title: String
        public let start: Date
        /// 종일이면 끝 날짜 다음 날 0시 (구글처럼 끝 날짜를 빼고 센다)
        public let end: Date?
        public let allDay: Bool
        public let location: String?
        public let notes: String?

        public init(id: String, title: String, start: Date, end: Date?, allDay: Bool, location: String?, notes: String?) {
            self.id = id; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        }
    }

    public enum Failure: Error, Equatable {
        /// 로그인이 만료됐거나 권한을 거뒀다 (다시 연결해야 한다)
        case unauthorized
        case http(Int, String)
    }

    static let base = "https://www.googleapis.com/calendar/v3"
    private let token: @Sendable () async throws -> String
    private let fetch: Fetch

    public init(token: @escaping @Sendable () async throws -> String, fetch: @escaping Fetch) {
        self.token = token
        self.fetch = fetch
    }

    /// URLSession 으로 보내는 실제 클라이언트
    public static func live(token: @escaping @Sendable () async throws -> String) -> GoogleCalendarClient {
        GoogleCalendarClient(token: token) { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func calendars() async throws -> [Calendar] {
        let root = try await send(URLRequest(url: URL(string: "\(Self.base)/users/me/calendarList")!))
        return (root["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let role = item["accessRole"] as? String ?? ""
            return Calendar(id: id, title: item["summaryOverride"] as? String ?? item["summary"] as? String ?? id,
                            color: (item["backgroundColor"] as? String ?? "#8A7566").uppercased(),
                            writable: role == "owner" || role == "writer", primary: item["primary"] as? Bool ?? false)
        }
    }

    /// 기간 안의 일정 (되풀이 일정은 하나씩 펼쳐서, 취소된 것은 빼고). 여러 쪽이면 다 받는다
    public func events(calendarId: String, from: Date, to: Date) async throws -> [Event] {
        let utc = ISO8601DateFormatter()                     // Z 로 끝나게: 쿼리의 + 가 빈칸으로 읽히지 않게
        utc.timeZone = TimeZone(identifier: "UTC")
        var events: [Event] = []
        var page: String?
        repeat {
            var parts = URLComponents(string: "\(Self.base)/calendars/\(Self.pathSegment(calendarId))/events")!
            parts.queryItems = [URLQueryItem(name: "timeMin", value: utc.string(from: from)), URLQueryItem(name: "timeMax", value: utc.string(from: to)),
                                URLQueryItem(name: "singleEvents", value: "true"), URLQueryItem(name: "orderBy", value: "startTime"),
                                URLQueryItem(name: "maxResults", value: "250")] + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            guard let url = parts.url else { break }
            let root = try await send(URLRequest(url: url))
            events += (root["items"] as? [[String: Any]] ?? []).compactMap(Self.event)
            page = root["nextPageToken"] as? String
        } while page != nil
        return events
    }

    /// 일정을 넣는다. 끝을 모르면 한 시간. 종일이면 날짜만 (끝은 다음 날). Returns: 새 일정 id
    public func insert(calendarId: String, title: String, start: Date, end: Date?, allDay: Bool, notes: String?,
                       timeZone: TimeZone = .current) async throws -> String {
        var body: [String: Any] = ["summary": title]
        if let notes, !notes.isEmpty { body["description"] = notes }
        if allDay {
            var days = Foundation.Calendar(identifier: .gregorian)
            days.timeZone = timeZone
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd"
            let first = days.startOfDay(for: start)
            let after = days.date(byAdding: .day, value: 1, to: first) ?? first
            body["start"] = ["date": f.string(from: first)]
            body["end"] = ["date": f.string(from: max(after, end ?? after))]
        } else {
            let iso = ISO8601DateFormatter()
            iso.timeZone = timeZone
            body["start"] = ["dateTime": iso.string(from: start), "timeZone": timeZone.identifier]
            body["end"] = ["dateTime": iso.string(from: end ?? start.addingTimeInterval(3_600)), "timeZone": timeZone.identifier]
        }
        var request = URLRequest(url: URL(string: "\(Self.base)/calendars/\(Self.pathSegment(calendarId))/events")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let root = try await send(request)
        guard let id = root["id"] as? String else { throw Failure.http(200, "일정 id 를 받지 못했어요") }
        return id
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, status) = try await fetch(request)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(status) else {
            throw Failure.http(status, ((root["error"] as? [String: Any])?["message"] as? String) ?? "구글 캘린더 요청 실패")
        }
        return root
    }

    /// 경로에 넣을 캘린더 id: 영문·숫자·-._~ 밖은 % 로 (공휴일 캘린더 id 의 #, 메일 주소의 @)
    static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? id
    }

    private static func event(_ item: [String: Any]) -> Event? {
        guard let id = item["id"] as? String, item["status"] as? String != "cancelled",
              let start = item["start"] as? [String: Any], let (begin, allDay) = moment(start) else { return nil }
        let end = (item["end"] as? [String: Any]).flatMap(moment)?.0
        return Event(id: id, title: item["summary"] as? String ?? "(제목 없음)", start: begin, end: end, allDay: allDay,
                     location: item["location"] as? String, notes: item["description"] as? String)
    }

    /// {"dateTime": "...+09:00"} 이면 그 시각, {"date": "2026-11-10"} 이면 이 Mac 시간대의 그날 0시 (종일)
    private static func moment(_ value: [String: Any]) -> (Date, Bool)? {
        if let text = value["dateTime"] as? String {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (plain.date(from: text) ?? fractional.date(from: text)).map { ($0, false) }
        }
        guard let text = value["date"] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: text).map { ($0, true) }
    }
}
