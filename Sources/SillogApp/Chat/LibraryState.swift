import AppKit
import Combine
import SillogCore

@MainActor
final class LibraryState: ObservableObject {
    @Published var items: [ChatLibraryItem] = [] {
        didSet { (grouped, versionCounts) = ChatLibraryItem.latestOfEachSeries(items) }
    }
    /// items with each chat result's versions folded into its newest one, for lists that show one row per result.
    private(set) var grouped: [ChatLibraryItem] = []
    private(set) var versionCounts: [String: Int] = [:]
    /// 보관 자료 id -> 연결 대화의 초점 (홈의 분야 기준). 없으면 "분야 없음"
    @Published var itemFocuses: [String: [ChatFocus]] = [:]
    @Published var busy = false {
        didSet { if !busy, !queued.isEmpty { let next = queued.removeFirst(); importFiles(next.urls, projectID: next.projectID, conversationID: next.conversationID, keepingError: true) } }
    }
    @Published var error: String?
    /// Import failure of files dropped or pasted into a chat; shown in the chat until the next send or import.
    @Published var chatImportError: String?
    /// Items attached to the chat on screen, cached so the composer doesn't query the DB on every keystroke.
    @Published private(set) var attached: [ChatLibraryItem] = []
    /// Project-wide items; detaching them from one chat does nothing, so they get no remove button.
    @Published private(set) var projectAttached: Set<String> = []
    private var attachedTo: (conversationID: String, projectID: String?) = ("", nil)
    var onChange: (() -> Void)?
    /// Pasted screenshots are written here first and removed once imported.
    static let pasteFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SillogPaste", isDirectory: true)
    private var queued: [(urls: [URL], projectID: String?, conversationID: String?)] = []
    let store: LibraryStore
    private let db: SillogDatabase
    init(db: SillogDatabase) { self.db = db; store = LibraryStore(db); reload() }

    func reload() {
        do { items = try store.items(); itemFocuses = try store.itemFocuses() } catch { self.error = error.localizedDescription }
        refreshAttached()
    }

    func showAttachments(conversationID: String, projectID: String?) {
        attachedTo = (conversationID, projectID); refreshAttached()
    }

    private func refreshAttached() {
        let fresh = sources(conversationID: attachedTo.conversationID, projectID: attachedTo.projectID)
        if fresh != attached { attached = fresh }
        let project = attachedTo.projectID.map { pid in Set((try? store.sourceIDs(conversationID: nil, projectID: pid)) ?? []) } ?? []
        if project != projectAttached { projectAttached = project }
    }

    func results(limit: Int? = nil) -> [ChatLibraryItem] {
        let all = grouped.filter { $0.kind == "generated" }.sorted { $0.createdAt > $1.createdAt }
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    // Separate from busy so the startup sweep doesn't refuse sending a chat.
    private var collecting = false

    func collectExisting() {
        guard !collecting else { return }
        collecting = true
        let db = db, store = store
        Task {
            do {
                try await Task.detached {
                    try store.collectArtifacts(ChatStore(db).messagesWithArtifacts())
                }.value
                changed()
            } catch { self.error = tr("기존 결과물 보관 실패: \(error.localizedDescription)") }
            collecting = false
        }
    }

    func importFiles(projectID: String? = nil, conversationID: String? = nil) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.message = tr("파일을 SILLOG 보관함에 복사합니다. 연결한 대화와 프로젝트에서 필요한 내용이 설정된 LLM에 전달됩니다.")
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls, projectID: projectID, conversationID: conversationID)
    }

    /// Args: urls are files to copy into the library; a call made while another import runs waits for it.
    func importFiles(_ urls: [URL], projectID: String? = nil, conversationID: String? = nil, keepingError: Bool = false) {
        guard !urls.isEmpty else { return }
        if busy { queued.append((urls, projectID, conversationID)); return }
        let store = store
        if !keepingError { error = nil; chatImportError = nil }
        busy = true
        Task {
            do {
                try await Task.detached {
                    for url in urls {
                        let item = try store.importFile(url)
                        if let projectID { try store.attach(item.id, projectID: projectID) }
                        if let conversationID { try store.attach(item.id, conversationID: conversationID) }
                    }
                }.value
            } catch {
                self.error = error.localizedDescription
                if conversationID != nil { chatImportError = error.localizedDescription }
            }
            for url in urls where url.path.hasPrefix(Self.pasteFolder.path) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            reload(); onChange?(); busy = false
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
    /// Deletes every version of a chat result, since lists show the series as one row.
    func delete(_ item: ChatLibraryItem) {
        do {
            for version in items where version.seriesKey == item.seriesKey { try store.delete(version) }
            changed()
        } catch { self.error = error.localizedDescription; reload() }
    }
    func saveResponse(_ message: ConversationMessage, title: String, projectID: String) {
        do {
            let item = try store.saveResponse(message, title: title)
            try store.attach(item.id, projectID: projectID); changed()
        } catch { self.error = error.localizedDescription }
    }
    func collect(_ message: ConversationMessage) {
        let store = store
        Task {
            do { try await Task.detached { try store.collectArtifacts([message]) }.value; changed() }
            catch { self.error = tr("결과물 보관 실패: \(error.localizedDescription)") }
        }
    }
    func export(_ item: ChatLibraryItem) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: store.url(for: item)).write(to: destination, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    private func changed() { error = nil; reload(); onChange?() }
}
