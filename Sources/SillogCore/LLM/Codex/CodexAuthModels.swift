import Foundation

/// ChatGPT(Codex) 로그인으로 받은 토큰 한 벌.
public struct CodexTokens: Codable, Equatable, Sendable {
    public var idToken: String
    public var accessToken: String
    public var refreshToken: String
    /// 마지막으로 발급·갱신된 시각 (Unix 초)
    public var lastRefresh: Double

    public init(idToken: String, accessToken: String, refreshToken: String, lastRefresh: Double) {
        self.idToken = idToken; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.lastRefresh = lastRefresh
    }

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token", accessToken = "access_token", refreshToken = "refresh_token", lastRefresh = "last_refresh"
    }

    static let authClaim = "https://api.openai.com/auth"

    /// 백엔드 호출에 붙이는 ChatGPT 계정 ID. id_token 에 없으면 access_token 에서 찾는다.
    public var accountId: String? {
        for token in [idToken, accessToken] {
            if let auth = JWT.claims(token)[Self.authClaim] as? [String: Any], let id = auth["chatgpt_account_id"] as? String { return id }
        }
        return nil
    }

    public var email: String? { JWT.claims(idToken)["email"] as? String }

    public var planType: String? {
        (JWT.claims(idToken)[Self.authClaim] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    public var accessTokenExpiry: Double? { (JWT.claims(accessToken)["exp"] as? NSNumber)?.doubleValue }
}

public struct CodexCredentials: Equatable, Sendable {
    public let accessToken: String
    public let accountId: String?

    public init(accessToken: String, accountId: String?) {
        self.accessToken = accessToken; self.accountId = accountId
    }
}

public enum CodexAuthStatus: Equatable, Sendable {
    case loggedOut
    case loggedIn(email: String?, plan: String?, expiresAt: Double?)
}

public enum CodexAuthError: Error, Equatable, CustomStringConvertible {
    case notLoggedIn
    case deviceLoginNotEnabled
    case timedOut
    case cancelled
    /// refresh token 이 만료·폐기·재사용됨. 다시 로그인해야 한다.
    case reloginRequired(String)
    case http(Int, String)
    case invalidResponse(String)
    case transport(String)

    public var description: String {
        switch self {
        case .notLoggedIn: return "ChatGPT 로그인이 필요합니다"
        case .deviceLoginNotEnabled: return "이 계정은 기기 코드 로그인이 꺼져 있어요. ChatGPT 설정의 보안 항목에서 켜 주세요."
        case .timedOut: return "15분 안에 승인되지 않아 로그인을 취소했습니다"
        case .cancelled: return "로그인을 취소했습니다"
        case .reloginRequired(let reason): return "로그인이 만료되어 다시 로그인해야 합니다 (\(reason))"
        case .http(let status, let body): return "인증 서버 오류 HTTP \(status): \(body)"
        case .invalidResponse(let text): return "인증 서버 응답을 해석하지 못했습니다: \(text)"
        case .transport(let message): return "인증 서버에 연결하지 못했습니다: \(message)"
        }
    }
}

/// 서명 검증 없이 클레임만 읽는다. 토큰의 진위는 서버가 판단하고, 앱은 만료 시각·계정 ID 표시에만 쓴다.
public enum JWT {
    public static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
