import SwiftUI
import SillogCore

/// The steps an answer took, folded into one line: what it is doing while it runs, "n steps · time" when done.
/// Opening it lists each tool call with what it looked at, and each result can be opened in turn.
struct ChatWorkLog: View {
    let message: ConversationMessage
    @Binding var isExpanded: Bool
    @State var openResults: Set<String> = []

    private var running: Bool { message.status == "running" }
    private var steps: [ChatStep] { message.trace ?? message.steps.map { ChatStep(title: $0, status: .done) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.small) }
                    Text(summary).font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
                    if !steps.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(steps.isEmpty)
            if isExpanded && !steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(step, last: index == steps.count - 1)
                    }
                }.padding(.leading, 2)
            }
        }
    }

    private var summary: String {
        if running { return steps.last.map { ChatRunner.displayTitle($0.title) } ?? tr("답변을 준비하고 있습니다") }
        guard message.trace != nil, let first = steps.first?.startedAt else { return tr("작업 \(steps.count)단계") }
        let end = steps.compactMap(\.endedAt).max() ?? first
        return tr("작업 \(steps.count)단계 · \(Self.duration(end - first))")
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        return total < 60 ? tr("\(total)초") : tr("\(total / 60)분 \(total % 60)초")
    }

    private func row(_ step: ChatStep, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                icon(step).frame(width: 14, height: 16)
                if !last { Rectangle().fill(Brand.line).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(ChatRunner.displayTitle(step.title)).font(Brand.font(.caption)).foregroundStyle(step.status == .failed ? Brand.ink : Brand.tabText)
                if !step.detail.isEmpty {
                    Text(step.detail).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(2).textSelection(.enabled)
                }
                if !step.result.isEmpty {
                    let open = openResults.contains(step.id)
                    Button(open ? tr("결과 접기") : tr("결과 보기")) {
                        if open { openResults.remove(step.id) } else { openResults.insert(step.id) }
                    }.buttonStyle(.plain).font(Brand.font(.tag)).foregroundStyle(Brand.gray).underline()
                    if open {
                        Text(step.result).font(.system(size: 11, design: .monospaced)).foregroundStyle(Brand.tabText).lineLimit(10)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(ChatPalette.soft, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.line))
                    }
                }
            }.padding(.bottom, last ? 0 : 12)
            Spacer(minLength: 0)
        }.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func icon(_ step: ChatStep) -> some View {
        switch step.status {
        case .running where running: ProgressView().controlSize(.mini)
        case .running: Image(systemName: "minus.circle").font(.system(size: 11)).foregroundStyle(Brand.gray)
        case .done: Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Brand.gray)
        case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Brand.ink)
        }
    }
}
