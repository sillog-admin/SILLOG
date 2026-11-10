import AppKit
import Foundation
import SwiftUI
import WorkGraphCore

struct FileField: Equatable { let name: String; let color: Color }

/// 내려받은 파일의 정리 위치 제안: 감지 → 문맥 모으기 → 제안 → 알림, 그리고 사용자의 결정.
extension AppState {
    var pendingFileSuggestions: Int { fileSuggestions.filter { $0.status == "pending" }.count }

    /// 제안이 나온 때의 업무(context 의 task 키) → 그 업무의 분야(theme ?? 업무 종류 최상위)와 색. 메모리의 taskList 만 쓴다(조회 없음).
    /// 못 찾으면 키에 없다 -> 화면에서 "분야 없음"
    func fileFields(for rows: [FileSuggestion]) -> [Int64: FileField] {
        let byKey = Dictionary(taskList.map { ($0.key, $0.field) }, uniquingKeysWith: { a, _ in a })
        let colors = Dictionary(TasksView.fieldStats(taskList).map { ($0.name, $0.color) }, uniquingKeysWith: { a, _ in a })
        var out: [Int64: FileField] = [:]
        for row in rows {
            guard let id = row.id, let data = row.context?.data(using: .utf8),
                  let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["task"] as? String,
                  let name = byKey[key] ?? nil else { continue }
            out[id] = FileField(name: name, color: colors[name] ?? Brand.sub)
        }
        return out
    }

    /// 파일 > 지난 기록 한 쪽의 줄 수
    static let fileHistoryPageSize = 20

    /// 대기 중인 제안은 전부, 지난 기록은 보고 있는 쪽만 불러온다 (쪽이 끝을 넘으면 마지막 쪽)
    func refreshFileSuggestions() {
        guard let db else { return }
        if taskList.isEmpty { refreshTasks() }
        let store = FileSuggestionStore(db)
        if let gone = try? store.closeGone(now: Date().timeIntervalSince1970, fileExists: { FileManager.default.fileExists(atPath: $0) }) {
            gone.forEach { notifier.remove(id: $0) }
        }
        let pending = (try? store.pending()) ?? []
        let total = (try? store.decidedCount()) ?? 0
        let size = Self.fileHistoryPageSize
        let page = min(fileHistoryPage, max(0, (total - 1) / size))
        let decided = (try? store.decided(limit: size, offset: page * size)) ?? []
        if page != fileHistoryPage { fileHistoryPage = page }
        if total != fileHistoryTotal { fileHistoryTotal = total }
        let ordered: [FileSuggestion] = pending + decided
        if ordered != fileSuggestions { fileSuggestions = ordered }
        let badge = pending.isEmpty ? "" : "\(pending.count)"
        if let dock = NSApp?.dockTile, dock.badgeLabel ?? "" != badge { dock.badgeLabel = badge }      // 테스트에는 NSApp 이 없다
    }

    /// 지난 기록의 다른 쪽 (0부터)
    func showFileHistoryPage(_ page: Int) {
        fileHistoryPage = max(0, page)
        refreshFileSuggestions()
    }

    /// 수집기가 다운로드 폴더의 새 파일을 알려 주면 여기로 온다.
    func fileDownloaded(path: String, origin: String?) async {
        guard settings.suggestFolders, let suggester, let store, let db else { return }
        let fileName = (path as NSString).lastPathComponent
        // 브라우저가 임시 이름을 최종 이름으로 바꾸는 동안 잠깐 기다린다. 사라졌으면(임시 파일이었으면) 그만.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard FileManager.default.fileExists(atPath: path) else { return }

        let now = Date().timeIntervalSince1970
        let index = await currentFolderIndex()
        let observations = (try? store.recent(limit: 120)) ?? []
        let recentTitles = Self.recentContext(from: observations, since: now - 600)
        // 받기 직전 화면의 텍스트 (강의 사이트라면 과목명·주차가 여기에 있다)
        let screenText: String? = observations.first { $0.ts >= now - 600 && $0.textId != nil }
            .flatMap { $0.textId }.flatMap { (try? store.texts(ids: [$0]))?[$0] }
            .map { String($0.prefix(800)) }
        let openTasks: [TaskDigest] = (try? await db.writer.read { try GraphTx($0).openTasks(limit: 6) }) ?? []
        let currentTask = openTasks.first.flatMap { $0.lastActive > now - 1_800 ? $0.id : nil }
        let context = FolderSuggester.Context(recentTitles: recentTitles, screenText: screenText, openTasks: openTasks, currentTaskKey: currentTask, now: now)

        do {
            guard let suggestion = try await suggester.suggest(filePath: path, originURL: origin, index: index, context: context) else {
                AppLog.write("파일 제안 없음: \(fileName)")
                return
            }
            AppLog.write("파일 제안: \(fileName) → \(suggestion.suggestedFolder) (\(suggestion.source), \(Int(suggestion.confidence * 100))%)")
            refreshFileSuggestions()
            notifier.notify(suggestion, home: NSHomeDirectory())
        } catch {
            AppLog.write("파일 제안 실패: \(fileName): \(String(describing: error).prefix(200))")
            await handleAuthLossIfNeeded()
        }
    }

    /// 폴더 색인은 30분 동안 재사용한다. 첫 색인은 백그라운드에서 만든다.
    func currentFolderIndex() async -> FolderIndex {
        let now = Date().timeIntervalSince1970
        if let folderIndex, now - folderIndexAt < 1_800 { return folderIndex }
        if let folderIndexTask { return await folderIndexTask.value }
        let home = NSHomeDirectory()
        let roots = settings.folderRoots.map { FolderSuggester.expand($0, home: home) }
        let task = Task.detached(priority: .utility) { FolderIndex.scan(roots: roots, home: home) }
        folderIndexTask = task
        let index = await task.value
        folderIndex = index
        folderIndexAt = Date().timeIntervalSince1970
        folderIndexTask = nil
        AppLog.write("폴더 색인: \(index.folders.count)개")
        return index
    }

    /// 최근 창 제목과 주소(호스트+경로 앞부분). 같은 것은 한 번만.
    static func recentContext(from observations: [Observation], since: Double) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for observation in observations where observation.ts >= since {
            var items: [String] = []
            if let title = observation.windowTitle, !title.isEmpty { items.append(title) }
            if let url = observation.url, let components = URLComponents(string: url), let host = components.host {
                items.append(host + components.path.prefix(40))
            }
            if let doc = observation.docPath { items.append((doc as NSString).lastPathComponent) }
            for item in items where seen.insert(item).inserted { result.append(item) }
            if result.count >= 14 { break }
        }
        return result
    }

    // MARK: 결정

    func acceptSuggestion(_ suggestion: FileSuggestion) {
        guard let suggester, let id = suggestion.id else { return }
        do {
            let target = try suggester.accept(id: id, now: Date().timeIntervalSince1970)
            AppLog.write("파일 옮김: \(suggestion.fileName) → \(target)")
            recordingTextMoved(from: suggestion.path, to: target)
        } catch {
            AppLog.write("파일 옮기기 실패: \(error.localizedDescription)")
            fileError = "옮기지 못했습니다. \(error.localizedDescription)"
        }
        notifier.remove(id: id)
        refreshFileSuggestions()
    }

    /// 사용자가 폴더를 직접 고른다. 고른 폴더가 다음 제안의 기준이 된다.
    func chooseFolderAndMove(_ suggestion: FileSuggestion) {
        guard let suggester, let id = suggestion.id else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "여기로 옮기기"
        panel.directoryURL = URL(fileURLWithPath: suggestion.suggestedFolder)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
        do {
            let target = try suggester.rejectAndMove(id: id, to: folder, now: Date().timeIntervalSince1970)
            AppLog.write("파일 옮김(직접 선택): \(suggestion.fileName) → \(target)")
            recordingTextMoved(from: suggestion.path, to: target)
        } catch {
            fileError = "옮기지 못했습니다. \(error.localizedDescription)"
        }
        notifier.remove(id: id)
        refreshFileSuggestions()
    }

    func ignoreSuggestion(_ suggestion: FileSuggestion) {
        guard let suggester, let id = suggestion.id else { return }
        try? suggester.ignore(id: id, now: Date().timeIntervalSince1970)
        notifier.remove(id: id)
        refreshFileSuggestions()
    }

    func undoSuggestion(_ suggestion: FileSuggestion) {
        guard let suggester, let id = suggestion.id else { return }
        do {
            let restored = try suggester.undo(id: id, now: Date().timeIntervalSince1970)
            AppLog.write("파일 되돌림: \(restored)")
            recordingTextMoved(from: suggestion.movedTo, to: restored)
        } catch {
            fileError = "되돌리지 못했습니다. \(error.localizedDescription)"
        }
        refreshFileSuggestions()
    }

    func revealSuggestionFile(_ suggestion: FileSuggestion) {
        let path = suggestion.status == "moved" ? (suggestion.movedTo ?? suggestion.path) : suggestion.path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func handleNotificationAction(_ action: SuggestionNotifier.Action, id: Int64) {
        refreshFileSuggestions()
        guard let suggestion = fileSuggestions.first(where: { $0.id == id }), suggestion.status == "pending" else { return }
        switch action {
        case .move: acceptSuggestion(suggestion)
        case .ignore: ignoreSuggestion(suggestion)
        case .open:
            openFileSuggestions()
            WindowOpener.shared.openMain()
        }
    }
}
