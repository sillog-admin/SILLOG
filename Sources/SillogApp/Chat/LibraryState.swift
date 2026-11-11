import AppKit
import Combine
import SillogCore

@MainActor
final class LibraryState: ObservableObject {
    @Published var items: [ChatLibraryItem] = []
    /// 보관 자료 id -> 연결 대화의 초점 (홈의 분야 기준). 없으면 "분야 없음"
    @Published var itemFocuses: [String: [ChatFocus]] = [:]
    @Published var busy = false
    @Published var error: String?
    var onChange: (() -> Void)?
    let store: LibraryStore
    private let db: SillogDatabase
    init(db: SillogDatabase) { self.db = db; store = LibraryStore(db); reload() }

    func reload() {
        do { items = try store.items(); itemFocuses = try store.itemFocuses() } catch { self.error = error.localizedDescription }
    }

    func results(limit: Int? = nil) -> [ChatLibraryItem] {
        let all = items.filter { $0.kind == "generated" }.sorted { $0.createdAt > $1.createdAt }
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    func collectExisting() {
        guard !busy else { return }
        busy = true
        let db = db, store = store
        Task {
            do {
                try await Task.detached {
                    let chats = ChatStore(db)
                    for conversation in try chats.conversations() { try store.collectArtifacts(chats.messages(conversation.id)) }
                }.value
                changed()
            } catch { self.error = tr("기존 결과물 보관 실패: \(error.localizedDescription)") }
            busy = false
        }
    }

    func importFiles(projectID: String? = nil, conversationID: String? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = tr("파일을 SILLOG 보관함에 복사합니다. 연결한 대화와 프로젝트에서 필요한 내용이 설정된 LLM에 전달됩니다.")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, store = store
        busy = true; error = nil
        Task {
            do {
                try await Task.detached {
                    for url in urls {
                        let item = try store.importFile(url)
                        if let projectID { try store.attach(item.id, projectID: projectID) }
                        if let conversationID { try store.attach(item.id, conversationID: conversationID) }
                    }
                }.value
            } catch { self.error = error.localizedDescription }
            busy = false; reload(); onChange?()
        }
    }

    func attach(_ item: ChatLibraryItem, projectID: String) {
        do { try store.attach(item.id, projectID: projectID); changed() } catch { self.error = error.localizedDescription }
    }
    func attach(_ item: ChatLibraryItem, conversationID: String) {
        do { try store.attach(item.id, conversationID: conversationID); changed() } catch { self.error = error.localizedDescription }
    }
    func detach(_ item: ChatLibraryItem, projectID: String) {
        do { try store.detach(item.id, projectID: projectID); changed() } catch { self.error = error.localizedDescription }
    }
    func detach(_ item: ChatLibraryItem, conversationID: String) {
        do { try store.detach(item.id, conversationID: conversationID); changed() } catch { self.error = error.localizedDescription }
    }
    func sources(conversationID: String? = nil, projectID: String? = nil) -> [ChatLibraryItem] {
        do {
            let ids = Set(try store.sourceIDs(conversationID: conversationID, projectID: projectID))
            return items.filter { ids.contains($0.id) }
        } catch { self.error = error.localizedDescription; return [] }
    }
    func projectIDs(_ item: ChatLibraryItem) -> [String] { (try? store.projectIDs(for: item.id)) ?? [] }
    func rename(_ item: ChatLibraryItem, title: String) {
        do { try store.rename(item.id, title: title); changed() } catch { self.error = error.localizedDescription }
    }
    func delete(_ item: ChatLibraryItem) {
        do { try store.delete(item); changed() } catch { self.error = error.localizedDescription }
    }
    func saveResponse(_ message: ConversationMessage, title: String, projectID: String) {
        do {
            let item = try store.saveResponse(message, title: title)
            try store.attach(item.id, projectID: projectID); changed()
        } catch { self.error = error.localizedDescription }
    }
    func collect(_ message: ConversationMessage) {
        do { try store.collectArtifacts([message]); changed() } catch { self.error = tr("결과물 보관 실패: \(error.localizedDescription)") }
    }
    func export(_ item: ChatLibraryItem) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: store.url(for: item)).write(to: destination, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    private func changed() { error = nil; reload(); onChange?() }
}
