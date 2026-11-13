# 개발 가이드

[README로 돌아가기](../README.ko.md)

## 빌드와 권한

```bash
./scripts/make-app.sh
open build/Sillog.app
```

빌드 스크립트는 소스를 임시 경로에 복사해 컴파일하고 앱 번들을 서명합니다. 완성된 앱은 `~/Applications/Sillog.app`에 설치하며, `build/Sillog.app`은 설치된 앱으로 연결되는 심볼릭 링크입니다. 컴파일과 서명은 Documents 동기화의 영향을 피하면서, 실행과 권한 등록에는 일정한 설치 경로를 사용합니다.

서명 인증서는 `SIGN_IDENTITY` 지정값 → `SILLOG Release` → `Apple Development` → ad-hoc 순서로 선택합니다. 직접 지정한 인증서로 서명하지 못하면 ad-hoc으로 넘어가지 않고 멈춥니다.

```bash
SIGN_IDENTITY="SILLOG Release" ./scripts/make-app.sh
```

`SILLOG Release`는 main 릴리스를 서명하는 자체 서명 인증서입니다. CI는 GitHub Secrets의 `SILLOG_SIGN_P12`(base64로 인코딩한 .p12)와 `SILLOG_SIGN_P12_PASSWORD`로 이 인증서를 가져옵니다. 같은 인증서로 서명하므로 업데이트해도 키체인 접근과 macOS 권한이 유지됩니다. 인증서 파일과 암호는 GitHub Secrets와 팀 비밀번호 관리자에만 두고, 저장소에는 커밋하지 않습니다. PR 빌드는 Secrets를 쓰지 않도록 ad-hoc으로 서명합니다.

번들 ID는 `com.sillog.app`입니다. 같은 번들 ID만으로 권한 유지가 보장되는 것은 아니며, **동일한 서명 인증서도 필요합니다.** ad-hoc 서명에서는 재빌드 후 권한을 다시 허용해야 할 수 있습니다.

문제가 생겼을 때:

- **화면 기록 목록에 앱이 없음**: 시스템 설정의 화면 기록 목록에 `~/Applications/Sillog.app`을 직접 추가하고 허용한 뒤 앱을 종료하고 다시 실행합니다.
- **시스템 설정은 허용인데 앱은 권한 없음**: ad-hoc 서명으로 다시 빌드하면 기존 권한에 저장된 서명과 달라질 수 있습니다. 앱을 종료하고 화면 기록 목록의 Sillog 항목을 제거한 뒤, 설치된 앱을 다시 추가·허용하고 실행합니다. 재빌드 후에도 권한을 유지하려면 같은 개발자 인증서로 서명합니다.
- **이미 실행 중 안내**: 같은 DB를 사용하는 기존 앱 또는 `swift run SillogApp` 프로세스를 종료합니다. 수집 중인 DB에 두 인스턴스가 동시에 쓰지 않도록 잠금이 걸립니다.
- **`no such module 'XCTest'`**: 전체 Xcode와 개발자 경로를 확인합니다. Command Line Tools만 설치한 환경에는 XCTest가 없을 수 있습니다. 앱 빌드 성공과 단위 테스트 통과는 별도로 확인해야 합니다.
- **실행·권한·정리 오류 확인**: `~/Library/Application Support/Sillog/app.log`를 확인합니다. 로그에 화면 내용이나 토큰은 기록하지 않습니다.

## 환경변수

기존 실행 설정과 호환되도록 `SILLOG_*` 이름을 유지합니다. OAuth 변수는 [커넥터 설정](connectors.md)을 참고하세요.

| 변수 | 용도 |
| --- | --- |
| `SILLOG_BUILD_DIR` | 빌드 캐시·소스 복사본·앱 번들을 준비할 경로 |
| `SIGN_IDENTITY` | 앱 서명 인증서. `-`는 ad-hoc |
| `SILLOG_DB` | 기본값 대신 사용할 SQLite 파일 |
| `SILLOG_CODEX_AUTH` | 앱 전용 ChatGPT 인증 파일 경로 |
| `SILLOG_SHOW_WINDOW=1` | 시작 시 메인 창 표시 |
| `SILLOG_REQUEST_PERMISSIONS=1` | 시작 시 손쉬운 사용·화면 기록 권한 요청 |
| (녹음 받아쓰기 모델) | Whisper large-v3-turbo 압축판(`openai_whisper-large-v3-v20240930_626MB`, 약 610MB)을 처음 받아쓸 때 데이터 폴더의 `models/` 아래로 내려받는다(WhisperKit, 기기 안). 녹음하는 동안 30초쯤마다 조용한 순간에 잘라 미리 받아써 두고(`LiveTranscription`), 끝나면 남은 조각만 받아쓴다(11분 녹음도 끝나고 약 2초). 앱을 다시 켰거나 미리 받아쓰기가 실패하면 파일 전체를 같은 30초 조각으로 받아쓴다. 내려받기·불러오기에 실패하면 애플 기기 안 음성 인식으로 받아쓴다. 모델은 90초 동안 안 쓰면 내려놓는다 |
| `SILLOG_TRANSCRIBE_TRACE` | 개발용 받아쓰기 진단: `<녹음 파일>|<적을 파일>`. 앱과 같은 방식으로 받아쓰며 인식기 결과(마지막 결과·발화 끝 표시·끝 시각·글)를 하나하나 적고 끝난다. 음성 인식 권한이 앱 번들에만 있어 `open -n Sillog.app --env 'SILLOG_TRANSCRIBE_TRACE=…'` 로 띄운다. `SILLOG_TRANSCRIBE_ENGINE=apple` 이면 애플 음성 인식으로(기본은 Whisper 로 파일 전체), `SILLOG_TRANSCRIBE_GAIN=2` 로 애플 인식의 키울 배수를 직접 정할 수 있다. `SILLOG_TRANSCRIBE_ENGINE=live` 면 파일을 녹음기처럼 흘려보내며 녹음 중 미리 받아쓰기를 하고 끝난 뒤 글이 나오기까지 걸린 시간을 적는다(`SILLOG_TRANSCRIBE_SPEED=8` 로 8배 빨리) |
| (숨은 설정 `frameLog`) | `defaults write com.sillog.app frameLog -bool true` 면 화면 갱신마다 메인 스레드가 늦은 프레임을 재서, 늦은 프레임이 있던 1초마다 화면 이름과 함께 app.log 에 `프레임 기록 자료 > 파일: 120장 중 늦음 3 (많이 늦음 1), 가장 긴 간격 40ms` 처럼 남긴다. 앱을 다시 켜야 적용, `defaults delete … frameLog` 로 끈다 |
| `SILLOG_TAB` | 시작 탭: `graph`, `chat`, `records`(기록 자료), `calendar`, `settings`. `files`, `history`(지난 기록), `library` 는 기록 자료의 그 구역으로, `activity` 는 설정의 활동 로그로 연다 (업무 목록은 그래프 탭에만 있다) |

## 테스트와 CLI

```bash
swift build
swift test
swift run sillogctl
```

`sillogctl`은 앱과 같은 코어 로직을 사용하는 개발 도구입니다. 기본 DB는 실제 사용자 기록이므로, 실험에는 `--db`로 별도 DB를 지정하세요. 그래프 재생성·업무 병합처럼 데이터를 변경하는 명령은 앱을 종료하고 백업 후 실행해야 합니다.

### 모델 없이 흐름 확인

```bash
SILLOG_TEST_DIR=$(mktemp -d)
SILLOG_TEST_DB="$SILLOG_TEST_DIR/sillog.sqlite"
swift run sillogctl --db "$SILLOG_TEST_DB" seed-demo
swift run sillogctl --db "$SILLOG_TEST_DB" batch --all --demo-llm
swift run sillogctl --db "$SILLOG_TEST_DB" stats
SILLOG_DB="$SILLOG_TEST_DB" SILLOG_SHOW_WINDOW=1 build/Sillog.app/Contents/MacOS/Sillog
```

`--demo-llm`은 시드 데이터를 규칙으로 분류하는 가짜 모델입니다. 수집→분류→그래프 흐름을 확인하는 용도이며 실제 LLM 품질 평가에 사용할 수 없습니다. 앱의 로그인·온보딩을 우회하지는 않습니다.

### 자주 쓰는 읽기 명령

```bash
swift run sillogctl rows --last 50 --text
swift run sillogctl batches
swift run sillogctl cards --last 20
swift run sillogctl tasks
swift run sillogctl schema
swift run sillogctl dump report.md --since-hours 24 --text
swift run sillogctl export-graph graph.json --tbox
swift run sillogctl export-rdf graph.ttl
swift run sillogctl export-cypher graph.cypher
```

덤프와 내보내기에는 개인 기록이 포함될 수 있으므로 저장소에 커밋하지 마세요.

`sillogctl find-events 배치ID…`는 저장된 배치의 행을 일정 찾기에 다시 보내 찾은 일정을 보여 줍니다(제안은 만들지 않음, 배치당 LLM 호출 1번). 앱이 아직 모르는 마이그레이션이 있으면 CLI가 DB를 열면서 적용하므로, 실제 기록으로 볼 때는 사본을 떠서 씁니다.

```bash
sqlite3 "file:$HOME/Library/Application Support/Sillog/sillog.sqlite?mode=ro" ".backup '/tmp/wg-copy.sqlite'"
SILLOG_DB=/tmp/wg-copy.sqlite swift run sillogctl find-events 1851 1779
```

## 데이터 구조

```text
앱·창·URL·화면·파일·AI 사용자 요청 수집
                    ↓
SQLite 원시 기록 + 화면 기억 카드
                    ↓ LLM 배정
업무·자료·주제 + 시간 기반 세션·관계
                    ↓
그래프 탐색 · 업무 재개 · 채팅 검색·결과물
```

- 앱·창·URL은 3초마다 확인합니다. 화면 캡처는 활성 창을 대상으로 하며, 캡처 도중 창이 바뀌면 저장하지 않습니다.
- LLM 정리는 기본 5분 배치로 실행하지만, 업무 판단 단위는 개별 관측 행입니다. 목표에 기여하는 행, 집중 이탈, 내용 없는 화면을 구분합니다.
- 화면 기억 카드는 대표 스크린샷의 내용을 요약합니다. 업무 배정과 채팅 검색에 활용하며 설정에서 끌 수 있습니다.
- 같은 화면에 머무는 동안의 주기 캡처는 화면이 그대로면 파일 없이 해시만 남깁니다. 그런 행은 같은 앱·제목·주소에 해시가 가까운 최근 카드를 붙여 보냅니다(`OntologyBatcher.carriedCards`). 정리가 끊긴 뒤 이어 본 화면이 제목만으로 판정되지 않게 하기 위해서입니다.
- 판정 규칙: 행 자신의 근거(화면 인용 줄, 글자, 제목, 파일·페이지 이름)가 무엇을 위한 것인지 보여 줄 때만 업무입니다. 근거가 없으면 업무 외(`off`)이고, `none`은 내용이 없는 화면(시스템 화면, 앱 사이 전환, 빈 페이지)에만 씁니다. 판단 모델 경로도 같습니다. 새 업무의 제목·목표에는 그 업무 행에 나온 이름만 씁니다(옆 행·업무 목록의 이름은 근거가 아님).
- 스크린샷은 앞 창 하나만 찍습니다(`ScreenCapturer.pick`: 같은 프로그램·위치·크기, 제목이 같거나 접근성 제목이 "캡처 쪽 제목 - …"인 창. Chrome 은 접근성 제목에만 " - Chrome - 프로필"을 붙입니다). 하나로 정해지지 않으면 찍지 않습니다.
- 세션은 같은 업무의 관측을 시간으로 묶습니다. URI 정규화·체류시간·세션 구성·프로젝트 연결은 LLM 없이 계산합니다.
- AI 코딩 도구 로그는 Claude Code·Codex의 로컬 기록에서 사용자 입력만 읽습니다. 처음에는 최근 24시간, 이후에는 새로 추가된 내용을 읽습니다. 앱 채팅과는 별도 데이터입니다.

SQLite 도구로 열 때는 **읽기 전용 연결**을 사용하세요. 앱이 WAL 모드로 계속 기록하는 파일입니다.

| 조회 뷰 | 내용 |
| --- | --- |
| `v_rows` | 관측 행, 현지 시각, 화면 텍스트, 캡처 경로, 처리 배치 |
| `v_row_tasks` | 관측 행의 업무 배정·이탈·자료 판정과 이유 |
| `v_chats` | 외부 AI 코딩 도구의 사용자 메시지 |
| `v_batches` | 정리 입력·프롬프트·응답·반영 결과·토큰·오류 |
| `v_cards` | 화면 기억 카드 |
| `v_sessions` | 업무별 세션과 작업 시간·요약 |
| `v_nodes`, `v_edges` | 그래프 노드·관계 |
| `v_file_suggestions` | 파일 이동 제안·결정·결과 |
| `v_ledger` | 날짜·업무·대상(업무·자료·앱·프로젝트)별 사용 시간과 동결 여부 |
| `v_digests` | 업무별 주간·월간 요약과 상태(draft·verified·edited) |

앱 채팅은 `app_conversations`, `app_messages`, `app_automations`에 저장됩니다. 원시 활동·외부 AI 대화와 분리되어 있으며, 시각은 Unix 초를 사용합니다.

CHAT-110의 목표별 프로젝트는 `app_projects`, 업무 소속은 `project_tasks`, 대화 소속은 `app_conversations.project_id`에 저장합니다. 기존 그래프의 저장소·폴더 `Project` 노드와는 별개입니다. 대기 중인 후보는 `project_proposals`, 검토·무시·수동 이동 이력은 `project_reviewed`에 남깁니다. 최초 검토는 기존 항목을 40개씩 처리하고, 이후 새 항목을 판단할 때 이전 미분류 항목도 연결 근거로 제공합니다. 사용자가 수락하기 전에는 소속을 변경하지 않습니다.

수락 대기 중인 업무의 자동 병합은 보류합니다. 수락한 뒤에도 서로 다른 프로젝트의 업무와 사용자가 직접 분류에서 뺀 업무는 병합으로 소속을 바꾸지 않습니다. 프로젝트를 삭제하면 대화와 예약의 프로젝트 소속만 해제합니다.

프로젝트의 `memoryMode`는 `allRecords`(기본) 또는 `projectOnly`입니다. 기본 모드는 현재 프로젝트의 대화를 우선하고 전용 프로젝트를 제외한 기록을 검색합니다. 전용 모드는 해당 프로젝트의 업무·대화·자료만 허용하며, 일반 채팅에서도 제외됩니다. 검색과 직접 읽기 모두 같은 범위를 검사하고, 공유 자료의 관계를 따라갈 때도 전용 업무·세션으로 확장하지 않습니다. 공개·전용 활동이 섞인 화면 카드는 요약을 노출하지 않습니다.

v13의 `app_library`에는 파일 메타데이터와 추출 텍스트, `library_project_sources`와 `library_conversation_sources`에는 명시적인 연결을 저장합니다. 파일 복사본은 DB 옆 `library/<자료 ID>/`에 둡니다. 프로젝트·대화 삭제 시 연결만 제거하고 보관함 원본은 유지합니다. `library_deleted_origins`는 사용자가 삭제한 생성 결과물이 다음 앱 실행에서 다시 수집되지 않게 합니다. 기존 경로는 그대로 유지하며 다른 대화의 경로를 자동 공유하지 않습니다.

v14의 `app_messages_fts`는 완료된 메시지와 결과물 본문 전체를 색인하고 저장·상태 변경·삭제 트리거로 갱신합니다. 검색은 일치한 메시지 ID를 반환하고 `read_context`로 원문을 문자 위치별로 이어 읽습니다. 대화 ID 조회는 시작 메시지 번호부터 20개씩 반환합니다. 저장 자료와 관련 과거 기록 일부는 실행 시작 시 제공하며 추가 원문은 도구로 읽습니다. 프로젝트 공통 지침은 사용자 설정이고 검색된 내용은 지시가 아닌 자료로 전달합니다.

### 기록 정리 (v15)

오래된 원문은 주·월 단위 요약과 결정적 집계로 바꿔 DB가 상한 없이 늘지 않게 합니다.

- `usage_ledger`: 날짜·업무·대상(업무·자료·앱·프로젝트)별 사용 시간. 그래프 재구성과 같은 계산(`ActivityTally`)을 써서 세션 시간의 합과 항상 같습니다. 원문을 지우는 날은 마지막으로 계산한 뒤 `frozen = 1`로 동결합니다. 업무 밖 행은 시간과 앱만 남기고 주소는 남기지 않습니다.
- `digests`·`digests_fts`: 업무별 주간(ISO 주)·월간 요약. 수치는 사용 시간 기록에서 코드가 계산하고, 문장은 정리용 모델이 씁니다. `DigestValidator`가 입력에 없는 숫자, 주지 않은 앵커, 근거 없는 완료(`evidenced`), 길이 초과를 거부합니다. 서술이 실패하면 결정적 요약을 `draft`로 두고 그 주의 원문은 지우지 않습니다. 같은 입력으로 세 번 검증에 실패하면 더 부르지 않고 초안으로 둡니다. 입력이나 프롬프트 버전이 바뀌면 다시 시도하고, 사용자가 요약을 확인해 저장하면(`edited`) 유예 기간 뒤 정리합니다. 사용자가 고친 요약(`edited`)은 다시 만들지 않습니다.
- `consolidation_state`: 진행 상태(`sealed_until`, 항목별 `*_pruned_until`, 첫 정리 동의, 보관 정책 JSON). 보관 정책은 앱과 sillogctl이 같이 쓰도록 DB에 둡니다.
- `retention_pins`: 원문을 지우지 않을 업무(`task`)·기간(`period`).
- `prompt_blobs`: 배치 시스템 프롬프트 원문을 한 번만 저장하고 `batches.system_prompt_hash`로 가리킵니다. 배치를 읽는 함수가 원문을 채웁니다.

정리 순서는 사용 시간 기록 → 주간 요약(실행당 최대 2주) → 월간 요약(최대 1개월) → 원문 정리 → 공간 회수입니다. 기간은 끝에서 48시간이 지나고 그 기간의 관측이 모두 정리 배치에 들어간 뒤에 닫습니다. 하루 D의 원문은 그 주에 활동한 모든 업무의 요약이 검증되고, 유예 기간이 지나고, 사용자가 첫 정리에 동의했을 때만 지웁니다. 아직 준비되지 않은 주(닫히지 않음, 요약 생성·재시도 중, 유예 중)가 있으면 그 뒤 날짜도 기다립니다. 요약이 검증을 통과하지 못한 주는 원문을 남긴 채 건너뛰고 그 뒤 주는 계속 정리합니다. 원문 보존 핀이 걸린 날도 같은 방식으로 건너뜁니다. 원문을 지운 날 이전(`sealed_until`)의 세션은 `GraphRebuilder`가 지우지 않고, 업무 시간은 사용 시간 기록에서 다시 채웁니다. 앱은 시작 10분 뒤부터 하루 한 번, 5분 이상 자리를 비웠고 일시정지가 아니며 전원이 충분할 때 정리합니다.

채팅은 `digest:` 출처를 검색하고 읽으며, 기간의 시간과 건수는 `summarize_period`로 계산합니다(출처 ID `usage:`). 시스템 프롬프트의 `raw_records_since`에는 원문이 남아 있는 첫 날이 들어갑니다(정리한 적이 없으면 `all`).

```bash
swift run sillogctl storage                       # 범주별 크기, 30일 하루 평균 증가량
swift run sillogctl retention                     # 보관 정책 보기 (--preset, --set 항목=일수|none, --grace, --narrate)
swift run sillogctl consolidate --dry-run         # 지울 날·건수·예상 회수량, 멈춘 이유, 원문을 남긴 주
swift run sillogctl consolidate --ledger-only     # 사용 시간 기록만 갱신하고 업무 시간과 비교
swift run sillogctl consolidate --no-prune        # 요약까지만 (원문은 지우지 않음)
swift run sillogctl digest show --week 2026-W40   # 요약 확인
```

실제 DB로 확인할 때는 사본(`sqlite3 원본 ".backup 사본"`)에 `--db`를 쓰고, 로그가 사본 옆에 남도록 `SILLOG_DB`도 같은 경로로 지정하세요. 원문을 지우는 `consolidate`(`--consent`)는 앱을 끄고 실행합니다.

## 구현 위치

- **스키마·관계**: `Sources/SillogCore/Ontology/TBox.swift`, `RelationSchema.swift`
- **업무 배정**: `OntologyPrompt.swift`, `AssignmentApplier.swift`, `SessionBuilder.swift`
- **자료 분류**: `RuleClassifier.swift`, `URINormalizer.swift`
- **채팅 실행**: `Sources/SillogCore/Chat/ChatRunner.swift`, `ChatTools.swift`
- **채팅 시스템 프롬프트**: `Sources/SillogCore/Chat/Prompts/chat-system-prompt.md`(원문), `ChatSystemPrompt.swift`(끝의 `{{…}}` 칸 채우기)
- **스킬**: `Sources/SillogCore/Chat/Skills/catalog.json`과 각 Markdown 지침
- **대화·예약 상태**: `Sources/SillogApp/Chat/ChatState.swift`
- **채팅 범위(분야·업무 여러 개로 좁히기)**: `ChatScope.focus`(대화 기록의 `scope.focuses`), `Sources/SillogCore/Chat/ChatFocus.swift`(고를 거리, 프롬프트의 `<focus>`), `ContextSearch.swift`의 `access`(합친 범위로 거르기), `Sources/SillogApp/Views/ChatFocusPicker.swift`(범위 단추, 분야→업무 나무 `ChatFocusTree`와 고르기 규칙)
- **프로젝트 제안·소속**(화면에서 뺌, 자동 제안도 부르지 않음. 데이터와 코드는 남김): `Sources/SillogCore/Chat/ProjectOrganizer.swift`, `ProjectStore.swift`, `Sources/SillogApp/Chat/ProjectState.swift`
- **자료 보관·추출**: `Sources/SillogCore/Chat/LibraryStore.swift`, `FileTextExtractor.swift`, `Sources/SillogApp/Chat/LibraryState.swift`, `Views/LibraryView.swift`
- **그래프 화면**: `Sources/SillogApp/Resources/graph`
- **기능 켜고 끄기**: `Sources/SillogApp/AppFeatures.swift`. 캘린더(캘린더 탭, 메뉴 막대 캘린더 줄, 일정 찾기·알림, 설정·온보딩의 캘린더 권한)는 기본 꺼짐, `defaults write com.sillog.app calendar -bool true` 로 켠다
- **일정 제안**: `Sources/SillogCore/Calendar/EventFinder.swift`(정리를 반영한 뒤 그 행 전부(업무 외 포함)를 다시 보내 일정을 찾는다. 남기는 것은 대화에서 정한 약속·회의·마감과 보고 있는 과제 하나의 마감뿐이고, 기간·계획표·캘린더 앱 화면은 뺀다. 무시한 제안은 거절한 예로 같이 보내고, 한 웹페이지에서 3개 넘게 남기면 계획표로 보고 버린다. 이미 아는 일정과 겹치는 것도 거른다), `Storage/EventSuggestionStore.swift`, `Sources/SillogApp/Calendar/CalendarService.swift`(EventKit: 오늘 일정, 등록, 직접 넣은 일정은 제안에서 닫기), `AppState+Calendar.swift`(새 제안 알림, 알림의 [등록]/[무시]). 캘린더 화면은 `Views/CalendarView.swift`(오른쪽 제안 카드·연결한 캘린더), `Calendar/CalendarWebView.swift`(웹 달력과 주고받기: 보이는 기간의 일정을 약속으로 답함), `Calendar/CalendarFeed.swift`(일정·제안 → FullCalendar 이벤트), `Resources/calendar`(FullCalendar 6.1.22 표준 묶음과 한국어, MIT, `vendor/fullcalendar/LICENSE.md`). 구글 계정 직접 연결은 `Sources/SillogCore/Calendar/GoogleCalendarClient.swift`(캘린더 목록·기간 일정·일정 넣기)와 `CalendarService` 의 구글 확장(로그인은 `ConnectorAuth` 의 "gcal", 맥과 겹치는 캘린더는 `CalendarFeed.merge` 가 숨김)
- **정리 제안 (하루 한 번)**: `Sources/SillogCore/Memory/WeeklyReview.swift`(AI 2번: TaskMerger 를 60일로 + 한 제품의 다른 이름·부분 작업 규칙과 업무별 프로젝트 폴더, 주제·나중에 할 일·문제를 한 번에 `tidy_graph`. 짧은 세션 붙이기는 AI 없이. `ReviewStore` 는 review_proposals 표. 거절은 짝 단위(`ReviewProposal.units`)로 기억해 다음 주 묶음이 달라져도 빼고, 반영한 것은 막지 않음. 반영과 표시는 `ReviewStore.apply` 한 트랜잭션, 앞에서 합쳐져 사라진 키는 남은 키로 따라감. 주제·문제 정리 호출이 실패하면 업무 합치기만 제안), `Sources/SillogApp/AppState+Review.swift`(오늘 안 만들었으면 기록 정리 루프에서, 새 제안이 있을 때만 알림, 실패하면 하루 뒤, 시트를 연 동안은 갈아 끼우지 않음, 반영하는 동안 정리 멈춤), `Views/ReviewSheet.swift`(시트와 업무 목록 위 줄). 실제 기록으로 미리 보기: `SILLOG_DB=사본 sillogctl weekly-review`
- **덜 쪼개고 덜 저장하기**: `SessionBuilder.glance`(1분 미만 행은 같은 날 같은 업무 세션에 붙임), ③ 업무 설명에 `topics in use`(기존 주제 이름을 다시 쓰게), `Storage/ScreenText.swift`(편집기 글자 3천 자, 업무 외 행 글자는 첫 삭제 동의와 설정한 보관 기간을 확인한 뒤 `Consolidator`에서 지움, 기간 핀은 남김)
- **노드 상세·지우기**: `Sources/SillogCore/Ontology/NodeDetail.swift`(노드 종류별 사실과 연결 묶음), `NodeEraser.swift`(노드 하나를 하위 노드와 원시 기록까지: 세션은 그 업무의 그 시간대 행, 자료는 그 키로 분류되는 행·화면 카드, 앱은 그 앱의 행 전부. 다른 노드에도 걸린 하위 노드는 남김, 업무 종류 같은 클래스는 안 지움), `RecordEraser.swift`(행·글 조각·화면 카드·정리 기록 원문 지우기, TaskEraser 와 함께 씀), `Sources/SillogApp/AppState+NodeDetail.swift`·`Views/NodeDetailView.swift`(드로어 자리의 노드 상세, 상세 안에서 넘어가면 ‹ 뒤로), `EraseDialog`(지우기 확인 창 하나), 그래프 `index.html` 의 `refOf`/`showNode`/`nodeMenu`(보기 4개가 그린 것을 노드 키로 바꿔 앱에 보냄, 우클릭은 앱이 NSMenu 로)
- **업무 지우기**: `Sources/SillogCore/Ontology/TaskEraser.swift`(업무·분야를 원시 행, 그 행에만 쓰인 글 조각·화면 카드, AI 대화·녹음, 요약·시간 기록까지 지우고 그 업무가 나온 정리 기록 원문을 비운다. 그래프는 `TaskMerger.retire` 로 정리, `compact` 로 검색 색인 다시 쓰기와 VACUUM), `Sources/SillogApp/AppState+Erase.swift`(지우는 동안 정리 멈춤), 업무 상세의 '이 업무 지우기'(`TasksView`), CLI `sillogctl erase-theme 분야이름 [--yes]`
- **기록 정리**: `Sources/SillogCore/Memory/Consolidator.swift`, `LedgerBuilder.swift`, `ActivityTally.swift`, `Digest*.swift`, `Storage/Pruner.swift`, `RetentionPolicy.swift`, `StorageUsage.swift`, `Sources/SillogApp/Views/StorageSettingsView.swift`

채팅 하위 에이전트는 독립적인 대화와 읽기 도구를 사용하고, 재위임하지 않습니다. 시스템 프롬프트는 주 에이전트와 같지만 `agent_role`에 역할 이름이 들어가고 스킬·프로젝트·기억 자료 블록은 빠집니다. 주·하위 작업은 한 요청의 실행 예산을 공유합니다. OpenAI 호환 방식은 모델 호출 최대 24회, Codex 방식은 에이전트 실행 최대 24회와 실행별 앱 도구 호출 최대 32회입니다. 사용자가 중단하면 실행을 취소합니다.
