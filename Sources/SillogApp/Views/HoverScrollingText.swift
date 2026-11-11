import SwiftUI

/// 한 줄을 넘는 제목은 호버할 때 끝까지 흘려 보여주고, 벗어나면 처음으로 돌아온다.
struct HoverScrollingText: View {
    let text: String
    var rowHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var textWidth: CGFloat = 0

    private var singleLine: String { text.replacingOccurrences(of: "\n", with: " ") }

    var body: some View {
        Text(singleLine).lineLimit(1).hidden()
            .overlay(alignment: .leading) {
                GeometryReader { viewport in
                    let overflow = max(0, textWidth - viewport.size.width)
                    let scrolling = (hovered || rowHovered) && !reduceMotion && overflow > 0
                    Text(singleLine).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { content in
                                Color.clear
                                    .onAppear { textWidth = content.size.width }
                                    .onChange(of: content.size.width) { _, width in textWidth = width }
                            }
                        }
                        .offset(x: scrolling ? -overflow : 0)
                        .animation(scrolling ? .linear(duration: max(1, overflow / 30)).delay(0.4) : .linear(duration: 0),
                                   value: scrolling)
                        .frame(height: viewport.size.height, alignment: .leading)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .help(reduceMotion ? text : "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}
