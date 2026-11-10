import AppKit
import Foundation
import WorkGraphCore

/// Slack 공개 배포에서 사용하는 설치형 PKCE 콜백.
@MainActor
enum SlackOAuth {
    nonisolated static let callback = "sillog://oauth/slack"
    private static var pending: (state: String, continuation: CheckedContinuation<String, Error>)?
    private static var timeout: Task<Void, Never>?

    static func receive(auth: URL, state: String) async throws -> String {
        guard pending == nil else { throw ChatToolError.unavailable("Slack 연결 승인이 이미 진행 중입니다.") }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (state, continuation)
                timeout = Task {
                    do { try await Task.sleep(nanoseconds: 600_000_000_000) }
                    catch { return }
                    guard pending?.state == state else { return }
                    finish(.failure(ChatToolError.unavailable("Slack 승인 시간이 지났습니다. 다시 연결하세요.")))
                }
                if !NSWorkspace.shared.open(auth) {
                    finish(.failure(ChatToolError.unavailable("Slack 로그인 화면을 열지 못했습니다.")))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard pending?.state == state else { return }
                finish(.failure(CancellationError()))
            }
        }
    }

    static func handle(_ url: URL) -> Bool {
        guard let state = pending?.state else { return false }
        do {
            guard let code = try authorizationCode(from: url, state: state) else { return false }
            finish(.success(code))
        } catch {
            finish(.failure(error))
        }
        return true
    }

    /// 다른 주소·세션의 콜백은 진행 중인 승인을 취소하지 않고 무시한다.
    static func authorizationCode(from url: URL, state: String) throws -> String? {
        guard url.scheme == "sillog", url.host == "oauth", url.path == "/slack",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == state else { return nil }
        if query.contains(where: { $0.name == "error" }) {
            throw ChatToolError.unavailable("Slack 연결 승인이 취소되었습니다. 다시 연결할 수 있어요.")
        }
        guard query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatToolError.unavailable("Slack 승인 응답을 확인하지 못했습니다. 다시 연결하세요.")
        }
        return code
    }

    private static func finish(_ result: Result<String, Error>) {
        guard let active = pending else { return }
        pending = nil
        timeout?.cancel()
        timeout = nil
        active.continuation.resume(with: result)
    }
}
