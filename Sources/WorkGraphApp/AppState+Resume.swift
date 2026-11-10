import AppKit
import Foundation
import WorkGraphCore

/// 업무 목록과 "다시 열기" (그때 쓰던 파일·프로젝트·웹페이지·앱을 한 번에 연다)
struct TaskSummary: Identifiable, Equatable {
    let id: Int64
    let key: String
    let title: String
    let taskType: String?
    let activeSeconds: Double
    let lastActive: Double
    let sessionCount: Int
    /// 업무가 속한 분야 (Task -PART_OF-> Theme). 없으면 nil — 업무 탭에서 '분야 없음' 폴더로 간다
    var theme: String? = nil
    /// 업무 목록의 분야 색: 분야(theme)가 있으면 그것, 없으면 업무 종류의 최상위 분류(그래프와 같은 기준)
    var field: String? = nil
}

struct SessionSummary: Identifiable, Equatable {
    let id: Int64
    let key: String
    let title: String
    /// 배치마다 한 문장씩 쌓인 "한 일" (시간순)
    let summaries: [String]
    let start: Double
    let end: Double
    let apps: [String]
    let resourceCount: Int
}

struct ResumeRequest: Identifiable, Equatable {
    let id = UUID()
    var plan: ResumePlan
}

extension AppState {
    func refreshTasks() {
        guard let db else { return }
        let fresh: [TaskSummary] = (try? db.writer.read { conn in
            let tx = GraphTx(conn)
            return try tx.nodes(label: NodeLabel.task).map { node in
                let sessions = try tx.edges(to: node.id, type: EdgeType.partOf).count
                let typeNode = try tx.edges(from: node.id, type: EdgeType.instanceOf).first.flatMap { try tx.node(id: $0.dst) }
                var top = typeNode   // SUBCLASS_OF 를 끝까지 올라간 최상위 분류
                while let cur = top, let up = try tx.edges(from: cur.id, type: EdgeType.subclassOf).first.flatMap({ try tx.node(id: $0.dst) }), up.id != cur.id { top = up }
                let theme = try ThemeGraph.theme(ofTask: node.id, tx)?.title
                return TaskSummary(id: node.id, key: node.key, title: node.title, taskType: typeNode?.title,
                                   activeSeconds: node.props["active_seconds"]?.doubleValue ?? 0,
                                   lastActive: node.props["last_active"]?.doubleValue ?? node.updatedAt, sessionCount: sessions,
                                   theme: theme, field: theme ?? top?.title)
            }
            .filter { $0.sessionCount > 0 }
            .sorted { $0.lastActive > $1.lastActive }
        }) ?? []
        if fresh != taskList { taskList = fresh }
        if let store {
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let off = (try? store.offTaskSeconds(from: startOfDay, to: startOfDay + 86_400)) ?? []
            if off.map(\.app) != offTaskToday.map(\.app) || off.map(\.seconds) != offTaskToday.map(\.seconds) { offTaskToday = off }
        }
    }

    func sessions(ofTask taskId: Int64) -> [SessionSummary] {
        guard let db else { return [] }
        return (try? db.writer.read { conn in
            let tx = GraphTx(conn)
            return try tx.edges(to: taskId, type: EdgeType.partOf).compactMap { edge -> SessionSummary? in
                guard let node = try tx.node(id: edge.src) else { return nil }
                let apps = try tx.edges(from: node.id, type: EdgeType.used).sorted { $0.weight > $1.weight }.prefix(4)
                    .compactMap { try tx.node(id: $0.dst)?.title }.filter { !["Sillog", "SILLOG", "WorkGraph", "제외된 앱"].contains($0) }
                let resources = try tx.edges(from: node.id, type: EdgeType.touched).count
                let summaries = node.props["summaries"]?.arrayValue?.compactMap(\.stringValue)
                    ?? [node.props["summary"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }
                return SessionSummary(id: node.id, key: node.key, title: node.title, summaries: summaries,
                                      start: node.props["start"]?.doubleValue ?? node.createdAt, end: node.props["end"]?.doubleValue ?? node.updatedAt,
                                      apps: apps, resourceCount: resources)
            }
            .sorted { $0.start > $1.start }
        }) ?? []
    }

    /// 업무 드로어의 자료 탭: 그래프 업무 팝업과 같은 기준의 종류별 자료와 같은 맥락 업무
    func taskMaterials(_ taskId: Int64) -> TaskMaterials {
        guard let db else { return TaskMaterials() }
        return (try? db.writer.read { try TaskMaterials.read(GraphTx($0), taskId: taskId) }) ?? TaskMaterials()
    }

    // MARK: 업무 드로어

    /// 업무 드로어를 그 업무로 연다 (업무 목록, 그래프, 같은 맥락 업무에서 누를 때)
    func openTaskDetail(id: Int64) {
        selectedTaskId = id
        openNode = nil
        nodeTrail = []
        taskDetailOpen = true
    }

    /// 그래프에서 업무를 눌렀을 때: 노드 키로 업무를 찾는다. 목록에 없으면 한 번 새로 읽어 본다
    func openTaskDetail(key: String) {
        if !taskList.contains(where: { $0.key == key }) { refreshTasks() }
        guard let task = taskList.first(where: { $0.key == key }) else { return }
        openTaskDetail(id: task.id)
    }

    /// 업무 드로어의 '이 업무로 묻기': 채팅 탭에서 그 업무만 보는 새 대화
    func askAbout(task: TaskSummary) {
        askAbout(ChatFocus(kind: .task, key: task.key, title: task.title))
    }

    /// 업무 목록 분야 폴더의 '이 분야로 묻기': 그 분야의 업무 전체만 보는 새 대화
    func askAbout(theme title: String) {
        let key = db.flatMap { db in try? db.writer.read { try String.fetchOne($0, sql: "SELECT key FROM nodes WHERE label = ? AND title = ?", arguments: [NodeLabel.theme, title]) } } ?? title
        askAbout(ChatFocus(kind: .theme, key: key, title: title))
    }

    /// 그래프 검색창에서 Enter: 새 대화로 그 글을 바로 보낸다
    func askInChat(_ text: String) {
        guard let chat, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        chat.newConversation()
        chat.draft = text
        taskDetailOpen = false
        selectedTab = .chat
        chat.send()
    }

    private func askAbout(_ focus: ChatFocus) {
        guard let chat else { return }
        chat.newConversation(focus: [focus])
        taskDetailOpen = false
        selectedTab = .chat
    }

    /// 자료 열기: 자료 키(file:·웹 주소·arxiv:·doi:·local:·recording:). 그래프 카드와 업무 드로어가 함께 쓴다
    func openGraphItem(uri: String) {
        if uri.hasPrefix("recording:") { openRecordingText(key: uri); return }   // 녹음은 받아쓴 글 .md 를 연다
        guard let url = URINormalizer.openableURL(forKey: uri, home: NSHomeDirectory()) else { return }
        if !NSWorkspace.shared.open(url) { AppLog.write("열기 실패: \(uri)") }
    }

    /// 앱 열기: 번들 id. "excluded" 는 기록하지 않는 앱 묶음이라 열지 않는다
    func openApp(bundle: String) {
        guard bundle != "excluded" else { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { AppLog.write("앱을 찾지 못함: \(bundle)"); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    // MARK: 다시 열기

    func prepareResume(taskId: Int64) {
        guard let db, let node = try? db.writer.read({ try GraphTx($0).node(id: taskId) }) else { return }
        prepareResume(node: node)
    }

    func prepareResume(sessionId: Int64) {
        guard let db, let node = try? db.writer.read({ try GraphTx($0).node(id: sessionId) }) else { return }
        prepareResume(node: node)
    }

    /// 그래프 화면에서 업무·세션 노드의 "다시 열기"
    func prepareResume(label: String, key: String) {
        guard let db, let node = try? db.writer.read({ try GraphTx($0).node(label: label, key: key) }) else { return }
        prepareResume(node: node)
    }

    private func prepareResume(node: GraphNode) {
        guard let db else { return }
        let home = NSHomeDirectory()
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        let plan: ResumePlan? = try? db.writer.read { conn in
            let tx = GraphTx(conn)
            switch node.label {
            case NodeLabel.task: return try ResumePlanner.plan(task: node, tx: tx, home: home, fileExists: exists)
            case NodeLabel.session: return try ResumePlanner.plan(session: node, tx: tx, home: home, fileExists: exists)
            default: return nil
            }
        }
        guard let plan else { return }
        resumeRequest = ResumeRequest(plan: plan)
        WindowOpener.shared.openMain()
    }

    /// 계획대로 연다: 프로젝트 폴더 → 파일 → 웹페이지(한 브라우저에 탭으로) → 앱
    func runResume(_ plan: ResumePlan) {
        let items = plan.selectedItems
        resumeRequest = nil
        guard !items.isEmpty else { return }
        AppLog.write("다시 열기: \(plan.title) — \(items.count)개")
        let workspace = NSWorkspace.shared
        func appURL(_ bundle: String?) -> URL? { bundle.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) } }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        for item in items where item.kind == .folder {
            let url = URL(fileURLWithPath: item.target, isDirectory: true)
            if let app = appURL(item.appBundle) { workspace.open([url], withApplicationAt: app, configuration: configuration) } else { workspace.open(url) }
        }
        let files = items.filter { $0.kind == .file }
        let delay: TimeInterval = items.contains { $0.kind == .folder } ? 1.2 : 0       // 편집기 창이 뜬 뒤 파일을 그 창에 연다
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for item in files {
                let url = URL(fileURLWithPath: item.target)
                if let app = appURL(item.appBundle) { workspace.open([url], withApplicationAt: app, configuration: configuration) } else { workspace.open(url) }
            }
            let pages = items.filter { $0.kind == .url }
            let byBrowser = Dictionary(grouping: pages, by: { $0.appBundle ?? "" })
            for (bundle, group) in byBrowser {
                let urls = group.compactMap { URL(string: $0.target) }
                if let app = appURL(bundle.isEmpty ? nil : bundle) { workspace.open(urls, withApplicationAt: app, configuration: configuration) }
                else { urls.forEach { workspace.open($0) } }
            }
            for item in items where item.kind == .app {
                if let app = appURL(item.target) { workspace.openApplication(at: app, configuration: configuration) }
            }
        }
    }
}
