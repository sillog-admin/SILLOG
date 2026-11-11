import Foundation

public protocol CodexCredentialProviding: Sendable {
    /// 유효한 액세스 토큰. 만료가 가까우면 먼저 갱신한다.
    func credentials() async throws -> CodexCredentials
    /// 서버가 401 을 돌려줬을 때: 실패한 토큰을 알려주면 갱신한 새 토큰을 돌려준다.
    func refreshAfterRejection(of accessToken: String) async throws -> CodexCredentials
}

/// 로그인 상태와 토큰 갱신을 한곳에서 관리한다.
public actor CodexAuthManager: CodexCredentialProviding {
    /// 만료 5분 전이면 갱신, 마지막 갱신에서 8일이 지나도 갱신 (Codex CLI 와 같은 기준).
    static let refreshWindow: Double = 5 * 60
    static let maxTokenAge: Double = 8 * 86_400

    private let store: CodexAuthStore
    private let oauth: CodexOAuthClient
    private let clock: @Sendable () -> Double
    private var cached: CodexTokens?
    private var refreshing: Task<CodexTokens, Error>?

    public init(store: CodexAuthStore = CodexAuthStore(), oauth: CodexOAuthClient = CodexOAuthClient(),
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.store = store; self.oauth = oauth; self.clock = clock
    }

    public func status() -> CodexAuthStatus {
        cached = store.load() ?? cached.flatMap { _ in nil }
        guard let tokens = cached else { return .loggedOut }
        return .loggedIn(email: tokens.email, plan: tokens.planType, expiresAt: tokens.accessTokenExpiry)
    }

    // MARK: 로그인 · 로그아웃

    public func beginDeviceLogin() async throws -> DeviceCode {
        try await oauth.requestDeviceCode(now: clock())
    }

    /// 사용자가 브라우저에서 승인할 때까지 기다린다. Task 를 취소하면 .cancelled 로 끝난다.
    public func completeDeviceLogin(_ code: DeviceCode) async throws -> CodexAuthStatus {
        let tokens = try await oauth.waitForTokens(code, now: clock)
        try store.save(tokens)
        cached = tokens
        return status()
    }

    public func logout() throws {
        refreshing?.cancel()
        refreshing = nil
        cached = nil
        try store.clear()
    }

    // MARK: 토큰

    public func credentials() async throws -> CodexCredentials {
        guard var tokens = cached ?? store.load() else { throw CodexAuthError.notLoggedIn }
        cached = tokens
        if needsRefresh(tokens) { tokens = try await refresh(rejectedAccessToken: nil) }
        return CodexCredentials(accessToken: tokens.accessToken, accountId: tokens.accountId)
    }

    public func refreshAfterRejection(of accessToken: String) async throws -> CodexCredentials {
        let tokens = try await refresh(rejectedAccessToken: accessToken)
        return CodexCredentials(accessToken: tokens.accessToken, accountId: tokens.accountId)
    }

    private func needsRefresh(_ tokens: CodexTokens) -> Bool {
        let now = clock()
        if let expiry = tokens.accessTokenExpiry, expiry - now < Self.refreshWindow { return true }
        return tokens.lastRefresh > 0 && now - tokens.lastRefresh > Self.maxTokenAge
    }

    /// 동시에 여러 곳에서 불러도 갱신 요청은 한 번만 나간다. 다른 프로세스가 먼저 갱신했으면 그 결과를 쓴다.
    private func refresh(rejectedAccessToken: String?) async throws -> CodexTokens {
        if let refreshing { return try await refreshing.value }
        let store = self.store, oauth = self.oauth, clock = self.clock
        let held = cached
        let task = Task<CodexTokens, Error> {
            try await store.withExclusiveLock {
                guard let current = store.load() ?? held else { throw CodexAuthError.notLoggedIn }
                let now = clock()
                let expiringSoon = current.accessTokenExpiry.map { $0 - now < CodexAuthManager.refreshWindow } ?? false
                let tooOld = current.lastRefresh > 0 && now - current.lastRefresh > CodexAuthManager.maxTokenAge
                let changedOnDisk = current.refreshToken != held?.refreshToken
                let stillRejected = rejectedAccessToken.map { $0 == current.accessToken } ?? false
                // 파일의 토큰이 이미 새것이면 (다른 프로세스가 갱신함) 다시 갱신하지 않는다.
                if changedOnDisk, !expiringSoon, !tooOld, !stillRejected { return current }
                if !changedOnDisk, rejectedAccessToken == nil, !expiringSoon, !tooOld { return current }
                let updated = try await oauth.refresh(current, now: now)
                try store.save(updated)                         // 회전된 refresh token 을 쓰기 전에 먼저 저장
                return updated
            }
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let tokens = try await task.value
            cached = tokens
            return tokens
        } catch let error as CodexAuthError {
            if case .reloginRequired = error {           // 폐기·만료·재사용된 토큰: 들고 있어 봐야 소용없으니 지운다
                cached = nil
                try? store.clear()
            }
            throw error
        }
    }
}
