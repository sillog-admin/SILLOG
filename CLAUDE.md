# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Sillog(실록)는 macOS에서 앱·창·URL·화면 텍스트·파일·AI 코딩 도구 대화·녹음을 기록하고, LLM으로 업무 그래프를 만든 뒤 그 기록을 근거로 채팅과 결과물을 만드는 네이티브 앱입니다. 사용자 설명은 `README.md`, 환경변수와 데이터 조회는 `docs/development.md`, OAuth 설정은 `docs/connectors.md`에 있습니다.

## 명령

```bash
swift build                                   # 디버그 빌드 (처음에는 의존성 때문에 몇 분 걸림)
swift test                                    # 전체 테스트. XCTest를 쓰므로 Xcode가 있어야 함
swift test --filter SillogCoreTests.JevClientTests             # 테스트 클래스 하나
swift test --filter SillogCoreTests.JevClientTests/testName    # 테스트 하나
./scripts/make-app.sh && open build/SILLOG.app   # 릴리스 빌드, 서명, ~/Applications 설치
swift run sillogctl                               # 개발용 CLI. 기본 DB가 실제 기록이므로 실험할 때는 --db로 다른 파일 지정
swift run sillogctl check-judge jev|decisions     # 판단 모델 실제 호출 확인. 키는 .env에서 읽음
```

- 린트·포매터 설정은 없습니다. 컴파일 경고를 늘리지 않으면 됩니다.
- Command Line Tools만 있으면 빌드는 되지만 `swift test`는 `no such module 'XCTest'`로 실패합니다.
- 모델 없이 수집→분류→그래프 흐름을 보려면 `sillogctl --db <임시 파일> seed-demo` 후 `batch --all --demo-llm`을 실행합니다(`docs/development.md` 참고).
- `make-app.sh`는 저장소 루트의 `.env`가 있으면 읽습니다. Google 커넥터의 client secret은 `SILLOG_GOOGLE_CLIENT_SECRET`로 빌드할 때 넣습니다.
- 저장소가 iCloud로 동기화되는 Documents 아래에 있으면 SwiftPM 체크아웃이 멈출 수 있습니다. 그래서 `make-app.sh`는 소스를 `$TMPDIR`에 복사해서 빌드합니다.

## 구조

SwiftPM 패키지 하나에 타깃이 네 개 있습니다(`Package.swift`). 의존 방향은 App·CLI → Collectors → Core입니다.

| 타깃 | 역할 |
| --- | --- |
| `SillogCore` | 화면과 무관한 로직 전체: 저장(GRDB/SQLite), LLM 클라이언트, 온톨로지 배치, 기억·요약, 채팅 실행·도구, 내보내기. 앱과 `sillogctl`이 함께 씀 |
| `SillogCollectors` | macOS 수집기(접근성, ScreenCaptureKit, Vision, FSEvents, AI 도구 로그). `CollectorCoordinator`가 묶음 |
| `SillogApp` | SwiftUI/AppKit 앱. `AppState`(@MainActor, 기능별로 `AppState+*.swift`에 나뉨)가 Core 객체를 만들고 화면 상태를 관리 |
| `sillogctl` | 개발·점검용 CLI. 앱과 같은 Core 로직으로 DB를 읽고 배치를 실행 |

여러 파일에 걸쳐 있는 주요 흐름은 다음과 같습니다.

1. **수집**: `CollectorCoordinator`가 모은 관측 행을 `EventStore`가 SQLite에 씁니다.
2. **정리 배치**: `OntologyBatcher`(actor)가 5분마다 미처리 행을 가져와 `EventCompressor`로 압축한 뒤 둘 중 한 경로로 보냅니다.
   - 앱 기본 경로(`Ontology/Staged/SeparatedJudgment.swift`): **판단 모델**(`ActivityJudging`)이 행마다 기존 업무 / `new` / `off` / `none` 중 하나를 고르고(`decideSeparately`), **정리 모델**이 새 업무의 이름과 요약을 씁니다(`organizeDecisions`). 고르기 전용 모델(Jev, Decisions)은 행 4개씩 동시에 묻고, 확신이 낮으면 `none`으로 봅니다. 앞에서부터 이어서 판단된 행만 반영하고 나머지는 다음 배치로 넘깁니다.
   - 판단 모델이 없을 때(CLI·평가): `StagedPipeline.run`의 분류→배정→서술 3단계, 또는 한 번에 묻는 `single`.

   결과(`AssignmentPatch`)는 `AssignmentApplier`가 한 트랜잭션으로 그래프에 반영하고 처리 완료로 표시합니다. 실패하면 행을 그대로 두고 잠시 뒤 다시 시도합니다. 건너뛰지 않습니다.
3. **기억 정리**: `Consolidator`가 사용 시간 기록(`usage_ledger`) → 주간·월간 요약 → 보관 기간이 지난 원문 삭제 순서로 진행합니다. 요약에 나온 숫자와 근거는 `DigestValidator`가 검증합니다.
4. **채팅**: `ChatState`(App) → `ChatRunner`(Core)가 `ChatBackend`로 답을 스트리밍하고, `ChatTools`로 기록·보관함·커넥터를 검색합니다.
5. **그래프 화면**: `Resources/graph`의 WKWebView(force-graph)입니다. Swift 쪽은 `GraphJSONExporter`가 만든 JSON을 넘깁니다.

### AI 연결

LLM 클라이언트는 `Settings.swift`(`AppSettings`)의 값으로 `AppState.makeClient` / `makeJudge` / `makeChatClient`에서만 만듭니다.

| 용도 | 인터페이스 | 구현 |
| --- | --- | --- |
| 정리 모델 | `LLMClient.callFunction` (도구 하나를 강제 호출해서 JSON을 받음) | `CodexResponsesClient`, `OpenAICompatClient` |
| 판단 모델 | `ActivityJudging`: `.gpt(LLMClient)` 또는 `.choice(ChoiceModel)` (보기 중 하나와 확률만 받음) | 위 둘 + `JevClient` (TypeSafe `/v1/systemone`), `DecisionsClient` (OpenAI `/v1/decisions`) |
| 채팅 모델 | `ChatBackend`: `.codex` / `.model` | `CodexAppServerClient`, `OpenAICompatClient` |

연결은 네 가지입니다. "ChatGPT 구독"은 앱 전용 OAuth 토큰으로 Codex 백엔드를 부르는 방식이고 공개 API가 아닙니다. "API 서버"는 OpenAI 호환 서버, "Jev"와 "OpenAI Decisions"는 판단 모델 전용입니다. 설정 화면은 [연결](계정·키)과 [용도별 모델](정리·채팅·판단이 어느 연결을 쓰는지)로 나뉩니다. 판단 모델 선택은 `AppSettings.judgeChoice`로 읽고 씁니다. API 키는 `AppSettings.save()`가 Keychain에 넣고 UserDefaults JSON에는 비워 둡니다.

## 코드 작성 규칙

지금 코드에는 팀원마다 다른 방식이 섞여 있습니다. 새로 쓰거나 손대는 코드는 아래 기준에 맞춥니다. 손대지 않는 코드를 한꺼번에 바꾸지는 않습니다.

- **ponytail 기준으로 작성합니다.** 코드를 쓰거나 고칠 때는 ponytail 스킬(`/ponytail`)을 켜고, 문제를 다 푸는 가장 작은 변경을 고릅니다. 요청받지 않은 추상화·옵션·재시도·검증은 넣지 않습니다. 알고도 택한 지름길에는 `// shortcut: <limit>, <when to upgrade>`를 남깁니다.
- **주석은 영어로 짧게 씁니다.** 코드만 봐서는 알 수 없는 이유만 한 줄로 적습니다. 사용법 안내나 괄호 속 덧붙임은 쓰지 않습니다. 기존 한국어 주석은 그 코드를 고칠 때 함께 정리합니다. throw하는 함수와 Core의 public 함수에는 `Args:` / `Returns:` / `Raises:`를 씁니다. Swift `throws`만으로는 어떤 오류가 나는지 알 수 없기 때문입니다.
- **로직은 Core에 둡니다.** 화면 없이 테스트할 수 있는 판단·변환·저장은 `SillogCore`로 보내고, App에는 상태 연결과 화면만 둡니다. `sillogctl`도 같은 로직을 써야 하기 때문입니다.
- **외부 호출은 프로토콜 뒤에 둡니다.** 모델·HTTP 호출은 `LLMClient`, `ChoiceModel` 같은 프로토콜로 받고, 테스트에서는 대역(`StubLLM`, `StubURLProtocol`)으로 바꿉니다. 새 공급자를 붙일 때는 새 프로토콜을 만들지 말고 용도가 같은 기존 프로토콜을 구현합니다.
- **종류를 나타내는 값은 enum으로 만듭니다.** 지금은 `"codex"`, `"openai"`, `"jev"` 같은 문자열을 직접 비교하는 코드가 많습니다. 새 값은 `String` raw value enum으로 만들고, 저장되는 JSON 문자열은 그대로 둬서 예전 설정과 호환되게 합니다.
- **오류는 `LocalizedError`로 던집니다.** `errorDescription`에는 사용자에게 보여 줄 문장을 넣습니다. UI는 `error.localizedDescription`을 그대로 씁니다. 원래 오류 문구는 버리지 말고 배치 기록(`StageCall`)이나 `AppLog`에 남깁니다.
- **시각은 Unix 초(`Double`)로** 저장하고 주고받습니다. DB와 Core 전체가 이미 이렇게 되어 있습니다.
- **비밀값은 Keychain에 둡니다.** API 키와 토큰은 `ChatSecrets`(서비스 `com.sillog.app.chat`)에 저장하고, UserDefaults·로그·DB·배치 기록에는 넣지 않습니다.
- **화면 문구는 `tr("한국어 원문")`으로 씁니다.** 한국어 원문이 키이고, 영어는 `Sources/SillogCore/Localization/en.json` 한 곳에서 찾습니다. 보간 값은 키에서 `%@`로 바뀌고, 영어에서 순서를 바꿔야 하면 `%1$@`처럼 씁니다. 번역이 없으면 한국어 원문이 그대로 나옵니다. 저장값으로 쓰는 enum 원시값은 그대로 두고 화면에서만 `L10n.tr(key:)`로 바꿉니다. AppLog, 프롬프트, DB에 저장되는 이름은 감싸지 않습니다. 새 문구를 넣으면 `en.json`에도 추가합니다(`L10nTests`가 자리표시자 수를 확인합니다).
- **언어 설정**은 `AppSettings.language`(`ko`/`en`)이고 `L10n.current`에 반영됩니다. 바꾸면 창 전체를 다시 그립니다(`View.localized`). 그래프·캘린더 웹 화면은 `WebL10n`이 같은 표로 글자를 바꿔 주므로 JS에는 한국어 원문을 그대로 씁니다. AI가 만드는 업무 이름·요약은 프롬프트의 `L10n.current.promptName`으로 언어를 정합니다.

## 검증

- 변경한 뒤에는 `swift build`와 `swift test`를 실행합니다. 화면 동작은 `Tests/SillogAppTests`가 `AppState(preview:)`로 화면 밖 창에 그려서 확인합니다. 실제 DB와 실행 잠금은 쓰지 않습니다.
- 외부 API는 자동 테스트에서 대역으로만 확인합니다. 실제 키가 필요한 연결 확인은 `.env`(커밋 금지, 템플릿은 `.env.copy`)의 키로 따로 실행하고 자동 테스트와 섞지 않습니다.
- GitHub Actions는 PR과 기본 브랜치 push에서 빌드와 테스트를 실행합니다.

## 호환성

아래 항목을 잘못 바꾸면 사용자 데이터나 macOS 권한이 사라집니다.

- **DB 스키마**: `SillogDatabase`의 GRDB migrator 끝에 `registerMigration`을 추가만 합니다. 이미 배포한 마이그레이션은 고치지 않습니다.
- **설정**: `AppSettings`는 UserDefaults에 JSON 한 덩어리로 저장됩니다. 새 필드는 `decodeIfPresent ?? 기본값`으로 읽어서 예전 저장값이 초기화되지 않게 합니다.
- **번들 ID** `com.sillog.app`, **Keychain 서비스** `com.sillog.app.chat`, **URL scheme** `sillog`(OAuth 콜백), **서명 인증서**를 바꾸면 macOS 권한과 저장된 토큰을 잃습니다.
- 데이터 경로(`~/Library/Application Support/Sillog`), `SILLOG_*` 환경변수, UserDefaults 키 이름을 바꿀 때는 예전 이름을 읽어서 옮기는 처리를 같이 넣습니다.
- 예전 이름(WorkGraph)은 이렇게 이어받습니다. 데이터 폴더 `WorkGraph`는 첫 실행 때 `Sillog`로 옮기고 그 자리에 심볼릭 링크를 남깁니다(DB에 저장된 절대 경로 때문). `workgraph.sqlite`는 `sillog.sqlite`로 바꿉니다(`SillogDatabase.migrateLegacyDirectory`). 환경변수는 `SillogEnv.value`가 `WORKGRAPH_*`도 읽고, UserDefaults는 `UserDefaults.migrateLegacyKeys`가 `workgraph.*` 키를 옮깁니다.

## 커밋

- 메시지는 `태그: 수정사항` 한 줄로 씁니다. 예: `feat: add email verification on signup`. 태그는 `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`, `perf`를 씁니다.
- 공개 저장소입니다. `.env`, API 키, 개인 기록 덤프(`sillogctl dump` / `export-*` 결과), 일회성 AI 작업 지시 문서는 커밋하지 않습니다. 커밋 전에 `git status`로 확인합니다.
