import SwiftUI
import SillogCore

/// 계정 동그라미를 누르면 뜨는 상자: 이름과 이메일, 로그아웃, 그 아래 연결 방식, 모델, 사용량
struct AccountPopover: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var logoutHover = false

    private var email: String? { if case .loggedIn(let email, _, _) = state.codexStatus { return email }; return nil }
    private var loggedIn: Bool { if case .loggedIn = state.codexStatus { return true }; return false }
    private var name: String { email.map { String($0.split(separator: "@").first ?? "") } ?? "" }   // 계정에 이름이 없어 이메일 @ 앞부분

    private static func providerLabel(_ provider: String) -> String { AppSettings.providerName(provider) }

    /// 정리와 채팅이 같은 방식이면 하나, 다르면 둘 다
    private var connection: String {
        let s = state.settings
        return s.llmProvider == s.effectiveChatProvider
            ? Self.providerLabel(s.llmProvider)
            : tr("정리 \(Self.providerLabel(s.llmProvider)), 채팅 \(Self.providerLabel(s.effectiveChatProvider))")
    }
    private var cleanupModel: String { state.settings.llmUsesAPI ? state.settings.llmEndpoint.model : state.settings.codexModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if loggedIn { signedIn } else { signedOut }
        }
        .padding(16).frame(width: 280).background(Color.white)
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(String((email ?? "?").prefix(2)).uppercased()).font(Brand.suit(11, .semibold)).foregroundStyle(Brand.badgeText)
                    .frame(width: 30, height: 30).background(Circle().fill(Brand.badgeFill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Brand.suit(13, .semibold)).foregroundStyle(Brand.ink).lineLimit(1)
                    Text(email ?? "").font(Brand.suit(11)).foregroundStyle(Brand.gray).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button { dismiss(); state.logoutCodex() } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 16))
                        .foregroundStyle(logoutHover ? Brand.ink : Brand.gray).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { logoutHover = $0 }.accessibilityLabel(tr("로그아웃"))
            }
            Rectangle().fill(Brand.hairline).frame(height: 1)
            VStack(spacing: 10) {
                row(tr("연결 방식"), connection)
                row(tr("채팅 모델"), state.settings.chatModelName)
                row(tr("정리 모델"), cleanupModel)
                if let usage = state.codexUsage, !windows(usage).isEmpty {
                    row(tr("사용량"), windows(usage).map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: "  "))
                }
            }
        }
    }

    private func windows(_ usage: CodexUsage) -> [CodexUsage.Window] { [usage.primary, usage.secondary].compactMap { $0 } }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Brand.suit(11)).foregroundStyle(Brand.gray)
            Spacer(minLength: 8)
            Text(value).font(Brand.suit(12)).foregroundStyle(Brand.ink).multilineTextAlignment(.trailing)
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("로그인되지 않음")).font(Brand.suit(13, .semibold)).foregroundStyle(Brand.ink)
            Button { dismiss(); state.settingsSection = .ai; state.selectedTab = .settings } label: {
                Text(tr("설정에서 연결")).font(Brand.suit(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 30).background(Capsule().fill(Brand.accent))
            }
            .buttonStyle(.plain)
        }
    }
}
