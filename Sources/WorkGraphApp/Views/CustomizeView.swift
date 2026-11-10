import SwiftUI

/// 맞춤 설정 탭의 구역 (왼쪽 목록의 커넥터, 스킬)
enum CustomizeSection: String, CaseIterable, Identifiable {
    case connectors = "커넥터", skills = "스킬"
    var id: String { rawValue }
}

/// 커넥터 탭: 왼쪽에 맞춤 설정 목록(커넥터, 스킬, 설치됨), 오른쪽에 고른 구역 (Figma CH-13)
struct CustomizeView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedID: String?
    @State private var connected: Set<String> = []

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 261).frame(maxHeight: .infinity).background(Brand.paper)
            Rectangle().fill(Brand.line).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { connected = Set(ConnectorEntry.all.filter { (try? ConnectorAuth.isConnected($0.id)) == true }.map(\.id)) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("맞춤 설정").font(Brand.suit(20, .bold)).foregroundStyle(Brand.ink).padding(.leading, 22).padding(.top, 18).padding(.bottom, 16)
            ForEach(CustomizeSection.allCases) { section in
                let on = state.customizeSection == section
                Button { state.customizeSection = section; selectedID = nil } label: {
                    HStack(spacing: 10) {
                        SVGIcon(d: section == .connectors ? RailIcon.connectors : RailIcon.skill)
                            .stroke(Brand.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)).frame(width: 14, height: 14)
                        Text(section.rawValue).font(Brand.suit(13)).foregroundStyle(Brand.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color(hex: 0xEAE5DF) : .clear))
                    .hoverHighlight(cornerRadius: 7, active: !on)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 2)
            }
            Text("설치됨").font(Brand.suit(12)).foregroundStyle(Brand.gray).padding(.leading, 22).padding(.top, 18).padding(.bottom, 6)
            let installed = ConnectorEntry.all.filter { connected.contains($0.id) }
            if installed.isEmpty {
                Text("설치한 커넥터가 없어요").font(Brand.suit(13)).foregroundStyle(Brand.ink).padding(.leading, 22).padding(.top, 4)
            } else {
                ForEach(installed) { connector in
                    Button { state.customizeSection = .connectors; selectedID = connector.id } label: {
                        HStack(spacing: 9) {
                            ConnectorLogo(connector: connector, size: 16, boxed: false)
                            Text(connector.name).font(Brand.suit(12)).foregroundStyle(Brand.ink).lineLimit(1)
                        }
                        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .hoverHighlight(cornerRadius: 7).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.horizontal, 12)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var content: some View {
        switch state.customizeSection {
        case .connectors:
            ConnectorCatalogView(onUseInChat: useInChat, selectedID: $selectedID, connected: $connected)
        case .skills:
            if let chat = state.chat { SkillCatalogView(chat: chat, onStart: startSkill) } else { Color.white }
        }
    }

    /// 커넥터를 켠 새 대화로 간다 (질문은 입력칸에 채워 둔다)
    private func useInChat(_ id: String, _ example: String) {
        guard let chat = state.chat else { return }
        chat.newConversation()
        if id == "github" { chat.current.scope.useGitHub = true } else { chat.current.scope.connectors.append(id) }
        chat.saveScope()
        chat.draft = example
        state.selectedTab = .chat
    }

    /// 그 스킬을 켠 새 대화로 간다
    private func startSkill(_ id: String) {
        guard let chat = state.chat else { return }
        chat.newConversation()
        chat.selectSkill(id)
        state.selectedTab = .chat
    }
}
