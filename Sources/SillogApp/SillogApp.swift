import AppKit
import SwiftUI
import SillogCollectors
import SillogCore

/// 시작점: 글꼴을 먼저 등록하고 SwiftUI 앱을 띄운다
@main
enum AppEntry {
    static func main() {
        UserDefaults.migrateLegacyKeys()
        // 개발용: 창 없이 상태별 화면을 PNG 로 그리고 끝난다 (SnapshotRunner)
        if let directory = SillogEnv.value("SNAPSHOT"), !directory.isEmpty {
            MainActor.assumeIsolated { SnapshotRunner.run(into: directory) }
        }
        // 개발용: 녹음 파일 하나를 앱과 같은 방식으로 받아쓰며 인식기 결과를 하나하나 적고 끝난다 (TranscribeTrace)
        if let spec = SillogEnv.value("TRANSCRIBE_TRACE"), !spec.isEmpty {
            TranscribeTrace.run(spec)
        }
        let fonts = BrandFonts.register()
        if fonts.count < 6 { AppLog.write("글꼴 \(fonts.count)/6개만 등록됨: \(fonts.sorted())") }
        MenuBarPlacement.preferRightSide(.standard)
        SillogApp.main()
    }
}

struct SillogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state).localized(state.settings.language)
        } label: {
            MenuBarLabel(paused: state.status.paused, recording: state.activeRecording != nil).environmentObject(state)
        }
        .menuBarExtraStyle(.window)

        Window("SILLOG", id: "main") {
            MainWindow().environmentObject(state).localized(state.settings.language)
                .background {
                    // ⌘+ (⇧=) as well as the menu's ⌘=.
                    Button("") { zoom(1) }.keyboardShortcut("+", modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Button(tr("확대")) { zoom(1) }.keyboardShortcut("=", modifiers: .command)
                    .disabled(state.settings.textScale >= TextScale.steps[TextScale.steps.count - 1])
                Button(tr("축소")) { zoom(-1) }.keyboardShortcut("-", modifiers: .command)
                    .disabled(state.settings.textScale <= TextScale.steps[0])
                Button(tr("실제 크기")) { state.setTextScale(1) }.keyboardShortcut("0", modifiers: .command)
                    .disabled(state.settings.textScale == 1)
            }
        }
    }

    private func zoom(_ delta: Int) { state.setTextScale(TextScale.step(state.settings.textScale, by: delta)) }
}

enum Launch {
    /// 이 실행이 첫 실행인지. 앱이 뜰 때 한 번만 계산한다.
    static let isFirst: Bool = {
        let key = "sillog.launchedBefore"
        let before = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        return !before || SillogEnv.value("SHOW_WINDOW") == "1"
    }()

    /// 로그인 항목으로 자동 실행된 경우. 이때만 창 없이 조용히 시작한다.
    @MainActor static var asLoginItem = false
}

/// SwiftUI 의 창 열기 동작을 AppKit 쪽(Dock 클릭, 앱 다시 실행)에서도 쓸 수 있게 보관한다.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?

    func openMain() {
        open?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 메뉴 막대 아이콘의 첫 자리. macOS 는 아이콘 자리를 앱 설정의 "NSStatusItem Preferred Position <이름>" 에 기억한다
/// (값은 화면 오른쪽 끝에서 잰 거리, 예: 와이파이 225 · 배터리 263 · 한/영 334). 저장된 자리가 없으면 맨 왼쪽에 붙어
/// 메뉴 막대가 붐비면 노치 뒤로 가려지므로, 시계 쪽(배터리와 한/영 사이)에 둔다. 사용자가 ⌘-드래그로 옮긴 자리는 그대로 둔다
enum MenuBarPlacement {
    /// SwiftUI MenuBarExtra 의 상태 막대 항목 이름은 Item-0
    static let key = "NSStatusItem Preferred Position Item-0"
    static let rightSide = 300.0

    static func preferRightSide(_ defaults: UserDefaults) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(rightSide, forKey: key)
    }
}

/// 메뉴바 아이콘. 메뉴바가 붐비면 노치 뒤로 가려질 수 있으므로 앱을 찾는 주 경로는 Dock 아이콘이다.
struct MenuBarLabel: View {
    let paused: Bool
    var recording = false
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.icon(paused: paused, recording: recording, tidying: state.batchRunning))
            .task {
                WindowOpener.shared.open = { openWindow(id: "main") }
                await state.bootstrap()
                // 로그인 항목으로 조용히 뜬 경우가 아니면 창을 보여준다. 로그인 전이면 항상 온보딩을 띄운다.
                guard state.phase != .ready || Launch.isFirst || !Launch.asLoginItem else { return }
                WindowOpener.shared.openMain()
            }
    }

    /// 메뉴 막대 색을 따르는 심볼 실루엣 템플릿. 눈은 뚫어 그린다: 평소 세로, 녹음 중 동그랗게, 정리 중 가로로 가늘게
    static func icon(paused: Bool, recording: Bool, tidying: Bool = false) -> NSImage {
        guard !paused, let body = Brand.iconBody else {
            let image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "SILLOG") ?? NSImage()
            image.isTemplate = true
            return image
        }
        let solid = Brand.menubarBody
        // 새 실루엣: 눈 크기는 그림 속 눈(폭 50, 높이 100 / 490) 그대로, 녹음 중 지름은 눈 높이의 0.7, 정리 중 폭은 눈 높이의 0.75
        let tall: CGFloat = 0.204
        let eye: CGSize = solid != nil ? (recording ? CGSize(width: tall * 0.7, height: tall * 0.7)
                : tidying ? CGSize(width: tall * 0.75, height: tall * 0.25) : CGSize(width: 0.102, height: tall))
            : recording ? CGSize(width: 0.15, height: 0.15)
            : tidying ? CGSize(width: 0.15, height: 0.05)
            : CGSize(width: 0.09, height: 0.2)
        // 눈 중심(왼쪽 아래 기준 비율)과 기울기: 새 그림은 눈이 시계 방향 17도 기울어 있다
        let eyes: [(x: CGFloat, y: CGFloat, tilt: CGFloat)] = solid != nil ? [(0.4038, 0.5068, -17), (0.6071, 0.4599, -17)] : [(0.404, 0.34, 0), (0.596, 0.34, 0)]
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let canvas = solid != nil ? rect : rect.insetBy(dx: -1.6, dy: -1.6)      // 옛 심볼 그림의 빈 여백은 밖으로 밀어 크게 그린다
            (solid ?? body).draw(in: canvas)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            for e in eyes {
                let w = canvas.width * eye.width, h = canvas.height * eye.height
                let turn = NSAffineTransform()
                turn.translateX(by: canvas.minX + canvas.width * e.x, yBy: canvas.minY + canvas.height * e.y)
                turn.rotate(byDegrees: e.tilt)
                NSGraphicsContext.saveGraphicsState()
                turn.concat()
                NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -h / 2, width: w, height: h), xRadius: min(w, h) / 2, yRadius: min(w, h) / 2).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? tr("녹음 중") : "SILLOG"
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 디자인(Figma)이 밝은 화면 전용이라 시스템이 다크 모드여도 앱은 밝게 그린다.
    /// 다크 모드를 따르면 유리 재질이 회색이 되고 진한 글씨가 탁해진다 (메뉴, 창, 웹 그래프 모두)
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Launch.asLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        NSApp.setActivationPolicy(AppSettings.savedShowDockIcon ? .regular : .accessory)

        // SILLOG_REQUEST_PERMISSIONS=1 로 띄우면 실행하자마자 두 권한을 요청해 시스템 설정 목록에 등록시킨다.
        if SillogEnv.value("REQUEST_PERMISSIONS") == "1" {
            _ = Permissions.accessibility(prompt: true)
            Permissions.requestScreenRecording()
        }
        // 로그인 항목으로 떴는데 SwiftUI 가 창을 자동으로 열었다면 닫아 둔다 (백그라운드 서비스답게).
        if Launch.asLoginItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    guard !Launch.isFirst else { return }
                    NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() }
                }
            }
        }
    }

    /// Dock 아이콘 클릭, Finder·Spotlight 에서 다시 실행 → 창을 연다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowOpener.shared.openMain() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where SlackOAuth.handle(url) {
                WindowOpener.shared.openMain()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension View {
    /// Rebuilds the tree when the language changes so every `tr()` string is read again; zoom redraws through Brand.zoom instead.
    func localized(_ language: AppLanguage) -> some View {
        id(language).environment(\.locale, Locale(identifier: language.rawValue))
    }
}
