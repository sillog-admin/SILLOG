import Foundation

/// 권한·실사용 데이터 없이 파이프라인을 끝까지 돌려보기 위한 하루치 가짜 활동.
/// 실제 수집기처럼 컨텍스트가 바뀔 때 한 행, 그리고 60초마다 생존 신호 행을 남긴다.
public enum DemoScenarios {
    public struct Step: Sendable {
        let minutes: Double
        let bundle: String
        let app: String
        let title: String
        var url: String?
        var doc: String?
        var text: String?
    }

    static let cursor = ("com.todesktop.230313mzl4w4u92", "Cursor")
    static let chrome = ("com.google.Chrome", "Google Chrome")

    static func step(_ minutes: Double, _ app: (String, String), _ title: String, url: String? = nil, doc: String? = nil, text: String? = nil) -> Step {
        Step(minutes: minutes, bundle: app.0, app: app.1, title: title, url: url, doc: doc, text: text)
    }

    /// 10:00 공부 → 13:00 서류 작업 → 14:02 프론트 개발 → 16:00 같은 프로젝트의 다른 업무
    public static func scenarios(home: String) -> [(startHour: Double, steps: [Step])] {
        let study: [Step] = [
            step(12, ("com.apple.Preview", "Preview"), "week3_linear_algebra.pdf", doc: "\(home)/Documents/AI기초수학/week3_linear_algebra.pdf",
                 text: "3주차 선형대수 복습. 고유값과 고유벡터. Av = λv 를 만족하는 0이 아닌 벡터 v. 대각화 A = PDP^-1"),
            step(15, chrome, "Eigenvectors and eigenvalues | Chapter 14, Essence of linear algebra - YouTube", url: "https://www.youtube.com/watch?v=PFDu9oVAE-g&t=120s"),
            step(10, ("md.obsidian", "Obsidian"), "3주차 - AI기초수학 - Obsidian", doc: "\(home)/vault/AI기초수학/3주차.md",
                 text: "# 3주차 고유값 분해\n- 고유벡터는 선형변환 후에도 방향이 유지되는 벡터\n- 대각화 가능 조건: 선형독립인 고유벡터 n개"),
            step(14, chrome, "week3_practice.ipynb - Colab", url: "https://colab.research.google.com/drive/1AbCdEfGh?usp=sharing#scrollTo=x1",
                 text: "import numpy as np\nw, v = np.linalg.eig(A)\nLinAlgError: Last 2 dimensions of the array must be square"),
            step(6, chrome, "고유값 분해가 안 되는 경우 - Claude", url: "https://claude.ai/chat/7f3a-eig"),
            step(9, chrome, "week3_practice.ipynb - Colab", url: "https://colab.research.google.com/drive/1AbCdEfGh"),
            step(4, ("md.obsidian", "Obsidian"), "3주차 - AI기초수학 - Obsidian", doc: "\(home)/vault/AI기초수학/3주차.md"),
        ]
        let paperwork: [Step] = [
            step(5, chrome, "팀 프로젝트 중간보고서 양식 안내 - LMS", url: "https://lms.example.com/notice/view?id=4821&utm_source=mail",
                 text: "팀 프로젝트 중간보고서 제출 안내. 제출 기한 9월 25일 23:59. 양식 첨부. 분량 10쪽 이내."),
            step(4, ("com.apple.Preview", "Preview"), "중간보고서_양식.pdf", doc: "\(home)/Downloads/중간보고서_양식.pdf"),
            step(18, ("com.microsoft.Word", "Microsoft Word"), "프로젝트_중간보고서.docx", doc: "\(home)/Documents/프로젝트/프로젝트_중간보고서.docx",
                 text: "1. 프로젝트 개요\nPC 활동 데이터를 온톨로지 그래프로 정리하여 업무 재개, 기억 기반 검색을 제공한다.\n2. 진행 현황"),
            step(6, chrome, "팀 일정표 - Google Sheets", url: "https://docs.google.com/spreadsheets/d/1TeamSchedule/edit#gid=0"),
            step(3, ("com.kakao.KakaoTalkMac", "KakaoTalk"), "프로젝트 팀방", text: "준호: 보고서 3장 시스템 구조도는 제가 그릴게요. 내일까지 드릴게요"),
            step(12, ("com.microsoft.Word", "Microsoft Word"), "프로젝트_중간보고서.docx", doc: "\(home)/Documents/프로젝트/프로젝트_중간보고서.docx"),
            step(3, chrome, "받은편지함 - Gmail", url: "https://mail.google.com/mail/u/0/#inbox"),
        ]
        let frontend: [Step] = [
            step(9, cursor, "TaskCard.tsx — dashboard"),
            step(13, chrome, "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card",
                 text: "Card. Displays a card with header, content, and footer. Installation: npx shadcn@latest add card"),
            step(11, cursor, "TaskCard.tsx — dashboard"),
            step(3, chrome, "Dashboard - localhost:3000", url: "http://localhost:3000/dashboard?tab=tasks"),
            step(4, ("com.apple.Terminal", "Terminal"), "dashboard — npm run dev",
                 text: "Warning: Each child in a list should have a unique \"key\" prop. Check the render method of `TaskList`."),
            step(2, chrome, "react each child in a list should have a unique key prop - Google 검색", url: "https://www.google.com/search?q=react+unique+key+prop+warning&sourceid=chrome"),
            step(9, chrome, "javascript - Understanding unique keys for array children in React.js - Stack Overflow",
                 url: "https://stackoverflow.com/questions/28329382/understanding-unique-keys-for-array-children-in-react-js"),
            step(12, cursor, "TaskList.tsx — dashboard"),
            step(3, chrome, "Dashboard - localhost:3000", url: "http://localhost:3000/dashboard"),
            step(4, ("com.tinyspeck.slackmacgap", "Slack"), "디자인팀 - Slack", text: "지은: 대시보드 카드 간격 16px로 맞춰주세요. 시안 업데이트했습니다"),
            step(6, chrome, "출근길 플레이리스트 - YouTube", url: "https://www.youtube.com/watch?v=jfKfPfyJRdk"),
            step(10, cursor, "TaskCard.tsx — dashboard"),
        ]
        let filter: [Step] = [
            step(8, cursor, "FilterBar.tsx — dashboard"),
            step(5, chrome, "Card - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/card#usage"),
            step(7, chrome, "Select - shadcn/ui - Google Chrome", url: "https://ui.shadcn.com/docs/components/select"),
            step(9, cursor, "FilterBar.tsx — dashboard"),
            step(3, chrome, "Dashboard - localhost:3000", url: "http://localhost:3000/dashboard"),
        ]
        return [(10.0, study), (13.0, paperwork), (14.0 + 2.0 / 60.0, frontend), (16.0, filter)]
    }

    /// dayStart = 그날 0시의 Unix 초. 돌려주는 값은 (관측 행, 그 행에 붙일 화면 텍스트).
    public static func observations(dayStart: Double, home: String) -> [(Observation, String?)] {
        var result: [(Observation, String?)] = []
        for scenario in scenarios(home: home) {
            var cursor = dayStart + scenario.startHour * 3600
            for step in scenario.steps {
                let end = cursor + step.minutes * 60
                var t = cursor
                var first = true
                while t < end {
                    let obs = Observation(ts: t, trigger: first ? "demo" : "periodic", appBundle: step.bundle, appName: step.app,
                                          windowTitle: step.title, url: step.url, docPath: step.doc)
                    result.append((obs, first ? step.text : nil))
                    first = false
                    t += 60
                }
                cursor = end
            }
        }
        return result
    }

    @discardableResult
    public static func seed(into store: EventStore, dayStart: Double, home: String) throws -> Int {
        let items = observations(dayStart: dayStart, home: home)
        for (observation, text) in items {
            var copy = observation
            if let text { copy.textId = try store.upsertText(text, source: "demo", at: observation.ts) }
            try store.insert(copy)
        }
        return items.count
    }
}
