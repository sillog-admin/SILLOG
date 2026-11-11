import SwiftUI
import SillogCore

/// 채팅 모델 칩: 누르면 그 자리에서 채팅 모델을 고른다 (설정의 "채팅" 연결과 같은 값).
/// ChatGPT 연결이면 확인된 모델 목록, 직접 연결한 서버면 지금 모델만 보이고, 맨 아래 "모델 설정…" 은 설정 탭으로 간다.
struct ChatModelMenu: View {
    @EnvironmentObject private var state: AppState
    let name: String
    var fontSize: CGFloat = 10
    let openSettings: () -> Void

    /// 메뉴 항목: 목록에 없는 지금 모델은 맨 위에 "(확인되지 않음)" 으로 남긴다 (설정 화면과 같은 규칙)
    static func options(models: [CodexModel], current: String) -> [(slug: String, title: String)] {
        let unverified: [(slug: String, title: String)] = current.isEmpty || models.contains { $0.slug == current } ? [] : [(current, "\(current) (확인되지 않음)")]
        return unverified + models.map { ($0.slug, $0.displayName) }
    }

    var body: some View {
        Menu {
            if state.settings.effectiveChatProvider == "codex" {
                if state.chatCodexModels.isEmpty {
                    Text(state.codexModelsLoading ? "모델 목록을 불러오는 중…" : state.chatCodexModelsError ?? "확인된 모델 목록이 아직 없어요")
                }
                Picker("채팅 모델", selection: Binding(get: { state.settings.effectiveChatCodexModel }, set: { state.selectChatModel($0) })) {
                    ForEach(Self.options(models: state.chatCodexModels, current: state.settings.effectiveChatCodexModel), id: \.slug) { option in
                        Text(option.title).tag(option.slug)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                Text("\(name) (직접 연결한 서버)")
            }
            Divider()
            Button("모델 설정…", action: openSettings)
        } label: {
            // borderlessButton 메뉴는 라벨을 시스템 버튼(화살표 왼쪽, 시스템 색)으로 바꿔 그린다. plain 버튼 메뉴로 이 모양 그대로 그린다
            HStack(spacing: 4) {
                Text(name).font(Brand.suit(fontSize)).foregroundStyle(Brand.tabText).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(Brand.tabText)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("채팅 모델 바꾸기")
    }
}
