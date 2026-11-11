import Foundation

/// 기기 코드 로그인에서 사용자에게 보여줄 정보.
public struct DeviceCode: Equatable, Sendable {
    public let verificationURL: URL
    public let userCode: String
    let deviceAuthId: String
    public let interval: Double
    public let expiresAt: Double

    public init(verificationURL: URL, userCode: String, deviceAuthId: String, interval: Double, expiresAt: Double) {
        self.verificationURL = verificationURL; self.userCode = userCode; self.deviceAuthId = deviceAuthId
        self.interval = interval; self.expiresAt = expiresAt
    }
}

/// OpenAI 인증 서버와의 통신. 규격은 공개된 Codex CLI(codex-rs/login)와 같다.
///   1. POST /api/accounts/deviceauth/usercode  → 사용자 코드
///   2. 사용자가 /codex/device 에서 코드 입력
///   3. POST /api/accounts/deviceauth/token 을 승인될 때까지 반복 (403·404 = 아직)
///   4. POST /oauth/token 으로 인증 코드를 토큰으로 교환
public struct CodexOAuthClient: Sendable {
    public static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let defaultIssuer = URL(string: "https://auth.openai.com")!
    static let loginWindow: Double = 15 * 60

    let issuer: URL
    let session: URLSession

    public init(issuer: URL = CodexOAuthClient.defaultIssuer, session: URLSession = .shared) {
        self.issuer = issuer
        self.session = session
    }

    public func requestDeviceCode(now: Double = Date().timeIntervalSince1970) async throws -> DeviceCode {
        let (status, data) = try await postJSON("api/accounts/deviceauth/usercode", ["client_id": Self.clientId])
        if status == 404 { throw CodexAuthError.deviceLoginNotEnabled }
        guard (200..<300).contains(status) else { throw CodexAuthError.http(status, Self.preview(data)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthId = object["device_auth_id"] as? String,
              let userCode = (object["user_code"] ?? object["usercode"]) as? String else {
            throw CodexAuthError.invalidResponse(Self.preview(data))
        }
        // interval 은 문자열("5")로 온다. 숫자로 와도 받는다.
        let interval = (object["interval"] as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            ?? (object["interval"] as? NSNumber)?.doubleValue ?? 5
        return DeviceCode(verificationURL: issuer.appendingPathComponent("codex/device"), userCode: userCode,
                          deviceAuthId: deviceAuthId, interval: max(1, interval), expiresAt: now + Self.loginWindow)
    }

    /// 사용자가 브라우저에서 승인할 때까지 기다렸다가 토큰을 받아 온다.
    public func waitForTokens(_ code: DeviceCode,
                              now: @Sendable () -> Double = { Date().timeIntervalSince1970 },
                              sleep: (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async throws -> CodexTokens {
        while true {
            try Task.checkCancellation()
            let (status, data) = try await postJSON("api/accounts/deviceauth/token",
                                                    ["device_auth_id": code.deviceAuthId, "user_code": code.userCode])
            if (200..<300).contains(status) {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let authorizationCode = object["authorization_code"] as? String,
                      let verifier = object["code_verifier"] as? String else {
                    throw CodexAuthError.invalidResponse(Self.preview(data))
                }
                return try await exchange(authorizationCode: authorizationCode, codeVerifier: verifier,
                                          redirectURI: issuer.appendingPathComponent("deviceauth/callback").absoluteString, now: now())
            }
            guard status == 403 || status == 404 else { throw CodexAuthError.http(status, Self.preview(data)) }
            if now() >= code.expiresAt { throw CodexAuthError.timedOut }
            do { try await sleep(code.interval) } catch { throw CodexAuthError.cancelled }
            if now() >= code.expiresAt { throw CodexAuthError.timedOut }
        }
    }

    func exchange(authorizationCode: String, codeVerifier: String, redirectURI: String, now: Double) async throws -> CodexTokens {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: authorizationCode),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]
        let form = (components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F").replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: issuer.appendingPathComponent("oauth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(form.utf8)
        let (status, data) = try await send(request)
        guard (200..<300).contains(status) else { throw CodexAuthError.http(status, Self.preview(data)) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = object["id_token"] as? String, let accessToken = object["access_token"] as? String,
              let refreshToken = object["refresh_token"] as? String else {
            throw CodexAuthError.invalidResponse("토큰 응답에 필요한 값이 없음")
        }
        return CodexTokens(idToken: idToken, accessToken: accessToken, refreshToken: refreshToken, lastRefresh: now)
    }

    /// refresh token 으로 새 토큰을 받는다. 응답에 없는 값은 기존 것을 유지한다.
    public func refresh(_ tokens: CodexTokens, now: Double) async throws -> CodexTokens {
        let (status, data) = try await postJSON("oauth/token", ["client_id": Self.clientId, "grant_type": "refresh_token",
                                                                "refresh_token": tokens.refreshToken])
        guard (200..<300).contains(status) else {
            let body = Self.preview(data)
            let lower = body.lowercased()
            let permanent = status == 401 || lower.contains("invalid_grant")
                || ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains { lower.contains($0) }
            throw permanent ? CodexAuthError.reloginRequired(body) : CodexAuthError.http(status, body)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.invalidResponse(Self.preview(data))
        }
        var updated = tokens
        if let value = object["id_token"] as? String, !value.isEmpty { updated.idToken = value }
        if let value = object["access_token"] as? String, !value.isEmpty { updated.accessToken = value }
        if let value = object["refresh_token"] as? String, !value.isEmpty { updated.refreshToken = value }
        updated.lastRefresh = now
        return updated
    }

    // MARK: HTTP

    private func postJSON(_ path: String, _ body: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: issuer.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data) {
        do {
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch is CancellationError {
            throw CodexAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw CodexAuthError.cancelled
        } catch {
            throw CodexAuthError.transport(error.localizedDescription)
        }
    }

    /// 에러 본문에 토큰이 섞여 나오지 않도록 짧게 자른다.
    static func preview(_ data: Data) -> String {
        String((String(data: data, encoding: .utf8) ?? "").prefix(300))
    }
}
