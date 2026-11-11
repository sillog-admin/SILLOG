import AppKit
import SwiftUI
import WebKit
import SillogCore

/// 캘린더 화면 가운데의 웹 달력 (Resources/calendar, FullCalendar 6). 보이는 기간이 바뀔 때마다 웹 쪽이 일정을 묻고(답은 약속으로 돌려준다),
/// 일정·제안·숨김이 바뀌면(CalendarService.changes) 다시 묻게 한다
struct CalendarWebView: NSViewRepresentable {
    @ObservedObject var calendar: CalendarService
    /// 고른 보기(일·주·월)를 기억하는 곳
    static let viewKey = "calendarView"

    func makeCoordinator() -> Coordinator { Coordinator(calendar: calendar) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "sillog")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")              // 로딩 중 흰 화면 방지
        context.coordinator.seen = calendar.changes
        if let directory = Self.directory() {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory.deletingLastPathComponent())   // ../Brand/Fonts 의 SUIT 글꼴도 읽게
        } else {
            webView.loadHTMLString("<body style='font:14px -apple-system;padding:40px;color:#736D68'>캘린더 화면 리소스를 찾지 못했습니다.</body>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.seen != calendar.changes else { return }
        context.coordinator.seen = calendar.changes
        webView.evaluateJavaScript("window.sillog && window.sillog.refetch()", completionHandler: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sillog", contentWorld: .page)   // 처리기가 Coordinator 를 붙잡고 남지 않게
    }

    /// .app 번들이면 Contents/Resources/calendar, `swift run` 이면 SwiftPM 리소스 번들
    static func directory() -> URL? {
        Bundle.main.url(forResource: "calendar", withExtension: nil) ?? Bundle.module.url(forResource: "calendar", withExtension: nil)
    }

    /// 웹 달력이 보내는 것: init(처음 보기·한 주의 첫 요일), events(기간의 일정), view(고른 보기), register/dismiss(제안), openCalendarApp
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply {
        private let calendar: CalendarService
        var seen = -1

        init(calendar: CalendarService) { self.calendar = calendar }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return replyHandler(nil, nil) }
            switch type {
            case "init":
                replyHandler(["view": CalendarFeed.view(stored: UserDefaults.standard.string(forKey: CalendarWebView.viewKey)),
                              "firstDay": Calendar.current.firstWeekday - 1], nil)
            case "events":
                let iso = ISO8601DateFormatter()
                guard let start = (body["start"] as? String).flatMap(iso.date), let end = (body["end"] as? String).flatMap(iso.date) else { return replyHandler([], nil) }
                let calendar = calendar
                Task { @MainActor in replyHandler(await calendar.feed(from: start, to: end), nil) }   // 구글 일정은 받아 오는 데 시간이 걸린다
            case "view":
                if let name = body["name"] as? String, CalendarFeed.views.contains(name) { UserDefaults.standard.set(name, forKey: CalendarWebView.viewKey) }
                replyHandler(nil, nil)
            case "register", "dismiss":
                let id = (body["id"] as? NSNumber)?.int64Value
                if let suggestion = calendar.suggestions.first(where: { $0.id == id }) {
                    if type == "register" { Task { await calendar.register(suggestion) } } else { calendar.dismiss(suggestion) }
                }
                replyHandler(nil, nil)
            case "openCalendarApp":
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                replyHandler(nil, nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}
