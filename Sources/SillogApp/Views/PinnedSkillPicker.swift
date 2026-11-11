import SwiftUI
import SillogCore

/// 고정할 버튼과 대화에 적용할 스킬은 별도로 선택한다.
struct PinnedSkillPicker: View {
    @ObservedObject var chat: ChatState
    var onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("채팅에 표시할 스킬")).font(Brand.suit(12, .semibold))
                Spacer()
                Text("\(chat.pinnedSkillIDs.count)/6").font(Brand.suit(11)).foregroundStyle(Brand.gray)
            }.padding(.horizontal, 8)
            Text(tr("최대 6개까지 표시할 수 있어요.")).font(Brand.suit(10)).foregroundStyle(Brand.gray).padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(chat.skills) { skill in
                        let pinned = chat.pinnedSkillIDs.contains(skill.id)
                        Button { chat.togglePinnedSkill(skill.id) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: pinned ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(pinned ? Brand.accent : Brand.gray)
                                Text(skill.displayTitle).font(Brand.suit(12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).hoverHighlight(cornerRadius: 6)
                        .disabled(!pinned && chat.pinnedSkillIDs.count == 6)
                        .accessibilityLabel("\(skill.displayTitle) \(pinned ? tr("표시 해제") : tr("표시"))")
                    }
                }
            }.frame(height: CGFloat(min(chat.skills.count, 8)) * 32)
            Divider()
            Button(action: onManage) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text(tr("스킬 관리")).font(Brand.suit(12))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }.padding(.horizontal, 8).frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).hoverHighlight(cornerRadius: 6)
        }.padding(12).frame(width: 264).foregroundStyle(Brand.tabText)
    }
}
