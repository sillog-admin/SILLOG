import AppKit
import Combine
import WorkGraphCore

@MainActor
final class ProjectState: ObservableObject {
    @Published var projects: [ChatProject] = []
    @Published var proposals: [ProjectProposal] = []
    @Published var items: [ProjectItem] = []
    @Published var checking = false
    @Published var error: String?
    var onChange: (() -> Void)?
    private let db: WGDatabase
    private let store: ProjectStore
    private let makeClient: () -> any LLMClient
    private var reviewTask: Task<Void, Never>?
    private var reviewID: UUID?
    private var reviewRequested = false

    init(db: WGDatabase, makeClient: @escaping () -> any LLMClient) {
        self.db = db; store = ProjectStore(db); self.makeClient = makeClient
        reload()
    }

    func reload() {
        do { projects = try store.projects(); proposals = try store.proposals(); items = try store.items() }
        catch { self.error = error.localizedDescription }
    }

    /// 첫 검토는 기존 항목을 모두 처리한다. 실행 중 생긴 항목도 이어서 검토하며 실패한 항목은 남긴다.
    func check() {
        if checking { reviewRequested = true; return }
        let id = UUID(), client = makeClient()
        reviewID = id; checking = true; error = nil
        reviewTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if reviewID == id { checking = false; reviewTask = nil; reviewID = nil }
            }
            do {
                repeat {
                    reviewRequested = false
                    while try await ProjectOrganizer.run(db: db, llm: client) > 0 {
                        try Task.checkCancellation()
                        guard reviewID == id else { return }
                        reload()
                    }
                } while reviewRequested && !Task.isCancelled
                try Task.checkCancellation()
                guard reviewID == id else { return }
                reload()
            } catch {
                guard reviewID == id, !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = "프로젝트 확인 실패: \((error as? LLMError)?.description ?? error.localizedDescription)"
            }
        }
    }

    func stop() {
        reviewTask?.cancel(); reviewTask = nil; reviewID = nil; checking = false; reviewRequested = false
    }

    func accept(_ proposal: ProjectProposal, title: String) {
        do { try store.accept(proposal.id, title: title); changed() }
        catch { self.error = error.localizedDescription }
    }

    func dismiss(_ proposal: ProjectProposal) {
        do { try store.dismiss(proposal.id); changed() }
        catch { self.error = error.localizedDescription }
    }

    func move(_ itemID: String, to projectID: String?) {
        do { try store.move(itemID, to: projectID); changed() }
        catch { self.error = error.localizedDescription }
    }

    func rename(_ project: ChatProject, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var updated = project; updated.title = String(title.prefix(120)); updated.updatedAt = Date().timeIntervalSince1970
        do { try store.save(updated); changed() } catch { self.error = error.localizedDescription }
    }

    @discardableResult func create(title: String, goal: String, instructions: String, memoryMode: ProjectMemoryMode, paths: [String] = []) -> ChatProject? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var project = ChatProject(title: String(name.prefix(120)), goal: goal)
        project.instructions = instructions; project.memoryMode = memoryMode
        project.paths = paths
        do { try store.save(project); changed(); return project } catch { self.error = error.localizedDescription; return nil }
    }

    @discardableResult func update(_ project: ChatProject, title: String, goal: String, instructions: String, memoryMode: ProjectMemoryMode) -> Bool {
        do {
            guard var updated = try store.projects().first(where: { $0.id == project.id }) else { throw ChatToolError.unavailable("프로젝트가 삭제되었습니다.") }
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return false }
            updated.title = String(name.prefix(120)); updated.goal = goal; updated.instructions = instructions
            updated.memoryMode = memoryMode; updated.updatedAt = Date().timeIntervalSince1970
            try store.save(updated); changed(); return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func delete(_ project: ChatProject) {
        do { try store.delete(project.id); changed() } catch { self.error = error.localizedDescription }
    }

    func connectFiles(_ project: ChatProject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "이 프로젝트에서 원본을 읽을 폴더를 선택하세요. 파일 업로드는 자료 보관함에서 추가할 수 있습니다."
        guard panel.runModal() == .OK else { return }
        var updated = project
        updated.paths = Array(Set(updated.paths + panel.urls.map(\.path))).sorted()
        do { try store.save(updated); changed() } catch { self.error = error.localizedDescription }
    }

    func disconnect(_ path: String, from project: ChatProject) {
        var updated = project; updated.paths.removeAll { $0 == path }
        do { try store.save(updated); changed() } catch { self.error = error.localizedDescription }
    }

    private func changed() { error = nil; reload(); onChange?() }
}
