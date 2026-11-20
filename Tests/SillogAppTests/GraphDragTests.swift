import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import SillogApp
import SillogCore

/// Dragging the graph: the 2D view moves with the pointer, and neither view can be dragged off into empty space.
/// Measured as the centroid of the drawn canvas pixels, with reduced motion so frames don't drift between reads.
@MainActor
final class GraphDragTests: XCTestCase {
    private final class Ready: NSObject, WKScriptMessageHandler {
        let done: XCTestExpectation
        var sent: [String] = []                                 // types of the messages the page posted to the app
        init(_ done: XCTestExpectation) { self.done = done }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:], type = body["type"] as? String ?? ""
            sent.append(type == "node" ? "node \(body["label"] ?? "") \(body["key"] ?? "")" : type)
            if type == "ready" { done.fulfill() }
        }
    }
    private var messages: Ready?

    /// The 3D view draws on animation frames, which a page in an off-screen window never gets: the window is on screen but nearly clear
    private func demoDatabase(fields: Bool = true) throws -> SillogDatabase {
        let database = try SillogDatabase.inMemory()
        try database.writer.write { conn in
            let tx = GraphTx(conn)
            if !fields {                                        // fields turned off: tasks group under the top task type instead
                let top = try tx.upsertNode(label: NodeLabel.taskType, key: "학습", subtype: nil, title: "학습", props: [:], at: 1_795_000_000)
                let sub = try tx.upsertNode(label: NodeLabel.taskType, key: "복습", subtype: nil, title: "복습", props: [:], at: 1_795_000_000)
                _ = try tx.upsertEdge(src: sub, dst: top, type: EdgeType.subclassOf, props: [:], addWeight: 0, at: 1_795_000_000)
                let task = try tx.upsertNode(label: NodeLabel.task, key: "review", subtype: nil, title: "AI기초수학 복습",
                                             props: ["active_seconds": .number(3600), "last_active": .number(1_795_000_000)], at: 1_795_000_000)
                _ = try tx.upsertEdge(src: task, dst: sub, type: EdgeType.instanceOf, props: [:], addWeight: 0, at: 1_795_000_000)
                let session = try tx.upsertNode(label: NodeLabel.session, key: "s-review", subtype: nil, title: "세션",
                                                props: ["start": .number(1_795_000_000), "end": .number(1_795_003_600), "active_seconds": .number(3600)], at: 1_795_000_000)
                _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1_795_000_000)
                return
            }
            let rows = [("flask", "Flask 웹앱 개발", "프로젝트"), ("stats", "통계학 수업", "학업"), ("report", "분기 성과 보고서", "프로젝트"), ("ml", "기계학습 과제", "학업")]
            for (index, row) in rows.enumerated() {
                let at = 1_795_000_000 + Double(index) * 3600
                let task = try tx.upsertNode(label: NodeLabel.task, key: row.0, subtype: nil, title: row.1,
                                             props: ["active_seconds": .number(3600), "last_active": .number(at)], at: at)
                let session = try tx.upsertNode(label: NodeLabel.session, key: "s-\(row.0)", subtype: nil, title: "세션",
                                                props: ["start": .number(at), "end": .number(at + 3600), "active_seconds": .number(3600)], at: at)
                _ = try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: at)
                _ = try ThemeGraph.attach(taskId: task, to: row.2, tx, now: at)
            }
        }
        return database
    }

    private func page(onScreen: Bool = false, fields: Bool = true) throws -> WKWebView {
        let json = AppState(preview: { $0.phase = .ready }, database: try demoDatabase(fields: fields)).graphJSON()

        let config = WKWebViewConfiguration()
        let ready = Ready(expectation(description: "ready"))
        messages = ready
        config.userContentController.add(ready, name: "wg")
        // Reduced motion: no animation loop in the 2D view, so pixels change only when it is dragged
        config.userContentController.addUserScript(WKUserScript(source: """
            const realMatch = window.matchMedia.bind(window);
            window.matchMedia = q => q.includes('reduced-motion') ? { matches: true, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} } : realMatch(q);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 831, height: 716), configuration: config)   // 기본 창(1180)의 그래프 칸
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        if onScreen { window.alphaValue = 0.02; window.ignoresMouseEvents = true; window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero) }
        else { window.setFrameOrigin(NSPoint(x: -20000, y: -20000)) }
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        let dir = try XCTUnwrap(GraphWebView.graphDirectory())
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir.deletingLastPathComponent())
        wait(for: [ready.done], timeout: 15)
        _ = run(web, "window.WG.setGraph(JSON.parse(data)); return 1", ["data": json])
        settle()
        return web
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

    /// The 3D view draws only on animation frames, which WebKit stops for a window it thinks is hidden (a locked CI screen)
    private func drawn3D(_ web: WKWebView) throws -> (x: Double, y: Double, n: Double, width: Double) {
        for _ in 0..<25 {
            let c = try centroid(web)
            if c.n > 100 { return c }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        // shortcut: CI runners sometimes give no animation frames at all; drop the skip once they do
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "3D 그래프가 5초 안에 그려지지 않음 (애니메이션 프레임 없음)")
        XCTFail("3D 그래프가 그려져야 한다")
        return try centroid(web)
    }

    private func run(_ web: WKWebView, _ js: String, _ arguments: [String: Any] = [:]) -> Any? {
        let done = expectation(description: "js")
        var value: Any?
        web.callAsyncJavaScript(js, arguments: arguments, in: nil, in: .page) { result in
            if case .success(let v) = result { value = v } else if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return value
    }

    private let canvas = "const cv = [...document.querySelectorAll('#main canvas')].sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];"

    /// Centroid (x, y in CSS px) and count of drawn pixels on the graph canvas
    private func centroid(_ web: WKWebView) throws -> (x: Double, y: Double, n: Double, width: Double) {
        let value = run(web, canvas + """
            const g = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data, r = cv.width / cv.clientWidth;
            let sx = 0, sy = 0, n = 0;
            for (let y = 0; y < cv.height; y += 3) for (let x = 0; x < cv.width; x += 3) if (g[(y * cv.width + x) * 4 + 3] > 20) { sx += x; sy += y; n++; }
            return [n ? sx / n / r : 0, n ? sy / n / r : 0, n, cv.clientWidth];
            """) as? [Double]
        let v = try XCTUnwrap(value)
        return (v[0], v[1], v[2], v[3])
    }

    private func drag(_ web: WKWebView, dx: Double, shift: Bool = false) {
        _ = run(web, canvas + """
            const b = cv.getBoundingClientRect(), x0 = b.left + b.width / 2, y0 = b.top + b.height / 2;
            const ev = (type, x) => cv.dispatchEvent(new PointerEvent(type, { clientX: x, clientY: y0, button: 0, buttons: 1, pointerId: 1, bubbles: true, shiftKey: shift }));
            ev('pointerdown', x0);
            for (let i = 1; i <= 12; i++) ev('pointermove', x0 + dx * i / 12);
            ev('pointerup', x0 + dx);
            return 1;
            """, ["dx": dx, "shift": shift])
        settle()
    }

    func testDraggingThe2DGraphMovesItButNotOffScreen() throws {
        let web = try page()
        let start = try centroid(web)
        XCTAssertGreaterThan(start.n, 100, "2D 그래프가 그려져야 한다")
        drag(web, dx: 150)
        let moved = try centroid(web)
        XCTAssertEqual(moved.x - start.x, 150, accuracy: 40, "끈 만큼 옮겨진다")
        drag(web, dx: 6000)
        let far = try centroid(web)
        XCTAssertLessThan(far.x - start.x, start.width * 0.5, "끝없이 밀려 나가지 않는다")
        XCTAssertGreaterThan(far.n, start.n * 0.3, "끝까지 밀어도 그래프가 화면에 남는다")
    }

    // 기간·보기 단추: 오른쪽 여백(34) 안쪽 끝에 붙는다. 상세 카드가 덮으면(--card-inset) 그만큼 더 비키고, 좁아도 잘리지 않는다
    func testFiltersSitAtTheRightEdgeInsideThePadding() throws {
        let web = try page()
        for inset in [0, 389, 480] {
            let box = run(web, """
                document.documentElement.style.setProperty('--card-inset', inset + 'px');
                const v = document.getElementById('viewSec').getBoundingClientRect(), s = document.querySelector('.tsearch').getBoundingClientRect(), t = document.querySelector('.toolbar');
                return [innerWidth - v.right, s.width, t.scrollWidth - t.clientWidth, v.top - s.top];
                """, ["inset": inset]) as? [Double]
            let v = try XCTUnwrap(box)
            XCTAssertEqual(v[0], 34 + Double(inset), accuracy: 2, "보기 단추 오른쪽 끝 = 여백 34 + 카드 (\(inset))")
            XCTAssertGreaterThanOrEqual(v[1], 80, "검색칸은 줄어도 남는다 (\(inset))")
            XCTAssertEqual(v[2], 0, "단추줄이 넘치지 않는다 (\(inset))")
            XCTAssertLessThan(abs(v[3]), 20, "단추는 검색칸과 한 줄 (\(inset))")
        }
    }

    // 2D 에서 업무 점을 진짜 마우스로 누르면(끌기 없이) 앱에 그 업무를 열라고 알린다
    func testClickingATaskIn2DOpensIt() throws {
        let web = try page(onScreen: true)                      // real mouse events need a window on screen
        let found = run(web, canvas + """
            const b = cv.getBoundingClientRect(), tip = document.querySelector('.soltip');
            for (let y = b.top + 8; y < b.bottom - 8; y += 5) for (let x = b.left + 8; x < b.right - 8; x += 5) {
              cv.dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y, bubbles: true }));
              if (cv.style.cursor === 'pointer' && !tip.hidden && tip.textContent.includes('자료')) return [x, y];
            }
            return [];
            """) as? [Double]
        let point = try XCTUnwrap(found)
        XCTAssertEqual(point.count, 2, "업무 점을 찾아야 한다")
        guard point.count == 2, let window = web.window else { return }
        let at = NSPoint(x: point[0], y: web.bounds.height - point[1])
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        settle()
        XCTAssertTrue(messages?.sent.contains("task") == true, "업무를 열라는 메시지: \(messages?.sent ?? [])")
    }

    // 분야를 끄면 업무 종류 맨 위로 묶어 '분야' 자리에 보인다: 그것을 눌러도 그 업무 종류의 상세를 연다
    func testClickingAFieldIn2DOpensItsDetailWhenTasksGroupByType() throws {
        let web = try page(fields: false)
        let hit = run(web, canvas + """
            const b = cv.getBoundingClientRect(), tip = document.querySelector('.soltip');
            for (let y = b.top + 8; y < b.bottom - 8; y += 4) for (let x = b.left + 8; x < b.right - 8; x += 4) {
              cv.dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y, bubbles: true }));
              if (cv.style.cursor === 'pointer' && !tip.hidden && tip.textContent.startsWith('학습분야')) {
                cv.dispatchEvent(new MouseEvent('click', { clientX: x, clientY: y, bubbles: true }));
                return 1;
              }
            }
            return 0;
            """) as? Int
        XCTAssertEqual(hit, 1, "'학습' 분야 점을 찾아야 한다")
        settle()
        XCTAssertTrue(messages?.sent.contains("node TaskType 학습") == true, "업무 종류 상세를 열라는 메시지: \(messages?.sent ?? [])")
    }

    // 앱 전체: 2D 그래프에서 업무 점을 진짜 마우스로 누르면 그 업무의 상세 카드가 열린다
    func testClickingATaskIn2DOpensTheDetailCardInTheApp() throws {
        let state = AppState(preview: { s in s.phase = .ready; s.selectedTab = .graph }, database: try demoDatabase())
        state.refreshTasks()
        let host = NSHostingView(rootView: AnyView(MainWindow().environmentObject(state)))
        host.frame = NSRect(x: 0, y: 0, width: 1180, height: 716)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0.02; window.ignoresMouseEvents = true
        window.setFrameOrigin(NSScreen.main?.visibleFrame.origin ?? .zero)
        window.orderFrontRegardless()
        addTeardownBlock { window.orderOut(nil) }
        func webView(in view: NSView) -> WKWebView? { (view as? WKWebView) ?? view.subviews.lazy.compactMap(webView).first }
        var web: WKWebView?
        for _ in 0..<60 where web == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); web = webView(in: host) }
        let page = try XCTUnwrap(web, "그래프 웹 화면")
        var point: [Double] = []
        for _ in 0..<40 where point.count != 2 {                   // 페이지가 뜨고 그래프 데이터를 받을 때까지
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            point = (run(page, """
                const cv = [...document.querySelectorAll('#main canvas')].sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0], tip = document.querySelector('.soltip');
                if (!cv || !tip) return [];
                const b = cv.getBoundingClientRect();
                for (let y = b.top + 8; y < b.bottom - 8; y += 5) for (let x = b.left + 8; x < b.right - 8; x += 5) {
                  cv.dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y, bubbles: true }));
                  if (cv.style.cursor === 'pointer' && !tip.hidden && tip.textContent.includes('자료')) return [x, y];
                }
                return [];
                """) as? [Double]) ?? []
        }
        XCTAssertEqual(point.count, 2, "업무 점을 찾아야 한다")
        guard point.count == 2 else { return }
        let inWindow = page.convert(NSPoint(x: point[0], y: point[1]), to: nil)      // the web view is flipped: page y grows down
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        settle()
        XCTAssertTrue(state.taskDetailOpen, "상세 카드가 열린다")
        XCTAssertNotNil(state.selectedTaskId)
    }

    // 2D 분야는 3D 분야처럼 흰 속에 분야 색 테두리를 두른 고리다 (업무 종류 고리보다 크다)
    func testFieldsIn2DAreRingsLikeIn3D() throws {
        let web = try page()
        let found = run(web, canvas + """
            const b = cv.getBoundingClientRect(), tip = document.querySelector('.soltip'), r = cv.width / cv.clientWidth;
            const g = cv.getContext('2d').getImageData(0, 0, cv.width, cv.height).data;
            let hits = 0, colored = 0;
            for (let y = b.top + 4; y < b.bottom - 4; y += 3) for (let x = b.left + 4; x < b.right - 4; x += 3) {
              cv.dispatchEvent(new PointerEvent('pointermove', { clientX: x, clientY: y, bubbles: true }));
              if (tip.hidden || !/분야업무 \\d+개/.test(tip.textContent)) continue;
              hits++;
              const o = (Math.round((y - b.top) * r) * cv.width + Math.round((x - b.left) * r)) * 4;
              if (Math.max(g[o], g[o + 1], g[o + 2]) - Math.min(g[o], g[o + 1], g[o + 2]) > 60) colored++;
            }
            return [hits, colored];
            """) as? [Double]
        let v = try XCTUnwrap(found)
        XCTAssertGreaterThan(v[0], 0, "분야 점을 찾아야 한다")
        XCTAssertLessThan(v[1] / max(v[0], 1), 0.4, "분야 속은 흰색이고 테두리만 분야 색이다 (\(v[1]) / \(v[0]))")
    }

    func testShiftDraggingThe3DGraphStopsAtAnEdge() throws {
        let web = try page(onScreen: true)
        _ = run(web, "document.querySelector('[data-mode=\"cosmos\"]').click(); return 1")
        let start = try drawn3D(web)
        drag(web, dx: 6000, shift: true)
        let far = try centroid(web)
        XCTAssertLessThan(far.x - start.x, start.width * 0.5, "끝없이 밀려 나가지 않는다")
        XCTAssertGreaterThan(far.n, start.n * 0.3, "끝까지 밀어도 그래프가 화면에 남는다")
    }
}
