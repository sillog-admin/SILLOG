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
            throw ChatToolError.unavailable(tr("웹 페이지를 읽지 못했거나 크기가 너무 큽니다."))
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
        guard !token.isEmpty else { throw ChatToolError.unavailable(tr("\(id) 커넥터를 설정에서 연결하세요.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if id == "notion" { request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version") }
        return request
    }

    /// Args: query는 Google Drive 파일 이름 검색어이다.
    /// Returns: 관련 파일의 제목·링크·설명.
    /// Raises: 연결·Drive API 오류.
    func driveSearch(_ query: String, onlyReadable: Bool = false) async throws -> ChatToolOutput {
        // drive.file reaches every file picked in any chat, so the chat tool lists only this chat's picks; the connector check lists any.
        if !onlyReadable {
            let term = query.trimmingCharacters(in: .whitespaces)
            return try Self.output(scope.driveFiles.filter { term.isEmpty || $0.name.localizedCaseInsensitiveContains(term) }
                .map { ChatSource(id: "drive:\($0.id)", title: $0.name, location: $0.url, excerpt: $0.mimeType) })
        }
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

    /// Args: reference is a Drive file ID or source ID; anyPicked lets the connector check read a file outside this chat's picks.
    /// Returns: the text of a Google Doc, Sheet or Slides file, a PDF or a text file.
    /// Raises: a file not picked for this chat, connection, format or Drive API errors.
    func driveRead(_ reference: String, anyPicked: Bool = false) async throws -> ChatToolOutput {
        let id = reference.hasPrefix("drive:") ? String(reference.dropFirst(6)) : reference
        guard id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ChatToolError.unavailable(tr("Drive 파일 ID가 올바르지 않습니다.")) }
        guard anyPicked || scope.driveFiles.contains(where: { $0.id == id }) else {
            throw ChatToolError.unavailable("이 대화에서 고른 Drive 파일만 읽을 수 있습니다. + 메뉴의 'Google Drive에서 선택'으로 추가하라고 안내하세요.")
        }
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
        } else { throw ChatToolError.unavailable(tr("현재 문서·시트·슬라이드·PDF·텍스트 파일을 읽을 수 있습니다.")) }
        let request = try await connectorRequest("drive", url)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 5_000_000 else { throw ChatToolError.unavailable(tr("Drive 파일을 읽지 못했거나 크기가 너무 큽니다.")) }
        let content: String
        if mime == "application/pdf" {
            guard let document = PDFDocument(data: data) else { throw ChatToolError.unavailable(tr("PDF 텍스트를 추출하지 못했습니다.")) }
            content = (0..<min(document.pageCount, 10)).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n")
        } else { content = String(decoding: data, as: UTF8.self) }
        let note = mime == "application/vnd.google-apps.spreadsheet" ? tr("(첫 번째 시트만 포함)\n") : ""
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
        guard UUID(uuidString: id) != nil else { throw ChatToolError.unavailable(tr("Notion 페이지 ID가 올바르지 않습니다.")) }
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
        let suffix = blocks["has_more"]?.boolValue == true ? tr("\n(하위 블록은 더 있지만 첫 100개만 읽었습니다.)") : ""
        return try Self.output([.init(id: "notion:\(id)", title: "Notion 페이지", location: location, excerpt: String(lines.prefix(20000)) + suffix)])
    }
}
