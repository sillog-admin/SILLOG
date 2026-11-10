import SwiftUI
import WorkGraphCollectors
import WorkGraphCore

/// 스냅샷으로 그릴 화면 목록. 이름은 Figma 화면 번호를 따른다 (Figma 에서 내보낸 같은 이름의 PNG 와 나란히 본다)
@MainActor
enum SnapshotCatalog {
    static var all: [Snapshot] { menus + windows + activity + chat + library + storage + [mathAnswer] + recording }

    /// Figma 창(760) 에서 제목 줄(44)을 뺀 내용 영역
    static let window = CGSize(width: 1180, height: 716)

    static var menus: [Snapshot] {
        [
            shot("OUT-W2", MenuBarView()) { s in s.phase = .login },
            shot("OUT-W7", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(paused: true)
                s.todayCount = 8; s.pendingCount = 2; s.lastBatchText = "14:05 정리 완료(새 업무 2개, 자료 5개)"
            },
            shot("OUT-W6", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(accessibility: false)
                s.todayCount = 8; s.pendingCount = 2; s.lastBatchText = "14:05 정리 완료(새 업무 1개, 자료 3개)"
            },
            shot("OUT-06", MenuBarView()) { s in
                s.phase = .ready; s.status = collector()
                s.todayCount = 62; s.pendingCount = 6; s.notificationsDenied = true
                s.fileSuggestions = pendingFiles(2); s.taskList = recentTasks
            },
            // 리뷰 포커스 4: 큰 숫자와 긴 업무 이름
            shot("OUT-06-long", MenuBarView()) { s in
                s.phase = .ready; s.status = collector()
                s.todayCount = 1234; s.pendingCount = 0
                s.taskList = [TaskSummary(id: 9, key: "long", title: "아주 긴 업무 이름이 메뉴 폭을 넘어가면 한 줄로 잘려야 하는지 보는 업무",
                                          taskType: nil, activeSeconds: 60, lastActive: todayAt(9, 5), sessionCount: 1)]
            },
        ]
    }

    /// 녹음: 메뉴 막대(녹음 중, 받아쓰는 중, 마이크 권한 꺼짐), 보관함 녹음 상세, 보관함 목록
    static var recording: [Snapshot] {
        let menuShots = [
            shot("REC-01", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(); s.todayCount = 62; s.pendingCount = 6; s.taskList = recentTasks
                s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751)
            },
            shot("REC-02", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(); s.todayCount = 62; s.pendingCount = 6; s.taskList = recentTasks
                s.recordingWork = .transcribing(0.37)
            },
            shot("REC-03", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(); s.todayCount = 62; s.pendingCount = 6
                s.recordingProblem = .microphone
            },
            // 리뷰 포커스 1: 일시정지돼도 녹음은 따로 돈다 (W7 메뉴 + 녹음 중 줄)
            shot("REC-06", MenuBarView()) { s in
                s.phase = .ready; s.status = collector(paused: true)
                s.todayCount = 8; s.pendingCount = 2; s.lastBatchText = "14:05 정리 완료(새 업무 2개, 자료 5개)"
                s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751)
            },
            // 리뷰 포커스 1: 로그인 전(W2)에도 녹음 중이면 끝내기 줄만 보인다 (시작 버튼은 없다)
            shot("REC-07", MenuBarView()) { s in
                s.phase = .login
                s.activeRecording = ActiveRecording(id: 1, startedAt: Date().timeIntervalSince1970 - 751)
            },
        ]
        return menuShots + [recordingDetailShot()] + [recordingLibraryShot()].compactMap { $0 }
    }

    static var windows: [Snapshot] {
        [
            shot("OUT-01", MainWindow(), size: window) { s in loginStep(s) },
            shot("OUT-02", MainWindow(), size: window) { s in loginStep(s); s.deviceCode = sampleCode },
            shot("OUT-02-signed-in", MainWindow(), size: window) { s in
                loginStep(s); s.phase = .permissions
                s.codexStatus = .loggedIn(email: "sillog@example.com", plan: nil, expiresAt: nil)
            },
            shot("OUT-03", MainWindow(), size: window) { s in permissionStep(s, PermissionGrants(accessibility: false, screenRecording: false)) },
            shot("OUT-04", MainWindow(), size: window) { s in permissionStep(s, PermissionGrants(accessibility: true, screenRecording: false)) },
            shot("OUT-05", MainWindow(), size: window) { s in
                permissionStep(s, PermissionGrants(accessibility: true, screenRecording: true)); s.askedScreenRecording = true
            },
            shot("OUT-W1", MainWindow(), size: window) { s in s.phase = .login; s.loginBlocked = true },
            shot("OUT-W3", MainWindow(), size: window) { s in s.startupError = AppState.alreadyRunningMessage },
            shot("OUT-W4", MainWindow(), size: window) { s in s.bootstrapped = false },
            // 왼쪽 아이콘 줄 옆에 늘 열린 업무 목록(분야 폴더 안에 업무), 본문은 기록 자료의 파일
            shot("TK-01", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.selectedTab = .records; s.taskList = themedTasks
            },
            // 업무를 누르면(목록이든 그래프든) 업무 드로어의 상세가 목록 오른쪽으로 펼쳐지고 본문은 오른쪽으로 밀려 좁아진다 (×, Esc 로 접는다)
            // 기본 창(1180)에서는 상세가 375 로 줄어 단추가 이름 아래 줄로, 넓은 창에서는 460 에 나란히
            shot("TK-02", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.selectedTab = .graph; s.taskList = recentTasks
                s.selectedTaskId = 1; s.taskDetailOpen = true
            },
            shot("TK-02-WIDE", MainWindow(), size: CGSize(width: 1500, height: 900)) { s in
                s.phase = .ready; s.status = collector(); s.selectedTab = .graph; s.taskList = recentTasks
                s.selectedTaskId = 1; s.taskDetailOpen = true
            },
            shot("OUT-W5", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.batchRunning = true; s.pendingCount = 6
                s.fileSuggestions = pendingFiles(2); s.taskList = recentTasks; s.selectedTab = .records
            },
            // 기록 자료 > 지난 기록 탭: 20줄씩 쪽으로 나눠 ‹ 1 2 3 › (45개 중 2쪽을 보는 중)
            shot("FL-PAGES", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.taskList = recentTasks; s.selectedTab = .records; s.recordsSection = .history
                s.fileSuggestions = decidedFiles(3); s.fileHistoryTotal = 45; s.fileHistoryPage = 1
            },
            // 설정: 위쪽 글자 탭(일반, AI 연결). 일반은 권한 타일, 수집, 기록하지 않을 앱, 저장 공간, 앱 실행을 한 쪽에
            shot("ST-GENERAL", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(accessibility: true, screenRecording: false); s.taskList = recentTasks
                s.selectedTab = .settings; s.settingsSection = .general
            },
            shot("ST-AI", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.taskList = recentTasks
                s.selectedTab = .settings; s.settingsSection = .ai
            },
            shot("ST-AI-usage", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.selectedTab = .settings; s.settingsSection = .ai
                s.codexStatus = .loggedIn(email: "sillog@example.com", plan: "plus", expiresAt: nil)
                let now = Date().timeIntervalSince1970
                s.codexUsage = .init(planType: "plus", primary: .init(usedPercent: 28, windowSeconds: 18_000, resetAt: now + 3_600),
                                     secondary: .init(usedPercent: 57, windowSeconds: 604_800, resetAt: now + 86_400))
                let models = [CodexModel(slug: "demo-judge", displayName: "GPT 판단 모델", defaultEffort: nil),
                              CodexModel(slug: "demo-organize", displayName: "GPT 정리 모델", defaultEffort: nil),
                              CodexModel(slug: "demo-chat", displayName: "GPT 채팅 모델", defaultEffort: nil)]
                s.codexModels = models; s.chatCodexModels = models
                s.settings.judgeCodexModel = "demo-judge"; s.settings.codexModel = "demo-organize"
                s.settings.chatSameAsOrganize = false; s.settings.chatCodexModel = "demo-chat"
            },
            shot("ST-AI-CHECK-SUCCESS", MainWindow(), size: window) { s in
                s.phase = .ready; s.selectedTab = .settings; s.settingsSection = .ai
                s.codexStatus = .loggedIn(email: "sillog@example.com", plan: "plus", expiresAt: nil)
                s.llmTestResult = "연결됨 · 정리 모델 응답 확인"
                s.chatTestResult = "연결됨 · 응답과 도구 호출 확인"
            },
            shot("ST-AI-CHECK-FAILURE", MainWindow(), size: window) { s in
                s.phase = .ready; s.selectedTab = .settings; s.settingsSection = .ai
                s.codexStatus = .loggedIn(email: "sillog@example.com", plan: "plus", expiresAt: nil)
                s.llmTestResult = "연결됨 · 정리 모델 응답 확인"
                s.chatTestResult = "채팅 모델 연결 확인 시간이 초과되었습니다."
            },
            shot("ST-AI-CHECK-RUNNING", MainWindow(), size: window) { s in
                s.phase = .ready; s.selectedTab = .settings; s.settingsSection = .ai
                s.codexStatus = .loggedIn(email: "sillog@example.com", plan: "plus", expiresAt: nil)
                s.llmTestResult = "확인 중…"
            },
            shot("ST-AI-FAIL", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.taskList = recentTasks
                s.settings.llmProvider = "openai"; s.settings.chatProvider = "openai"
                s.llmTestResult = "서버에 연결할 수 없습니다. 서버가 켜져 있는지 확인하세요."
                s.selectedTab = .settings; s.settingsSection = .ai
            },
            // 설정의 활동 로그: 대기와 정리 묶음을 한 줄기로
            shot("LG-01", MainWindow(), size: window) { s in
                s.phase = .ready; s.status = collector(); s.taskList = recentTasks
                s.selectedTab = .settings; s.settingsSection = .activity
            },
        ]
    }

    /// 활동 로그 정리 기록: 정리 40번이 쌓인 표와 아래에 고정된 LLM 교환 카드 (보낸 내용, 받은 응답, 실패)
    static var activity: [Snapshot] {
        [
            batchShot("LG-W3", ActivityLogView(section: .batches)),
            batchShot("LG-W4", ActivityLogView(section: .batches, showReceived: true)),
            batchShot("LG-W7", ActivityLogView(section: .batches), failedFirst: true),
        ]
    }

    /// 채팅 답의 수식: 블록 행렬(\text{①}, \qquad), 글줄 수식, \text 안 한글, 분수
    static var mathAnswer: Snapshot {
        let answer = #"""
        두 행렬을 비교하면 이렇습니다.

        \[
        \text{① }\begin{pmatrix}1&0\\0&1\end{pmatrix}\qquad\text{② }\begin{pmatrix}1&1\\1&1\end{pmatrix}
        \]

        ①은 항등행렬이라 $\det = 1$ 이고, ②는 $\det = 1\cdot1 - 1\cdot1 = 0$ 이라 역행렬이 없어요. 넓이는 \(\text{넓이} = \frac{1}{2}ab\) 로 구해요.

        $$\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$$
        """#
        let view = ChatMessageText(text: answer, sources: [], onSource: { _ in }).frame(width: 640).padding(24).background(Color.white)
        return Snapshot(name: "CH-math", size: CGSize(width: 688, height: 420), view: AnyView(view.environmentObject(AppState(preview: { _ in }))))
    }

    /// 기록 자료 보관함: 홈과 종류별 화면 (Figma LB-25, 04, 06, 16, 17, 18). 내 보관함과 같은 개수(결과물 2, 녹음 7)로 그린다
    static var library: [Snapshot] {
        guard let database = try? WGDatabase.inMemory() else { return [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sillog-lb-snapshot", isDirectory: true)
        let store = LibraryStore(database, directory: dir)
        let state = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .records
            let now = Date().timeIntervalSince1970
            for var r in [
                Recording(id: 7, startedAt: now - 3_600, endedAt: now - 3_597, duration: 3, audioPath: "", status: .failed),
                Recording(id: 6, startedAt: now - 3_700, endedAt: now - 3_700, duration: 0, audioPath: "", status: .failed),
                Recording(id: 5, startedAt: now - 3_800, endedAt: now - 3_800, duration: 0, audioPath: "", status: .failed),
                Recording(id: 4, startedAt: now - 86_400, endedAt: now - 86_394, duration: 6, audioPath: "", title: "마켓 산업 전반의 베이스라인 모델", transcript: "내용", status: .ready),
                Recording(id: 3, startedAt: now - 90_000, endedAt: now - 89_939, duration: 61, audioPath: "", title: "여러 개에 관한 짧은 메모", transcript: "내용", status: .ready),
                Recording(id: 2, startedAt: now - 3 * 86_400, endedAt: now - 3 * 86_400 + 11, duration: 11, audioPath: "", title: "녹음 연습", transcript: "내용", status: .ready),
                Recording(id: 1, startedAt: now - 4 * 86_400, endedAt: now - 4 * 86_400 + 13, duration: 13, audioPath: "", status: .ready),
            ] { r.id = nil; _ = try? RecordingStore(database).insert(r) }
        }, database: database)
        let library = LibraryState(db: database)
        var one = ChatLibraryItem(title: "실록 정리본", filename: "실록 정리본.html", kind: "generated"); one.createdAt = Date().timeIntervalSince1970 - 27 * 86_400
        var two = ChatLibraryItem(title: "실록 — 2026.09.28", filename: "실록 — 2026.09.28.html", kind: "generated"); two.createdAt = one.createdAt
        library.items = [one, two]
        for item in library.items {
            let url = LibraryStore(database, directory: dir).url(for: item)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "<h1>\(item.title)</h1><p>정리한 내용입니다.</p>".write(to: url, atomically: true, encoding: .utf8)
        }
        _ = store
        // 업로드와 저장한 답변은 내 보관함에 0개라 목록 모양을 볼 예시를 따로 둔다 (Figma LB-16, LB-18)
        let filled = LibraryState(db: database)
        let day = 86_400.0, now = Date().timeIntervalSince1970
        func make(_ title: String, _ file: String, _ kind: String, _ ago: Double, _ body: String) -> ChatLibraryItem {
            var item = ChatLibraryItem(title: title, filename: file, kind: kind); item.createdAt = now - ago * day
            let url = filled.store.url(for: item)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            return item
        }
        filled.items = [make("경제사 기말 범위.pdf", "경제사 기말 범위.pdf", "upload", 4, "x"), make("기획 회의록.docx", "기획 회의록.docx", "upload", 11, "x"),
                        make("경제사 기말 범위 정리", "정리.md", "note", 2, "# 경제사 기말 범위 정리\n산업혁명과 대공황의 원인을 정리한 답변입니다."),
                        make("AI리터러시 오답 정리", "오답.md", "note", 5, "프롬프트 작성 오답을 모은 답변입니다.")]
        let sample = [libraryHomeSample(name: "LB-home-few", counts: (7, 2, 2, 3), fieldShares: [3, 2, 4, 0, 1, 4], spanDays: 28, fixedDates: true),
                      libraryHomeSample(name: "LB-home-many", counts: (642, 187, 96, 359), fieldShares: [412, 286, 233, 118, 147, 88], spanDays: 390)]
        return sample + ["home", "", "recording", "upload", "generated", "note"].map { kind in
            Snapshot(name: "LB-\(kind.isEmpty ? "all" : kind)", size: window, view: AnyView(LibraryView(library: library, initialKind: kind).environmentObject(state)))
        } + ["upload", "note"].map { kind in
            Snapshot(name: "LB-\(kind)-data", size: window, view: AnyView(LibraryView(library: filled, initialKind: kind).environmentObject(state)))
        }
    }

    /// 보관함 홈 예시 (Figma LB-25, LB-26): 스냅샷 전용 가짜 자료. 분야는 업무 6개와 대화 초점으로 나눈다
    private static func libraryHomeSample(name: String, counts: (Int, Int, Int, Int), fieldShares: [Int], spanDays: Double, fixedDates: Bool = false) -> Snapshot {
        let fieldNames = ["산출물작성", "정보수집", "학습", "행정처리", "커뮤니케이션", "분야 없음"]
        let tasks = fieldNames.enumerated().map { i, field in
            TaskSummary(id: Int64(i + 1), key: "t\(i + 1)", title: "\(field) 업무", taskType: nil, activeSeconds: 0, lastActive: 0, sessionCount: 0,
                        theme: i == 5 ? nil : field, field: i == 5 ? nil : field)
        }
        let total = max(fieldShares.reduce(0, +), 1)
        var seed: UInt64 = 7
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let now = Date().timeIntervalSince1970
        // 앞쪽(오래된 쪽)은 드물고 최근으로 갈수록 많이 쌓인다. 가장 새 항목은 이틀 전
        func ago() -> Double { (spanDays * (1 - random().squareRoot()) + 1) * 86_400 }
        // 비율대로 정확히 나누도록 분야 칸을 펴서 섞어 둔다
        var pool = fieldShares.enumerated().flatMap { Array(repeating: $0.offset, count: $0.element) }
        for i in stride(from: pool.count - 1, to: 0, by: -1) { pool.swapAt(i, Int(random() * Double(i + 1))) }
        func fieldIndex() -> Int { pool.popLast() ?? 0 }
        // LB-25 날짜: 10/3부터 10/27까지 아홉 건, 나머지 다섯 건은 10/30 (가장 새 것 14:18)
        var made = 0
        func created() -> Double {
            defer { made += 1 }
            guard fixedDates else { return now - ago() }
            let cal = Calendar.current
            let day = made < 9 ? DateComponents(year: 2026, month: 10, day: 3 + made * 3, hour: 10)
                               : DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 18 - (13 - made) * 7)
            return cal.date(from: day)?.timeIntervalSince1970 ?? now
        }
        guard let database = try? WGDatabase.inMemory() else { return Snapshot(name: name, size: window, view: AnyView(EmptyView())) }
        let state = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .records; s.taskList = tasks
            for n in 0..<counts.0 {
                let started = created()
                let tid = Int64(fieldIndex() + 1)
                // fixedDates: 받아쓰기 완료 2, 내용 없음 2, 실패 3, 총 1분 34초 (Figma LB-25)
                let few = fixedDates
                let dur = few ? [30.0, 24, 20, 20, 0, 0, 0][n % 7] : (n % 9 == 0 ? 0 : Double(10 + n % 50))
                let empty = few ? (n == 2 || n == 3) : n % 14 == 0
                let fail = few ? n >= 4 : n % 25 == 0
                var r = Recording(startedAt: started, endedAt: started + 20, duration: dur, audioPath: "",
                                  title: "녹음 \(n + 1)", transcript: empty || fail ? "" : "내용", status: fail ? .failed : .ready, taskId: tid)
                _ = try? RecordingStore(database).insert(r)
            }
        }, database: database)
        let library = LibraryState(db: database)
        var items: [ChatLibraryItem] = []
        for (kind, n) in [("upload", counts.1), ("generated", counts.2), ("note", counts.3)] {
            for k in 0..<n {
                var item = ChatLibraryItem(title: "\(LibraryLook.name(kind)) \(k + 1)", filename: kind == "note" ? "답변\(k).md" : "자료\(k).\(kind == "upload" ? "pdf" : "html")", kind: kind)
                item.createdAt = created()
                library.itemFocuses[item.id] = [ChatFocus(kind: .task, key: "t\(fieldIndex() + 1)", title: "")]
                items.append(item)
            }
        }
        library.items = items
        return Snapshot(name: name, size: window, view: AnyView(LibraryView(library: library, initialKind: "home").environmentObject(state)))
    }

    /// 채팅: 머리의 모델 칩 (누르면 그 자리에서 채팅 모델을 고른다)
    static var chat: [Snapshot] {
        guard let database = try? WGDatabase.inMemory() else { return [] }
        let state = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .chat
            s.settings.chatProvider = "codex"; s.settings.chatCodexModel = "gpt-6-luna"; s.settings.chatSameAsOrganize = false
            s.codexStatus = .loggedIn(email: nil, plan: "plus", expiresAt: nil)
            s.chatCodexModels = [CodexModel(slug: "gpt-6-luna", displayName: "GPT-6 Luna", defaultEffort: nil),
                                 CodexModel(slug: "gpt-6", displayName: "GPT-6", defaultEffort: nil)]
            let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)   // 그리기만 하고 부르지 않는다
            s.chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        })
        let tab = { (section: CustomizeSection) -> AppState in
            AppState(preview: { s in
                s.phase = .ready; s.status = collector(); s.selectedTab = .connectors; s.customizeSection = section
                s.chat = state.chat
            })
        }
        return [Snapshot(name: "CH-01", size: window, view: AnyView(MainWindow().environmentObject(state))),
                Snapshot(name: "CH-SKILL-PINS", size: nil, view: AnyView(PinnedSkillPicker(chat: state.chat!, onManage: {}).background(.white))),
                Snapshot(name: "CH-13", size: window, view: AnyView(MainWindow().environmentObject(tab(.connectors)))),
                Snapshot(name: "CH-59", size: window, view: AnyView(MainWindow().environmentObject(tab(.skills))))] + chatFocus
    }

    /// 채팅 범위: 업무 하나로 좁힌 대화(정리 전 기록 안내 포함)와 범위 고르기 창
    private static var chatFocus: [Snapshot] {
        guard let database = try? WGDatabase.inMemory() else { return [] }
        try? database.writer.write { conn in
            let tx = GraphTx(conn)
            for (index, (key, title, theme)) in [("flask", "Flask 웹앱 개발", "프로젝트"), ("stats", "통계학 수업", "학업"), ("algebra", "선형대수 과제", "학업")].enumerated() {
                let task = try tx.upsertNode(label: NodeLabel.task, key: key, subtype: nil, title: title,
                                             props: ["last_active": .number(Double(300 - index))], at: 1)
                try ThemeGraph.attach(taskId: task, to: theme, tx, now: 1)
                let session = try tx.upsertNode(label: NodeLabel.session, key: "\(key)-s", subtype: nil, title: title, props: [:], at: 1)
                try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: 1)
            }
        }
        let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)   // 그리기만 하고 부르지 않는다
        let chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        chat.newConversation(focus: [ChatFocus(kind: .task, key: "flask", title: "Flask 웹앱 개발"), ChatFocus(kind: .theme, key: "학업", title: "학업")])
        let state = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .chat; s.pendingCount = 12
            s.settings.chatProvider = "codex"; s.settings.chatCodexModel = "gpt-6-luna"
            s.chat = chat
        })
        // 대화를 시작하면 범위는 제목 아래(모델 칩 옆)에 작게
        var started = ChatConversation(); started.title = "이번 주 학업 정리"
        started.scope.focus = [ChatFocus(kind: .theme, key: "학업", title: "학업")]
        try? ChatStore(database).startTurn(conversation: started, user: ConversationMessage(conversationID: started.id, role: "user", text: "이번 주 학업 진행 상황 정리해 줘"),
                                           answer: ConversationMessage(conversationID: started.id, role: "assistant", text: "이번 주에는 통계학 수업과 선형대수 과제를 진행했어요."))
        let talking = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
        let talkingState = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .chat
            s.settings.chatProvider = "codex"; s.settings.chatCodexModel = "gpt-6-luna"
            s.chat = talking
        })
        return [
            Snapshot(name: "CH-FOCUS", size: window, view: AnyView(MainWindow().environmentObject(state))),
            Snapshot(name: "CH-FOCUS-HEADER", size: window, view: AnyView(MainWindow().environmentObject(talkingState))),
            Snapshot(name: "CH-FOCUS-PICKER", size: nil, view: AnyView(ChatFocusPicker(chat: chat).background(.white).environmentObject(state))),
        ]
    }

    /// 저장 공간 설정(기본·항목별 보관일 펼침), 첫 정리 동의 시트, 업무 요약 탭
    static var storage: [Snapshot] {
        [
            shot("ST-STORAGE", SettingsView(), size: window) { s in storageState(s); s.settingsSection = .general },
            shot("ST-STORAGE-ADVANCED", ScrollView { StorageSettingsView(advanced: true).padding(.horizontal, 34).padding(.bottom, 40) }.background(.white),
                 size: CGSize(width: 946, height: 1500)) { s in storageState(s) },
            shot("ST-CLEANUP-CONSENT", CleanupPreviewSheet(preview: sampleCleanup)) { s in storageState(s) },
            digestShot("TK-DIGEST"),
            materialsShot("TK-MATERIALS"),
        ]
    }

    private static func storageState(_ s: AppState) {
        s.phase = .ready; s.status = collector()
        var usage = StorageUsage()
        usage.bytes = [.screenshots: 38_400_000, .screenText: 15_600_000, .batchLog: 6_000_000, .screenCards: 700_000, .observations: 668_000,
                       .graph: 582_000, .other: 152_000, .aiRequests: 135_000, .chatLibrary: 123_000, .digests: 49_000]
        usage.dailyGrowth = [.screenText: 520_000, .batchLog: 200_000, .observations: 22_000, .screenCards: 23_000, .graph: 19_000]
        usage.measuredWithDBStat = true
        s.storageUsage = usage
        s.retention = .standard
        var report = Consolidator.Report(startedAt: todayAt(3, 12))
        report.finishedAt = todayAt(3, 13); report.weekly = 3; report.prunedDays = 2; report.reclaimedBytes = 8_400_000
        s.consolidationReport = report
        s.rawRecordsSince = "2026-09-08"
        s.pruneConsented = true
        s.taskList = recentTasks
        s.retentionPins = [RetentionPin(id: 1, kind: .task, key: "report", createdAt: 0), RetentionPin(id: 2, kind: .period, key: "2026-09-15..2026-09-15", createdAt: 0)]
    }

    private static var sampleCleanup: CleanupPreview {
        var plan = PrunePlan()
        plan.days = [.init(day: "2026-09-01", categories: [.batchLog, .screenText]), .init(day: "2026-09-02", categories: [.batchLog, .screenText])]
        plan.counts = [.screenText: 1_234, .batchLog: 96]
        plan.estimatedBytes = 9_800_000
        plan.consentNeeded = true
        plan.blockedReason = "2026-W37 주는 요약 확인 뒤 유예 기간(7일) 중이에요"
        plan.keptReasons = ["2026-W35 주 'Flask 웹앱 개발' 요약이 검증을 통과하지 못해 이 주 원문은 남겨 뒀어요. 업무 탭 요약의 '고치기'에서 확인하고 저장하면 유예 기간 뒤 정리돼요"]
        return CleanupPreview(plan: plan, digests: Array(sampleDigests.prefix(2)), consentNeeded: true)
    }

    private static var sampleDigests: [Digest] {
        func digest(_ id: Int64, _ level: PeriodCalendar.Level, _ period: String, _ status: Digest.Status, _ content: DigestContent, seconds: Double) -> Digest {
            var metrics = DigestMetrics()
            metrics.activeSeconds = seconds; metrics.sessions = 4; metrics.aiRequests = 6
            metrics.resources = [.init(key: "https://flask.palletsprojects.com/quickstart/", title: "Flask 공식 문서", seconds: 2_400),
                                 .init(key: "file:~/flask/app.py", title: "app.py", seconds: 5_100)]
            let range = PeriodCalendar().period(id: period)
            return Digest(id: id, level: level, period: period, periodStart: range?.start ?? 0, periodEnd: range?.end ?? 0, tz: TimeZone.current.identifier,
                          taskKey: "flask", title: Digest.title(level: level, task: "Flask 웹앱 개발", period: period),
                          body: DigestRenderer.body(content, metrics: metrics), content: content, metrics: metrics, anchors: ["flask"],
                          status: status, model: status == .verified ? "gpt-6-luna" : nil, promptVersion: DigestPrompt.version, inputHash: "preview",
                          attempts: status == .draft ? DigestBuilder.maxAttempts : 0, createdAt: 0, verifiedAt: status == .draft ? nil : 0)
        }
        return [
            digest(3, .week, "2026-W39", .verified, DigestContent(
                summary: "로그인 흐름을 Flask 세션으로 옮기고 회원가입 폼 검증을 붙였다. 배포 설정은 아직 손대지 않았다.",
                progress: [.init(text: "로그인 오류(세션 만료)를 해결했다.", status: "evidenced", anchors: ["flask"]),
                           .init(text: "회원가입 폼 검증을 작성하는 중이다.", status: "in_progress", anchors: ["flask"]),
                           .init(text: "비밀번호 재설정 메일 구현을 AI에게 요청했다.", status: "requested", anchors: ["flask"])],
                problems: [.init(text: "세션 쿠키가 저장되지 않음", state: "resolved", anchors: ["flask"])],
                openItems: [.init(text: "배포용 환경 변수 정리", anchors: ["flask"])]), seconds: 9_600),
            digest(2, .week, "2026-W38", .draft, DigestContent(
                summary: "Flask 웹앱 개발 업무 기록이 약 1시간 10분 있습니다. 로그인 페이지 레이아웃을 손봤다.",
                progress: [.init(text: "로그인 페이지 레이아웃을 손봤다.", status: "in_progress", anchors: ["flask"]),
                           .init(text: "Flask 공식 문서의 세션 설명을 읽었다.", status: "in_progress", anchors: ["flask"])]), seconds: 4_200),
            digest(1, .month, "2026-09", .edited, DigestContent(summary: "9월에는 Flask 웹앱의 인증 흐름을 만들었다. 고친 요약: 발표 전에 배포까지 마치기로 했다."), seconds: 21_000),
        ]
    }

    private static func digestShot(_ name: String) -> Snapshot {
        let database = try? WGDatabase.inMemory()
        var taskId: Int64?
        try? database?.writer.write { conn in
            let tx = GraphTx(conn)
            let task = try tx.upsertNode(label: NodeLabel.task, key: "flask", subtype: nil, title: "Flask 웹앱 개발",
                                         props: ["active_seconds": 9_600, "last_active": .number(todayAt(14, 32))], at: todayAt(14, 32))
            let session = try tx.upsertNode(label: NodeLabel.session, key: "s_flask", subtype: nil, title: "세션",
                                            props: ["start": .number(todayAt(13, 0)), "end": .number(todayAt(14, 32)), "active_seconds": 5_400,
                                                    "summaries": .array(["로그인 흐름을 구현했다."])], at: todayAt(14, 32))
            try tx.upsertEdge(src: session, dst: task, type: EdgeType.partOf, props: [:], addWeight: 0, at: todayAt(14, 32))
            for var digest in sampleDigests { digest.id = nil; try DigestStore.save(conn, digest) }
            taskId = task
        }
        let state = AppState(preview: { s in s.phase = .ready; s.status = collector() }, database: database)
        return Snapshot(name: name, size: window, view: AnyView(TasksView(selectedTask: taskId, tab: .digests).environmentObject(state)))
    }

    /// 업무 드로어의 자료 탭: 그래프 업무 팝업과 같은 종류별 자료와 같은 맥락 업무
    private static func materialsShot(_ name: String) -> Snapshot {
        let database = try? WGDatabase.inMemory()
        var taskId: Int64?
        try? database?.writer.write { conn in
            let tx = GraphTx(conn)
            let at = todayAt(14, 32)
            let node = { (label: String, key: String, subtype: String?, title: String, props: [String: JSONValue]) in
                try tx.upsertNode(label: label, key: key, subtype: subtype, title: title, props: props, at: at)
            }
            let edge = { (src: Int64, dst: Int64, type: String) in _ = try tx.upsertEdge(src: src, dst: dst, type: type, props: [:], addWeight: 0, at: at) }
            let task = try node(NodeLabel.task, "flask", nil, "Flask 웹앱 개발", ["active_seconds": 9_600, "last_active": .number(at)])
            let report = try node(NodeLabel.task, "report", nil, "분기 성과 보고서", [:])
            let s1 = try node(NodeLabel.session, "s1", nil, "로그인 흐름 구현", ["start": .number(todayAt(13, 0)), "end": .number(at)])
            let s2 = try node(NodeLabel.session, "s2", nil, "보고서 초안", ["start": .number(todayAt(11, 0))])
            try edge(s1, task, EdgeType.partOf); try edge(s2, report, EdgeType.partOf)
            for (key, subtype, title) in [("file:///Users/me/flask/app.py", "CodeFile", "app.py"), ("file:///Users/me/flask/auth.py", "CodeFile", "auth.py"),
                                          ("https://flask.palletsprojects.com/quickstart/", "WebPage", "Flask 공식 문서"),
                                          ("https://stackoverflow.com/q/1", "WebPage", "세션 쿠키가 저장되지 않을 때")] {
                try edge(s1, try node(NodeLabel.resource, key, subtype, title, [:]), EdgeType.touched)
            }
            try edge(s2, try node(NodeLabel.resource, "https://flask.palletsprojects.com/quickstart/", "WebPage", "Flask 공식 문서", [:]), EdgeType.touched)
            try edge(s1, try node(NodeLabel.app, "com.microsoft.VSCode", nil, "Code", [:]), EdgeType.used)
            try edge(s1, try node(NodeLabel.app, "com.google.Chrome", nil, "Google Chrome", [:]), EdgeType.used)
            try edge(task, try node(NodeLabel.topic, "topic:login", nil, "로그인 흐름", [:]), EdgeType.about)
            try edge(s1, try node(NodeLabel.problem, "problem:csrf", nil, "CSRF 토큰 누락", [:]), EdgeType.hit)
            try edge(try node(NodeLabel.laterItem, "later:deploy", nil, "배포 환경 변수 정리", [:]), task, EdgeType.forTask)
            taskId = task
        }
        let state = AppState(preview: { s in s.phase = .ready; s.status = collector() }, database: database)
        return Snapshot(name: name, size: window, view: AnyView(TasksView(selectedTask: taskId, tab: .materials).environmentObject(state)))
    }

    private static func batchShot(_ name: String, _ view: ActivityLogView, failedFirst: Bool = false) -> Snapshot {
        let records = sampleBatches(failedFirst: failedFirst)
        let database = try? WGDatabase.inMemory()
        try? database?.writer.write { conn in for var record in records { try record.insert(conn) } }
        let state = AppState(preview: { s in s.phase = .ready; s.batches = records }, database: database)
        return Snapshot(name: name, size: window, view: AnyView(view.environmentObject(state)))
    }

    private static func sampleBatches(failedFirst: Bool) -> [BatchRecord] {
        let stats = #"{"resources":2,"problems":0,"topics":1,"uncoveredRows":0,"laterItems":0,"offTaskRows":0,"tasksCreated":0,"tasksMerged":0,"sessions":1,"sessionsExtended":0,"unassignedRows":0}"#
        let rows = (1...14).map { i in "\(i) | 14:\(String(format: "%02d", 20 + i))-14:\(String(format: "%02d", 21 + i)) | \(40 + i * 7)s | Chrome | Documentation | Flask 공식 문서 \(i) | https://flask.palletsprojects.com/quickstart/" }
        let prompt = (["NOW: 2026-09-28 14:35", "TASK_TYPES: 문헌조사, 시장조사, 문서작성, 발표자료, 코드작성, 회의, 메신저대응, 강의수강, 복습, 데이터정리, 기타",
                       "OPEN_TASKS:", "- id=t12 | Flask 웹앱 개발 | 코드작성 | topics: 로그인 흐름 구현", "ROWS (row | time | dwell | app | type | title | uri) — assign every row:"] + rows)
            .joined(separator: "\n")
        let patch = #"{ "rows" : [ { "reason" : "로그인 예제 확인", "resource" : true, "rows" : "1", "task" : "A" } ], "tasks" : [ { "id" : "t12", "match" : "existing", "ref" : "A" } ] }"#
        let applied = "row | task | resource\n1 | Flask 웹앱 개발 | 로그인 예제 확인\n2 | Flask 웹앱 개발 | 자료 아님 | 내용 없음"
        return (0..<40).map { k in
            let id = Int64(212 - k), newest = k == 0, failed = newest && failedFirst
            return BatchRecord(id: id, startedAt: todayAt(14, 35) - Double(k) * 300, rowCount: 6, status: failed ? "failed" : "ok", model: "gpt-6-luna",
                               promptTokens: failed ? 0 : 3120, completionTokens: failed ? 0 : 840, error: failed ? "연결 실패: 요청 시간 초과" : nil,
                               rawResponse: newest && !failed ? #"{"id":"resp_0a91","object":"response","model":"gpt-6-luna","output":[{"type":"function_call","name":"assign_rows"}]}"# : nil,
                               stats: failed ? nil : stats, systemPrompt: newest ? OntologyPrompt.system : nil, userPrompt: newest ? prompt : nil,
                               llmPatch: newest && !failed ? patch : nil, appliedPatch: newest && !failed ? applied : nil)
        }
    }

    /// 보관함 녹음 상세: 녹음 파일과 받아쓴 글이 있는 상태 (임시 폴더에 두 파일을 만든다)
    private static func recordingDetailShot() -> Snapshot {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sillog-snapshot-recording", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("7.m4a")
        let text = folder.appendingPathComponent("2026-10-10 자료구조 3주차 강의.md")
        try? Data("a".utf8).write(to: audio)
        try? Data("# 자료구조 3주차 강의".utf8).write(to: text)
        let state = AppState(preview: { s in s.phase = .ready })
        let view = RecordingDetailView(recording: sampleRecording(audioPath: audio.path, textPath: text.path)).environmentObject(state)
        return Snapshot(name: "REC-04", size: CGSize(width: 640, height: 520), view: AnyView(view))
    }

    /// 보관함 '전체 종류'에 섞인 녹음
    private static func recordingLibraryShot() -> Snapshot? {
        guard let database = try? WGDatabase.inMemory() else { return nil }
        var recording = sampleRecording(audioPath: "/tmp/7.m4a", textPath: NSHomeDirectory() + "/Documents/학교/자료구조/2026-10-10 자료구조 3주차 강의.md")
        recording.id = nil
        _ = try? RecordingStore(database).insert(recording)
        let state = AppState(preview: { s in
            s.phase = .ready; s.status = collector(); s.selectedTab = .chat; s.showsChatResultsOnOpen = true
            s.recordings = (try? RecordingStore(database).all()) ?? []
            let offline = OpenAICompatClient(baseURL: URL(string: "http://localhost:5010/v1")!, model: "preview", apiKey: nil)   // 그리기만 하고 부르지 않는다
            let chat = ChatState(db: database, makeClient: { .model(offline) }, makeProjectClient: { offline })
            s.chat = chat
            _ = try? chat.library.store.saveArtifact(.init(title: "회의 요약", format: "html", content: "<h1>회의 요약</h1><p>확인한 내용과 다음 할 일</p>"))
            _ = try? chat.library.store.saveResponse(.init(conversationID: "preview", role: "assistant", text: "검토한 변경 사항입니다."), title: "검토 답변")
            let sample = Bundle.main.url(forResource: "github", withExtension: "png", subdirectory: "ConnectorIcons")
                ?? Bundle.module.url(forResource: "github", withExtension: "png", subdirectory: "ConnectorIcons")
            if let sample { _ = try? chat.library.store.importFile(sample) }
            chat.library.reload()
        }, database: database)
        return Snapshot(name: "REC-05", size: window, view: AnyView(MainWindow().environmentObject(state)))
    }

    private static func sampleRecording(audioPath: String, textPath: String) -> Recording {
        Recording(id: 7, startedAt: todayAt(15, 32), endedAt: todayAt(15, 32) + 3_130, duration: 3_130, audioPath: audioPath, textPath: textPath,
                  title: "자료구조 3주차 강의", summary: "연결 리스트와 스택의 구현을 예제로 설명한 강의.",
                  transcript: "오늘은 연결 리스트를 봅니다.\n노드는 값과 다음 노드를 가리키는 포인터를 가집니다.\n스택은 리스트 앞쪽에서 넣고 뺍니다.",
                  status: .ready, readyAt: Date().timeIntervalSince1970 - 2 * 86_400)
    }

    // MARK: 예시 상태

    private static func shot<V: View>(_ name: String, _ view: V, size: CGSize? = nil, _ configure: (AppState) -> Void) -> Snapshot {
        let state = AppState(preview: configure)
        return Snapshot(name: name, size: size, view: AnyView(view.environmentObject(state)))
    }

    /// 시트 뒤에는 기록 자료 탭(그래프 탭은 웹 보기라 스냅샷에 안 그려진다)
    private static func loginStep(_ s: AppState) {
        s.phase = .login; s.onboardingStep = .login; s.selectedTab = .records
        s.taskList = recentTasks; s.fileSuggestions = pendingFiles(2); s.pendingCount = 6
    }

    private static func permissionStep(_ s: AppState, _ grants: PermissionGrants) {
        s.phase = .permissions; s.onboardingStep = .permissions; s.permissionGrants = grants; s.selectedTab = .records
        s.taskList = recentTasks; s.fileSuggestions = pendingFiles(2); s.pendingCount = 6
    }

    private static func collector(accessibility: Bool = true, screenRecording: Bool = true, paused: Bool = false) -> CollectorStatus {
        var status = CollectorStatus()
        status.running = true
        status.accessibility = accessibility
        status.screenRecording = screenRecording
        status.paused = paused
        return status
    }

    private static func todayAt(_ hour: Int, _ minute: Int) -> Double {
        (Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()).timeIntervalSince1970
    }

    private static var recentTasks: [TaskSummary] {
        [TaskSummary(id: 1, key: "flask", title: "Flask 웹앱 개발", taskType: nil, activeSeconds: 9600, lastActive: todayAt(14, 32), sessionCount: 3),
         TaskSummary(id: 2, key: "stats", title: "통계학 수업", taskType: nil, activeSeconds: 3000, lastActive: todayAt(12, 10), sessionCount: 1),
         TaskSummary(id: 3, key: "report", title: "분기 성과 보고서", taskType: nil, activeSeconds: 4500, lastActive: todayAt(11, 45), sessionCount: 1)]
    }

    private static var themedTasks: [TaskSummary] {
        let rows: [(String, String?, String, Double, Int, Int)] = [
            ("Sillog 앱 기능·UI 고도화", "프로젝트", "코드작성", 5340, 14, 32), ("WorkGraph 파이프라인 변경사항 커밋·PR 및 그래프 확인", "프로젝트", "코드작성", 4860, 13, 10),
            ("기하학습 회귀 실습 노트북 완성", "학업", "복습", 1620, 12, 40), ("팀 Claude 요금제·환불 검토", "프로젝트", "문헌조사", 360, 11, 20),
            ("자료구조 기초 및 활용 수업 학습", "학업", "강의수강", 60, 10, 5), ("SK AX ERP·Talent AX 직무 지원 준비", "취업 준비", "면접·시험준비", 300, 9, 50),
            ("현대오토에버 2026년 4분기 신입채용 지원서 작성", "취업 준비", "신청·지원", 240, 9, 10), ("분류 전 업무", nil, "기타", 120, 8, 0),
        ]
        return rows.enumerated().map { i, r in
            TaskSummary(id: Int64(i + 1), key: "t\(i)", title: r.0, taskType: r.2, activeSeconds: r.3, lastActive: todayAt(r.4, r.5), sessionCount: 1, theme: r.1)
        }
    }

    /// 지난 기록 줄: 옮김(되돌리기 단추)과 무시(단추 없음)를 섞는다
    private static func decidedFiles(_ count: Int) -> [FileSuggestion] {
        (0..<count).map { (index: Int) -> FileSuggestion in
            let name = "report\(index).pdf"
            let ignored = index == 1
            return FileSuggestion(id: Int64(index + 100), ts: 0, path: "/tmp/" + name, fileName: name, originUrl: nil,
                                  suggestedFolder: "/tmp/학교", confidence: 0.9, reason: nil, source: "llm",
                                  status: ignored ? "ignored" : "moved", movedTo: ignored ? nil : "/tmp/학교/" + name)
        }
    }

    private static func pendingFiles(_ count: Int) -> [FileSuggestion] {
        (0..<count).map {
            FileSuggestion(id: Int64($0 + 1), ts: 0, path: "/tmp/file\($0).pdf", fileName: "file\($0).pdf", originUrl: nil,
                           suggestedFolder: "/tmp", confidence: 0.9, reason: nil, source: "llm")
        }
    }

    private static var sampleCode: DeviceCode {
        DeviceCode(verificationURL: URL(string: "https://auth.openai.com/codex/device")!, userCode: "SILL-OG26",
                   deviceAuthId: "preview", interval: 5, expiresAt: Date().timeIntervalSince1970 + 900)
    }
}
