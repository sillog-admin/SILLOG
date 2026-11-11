import Foundation
import PDFKit

private final class WebRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// Args: session·task는 웹 읽기 요청, response·request는 리디렉션 대상, completionHandler는 허용 여부이다.
    /// Returns: 없음. 공개 HTTPS 주소로만 리디렉션을 허용한다.
    /// Raises: 없음.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler((try? ChatTools.webURL(request.url?.absoluteString ?? "")) != nil ? request : nil)
    }
}

extension ChatTools {
    /// Args: url은 검증된 공개 HTTPS 주소이다.
    /// Returns: 페이지의 텍스트와 원문 출처.
    /// Raises: HTTP·크기·네트워크 오류.
    func webRead(_ url: URL) async throws -> ChatToolOutput {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let session = URLSession(configuration: .ephemeral, delegate: WebRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw ChatToolError.unavailable("웹 페이지를 읽지 못했거나 크기가 너무 큽니다.")
        }
        let plain = Self.htmlText(String(decoding: data, as: UTF8.self))
        return try Self.output([.init(id: url.absoluteString, title: url.host ?? "웹 자료", location: url.absoluteString, excerpt: String(plain.prefix(20000)))])
    }

    private static func htmlText(_ raw: String) -> String {
        let withoutScripts = raw.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        return withoutScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }

    /// Args: id는 커넥터 이름, url은 해당 서비스의 고정 API URL이다.
    /// Returns: OAuth 인증 헤더를 넣은 읽기 요청.
    /// Raises: 커넥터 연결 또는 Keychain 오류.
    private func connectorRequest(_ id: String, _ url: URL) async throws -> URLRequest {
        let token = try await connectorToken(id)
        guard !token.isEmpty else { throw ChatToolError.unavailable("\(id) 커넥터를 설정에서 연결하세요.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if id == "notion" { request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version") }
        return request
    }

    /// Args: query는 Gmail 검색 문법의 검색어이다.
    /// Returns: 관련 메일의 제목·미리보기·원문 위치.
    /// Raises: 연결·Gmail API 오류.
    func gmailSearch(_ query: String, limit: Int = 10) async throws -> ChatToolOutput {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        url.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(300))), URLQueryItem(name: "maxResults", value: "\(limit)")]
        let listing = try await Self.json(connectorRequest("gmail", url.url!)).objectValue ?? [:]
        var sources: [ChatSource] = []
        for item in listing["messages"]?.arrayValue ?? [] {
            guard let id = item.objectValue?["id"]?.stringValue else { continue }
            var detailURL = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
            detailURL.queryItems = [URLQueryItem(name: "format", value: "metadata"), URLQueryItem(name: "metadataHeaders", value: "Subject"), URLQueryItem(name: "metadataHeaders", value: "From"), URLQueryItem(name: "metadataHeaders", value: "Date")]
            let detail = try await Self.json(connectorRequest("gmail", detailURL.url!)).objectValue ?? [:]
            let headers = detail["payload"]?.objectValue?["headers"]?.arrayValue ?? []
            let fields = Dictionary(headers.compactMap { item -> (String, String)? in
                let value = item.objectValue ?? [:]
                guard let name = value["name"]?.stringValue, let text = value["value"]?.stringValue else { return nil }
                return (name.lowercased(), text)
            }, uniquingKeysWith: { first, _ in first })
            let location = "https://mail.google.com/mail/u/0/#all/\(id)"
            sources.append(.init(id: "gmail:\(id)", title: fields["subject"] ?? "제목 없는 메일", location: location,
                                 excerpt: "보낸 사람: \(fields["from"] ?? "") · 날짜: \(fields["date"] ?? "")\n\(detail["snippet"]?.stringValue ?? "")"))
        }
        return try Self.output(sources)
    }

    /// Args: reference는 Gmail 검색 결과의 메일 ID 또는 출처 ID이다.
    /// Returns: 메일 본문과 원문 위치.
    /// Raises: 연결·Gmail API 오류.
    func gmailRead(_ reference: String, allowSnippet: Bool = true) async throws -> ChatToolOutput {
        let id = reference.hasPrefix("gmail:") ? String(reference.dropFirst(6)) : reference
        guard id.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { throw ChatToolError.unavailable("메일 ID가 올바르지 않습니다.") }
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let detail = try await Self.json(connectorRequest("gmail", url)).objectValue ?? [:]
        let payload = detail["payload"]?.objectValue ?? [:]
        let headers = payload["headers"]?.arrayValue ?? []
        let subject = headers.first { $0.objectValue?["name"]?.stringValue?.lowercased() == "subject" }?.objectValue?["value"]?.stringValue ?? "제목 없는 메일"
        let body = Self.gmailBody(payload, mimeType: "text/plain")
            ?? Self.gmailBody(payload, mimeType: "text/html").map(Self.htmlText)
            ?? (allowSnippet ? detail["snippet"]?.stringValue : nil) ?? ""
        let location = "https://mail.google.com/mail/u/0/#all/\(id)"
        return try Self.output([.init(id: "gmail:\(id)", title: subject, location: location, excerpt: String(body.prefix(20000)))])
    }

    /// Args: payload는 Gmail MIME 파트, mimeType은 찾을 본문 형식이다.
    /// Returns: 해당 형식의 첫 번째 텍스트 본문 또는 없음.
    /// Raises: 없음.
    private static func gmailBody(_ payload: [String: JSONValue], mimeType: String) -> String? {
        if payload["mimeType"]?.stringValue == mimeType, let encoded = payload["body"]?.objectValue?["data"]?.stringValue {
            let base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
            if let data = Data(base64Encoded: padded) {
                let text = String(decoding: data, as: UTF8.self)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
        }
        for part in payload["parts"]?.arrayValue ?? [] {
            if let body = gmailBody(part.objectValue ?? [:], mimeType: mimeType) { return body }
        }
        return nil
    }

    /// Args: query는 Google Drive 파일 이름 검색어이다.
    /// Returns: 관련 파일의 제목·링크·설명.
    /// Raises: 연결·Drive API 오류.
    func driveSearch(_ query: String, onlyReadable: Bool = false) async throws -> ChatToolOutput {
        var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let escaped = String(query.prefix(200)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var filters = ["trashed = false"]
        if !escaped.isEmpty { filters.append("name contains '\(escaped)'") }
        if onlyReadable {
            filters.append("(mimeType = 'application/vnd.google-apps.document' or mimeType = 'application/vnd.google-apps.spreadsheet' or mimeType contains 'text/')")
        }
        url.queryItems = [URLQueryItem(name: "q", value: filters.joined(separator: " and ")),
                          URLQueryItem(name: "fields", value: "files(id,name,mimeType,webViewLink,description),nextPageToken"),
                          URLQueryItem(name: "pageSize", value: onlyReadable ? "1" : "20")]
        let response = try await Self.json(connectorRequest("drive", url.url!)).objectValue ?? [:]
        let files: [JSONValue] = response["files"]?.arrayValue ?? []
        var sources: [ChatSource] = []
        for item in files {
            let file = item.objectValue ?? [:]
            guard let id = file["id"]?.stringValue else { continue }
            let title = file["name"]?.stringValue ?? "Drive 파일"
            let location = file["webViewLink"]?.stringValue ?? "https://drive.google.com/open?id=\(id)"
            let excerpt = file["description"]?.stringValue ?? file["mimeType"]?.stringValue ?? ""
            sources.append(.init(id: "drive:\(id)", title: title, location: location, excerpt: excerpt))
        }
        return try Self.output(sources)
    }

    /// Args: reference는 Drive 검색 결과의 파일 ID 또는 출처 ID이다.
    /// Returns: Google 문서·시트·슬라이드, PDF 또는 텍스트 파일 원문.
    /// Raises: 연결·형식·Drive API 오류.
    func driveRead(_ reference: String) async throws -> ChatToolOutput {
        let id = reference.hasPrefix("drive:") ? String(reference.dropFirst(6)) : reference
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ChatToolError.unavailable("Drive 파일 ID가 올바르지 않습니다.") }
        let metadataURL = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?fields=id,name,mimeType,webViewLink")!
        let file = try await Self.json(connectorRequest("drive", metadataURL)).objectValue ?? [:]
        let mime = file["mimeType"]?.stringValue ?? ""
        let url: URL
        if mime == "application/vnd.google-apps.document" || mime == "application/vnd.google-apps.presentation" {
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=text%2Fplain")!
        } else if mime == "application/vnd.google-apps.spreadsheet" {
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)/export?mimeType=text%2Fcsv")!
        } else if mime.hasPrefix("text/") || mime == "application/json" || mime == "application/pdf" {
            url = URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!
        } else { throw ChatToolError.unavailable("현재 문서·시트·슬라이드·PDF·텍스트 파일을 읽을 수 있습니다.") }
        let request = try await connectorRequest("drive", url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 5_000_000 else { throw ChatToolError.unavailable("Drive 파일을 읽지 못했거나 크기가 너무 큽니다.") }
        let content: String
        if mime == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw ChatToolError.unavailable("PDF 텍스트를 추출하지 못했습니다.") }
            content = (0..<min(document.pageCount, 10)).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n")
        } else { content = String(decoding: data, as: UTF8.self) }
        let note = mime == "application/vnd.google-apps.spreadsheet" ? "(첫 번째 시트만 포함)\n" : ""
        return try Self.output([.init(id: "drive:\(id)", title: file["name"]?.stringValue ?? "Drive 파일", location: file["webViewLink"]?.stringValue ?? "https://drive.google.com/open?id=\(id)", excerpt: note + String(content.prefix(20000)))])
    }

    /// Args: query는 Notion 페이지 제목 검색어이다.
    /// Returns: 관련 페이지의 제목·링크.
    /// Raises: 연결·Notion API 오류.
    func notionSearch(_ query: String, onlyPages: Bool = false) async throws -> ChatToolOutput {
        var request = try await connectorRequest("notion", URL(string: "https://api.notion.com/v1/search")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var fields: [String: JSONValue] = ["page_size": .number(onlyPages ? 1 : 20)]
        if !query.isEmpty { fields["query"] = .string(String(query.prefix(200))) }
        if onlyPages { fields["filter"] = .object(["property": .string("object"), "value": .string("page")]) }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(fields))
        let response = try await Self.json(request).objectValue ?? [:]
        let sources = (response["results"]?.arrayValue ?? []).compactMap { item -> ChatSource? in
            let page = item.objectValue ?? [:]
            guard let id = page["id"]?.stringValue else { return nil }
            let properties = page["properties"]?.objectValue ?? [:]
            let title = properties.values.compactMap { $0.objectValue?["title"]?.arrayValue?.first?.objectValue?["plain_text"]?.stringValue }.first
                ?? page["title"]?.arrayValue?.first?.objectValue?["plain_text"]?.stringValue ?? "Notion 페이지"
            return .init(id: "notion:\(id)", title: title, location: page["url"]?.stringValue ?? "https://www.notion.so/\(id)", excerpt: page["last_edited_time"]?.stringValue ?? "")
        }
        return try Self.output(sources)
    }

    /// Args: reference는 Notion 검색 결과의 페이지 ID 또는 출처 ID이다.
    /// Returns: 페이지의 상위 100개 블록 원문.
    /// Raises: 연결·Notion API 오류.
    func notionRead(_ reference: String) async throws -> ChatToolOutput {
        let id = reference.hasPrefix("notion:") ? String(reference.dropFirst(7)) : reference
        guard UUID(uuidString: id) != nil else { throw ChatToolError.unavailable("Notion 페이지 ID가 올바르지 않습니다.") }
        let page = try await Self.json(connectorRequest("notion", URL(string: "https://api.notion.com/v1/pages/\(id)")!)).objectValue ?? [:]
        let blocks = try await Self.json(connectorRequest("notion", URL(string: "https://api.notion.com/v1/blocks/\(id)/children?page_size=100")!)).objectValue ?? [:]
        let lines = (blocks["results"]?.arrayValue ?? []).map { item -> String in
            let block = item.objectValue ?? [:]
            let type = block["type"]?.stringValue ?? ""
            let value = block[type]?.objectValue ?? [:]
            let text = (value["rich_text"]?.arrayValue ?? []).compactMap { $0.objectValue?["plain_text"]?.stringValue }.joined()
            return text.isEmpty ? (value["title"]?.stringValue ?? "") : text
        }.filter { !$0.isEmpty }.joined(separator: "\n")
        let location = page["url"]?.stringValue ?? "https://www.notion.so/\(id)"
        let suffix = blocks["has_more"]?.boolValue == true ? "\n(하위 블록은 더 있지만 첫 100개만 읽었습니다.)" : ""
        return try Self.output([.init(id: "notion:\(id)", title: "Notion 페이지", location: location, excerpt: String(lines.prefix(20000)) + suffix)])
    }
}
