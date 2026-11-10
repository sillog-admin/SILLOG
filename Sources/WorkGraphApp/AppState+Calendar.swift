import AppKit
import WorkGraphCore

/// 일정 제안: 정리(배치)가 기록에서 찾은 일정을 알리고, 알림의 [등록]/[무시]를 처리한다
extension AppState {
    /// 앱을 켤 때: 제안을 읽어 두고(이미 있던 것은 알리지 않음), 정리의 일정 찾기에 캘린더 일정을 넘긴다
    func attachCalendar(_ database: WGDatabase, batcher: OntologyBatcher) {
        let calendar = CalendarService.shared
        calendar.onDecided = { [notifier] id in notifier.removeEvent(id: id) }   // attach 가 캘린더에 이미 있는 제안을 닫을 때도 알림을 지우게 먼저
        calendar.attach(database)
        notifier.pruneEvents(keeping: Set(calendar.suggestions.map(\.id)))
        Task { await batcher.setUpcomingEvents { from, to in await CalendarService.shared.knownEvents(from: from, to: to) } }
    }

    /// 정리에서 새로 찾은 일정 제안을 limit 개까지 가까운 날짜부터 알린다 (나머지는 메뉴 막대 캘린더 줄에만). 제안에서 빠진 일정의 알림은 지운다.
    /// Returns: 띄운 알림 수
    @discardableResult
    func announceEventSuggestions(limit: Int) -> Int {
        guard AppFeatures.calendarOn else { return 0 }
        let calendar = CalendarService.shared
        calendar.refresh()
        notifier.pruneEvents(keeping: Set(calendar.suggestions.map(\.id)))
        let fresh = calendar.freshSuggestions().prefix(max(0, limit))
        fresh.forEach { notifier.notify(event: $0) }
        return fresh.count
    }

    /// 알림의 [등록]/[무시]. 알림 본문을 누르면 메뉴 막대 창을 캘린더 줄을 편 채로 연다 (지난 알림이어도)
    func handleEventNotificationAction(_ action: SuggestionNotifier.EventAction, id: Int64) {
        guard AppFeatures.calendarOn else { return }
        if action == .open {
            UserDefaults.standard.set(true, forKey: MenuBarPanel.calendarExpandedKey)
            MenuBarPanel.open()
            return
        }
        let calendar = CalendarService.shared
        calendar.refresh()
        guard let suggestion = calendar.suggestions.first(where: { $0.id == id }) else {   // 이미 정했거나 날짜가 지난 제안
            notifier.removeEvent(id: id)
            return
        }
        if action == .register { Task { await calendar.register(suggestion) } } else { calendar.dismiss(suggestion) }
    }
}

/// 메뉴 막대 창. SwiftUI MenuBarExtra 에는 코드로 여는 방법이 없어 상태 막대 단추를 대신 누른다 (단추를 못 찾으면 아무것도 안 한다)
enum MenuBarPanel {
    /// 캘린더 줄을 펴 둘지 (MenuBarCalendar 의 @AppStorage)
    static let calendarExpandedKey = "menuCalendarExpanded"

    @MainActor static func open() {
        let windows = NSApp.windows.filter { $0.className.contains("StatusBarWindow") }
        guard let button = windows.lazy.compactMap({ $0.contentView.flatMap(firstButton) }).first else {
            AppLog.write("메뉴 막대 단추를 찾지 못해 창을 열지 못함")
            return
        }
        button.performClick(nil)
    }

    @MainActor private static func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap(firstButton).first
    }
}
