import AppKit
import QuartzCore
import WorkGraphCore

/// 개발용: 스크롤 끊김 재기. 숨은 설정 frameLog 를 켜면(defaults write com.sillog.app frameLog -bool true) 화면 갱신마다 불려
/// 메인 스레드가 다음 프레임에 늦은 횟수를 재고, 늦은 프레임이 있던 1초마다 지금 화면 이름과 함께 app.log 에 남긴다 (10/29: 업무 목록은 부드럽고 파일·지난 기록은 끊김)
@MainActor
final class FrameMonitor: NSObject {
    enum Lateness { case onTime, late, veryLate }

    static let shared = FrameMonitor()
    static let enabled = UserDefaults.standard.bool(forKey: "frameLog")

    /// 지금 화면 이름 (AppState 가 넣는다)
    var screen: () -> String = { "" }
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0, late = 0, veryLate = 0
    private var longest: CFTimeInterval = 0

    /// 간격이 한 프레임의 1.5배를 넘으면 늦음(한 장을 놓침), 3배를 넘으면 많이 늦음
    nonisolated static func lateness(gap: CFTimeInterval, interval: CFTimeInterval) -> Lateness {
        if gap > interval * 3 { return .veryLate }
        if gap > interval * 1.5 { return .late }
        return .onTime
    }

    func start(on view: NSView) {
        guard Self.enabled, link == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        AppLog.write("프레임 측정 시작")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { windowStart = now; return }
        let gap = now - last
        frames += 1
        switch Self.lateness(gap: gap, interval: link.duration > 0 ? link.duration : 1.0 / 120) {
        case .onTime: break
        case .late: late += 1
        case .veryLate: late += 1; veryLate += 1
        }
        longest = max(longest, gap)
        guard now - windowStart >= 1 else { return }
        if late > 0 {
            AppLog.write(String(format: "프레임 %@: %d장 중 늦음 %d (많이 늦음 %d), 가장 긴 간격 %.0fms", screen(), frames, late, veryLate, longest * 1000))
        }
        frames = 0; late = 0; veryLate = 0; longest = 0; windowStart = now
    }
}
