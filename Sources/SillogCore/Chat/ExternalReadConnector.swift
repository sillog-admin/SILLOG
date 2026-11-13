import Foundation

/// 외부 계정의 자료를 검색하고 읽는 도구. 채팅에서 선택한 서비스만 노출한다.
public enum ExternalReadConnector: String, CaseIterable, Identifiable, Sendable {
    case figma, slack, discord, higgsfield, canva, lovable

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .figma: "Figma"
        case .slack: "Slack"
        case .discord: "Discord"
        case .higgsfield: "Higgsfield"
        case .canva: "Canva"
        case .lovable: "Lovable"
        }
    }

    var specs: [ToolSpec] {
        let searchable: String
        let readable: String
        switch self {
        case .figma: (searchable, readable) = ("지정한 폴더의 디자인 파일 이름", "파일의 화면·레이어 이름과 텍스트")
        case .slack: (searchable, readable) = ("메시지 본문과 원문 링크", "")
        case .discord: (searchable, readable) = ("지정한 채널의 최근 100개 메시지 본문", "메시지 본문")
        case .higgsfield: (searchable, readable) = ("등록한 API 요청의 ID 또는 상태", "API 요청 상태와 결과 파일 종류")
        case .canva: (searchable, readable) = ("디자인 제목", "디자인 제목·종류·페이지 수와 수정 시각")
        case .lovable: (searchable, readable) = ("지정한 워크스페이스의 프로젝트 이름과 설명", "프로젝트 설명과 공개 상태")
        }
        let search = ChatTools.spec("\(id)_search", "\(name)에서 \(searchable)을 찾아 채팅의 참고 자료로 사용한다.",
                                    ["query": "검색에 필요한 짧은 검색어. 비밀 값이나 대화 전체를 넣지 않는다."])
        guard !readable.isEmpty else { return [search] }
        return [search, ChatTools.spec("\(id)_read", "\(name)에서 \(readable)을 읽는다.", ["id": "검색 결과의 ID"])]
    }

    public func verify(token: String, resource: String) async throws {
        _ = try await sources(query: self == .slack ? "after:2000-01-01" : "", token: token, resource: resource, limit: 1)
    }

    func sources(query: String = "", reference: String? = nil, token: String, resource: String, limit: Int = 10) async throws -> [ChatSource] {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(250))
        let reference = try reference.map { value in
            let prefix = "\(id):"
            return try identifier(value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value)
        }
        switch self {
        case .figma:
            let folder = try identifier(resource)
            let list = try await get("https://api.figma.com/v2/folders/\(folder)/files", token: token)
            let files = list["files"]?.arrayValue ?? []
            if let reference {
                guard files.contains(where: { $0.objectValue?["key"]?.stringValue == reference }) else {
                    throw ChatToolError.unavailable(tr("지정한 Figma 폴더에 있는 파일만 읽을 수 있습니다."))
                }
                let file = try await get("https://api.figma.com/v1/files/\(reference)", ["depth": "5"], token: token)
                var text: [String] = []
                Self.figmaText(file["document"], into: &text)
                return [source(reference, title: file["name"]?.stringValue, location: "https://www.figma.com/file/\(reference)",
                               excerpt: text.joined(separator: "\n"))]
            }
            return Array(files.compactMap { value -> ChatSource? in
                guard let file = value.objectValue, let key = file["key"]?.stringValue,
                      let title = file["name"]?.stringValue, Self.matches(title, term) else { return nil }
                return source(key, title: title, location: "https://www.figma.com/file/\(key)", excerpt: file["last_modified"]?.stringValue ?? "")
            }.prefix(limit))
        case .slack:
            let response = try await get("https://slack.com/api/search.messages",
                                         ["query": term.isEmpty ? "after:2000-01-01" : term, "count": "\(limit)"], token: token)
            guard response["ok"] == .bool(true) else {
                if ["token_expired", "token_revoked", "invalid_auth"].contains(response["error"]?.stringValue) {
                    throw ChatToolError.unavailable(tr("Slack 로그인이 만료됐어요. 커넥터에서 다시 연결해 주세요."))
                }
                throw ChatToolError.unavailable(tr("Slack 검색에 실패했습니다. 사용자 토큰에 search:read 권한이 있는지 확인하세요."))
            }
            return (response["messages"]?.objectValue?["matches"]?.arrayValue ?? []).compactMap { value in
                guard let message = value.objectValue, let body = message["text"]?.stringValue,
                      let url = message["permalink"]?.stringValue, URL(string: url)?.scheme == "https" else { return nil }
                let channel = message["channel"]?.objectValue?["name"]?.stringValue ?? "메시지"
                return source(url, title: "Slack · \(channel)", location: url, excerpt: body)
            }
        case .discord:
            let channel = try identifier(resource)
            let url = "https://discord.com/api/v10/channels/\(channel)"
            let details = try await get(url, token: token)
            let guild = details["guild_id"]?.stringValue ?? "@me"
            if let reference {
                let message = try await get("\(url)/messages/\(reference)", token: token)
                return discordMessage(message, channel: channel, guild: guild).map { [$0] } ?? []
            }
            let messages = try await json("\(url)/messages", ["limit": limit == 1 ? "3" : "100"], token: token).arrayValue ?? []
            let found = messages.compactMap { discordMessage($0.objectValue ?? [:], channel: channel, guild: guild) }
            if !messages.isEmpty && found.allSatisfy({ $0.excerpt.isEmpty }) {
                throw ChatToolError.unavailable(tr("Discord 메시지 본문을 읽을 수 없습니다. 봇의 Message Content 권한을 확인하세요."))
            }
            return Array(found.filter { Self.matches($0.excerpt, term) }.prefix(limit))
        case .higgsfield:
            let registered = try resource.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { try identifier(String($0)) }
            guard (1...10).contains(registered.count), registered.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw ChatToolError.unavailable(tr("Higgsfield API 요청 ID를 1개에서 10개까지 입력하세요."))
            }
            if let reference, !registered.contains(reference) {
                throw ChatToolError.unavailable(tr("등록한 Higgsfield 요청만 읽을 수 있습니다."))
            }
            var matches: [ChatSource] = []
            for key in reference.map({ [$0] }) ?? registered {
                let job = try await get("https://api.higgsfield.ai/requests/\(key)/status", token: token)
                let status = job["status"]?.stringValue ?? ""
                guard Self.matches("\(key) \(status)", term) else { continue }
                let images = job["images"]?.arrayValue?.count ?? 0
                let video = job["video"]?.objectValue != nil
                let audio = job["audio"]?.objectValue != nil || !(job["audios"]?.arrayValue ?? []).isEmpty
                let excerpt = tr("상태 \(status) · 이미지 \(images)개\(video ? tr(" · 영상 있음") : "")\(audio ? tr(" · 오디오 있음") : "")")
                matches.append(source(key, title: "Higgsfield · \(key)", location: "https://open.higgsfield.ai", excerpt: excerpt))
                if matches.count == limit { break }
            }
            return matches
        case .canva:
            let url = "https://api.canva.com/rest/v1/designs"
            let rows: [JSONValue]
            if let reference {
                let design = try await get("\(url)/\(reference)", token: token)
                rows = design["design"].map { [$0] } ?? []
            } else {
                var parameters = ["limit": "\(limit)"]
                if !term.isEmpty { parameters["query"] = term }
                rows = try await get(url, parameters, token: token)["items"]?.arrayValue ?? []
            }
            return rows.compactMap { value in
                guard let design = value.objectValue, let key = design["id"]?.stringValue else { return nil }
                let types = design["design_types"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let format = types.isEmpty ? tr("디자인") : types.joined(separator: ", ")
                let pages = design["page_count"]?.doubleValue.flatMap(Int.init(exactly:)).map { tr("\($0)페이지") }
                let updated = design["updated_at"]?.doubleValue.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
                return source(key, title: design["title"]?.stringValue, location: "https://www.canva.com/design/\(key)/view",
                              excerpt: [format, pages, updated].compactMap { $0 }.joined(separator: " · "))
            }
        case .lovable:
            let url = "https://api.lovable.dev/v1/projects"
            let workspace = try identifier(resource)
            let rows: [JSONValue]
            if let reference {
                let project = try await json("\(url)/\(reference)", token: token)
                guard project.objectValue?["workspace_id"]?.stringValue == workspace else {
                    throw ChatToolError.unavailable(tr("연결한 Lovable 워크스페이스의 프로젝트만 읽을 수 있습니다."))
                }
                rows = [project]
            } else {
                var parameters = ["workspace_id": workspace, "limit": "\(limit)"]
                if !term.isEmpty { parameters["query"] = term }
                rows = try await get(url, parameters, token: token)["data"]?.arrayValue ?? []
            }
            return rows.compactMap { value in
                guard let project = value.objectValue, let key = project["id"]?.stringValue else { return nil }
                let status = project["is_published"] == .bool(true) ? tr("게시됨") : tr("게시 전")
                return source(key, title: project["name"]?.stringValue, location: "https://lovable.dev/projects/\(key)",
                              excerpt: [project["description"]?.stringValue, status, project["last_edited_at"]?.stringValue]
                                .compactMap { $0 }.joined(separator: "\n"))
            }
        }
    }

    private func source(_ key: String, title: String?, location: String, excerpt: String) -> ChatSource {
        .init(id: "\(id):\(key)", title: String((title ?? name).prefix(160)), location: location, excerpt: String(excerpt.prefix(12_000)))
    }

    private func discordMessage(_ message: [String: JSONValue], channel: String, guild: String) -> ChatSource? {
        guard let key = message["id"]?.stringValue else { return nil }
        let author = message["author"]?.objectValue
        let name = author?["global_name"]?.stringValue ?? author?["username"]?.stringValue ?? "메시지"
        let attachments = (message["attachments"]?.arrayValue ?? []).compactMap { $0.objectValue?["filename"]?.stringValue }
        let body = [message["content"]?.stringValue ?? "", attachments.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: "\n")
        return source(key, title: "Discord · \(name)", location: "https://discord.com/channels/\(guild)/\(channel)/\(key)", excerpt: body)
    }

    private static func figmaText(_ value: JSONValue?, into lines: inout [String]) {
        guard let node = value?.objectValue, lines.count < 250 else { return }
        if let text = node["characters"]?.stringValue ?? node["name"]?.stringValue, !text.isEmpty {
            lines.append(String(text.prefix(500)))
        }
        for child in node["children"]?.arrayValue ?? [] { figmaText(child, into: &lines) }
    }

    private static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    private func identifier(_ value: String) throws -> String {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw ChatToolError.unavailable(tr("\(name) 자료 ID를 확인하세요."))
        }
        return id
    }

    private func get(_ url: String, _ parameters: [String: String] = [:], token: String) async throws -> [String: JSONValue] {
        guard let object = try await json(url, parameters, token: token).objectValue else {
            throw ChatToolError.unavailable(tr("\(name) 응답을 읽을 수 없습니다."))
        }
        return object
    }

    private func json(_ url: String, _ parameters: [String: String] = [:], token: String) async throws -> JSONValue {
        guard !token.isEmpty, !token.contains(where: \.isNewline), var parts = URLComponents(string: url) else {
            throw ChatToolError.unavailable(tr("\(name) 연결 정보를 확인하세요."))
        }
        if !parameters.isEmpty {
            parts.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = parts.url else { throw ChatToolError.unavailable(tr("\(name) 요청 주소가 올바르지 않습니다.")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch self {
        case .figma: request.setValue(token, forHTTPHeaderField: "X-Figma-Token")
        case .discord: request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        case .higgsfield: request.setValue("Key \(token)", forHTTPHeaderField: "Authorization")
        case .lovable:
            request.setValue(token, forHTTPHeaderField: "Lovable-API-Key")
            request.setValue("2026-09-11", forHTTPHeaderField: "Lovable-Version")
        case .slack, .canva: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await ChatTools.json(request, delegate: ConnectorHTTP())
    }
}
