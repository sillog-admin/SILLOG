import AppKit
import SwiftUI
import SillogCore

/// Settings section that registers SILLOG's MCP server in the ChatGPT and Claude desktop apps.
struct MCPConnectSection: View {
    @EnvironmentObject private var state: AppState
    @State private var connected: Set<MCPRegistry.Client> = []
    @State private var notes: [String: String] = [:]

    /// make-app.sh puts sillogctl next to the app's executable; swift build does the same in its bin folder.
    private var registry: MCPRegistry {
        MCPRegistry(command: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("sillogctl").path ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(tr("MCP로 다른 AI 앱에 연결"))
            Text(tr("ChatGPT나 Claude 데스크톱 앱에서 SILLOG 기록을 바탕으로 질문할 수 있어요."))
                .font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.horizontal, 4).padding(.bottom, 4)
            SettingTiles {
                row(.chatGPT, "ChatGPT", detail: tr("데스크톱 앱의 Work·Codex에서 사용"), logo: "codex")
                row(.claude, "Claude", detail: tr("데스크톱 앱에서 사용"), logo: "claude")
                SettingTile(tr("다른 앱"), detail: tr("Cursor처럼 MCP를 지원하는 앱에 직접 등록"), icon: "square.grid.2x2", notes: note("other")) {
                    Button(tr("설정 복사")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(registry.snippet, forType: .string)
                        notes["other"] = tr("복사했어요. 그 앱의 MCP 설정에 붙여 넣어 주세요.")
                    }
                    .buttonStyle(BrandButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("· " + tr("'프로젝트 전용 메모리'로 둔 프로젝트의 기록은 보내지 않아요."))
                Text("· " + tr("웹과 휴대폰 앱에서는 아직 쓸 수 없어요."))
            }
            .font(Brand.font(.caption)).foregroundStyle(Brand.gray).padding(.horizontal, 4).padding(.top, 10)
        }
        .onAppear(perform: refresh)
        // The other apps can change their config while SILLOG is in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func row(_ client: MCPRegistry.Client, _ title: String, detail: String, logo: String) -> some View {
        SettingTile(title, detail: detail, logo: logo, notes: note(client.rawValue)) {
            if connected.contains(client) {
                Label(tr("연결됨"), systemImage: "checkmark.circle.fill").font(Brand.font(.caption, .semibold)).foregroundStyle(ActivityLogView.okColor)
                Button(tr("해제")) { change(client, title, connect: false) }.buttonStyle(BrandButtonStyle())
            } else {
                Button(tr("연결하기")) { change(client, title, connect: true) }.buttonStyle(BrandButtonStyle(kind: .primary))
            }
        }
    }

    private func note(_ key: String) -> [String] { notes[key].map { [$0] } ?? [] }

    private func change(_ client: MCPRegistry.Client, _ title: String, connect: Bool) {
        if let id = client.closeFirstBundleID, !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
            notes[client.rawValue] = tr("\(title) 앱을 종료한 뒤 다시 눌러 주세요. 켜져 있으면 \(title) 앱이 설정을 덮어써요.")
            return
        }
        do {
            try connect ? registry.connect(client) : registry.disconnect(client)
            // Both apps read their MCP list only at launch.
            notes[client.rawValue] = tr("\(title) 앱을 다시 열면 적용돼요.")
        } catch {
            notes[client.rawValue] = error.localizedDescription
        }
        refresh()
    }

    /// Previews and UI tests must not read the real config files in the home folder.
    private func refresh() {
        guard !state.isPreview else { return }
        connected = Set(MCPRegistry.Client.allCases.filter(registry.isConnected))
    }
}
