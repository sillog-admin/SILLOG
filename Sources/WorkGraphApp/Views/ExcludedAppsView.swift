import AppKit
import SwiftUI
import WorkGraphCollectors

/// 기록하지 않을 앱 목록. 제외한 앱은 이름과 시간만 남고 창 제목·주소·텍스트·스크린샷은 기록되지 않는다.
struct ExcludedAppsView: View {
    @EnvironmentObject private var state: AppState

    private struct Entry: Identifiable {
        let id: String          // bundle id
        let name: String
        let icon: NSImage?
    }

    private var entries: [Entry] {
        state.settings.excludedBundles.map { bundle in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let name = PrivacyFilter.defaultNames[bundle]
                ?? url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundle
            return Entry(id: bundle, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 지금 실행 중인 일반 앱 중 아직 제외하지 않은 것 (메뉴바 앱·백그라운드 프로세스 제외)
    private var runningCandidates: [(bundle: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !state.settings.excludedBundles.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("기록하지 않을 앱")
            SettingCard {
                ForEach(entries) { entry in
                    SettingRow(entry.name, icon: entry.icon == nil ? "app.dashed" : nil, iconImage: entry.icon) {   // 앱 아이콘을 이름 앞에
                        Button("제거") { remove(entry.id) }
                            .buttonStyle(.plain).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                    }
                }
                if entries.isEmpty { SettingRow("없음") { EmptyView() } }
                HStack(spacing: 12) {
                    Menu {
                        if runningCandidates.isEmpty { Text("추가할 앱 없음") }
                        ForEach(runningCandidates, id: \.bundle) { candidate in
                            Button(candidate.name) { add(candidate.bundle) }
                        }
                    } label: {
                        Label("실행 중인 앱에서 추가", systemImage: "plus").font(Brand.suit(12)).foregroundStyle(Brand.tabText)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Button("앱 파일 선택…") { pickApp() }.buttonStyle(.plain).font(Brand.suit(12)).foregroundStyle(Brand.tabText)
                    Spacer()
                    Button("기본값으로") { state.settings.excludedBundles = PrivacyFilter.defaultExcludedBundles.sorted() }
                        .buttonStyle(.plain).font(Brand.suit(11)).foregroundStyle(Brand.gray)
                }
                .frame(height: 44)
            }
            InfoLine("제외한 앱은 이름과 시간만 남고 창 제목, 주소, 화면 텍스트, 스크린샷은 기록되지 않아요.")
        }
    }

    private func add(_ bundle: String) {
        guard !state.settings.excludedBundles.contains(bundle) else { return }
        state.settings.excludedBundles.append(bundle)
    }

    private func remove(_ bundle: String) {
        state.settings.excludedBundles.removeAll { $0 == bundle }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.message = "기록하지 않을 앱을 고르세요"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundle = Bundle(url: url)?.bundleIdentifier { add(bundle) }
        }
    }
}
