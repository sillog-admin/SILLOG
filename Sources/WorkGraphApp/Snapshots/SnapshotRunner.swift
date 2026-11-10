import AppKit
import SwiftUI

/// 개발용 스냅샷: `WORKGRAPH_SNAPSHOT=<폴더> swift run WorkGraphApp` 로 실행하면 창을 띄우지 않고
/// 상태별 화면(SnapshotCatalog)을 PNG 로 그린 뒤 끝난다. DB·실행 잠금·수집기를 만들지 않아 실행 중인 앱과 데이터에 영향이 없다.
@MainActor
enum SnapshotRunner {
    static func run(into directory: String) -> Never {
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // 혹시 실제 경로를 읽는 코드가 있어도 사용자 데이터가 아니라 스냅샷 폴더를 보게 한다
        setenv("WORKGRAPH_DB", out.appendingPathComponent("snapshot.sqlite").path, 1)
        setenv("WORKGRAPH_CODEX_AUTH", out.appendingPathComponent("no-auth.json").path, 1)
        NSApplication.shared.setActivationPolicy(.prohibited)
        print("fonts: \(BrandFonts.register().sorted().joined(separator: ", "))")
        var failures = 0
        for shot in SnapshotCatalog.all {
            if render(shot, to: out.appendingPathComponent("\(shot.name).png")) {
                print("ok \(shot.name)")
            } else {
                failures += 1
                print("FAIL \(shot.name)")
            }
        }
        exit(failures == 0 ? 0 : 1)
    }

    private static func render(_ shot: Snapshot, to url: URL) -> Bool {
        let host = NSHostingView(rootView: shot.view)
        host.frame.size = shot.size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<3 {                                   // SwiftUI 가 상태를 반영해 다시 그릴 시간을 준다
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if shot.size == nil {                              // 폭이 고정된 화면(메뉴)은 내용 높이에 맞춘다
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

/// 그릴 화면 하나: 이름(Figma 화면 번호), 크기(nil 이면 화면이 정한 크기), 화면
struct Snapshot {
    let name: String
    let size: CGSize?
    let view: AnyView
}
