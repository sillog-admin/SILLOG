import SwiftUI
import SillogCore

/// The steps an answer took, folded into one line: the current step and elapsed time while it runs, "n steps · time" when done.
/// Opening it lists each tool call with what it looked at, and each result can be opened in turn.
struct ChatWorkLog: View {
    let message: ConversationMessage
    @Binding var isExpanded: Bool
    @State var openResults: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool { message.status == "running" }
    private var steps: [ChatStep] { message.trace ?? message.steps.map { ChatStep(title: $0, status: .done) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isExpanded.toggle() } } label: {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { context in summaryText(at: context.date) }
                    } else {
                        summaryText(at: .now)
                    }
                    if !steps.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.gray)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize().disabled(steps.isEmpty)
            .accessibilityValue(isExpanded ? tr("펼침") : tr("접힘"))
            if isExpanded && !steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        row(step, last: index == steps.count - 1)
                    }
                }.padding(.leading, 2)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func summaryText(at now: Date) -> some View {
        Text(summary(at: now)).font(Brand.font(.caption)).foregroundStyle(Brand.gray).lineLimit(1)
    }

    private func summary(at now: Date) -> String {
        if running {
            let current = steps.last.map { ChatRunner.displayTitle($0.title) } ?? tr("답변을 준비하고 있습니다")
            return current + " · " + Self.duration(now.timeIntervalSince1970 - message.createdAt)
        }
        // Whole answer time, so writing after the last tool counts too.
        if let end = message.completedAt { return tr("작업 \(steps.count)단계 · \(Self.duration(end - message.createdAt))") }
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
                HStack(spacing: 6) {
                    Text(ChatRunner.displayTitle(step.title)).font(Brand.font(.caption)).foregroundStyle(step.status == .failed ? Brand.ink : Brand.tabText)
                    if step.status == .failed { Text(tr("실패")).font(Brand.font(.tag, .medium)).foregroundStyle(Brand.danger) }
                }
                if !step.detail.isEmpty {
                    Text(step.detail).font(Brand.font(.tag)).foregroundStyle(Brand.gray).lineLimit(2).textSelection(.enabled)
                }
                if !step.result.isEmpty {
                    let open = openResults.contains(step.id)
                    Button {
                        if open { openResults.remove(step.id) } else { openResults.insert(step.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(tr("결과")).font(Brand.font(.tag))
                            Image(systemName: "chevron.right").font(.system(size: 8)).rotationEffect(.degrees(open ? 90 : 0))
                        }.foregroundStyle(Brand.gray).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(open ? tr("펼침") : tr("접힘"))
                    if open {
                        Text(step.result).font(Brand.font(.caption)).lineSpacing(3).foregroundStyle(Brand.tabText).lineLimit(10)
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
        case .failed: Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Brand.danger)
        }
    }
}
