import XCTest
@testable import WorkGraphCore

enum TestJWT {
    /// 서명 없는 테스트용 JWT (헤더.페이로드.서명 자리만 맞춘다).
    static func make(_ claims: [String: Any]) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = b64(Data(#"{"alg":"none"}"#.utf8))
        let payload = b64(try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))   // 키 순서 고정
        return "\(header).\(payload).sig"
    }

    static func tokens(exp: Double, refresh: String = "r1", access: String? = nil, lastRefresh: Double = 0) -> CodexTokens {
        let auth: [String: Any] = ["chatgpt_account_id": "acct_123", "chatgpt_plan_type": "plus"]
        let id = make(["email": "me@example.com", "https://api.openai.com/auth": auth])
        let accessToken = access ?? make(["exp": exp, "https://api.openai.com/auth": auth])
        return CodexTokens(idToken: id, accessToken: accessToken, refreshToken: refresh, lastRefresh: lastRefresh)
    }
}

final class CodexAuthTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wg-codex-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> CodexAuthStore { CodexAuthStore(fileURL: directory.appendingPathComponent("codex-auth.json")) }

    private func makeOAuth() -> CodexOAuthClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return CodexOAuthClient(session: URLSession(configuration: config))
    }

    func testTokensExposeClaims() {
        let tokens = TestJWT.tokens(exp: 2_000)
        XCTAssertEqual(tokens.accountId, "acct_123")
        XCTAssertEqual(tokens.email, "me@example.com")
        XCTAssertEqual(tokens.planType, "plus")
        XCTAssertEqual(tokens.accessTokenExpiry, 2_000)
        XCTAssertNil(CodexTokens(idToken: "garbage", accessToken: "x", refreshToken: "r", lastRefresh: 0).accountId)
    }

    func testStoreRoundTripIsPrivateToTheUser() throws {
        let store = makeStore()
        XCTAssertNil(store.load())
        let tokens = TestJWT.tokens(exp: 2_000)
        try store.save(tokens)
        XCTAssertEqual(store.load(), tokens)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try store.clear()
        XCTAssertNil(store.load())
    }

    func testDeviceLoginPollsUntilApprovedThenExchangesCode() async throws {
        let id = TestJWT.make(["email": "me@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": "acct_9"]])
        StubURLProtocol.reset([
            .init(status: 200, body: #"{"device_auth_id":"dev_1","user_code":"ABCD-1234","interval":"2"}"#),
            .init(status: 403, body: #"{"error":"authorization_pending"}"#),
            .init(status: 404, body: "{}"),
            .init(status: 200, body: #"{"authorization_code":"code_1","code_challenge":"ch","code_verifier":"ver_1"}"#),
            .init(status: 200, body: #"{"id_token":"\#(id)","access_token":"acc_1","refresh_token":"ref_1"}"#),
        ])
        let oauth = makeOAuth()
        let code = try await oauth.requestDeviceCode(now: 100)
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(code.interval, 2)

        var slept: [Double] = []
        let tokens = try await oauth.waitForTokens(code, now: { 100 }, sleep: { slept.append($0) })
        XCTAssertEqual(slept, [2, 2])
        XCTAssertEqual(tokens.accessToken, "acc_1")
        XCTAssertEqual(tokens.refreshToken, "ref_1")
        XCTAssertEqual(tokens.accountId, "acct_9")

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.map(\.url.path), ["/api/accounts/deviceauth/usercode", "/api/accounts/deviceauth/token",
                                                  "/api/accounts/deviceauth/token", "/api/accounts/deviceauth/token", "/oauth/token"])
        XCTAssertEqual(requests[0].body["client_id"] as? String, CodexOAuthClient.clientId)
        XCTAssertEqual(requests[1].body["device_auth_id"] as? String, "dev_1")
        let form = StubURLProtocol.rawBodies.last ?? ""
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("code=code_1"))
        XCTAssertTrue(form.contains("code_verifier=ver_1"))
        XCTAssertTrue(form.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"))
    }

    func testDeviceLoginReportsWhenNotEnabledAndWhenTimedOut() async {
        StubURLProtocol.reset([.init(status: 404, body: "not found")])
        do { _ = try await makeOAuth().requestDeviceCode(now: 0); XCTFail("에러가 나야 함") }
        catch { XCTAssertEqual(error as? CodexAuthError, .deviceLoginNotEnabled) }

        StubURLProtocol.reset([.init(status: 403, body: "{}"), .init(status: 403, body: "{}")])
        let code = DeviceCode(verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "X", deviceAuthId: "d",
                              interval: 5, expiresAt: 900)
        let clock = TestClock(0)
        do {
            _ = try await makeOAuth().waitForTokens(code, now: { clock.now }, sleep: { _ in clock.now += 600 })
            XCTFail("에러가 나야 함")
        } catch { XCTAssertEqual(error as? CodexAuthError, .timedOut) }
    }

    func testFreshTokenIsUsedWithoutAnyNetworkCall() async throws {
        StubURLProtocol.reset([])
        let store = makeStore()
        try store.save(TestJWT.tokens(exp: 10_000, lastRefresh: 900))
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 1_000 })
        let credentials = try await manager.credentials()
        XCTAssertEqual(credentials.accountId, "acct_123")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        let status = await manager.status()
        XCTAssertEqual(status, .loggedIn(email: "me@example.com", plan: "plus", expiresAt: 10_000))
    }

    func testExpiringTokenIsRefreshedAndRotatedTokenIsPersisted() async throws {
        let newAccess = TestJWT.make(["exp": 99_999.0])
        StubURLProtocol.reset([.init(status: 200, body: #"{"access_token":"\#(newAccess)","refresh_token":"r2"}"#)])
        let store = makeStore()
        try store.save(TestJWT.tokens(exp: 1_100, refresh: "r1", lastRefresh: 900))          // 100초 뒤 만료 → 갱신 대상
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 1_000 })

        async let first = manager.credentials()
        async let second = manager.credentials()                                              // 동시에 불러도 갱신은 한 번
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.accessToken), [newAccess, newAccess])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests[0].body["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(StubURLProtocol.requests[0].body["refresh_token"] as? String, "r1")

        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.refreshToken, "r2")                                              // 회전된 토큰을 바로 저장
        XCTAssertEqual(saved.accessToken, newAccess)
        XCTAssertEqual(saved.lastRefresh, 1_000)
        XCTAssertEqual(saved.email, "me@example.com")                                         // id_token 이 안 오면 기존 것 유지
    }

    func testTokenRefreshedByAnotherProcessIsReusedInsteadOfRefreshingAgain() async throws {
        StubURLProtocol.reset([])
        let store = makeStore()
        try store.save(TestJWT.tokens(exp: 1_100, refresh: "r1", lastRefresh: 900))
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 1_000 })
        _ = await manager.status()                                                            // 메모리에 r1 을 들고 있는 상태
        try store.save(TestJWT.tokens(exp: 50_000, refresh: "r2", lastRefresh: 999))          // 그 사이 다른 프로세스가 갱신
        let credentials = try await manager.credentials()
        XCTAssertEqual(TestJWT.tokens(exp: 50_000).accessToken, credentials.accessToken)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "이미 쓴 refresh token 을 다시 보내면 세션 전체가 무효가 된다")
    }

    func testRevokedRefreshTokenAsksForLoginAgain() async throws {
        StubURLProtocol.reset([.init(status: 400, body: #"{"error":{"code":"refresh_token_reused","message":"already used"}}"#)])
        let store = makeStore()
        try store.save(TestJWT.tokens(exp: 1_100, lastRefresh: 900))
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 1_000 })
        do { _ = try await manager.credentials(); XCTFail("에러가 나야 함") }
        catch let error as CodexAuthError {
            guard case .reloginRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(store.load(), "쓸 수 없는 토큰은 지워서 로그아웃 상태로 만든다")
        let status = await manager.status()
        XCTAssertEqual(status, .loggedOut)
    }

    func testRevokedTokenOn401ClearsLoginToo() async throws {
        // 서버가 요청을 401 로 거부 → 갱신 시도 → 갱신도 거부(token_revoked) → 로그아웃 상태
        StubURLProtocol.reset([.init(status: 401, body: #"{"error":{"code":"refresh_token_invalidated","message":"revoked"}}"#)])
        let store = makeStore()
        try store.save(TestJWT.tokens(exp: 90_000, lastRefresh: 900))
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 1_000 })
        let current = try await manager.credentials()
        do { _ = try await manager.refreshAfterRejection(of: current.accessToken); XCTFail("에러가 나야 함") }
        catch let error as CodexAuthError { guard case .reloginRequired = error else { return XCTFail("\(error)") } }
        let status = await manager.status()
        XCTAssertEqual(status, .loggedOut)
    }

    func testLoggedOutStateAndLogout() async throws {
        let store = makeStore()
        let manager = CodexAuthManager(store: store, oauth: makeOAuth(), clock: { 0 })
        let before = await manager.status()
        XCTAssertEqual(before, .loggedOut)
        do { _ = try await manager.credentials(); XCTFail("에러가 나야 함") } catch { XCTAssertEqual(error as? CodexAuthError, .notLoggedIn) }
        try store.save(TestJWT.tokens(exp: 10_000))
        let during = await manager.status()
        XCTAssertNotEqual(during, .loggedOut)
        try await manager.logout()
        let after = await manager.status()
        XCTAssertEqual(after, .loggedOut)
        XCTAssertNil(store.load())
    }

    func testDeviceLoginDisabledMessageMatchesLoginErrorScreen() {
        // Figma OUT-W1 의 오류 상자 문구
        XCTAssertEqual(CodexAuthError.deviceLoginNotEnabled.description,
                       "이 계정은 기기 코드 로그인이 꺼져 있어요. ChatGPT 설정의 보안 항목에서 켜 주세요.")
    }
}
