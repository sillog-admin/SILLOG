import XCTest
@testable import SillogCore

final class ResumePlannerTests: XCTestCase {
    private var db: SillogDatabase!
    private let home = "/Users/me"
    private var existing: Set<String> = []

    override func setUpWithError() throws {
        db = try SillogDatabase.inMemory()
        existing = ["/Users/me/Desktop/study/기학기/실습환경/[0922]lab.ipynb", "/Users/me/Desktop/study/기학기/[0922]Regression.pdf",
                    "/Users/me/Desktop/study/기학기/실습환경", "/Users/me/Desktop/study/기학기/[0922]Regression.pdf.png"]
    }

    /// 기학기 공부 세션: VS Code 로 노트북, 미리보기로 강의자료 PDF, Chrome 으로 강의 사이트 두 페이지, Discord 잠깐
    private func seedStudySession(at start: Double = 1_000) throws -> (task: GraphNode, session: GraphNode) {
        try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_study", subtype: nil, title: "기학기 실습 공부", props: [:], at: start)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s_t_study_\(Int(start))", subtype: nil, title: "회귀분석 실습을 했다",
                                            props: ["start": .number(start), "end": .number(start + 1_800)], at: start)
            try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: start)
            let code = try tx.upsertNode(label: NodeLabel.app, key: "com.microsoft.VSCode", subtype: nil, title: "Code", props: [:], at: start)
            let chrome = try tx.upsertNode(label: NodeLabel.app, key: "com.google.Chrome", subtype: nil, title: "Google Chrome", props: [:], at: start)
            let preview = try tx.upsertNode(label: NodeLabel.app, key: "com.apple.Preview", subtype: nil, title: "미리보기", props: [:], at: start)
            let discord = try tx.upsertNode(label: NodeLabel.app, key: "com.hnc.Discord", subtype: nil, title: "Discord", props: [:], at: start)
            let wg = try tx.upsertNode(label: NodeLabel.app, key: "com.sillog.app", subtype: nil, title: "Sillog", props: [:], at: start)
            for (app, seconds) in [(code, 900.0), (chrome, 300.0), (preview, 400.0), (discord, 20.0), (wg, 500.0)] {
                try tx.upsertEdge(src: session, dst: app, type: EdgeType.used, props: [:], addWeight: seconds, at: start)
            }
            let project = try tx.upsertNode(label: NodeLabel.project, key: "file:~/Desktop/study/기학기/실습환경", subtype: nil, title: "실습환경", props: [:], at: start)
            let notebook = try tx.upsertNode(label: NodeLabel.resource, key: "file:~/Desktop/study/기학기/실습환경/[0922]lab.ipynb", subtype: "CodeFile", title: "[0922]lab.ipynb", props: [:], at: start)
            try tx.upsertEdge(src: notebook, dst: project, type: EdgeType.belongsTo, props: [:], addWeight: 0, at: start)
            let pdf = try tx.upsertNode(label: NodeLabel.resource, key: "file:~/Desktop/study/기학기/[0922]Regression.pdf", subtype: "Document", title: "[0922]Regression.pdf", props: [:], at: start)
            let gone = try tx.upsertNode(label: NodeLabel.resource, key: "file:~/Downloads/deleted.pdf", subtype: "Document", title: "deleted.pdf", props: [:], at: start)
            let lmsPage = try tx.upsertNode(label: NodeLabel.resource, key: "https://lms.example.com/ultra/courses/_12345_1/outline", subtype: "WebPage", title: "기계학습기초", props: [:], at: start)
            let glance = try tx.upsertNode(label: NodeLabel.resource, key: "https://example.com/quick", subtype: "WebPage", title: "잠깐 본 페이지", props: [:], at: start)
            let search = try tx.upsertNode(label: NodeLabel.resource, key: "https://google.com/search?q=regression", subtype: "WebPage", title: "regression - Google 검색", props: [:], at: start)
            let login = try tx.upsertNode(label: NodeLabel.resource, key: "https://console.typesafe.ai/login?error=signups_disabled", subtype: "WebPage", title: "TypeSafe", props: [:], at: start)
            let glimpse = try tx.upsertNode(label: NodeLabel.resource, key: "file:~/Desktop/study/기학기/[0922]Regression.pdf.png", subtype: "Design", title: "잠깐 본 그림", props: [:], at: start)
            // 마지막으로 만진 시각: 노트북·PDF 는 끝 무렵, 강의 사이트는 초반
            for (resource, seconds, at) in [(notebook, 900.0, start + 1_790), (pdf, 400.0, start + 1_700), (gone, 100.0, start + 1_750), (lmsPage, 200.0, start + 300),
                                            (glance, 3.0, start + 100), (search, 120.0, start + 1_600), (login, 90.0, start + 1_500), (glimpse, 5.0, start + 1_780)] {
                try tx.upsertEdge(src: session, dst: resource, type: EdgeType.touched, props: [:], addWeight: seconds, at: at)
            }
            return (try tx.node(id: task)!, try tx.node(id: session)!)
        }
    }

    func testSessionPlanOpensProjectFilesPagesInTheAppsUsed() throws {
        let (_, session) = try seedStudySession()
        let plan = try db.writer.read { try ResumePlanner.plan(session: session, tx: GraphTx($0), home: self.home, fileExists: { self.existing.contains($0) }) }
        XCTAssertEqual(plan.title, "회귀분석 실습을 했다")
        let ids = plan.items.map(\.id)
        // 켜진 것이 앞에 (마지막에 하던 노트북·PDF 와 그 프로젝트 폴더), 나머지는 뒤에 꺼진 채로
        XCTAssertEqual(ids, [
            "folder:/Users/me/Desktop/study/기학기/실습환경",
            "file:/Users/me/Desktop/study/기학기/실습환경/[0922]lab.ipynb",
            "file:/Users/me/Desktop/study/기학기/[0922]Regression.pdf",
            "url:https://lms.example.com/ultra/courses/_12345_1/outline",
            "app:com.apple.Preview",
        ])
        XCTAssertEqual(plan.items.map(\.selected), [true, true, true, false, false], "끝나기 10분 안에 만진 것만 기본으로 켠다")
        XCTAssertEqual(plan.items[0].appBundle, "com.microsoft.VSCode", "프로젝트 폴더는 그때 쓴 편집기로")
        XCTAssertEqual(plan.items[1].appBundle, "com.microsoft.VSCode")
        XCTAssertNil(plan.items[2].appBundle, "PDF 는 기본 앱으로")
        XCTAssertEqual(plan.items[3].appBundle, "com.google.Chrome", "웹페이지는 그때 쓴 브라우저로")
        // 지워진 파일, 3초 본 페이지, 검색 결과·로그인 페이지, 5초 본 그림, 20초 쓴 Discord, Sillog 자신은 없다
        XCTAssertFalse(ids.contains { $0.contains("deleted.pdf") || $0.contains("quick") || $0.contains("google.com") || $0.contains("login") || $0.contains(".png") || $0.contains("Discord") || $0.contains("sillog") })
    }

    func testTaskPlanMergesRecentSessions() throws {
        let (task, _) = try seedStudySession(at: 1_000)
        _ = try seedStudySession(at: 10_000)                                   // 같은 업무의 두 번째 세션 (같은 자료)
        let plan = try db.writer.read { try ResumePlanner.plan(task: task, tx: GraphTx($0), home: self.home, fileExists: { self.existing.contains($0) }) }
        XCTAssertEqual(plan.title, "기학기 실습 공부")
        XCTAssertEqual(plan.items.filter { $0.kind == .file }.count, 2, "같은 파일은 한 번만")
        XCTAssertEqual(plan.items.first { $0.kind == .file }?.seconds, 1_800, "머문 시간은 합산")
        XCTAssertEqual(plan.items.filter(\.selected).map(\.kind), [.folder, .file, .file], "업무 단위도 마지막 세션의 마지막 것만 켠다")
    }

    func testNothingRecentMeansOnlyAppsAreOfferedButStillOffered() throws {
        let start = 1_000.0
        let session: GraphNode = try db.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "t_chat", subtype: nil, title: "메신저 확인", props: [:], at: start)
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s_chat", subtype: nil, title: "Discord 확인", props: ["start": .number(start), "end": .number(start + 300)], at: start)
            try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: start)
            let discord = try tx.upsertNode(label: NodeLabel.app, key: "com.hnc.Discord", subtype: nil, title: "Discord", props: [:], at: start)
            try tx.upsertEdge(src: session, dst: discord, type: EdgeType.used, props: [:], addWeight: 240, at: start + 290)
            return try tx.node(id: session)!
        }
        let plan = try db.writer.read { try ResumePlanner.plan(session: session, tx: GraphTx($0), home: self.home, fileExists: { _ in false }) }
        XCTAssertEqual(plan.items.map(\.id), ["app:com.hnc.Discord"])
        XCTAssertTrue(plan.items[0].selected, "파일·페이지가 없으면 그때 쓴 앱을 켠다")
    }
}
