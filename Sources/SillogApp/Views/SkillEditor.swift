import SwiftUI
import UniformTypeIdentifiers
import SillogCore

struct SkillDraft: Identifiable {
    let id = UUID()
    var skillID: String?
    var title = ""
    var summary = ""
    var instructions = ""

    init() {}

    init(skill: ChatSkill) throws {
        skillID = skill.id
        title = skill.displayTitle
        summary = skill.displaySummary
        instructions = try skill.instructions()
    }

    var canSave: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 80 && summary.count <= 200
            && !instructions.isEmpty && instructions.count <= 12_000
    }

    static func read(_ url: URL) throws -> SkillDraft {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.isRegularFile == true, (file.fileSize ?? 0) <= 64_000,
              let body = try? String(contentsOf: url, encoding: .utf8), body.count <= 12_000,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatToolError.unavailable(tr("UTF-8 텍스트로 저장된 12,000자 이하의 스킬 파일을 선택하세요."))
        }
        let heading = body.split(separator: "\n").first { $0.hasPrefix("# ") }
        var draft = SkillDraft()
        draft.title = String((heading.map { String($0.dropFirst(2)) } ?? url.deletingPathExtension().lastPathComponent).prefix(80))
        draft.instructions = body
        return draft
    }
}

private struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SkillDraft
    var onSave: (SkillDraft) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.skillID == nil ? tr("새 스킬") : tr("스킬 수정")).font(Brand.font(.screenTitle))
            VStack(alignment: .leading, spacing: 8) {
                field(tr("이름"), placeholder: tr("스킬 이름"), text: $draft.title)
                field(tr("설명"), placeholder: tr("어떤 작업에 쓰는지 한 줄로 적어 주세요"), text: $draft.summary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("지침")).font(Brand.font(.body, .medium))
                Text(tr("채팅에서 이 스킬을 선택했을 때 따를 지침을 적으세요."))
                    .font(Brand.font(.caption)).foregroundStyle(Brand.gray)
                TextEditor(text: $draft.instructions)
                    .font(Brand.font(.body)).frame(minHeight: 170)
                    .padding(6).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Brand.line))
                    .accessibilityLabel(tr("스킬 지침"))
            }
            if let error { Text(error).font(Brand.font(.caption)).foregroundStyle(.red) }
            HStack(spacing: 8) {
                Spacer()
                Button(tr("취소")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.skillID == nil ? tr("추가") : tr("저장")) {
                    do { try onSave(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(!draft.canSave)
            }
        }.padding(24).frame(width: 490)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Brand.font(.body, .medium))
            TextField(placeholder, text: text).font(Brand.font(.body)).accessibilityLabel(tr("스킬 \(label)"))
        }
    }
}

struct SkillEditorPresentation: ViewModifier {
    let chat: ChatState
    @Binding var draft: SkillDraft?
    @Binding var importing: Bool
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .sheet(item: $draft) { draft in
                SkillEditor(draft: draft) { value in
                    try chat.saveSkill(id: value.skillID, title: value.title, summary: value.summary, instructions: value.instructions)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText]) { result in
                do { draft = try SkillDraft.read(result.get()) }
                catch { importError = error.localizedDescription }
            }
            .alert(tr("스킬 파일을 읽지 못했어요"), isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button(tr("확인"), role: .cancel) {}
            } message: { Text(importError ?? "") }
    }
}
