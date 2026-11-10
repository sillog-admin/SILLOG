import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import WorkGraphCore

struct ConnectorToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
    var resource: String? = nil
    var canvaClient: CanvaOAuthClient? = nil
    var oauthClient: ConnectorOAuthClient? = nil
    var remoteMCP: Bool? = nil
}

struct ConnectorOAuthClient: Codable {
    let id: String
    let tokenEndpoint: String
}

struct CanvaOAuthClient: Codable {
    let id: String
    let secret: String
}

// 기존 계정 연결을 유지하기 위해 Keychain 저장 키의 plugin- 접두사는 그대로 사용한다.
enum ConnectorAuth {
    static let callback = "http://127.0.0.1:8765/callback"
    private static let refreshes = ConnectorRefreshes()
    private static let tokenChanges = NSLock()

    /// Args: id는 연결할 커넥터 ID이다.
    /// Returns: 이 빌드에 해당 서비스의 OAuth 앱 정보가 준비되어 있으면 true.
    /// Raises: Keychain 접근 오류.
    static func isAvailable(_ id: String) throws -> Bool {
        switch id {
        case "gmail", "drive", "gcal": return try !configuration("google-client", environment: "WORKGRAPH_GOOGLE_CLIENT_ID").isEmpty
        case "github": return try !configuration("github-client", environment: "WORKGRAPH_GITHUB_CLIENT_ID").isEmpty
        case "notion", "higgsfield", "lovable": return true
        case "slack": return try !configuration("slack-client", environment: "WORKGRAPH_SLACK_CLIENT_ID").isEmpty
        default: return ExternalReadConnector(rawValue: id) != nil
        }
    }

    /// Args: key는 이전 Keychain 설정 이름, environment는 배포 환경 변수 이름이다.
    /// Returns: 앱 제공자가 설정한 OAuth 앱 정보. 이전 빌드에서 저장한 값도 읽는다.
    /// Raises: Keychain 접근 오류.
    static func configuration(_ key: String, environment: String) throws -> String {
        if let value = ProcessInfo.processInfo.environment[environment], !value.isEmpty { return value }
        if let value = Bundle.main.object(forInfoDictionaryKey: environment) as? String, !value.isEmpty { return value }
        return try ChatSecrets.load("plugin-\(key)")
    }

    /// Args: id는 gmail·drive·github·notion 중 하나이다.
    /// Returns: Keychain에 연결된 계정이 있으면 true.
    /// Raises: Keychain 접근 오류.
    static func isConnected(_ id: String) throws -> Bool { try !ChatSecrets.load("plugin-\(id)").isEmpty }

    static func connectExternal(_ connector: ExternalReadConnector, token: String, resource: String) async throws {
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        try await connector.verify(token: credential, resource: resource)
        try save(.init(accessToken: credential, refreshToken: nil, expiresAt: nil, resource: resource), id: connector.id)
    }

    static func resource(_ id: String) throws -> String {
        let value = try ChatSecrets.load("plugin-\(id)")
        return (try? JSONDecoder().decode(ConnectorToken.self, from: Data(value.utf8)))?.resource ?? ""
    }

    static func remoteIDs() throws -> Set<String> {
        Set(try RemoteReadConnector.allCases.filter {
            let saved = try ChatSecrets.load("plugin-\($0.rawValue)")
            return (try? JSONDecoder().decode(ConnectorToken.self, from: Data(saved.utf8)))?.remoteMCP == true
        }.map(\.rawValue))
    }

    static func connectRemote(_ connector: RemoteReadConnector) async throws {
        let metadata = try await response(URLRequest(url: connector.metadataURL))
        guard let authorize = metadata["authorization_endpoint"] as? String,
              let endpoint = metadata["token_endpoint"] as? String,
              let register = metadata["registration_endpoint"] as? String,
              (metadata["code_challenge_methods_supported"] as? [String])?.contains("S256") == true,
              (metadata["token_endpoint_auth_methods_supported"] as? [String])?.contains("none") == true else {
            throw ChatToolError.unavailable("이 서비스에서 데스크톱 로그인을 지원하지 않습니다.")
        }
        let authURL = try connector.trustedAuthURL(authorize)
        let tokenURL = try connector.trustedAuthURL(endpoint)
        let registrationURL = try connector.trustedAuthURL(register)
        let account = "connector-oauth-client-\(connector.rawValue)"
        var clientID = try ChatSecrets.load(account)
        if clientID.isEmpty {
            var registration = URLRequest(url: registrationURL)
            registration.httpMethod = "POST"; registration.timeoutInterval = 30
            registration.setValue("application/json", forHTTPHeaderField: "Content-Type")
            registration.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_name": "Sillog", "redirect_uris": [callback],
                "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
                "token_endpoint_auth_method": "none", "scope": connector.scopes
            ])
            let registered = try await response(registration)
            guard let value = registered["client_id"] as? String, !value.isEmpty else {
                throw ChatToolError.unavailable("커넥터 로그인 정보를 등록하지 못했습니다.")
            }
            clientID = value
            try ChatSecrets.save(value, account: account)
        }
        let verifier = randomURLSafe(32), state = randomURLSafe(32)
        var auth = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        auth.queryItems = ["client_id": clientID, "redirect_uri": callback, "response_type": "code",
                           "scope": connector.scopes, "resource": connector.resource, "state": state,
                           "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded(),
                           "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let code = try await LoopbackOAuth.receive(auth: auth.url!, state: state)
        var token = try await exchange(formRequest(tokenURL, ["grant_type": "authorization_code", "client_id": clientID,
            "code": code, "redirect_uri": callback, "code_verifier": verifier, "resource": connector.resource]))
        _ = try await RemoteReadSession(connector, token: token.accessToken).tools()
        token.oauthClient = .init(id: clientID, tokenEndpoint: endpoint)
        token.remoteMCP = true
        try save(token, id: connector.rawValue)
    }

    static func connectSlack() async throws {
        let clientID = try configuration("slack-client", environment: "WORKGRAPH_SLACK_CLIENT_ID")
        guard !clientID.isEmpty else { throw ChatToolError.unavailable("앱 제공자가 Slack 연결 정보를 등록해야 합니다.") }
        let redirect = SlackOAuth.callback
        let verifier = randomURLSafe(32), state = randomURLSafe(32)
        var auth = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        auth.queryItems = ["client_id": clientID, "redirect_uri": redirect, "user_scope": "search:read", "scope": "", "state": state,
                           "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded(),
                           "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let code = try await SlackOAuth.receive(auth: auth.url!, state: state)
        let endpoint = "https://slack.com/api/oauth.v2.access"
        var token = try await slackExchange(formRequest(URL(string: endpoint)!, ["client_id": clientID, "code": code,
            "redirect_uri": redirect, "code_verifier": verifier]))
        try await ExternalReadConnector.slack.verify(token: token.accessToken, resource: "")
        token.oauthClient = .init(id: clientID, tokenEndpoint: endpoint)
        try save(token, id: "slack")
    }

    private static func slackExchange(_ request: URLRequest, oldRefresh: String? = nil) async throws -> ConnectorToken {
        let result = try await response(request)
        let user = result["authed_user"] as? [String: Any] ?? result
        guard result["ok"] as? Bool == true, let access = user["access_token"] as? String,
              (user["scope"] as? String ?? "").split(separator: ",").contains("search:read") else {
            throw ChatToolError.unavailable("Slack 검색 권한을 승인하지 못했습니다: \(result["error"] as? String ?? "search:read 필요")")
        }
        var value = token(from: user, accessToken: access)
        value.refreshToken = value.refreshToken ?? oldRefresh
        return value
    }

    /// Args: id는 연결한 커넥터 이름이다.
    /// Returns: 유효한 OAuth 액세스 토큰.
    /// Raises: 미연결·갱신·Keychain·네트워크 오류.
    static func accessToken(_ id: String) async throws -> String {
        try await refreshes.token(id)
    }

    fileprivate static func loadOrRefreshToken(_ id: String) async throws -> String {
        let saved = try ChatSecrets.load("plugin-\(id)")
        guard let data = saved.data(using: .utf8), var token = try? JSONDecoder().decode(ConnectorToken.self, from: data) else {
            throw ChatToolError.unavailable("채팅의 커넥터에서 \(id)을 연결하세요.")
        }
        if let expiresAt = token.expiresAt, expiresAt < Date().timeIntervalSince1970 + 60 {
            guard let refresh = token.refreshToken else { throw ChatToolError.unavailable("\(id) 커넥터를 다시 연결하세요.") }
            var fields = ["grant_type": "refresh_token", "refresh_token": refresh]
            var request: URLRequest
            if let client = token.oauthClient {
                fields["client_id"] = client.id
                let endpoint: URL
                if token.remoteMCP == true, let connector = RemoteReadConnector(rawValue: id) {
                    endpoint = try connector.trustedAuthURL(client.tokenEndpoint)
                    fields["resource"] = connector.resource
                } else if id == "slack", client.tokenEndpoint == "https://slack.com/api/oauth.v2.access" {
                    endpoint = URL(string: client.tokenEndpoint)!
                } else { throw ChatToolError.unavailable("커넥터 인증 설정을 확인할 수 없습니다. 다시 연결하세요.") }
                request = formRequest(endpoint, fields)
            } else if id == "canva", let client = token.canvaClient {
                request = canvaTokenRequest(client, fields)
            } else if googleIDs.contains(id) {
                fields["client_id"] = try configuration("google-client", environment: "WORKGRAPH_GOOGLE_CLIENT_ID")
                fields["client_secret"] = googleSecretField()["client_secret"]
                request = formRequest(URL(string: "https://oauth2.googleapis.com/token")!, fields)
            } else if id == "github" {
                fields["client_id"] = try configuration("github-client", environment: "WORKGRAPH_GITHUB_CLIENT_ID")
                // Sillog의 디바이스 인증으로 발급한 토큰은 비밀키 없이 갱신할 수 있다.
                request = formRequest(URL(string: "https://github.com/login/oauth/access_token")!, fields)
            } else if id == "notion" {
                request = jsonRequest(URL(string: "https://api.notion.com/v1/oauth/token")!, fields)
                request.setValue(try notionBasicAuth(), forHTTPHeaderField: "Authorization")
            } else {
                throw ChatToolError.unavailable("\(id) 커넥터를 다시 연결하세요.")
            }
            var updated = try await id == "slack" ? slackExchange(request, oldRefresh: refresh) : exchange(request, oldRefresh: refresh)
            updated.resource = token.resource
            updated.canvaClient = token.canvaClient
            updated.oauthClient = token.oauthClient
            updated.remoteMCP = token.remoteMCP
            try save(updated, id: id, replacing: saved)
            token = updated
        }
        return token.accessToken
    }

    /// Args: id는 연결 해제할 커넥터이다.
    /// Returns: 없음. 로컬 OAuth 토큰만 제거한다.
    /// Raises: Keychain 오류.
    static func disconnect(_ id: String) throws {
        try tokenChanges.withLock { try ChatSecrets.save("", account: "plugin-\(id)") }
    }

    /// Args: ids는 사용자가 설치할 Google 커넥터 ID 목록, clientID는 데스크톱 OAuth 클라이언트 ID이다.
    /// Returns: 없음. 한 번의 브라우저 승인으로 선택한 커넥터의 토큰을 저장한다.
    /// Raises: OAuth 거절·콜백·토큰 교환 오류.
    static func connectGoogle(_ ids: Set<String>, clientID: String) async throws {
        let scopes = googleScopes(ids)
        let verifier = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafe(16)
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = ["client_id": clientID, "redirect_uri": callback, "response_type": "code", "scope": scopes.joined(separator: " "),
                           "code_challenge": challenge, "code_challenge_method": "S256", "state": state,
                           "access_type": "offline", "prompt": "consent"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let code = try await LoopbackOAuth.receive(auth: auth.url!, state: state)
        let request = formRequest(URL(string: "https://oauth2.googleapis.com/token")!,
                                  googleSecretField().merging(["client_id": clientID, "code": code, "code_verifier": verifier,
                                                               "redirect_uri": callback, "grant_type": "authorization_code"]) { $1 })
        let token = try await exchange(request)
        for id in ids { try save(token, id: id) }
    }

    /// 구글 로그인을 쓰는 커넥터: Gmail·Drive(채팅), 캘린더(gcal, 캘린더 탭)
    static let googleIDs: Set<String> = ["gmail", "drive", "gcal"]

    /// Args: ids는 연결할 구글 커넥터 ID이다.
    /// Returns: 요청할 권한. 캘린더는 캘린더 목록 읽기와 일정 읽기·쓰기만.
    /// Raises: 없음.
    static func googleScopes(_ ids: Set<String>) -> [String] {
        ids.sorted().flatMap { id -> [String] in
            switch id {
            case "gmail": ["https://www.googleapis.com/auth/gmail.readonly"]
            case "drive": ["https://www.googleapis.com/auth/drive.readonly"]
            case "gcal": ["https://www.googleapis.com/auth/calendar.calendarlist.readonly", "https://www.googleapis.com/auth/calendar.events"]
            default: []
            }
        }
    }

    /// 구글 '데스크톱 앱' 클라이언트는 토큰을 바꿀 때 클라이언트 시크릿도 요구한다 (비밀은 아니다). 빌드에 넣었으면 같이 보낸다
    private static func googleSecretField() -> [String: String] {
        let secret = (try? configuration("google-secret", environment: "WORKGRAPH_GOOGLE_CLIENT_SECRET")) ?? ""
        return secret.isEmpty ? [:] : ["client_secret": secret]
    }

    static func connectCanva(clientID: String, clientSecret: String) async throws {
        let client = CanvaOAuthClient(id: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                      secret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        let verifier = randomURLSafe(32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafe(16)
        var auth = URLComponents(string: "https://www.canva.com/api/oauth/authorize")!
        auth.queryItems = ["client_id": client.id, "redirect_uri": callback, "response_type": "code",
                           "scope": "design:meta:read", "code_challenge": challenge,
                           "code_challenge_method": "S256", "state": state].map { URLQueryItem(name: $0.key, value: $0.value) }
        let code = try await LoopbackOAuth.receive(auth: auth.url!, state: state)
        let request = canvaTokenRequest(client, ["grant_type": "authorization_code", "code": code,
                                                 "redirect_uri": callback, "code_verifier": verifier])
        var token = try await exchange(request)
        try await ExternalReadConnector.canva.verify(token: token.accessToken, resource: "")
        token.canvaClient = client
        try save(token, id: "canva")
    }

    private static func canvaTokenRequest(_ client: CanvaOAuthClient, _ body: [String: String]) -> URLRequest {
        var request = formRequest(URL(string: "https://api.canva.com/rest/v1/oauth/token")!, body)
        request.setValue("Basic " + Data("\(client.id):\(client.secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }

    /// Args: clientID는 읽기 권한을 등록하고 디바이스 흐름을 켠 GitHub App의 ID, onCode는 승인 코드 표시 함수이다.
    /// Returns: 없음. 사용자가 브라우저에서 승인하면 토큰을 저장한다.
    /// Raises: 승인 거절·기한 초과·네트워크 오류.
    static func connectGitHub(clientID: String, onCode: @escaping @MainActor (String) -> Void) async throws {
        let deviceRequest = formRequest(URL(string: "https://github.com/login/device/code")!, ["client_id": clientID])
        let device = try await response(deviceRequest)
        guard let code = device["device_code"] as? String, let userCode = device["user_code"] as? String,
              let verification = device["verification_uri"] as? String, let url = URL(string: verification) else {
            throw ChatToolError.unavailable("GitHub 승인 코드를 받지 못했습니다.")
        }
        await onCode(userCode)
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        var interval = max(5, device["interval"] as? Int ?? 5)
        let deadline = Date().addingTimeInterval(Double(device["expires_in"] as? Int ?? 900))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            let request = formRequest(URL(string: "https://github.com/login/oauth/access_token")!,
                                      ["client_id": clientID, "device_code": code, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let result = try await response(request)
            if let value = result["access_token"] as? String {
                try save(token(from: result, accessToken: value), id: "github")
                return
            }
            switch result["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw ChatToolError.unavailable(result["error_description"] as? String ?? "GitHub 승인이 완료되지 않았습니다.")
            }
        }
        throw ChatToolError.unavailable("GitHub 승인 시간이 지났습니다. 다시 연결하세요.")
    }

    /// Args: request는 공급자 토큰 요청, oldRefresh는 갱신 응답에 refresh_token이 없을 때 유지할 기존 토큰이다.
    /// Returns: 교환된 OAuth 토큰.
    /// Raises: HTTP·서비스 오류.
    private static func exchange(_ request: URLRequest, oldRefresh: String? = nil) async throws -> ConnectorToken {
        let result = try await response(request)
        guard let value = result["access_token"] as? String else {
            throw ChatToolError.unavailable(result["error_description"] as? String ?? "커넥터 인증에 실패했습니다.")
        }
        var token = token(from: result, accessToken: value)
        token.refreshToken = token.refreshToken ?? oldRefresh
        return token
    }

    /// Args: result는 공급자 토큰 응답, accessToken은 필수 액세스 토큰이다.
    /// Returns: 만료 정보가 포함된 저장용 토큰.
    /// Raises: 없음.
    private static func token(from result: [String: Any], accessToken: String) -> ConnectorToken {
        let seconds = result["expires_in"] as? Double ?? (result["expires_in"] as? Int).map(Double.init)
        return .init(accessToken: accessToken, refreshToken: result["refresh_token"] as? String,
                     expiresAt: seconds.map { Date().timeIntervalSince1970 + $0 })
    }

    /// Args: token은 OAuth 토큰, id는 서비스 이름이다.
    /// Returns: 없음. 토큰을 Keychain에 저장한다.
    /// Raises: 인코딩·Keychain 오류.
    private static func save(_ token: ConnectorToken, id: String, replacing previous: String? = nil) throws {
        let data = try JSONEncoder().encode(token)
        let account = "plugin-\(id)"
        try tokenChanges.withLock {
            if let previous, try ChatSecrets.load(account) != previous {
                throw ChatToolError.unavailable("\(id) 연결이 바뀌었습니다. 다시 시도하세요.")
            }
            try ChatSecrets.save(String(decoding: data, as: UTF8.self), account: account)
        }
    }

    /// Args: url·fields는 폼 방식 OAuth 요청 정보이다.
    /// Returns: JSON 응답을 받도록 설정한 POST 요청.
    /// Raises: 없음.
    private static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return request
    }

    /// Args: url은 Notion OAuth 토큰 주소, fields는 JSON 본문 값이다.
    /// Returns: JSON 방식 토큰 교환 요청.
    /// Raises: 없음.
    private static func jsonRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(fields)
        return request
    }

    /// Args: request는 고정된 OAuth 서비스 주소의 요청이다.
    /// Returns: 서비스의 JSON 객체.
    /// Raises: HTTP·네트워크·JSON 오류.
    private static func response(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("Sillog/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw ChatToolError.unavailable(json["error_description"] as? String ?? "커넥터 인증 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return json
    }

    /// Args: 없음.
    /// Returns: Notion 클라이언트 ID·비밀키의 HTTP Basic 헤더.
    /// Raises: Keychain 오류.
    private static func notionBasicAuth() throws -> String {
        let id = try configuration("notion-client", environment: "WORKGRAPH_NOTION_CLIENT_ID")
        let secret = try configuration("notion-secret", environment: "WORKGRAPH_NOTION_CLIENT_SECRET")
        return "Basic " + Data("\(id):\(secret)".utf8).base64EncodedString()
    }

    /// Args: count는 난수 바이트 수이다.
    /// Returns: URL-safe OAuth state 또는 PKCE verifier.
    /// Raises: 없음.
    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }
}

private actor ConnectorRefreshes {
    private var pending: [String: Task<String, Error>] = [:]

    func token(_ id: String) async throws -> String {
        if let task = pending[id] { return try await task.value }
        let task = Task { try await ConnectorAuth.loadOrRefreshToken(id) }
        pending[id] = task
        defer { pending[id] = nil }
        return try await task.value
    }
}

private extension Data {
    /// Args: 없음.
    /// Returns: 패딩 없는 URL-safe Base64 문자열.
    /// Raises: 없음.
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LoopbackOAuth {
    /// Args: auth는 브라우저 승인 URL, state는 CSRF 방지 난수이다.
    /// Returns: 승인 후 로컬 콜백으로 받은 코드.
    /// Raises: 포트 사용 중·승인 거절·상태 불일치.
    static func receive(auth: URL, state: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let server = socket(AF_INET, SOCK_STREAM, 0)
            guard server >= 0 else { throw ChatToolError.unavailable("OAuth 콜백을 시작하지 못했습니다.") }
            defer { close(server) }
            var reuse: Int32 = 1
            _ = setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(8765).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(server, 1) == 0 else { throw ChatToolError.unavailable("OAuth 콜백 포트 8765를 열 수 없습니다.") }
            await MainActor.run { _ = NSWorkspace.shared.open(auth) }
            var ready = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 600_000) > 0 else { throw ChatToolError.unavailable("OAuth 승인 시간이 지났습니다. 다시 연결하세요.") }
            let connection = accept(server, nil, nil)
            guard connection >= 0 else { throw ChatToolError.unavailable("OAuth 콜백을 받지 못했습니다.") }
            defer { close(connection) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = recv(connection, &buffer, buffer.count, 0)
            let line = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let values = URLComponents(string: "http://127.0.0.1\(path)")?.queryItems ?? []
            let receivedState = values.first { $0.name == "state" }?.value
            let code = values.first { $0.name == "code" }?.value
            let accepted = line.hasPrefix("GET ") && path.hasPrefix("/callback?") && receivedState == state && !(code ?? "").isEmpty
                && values.filter({ $0.name == "state" }).count == 1 && values.filter({ $0.name == "code" }).count == 1
                && !values.contains(where: { $0.name == "error" })
            let html = accepted ? "<h2>승인을 받았습니다. 연결 결과는 SILLOG 앱에서 확인하세요.</h2>" : "<h2>승인이 완료되지 않았습니다. SILLOG에서 다시 시도하세요.</h2>"
            let body = Data(html.utf8)
            let header = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let reply = Data(header.utf8) + body
            _ = reply.withUnsafeBytes { send(connection, $0.baseAddress, reply.count, 0) }
            guard accepted, let code else { throw ChatToolError.unavailable("OAuth 승인 또는 상태 확인에 실패했습니다.") }
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            return code
        }.value
    }
}
