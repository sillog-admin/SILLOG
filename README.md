<div align="center">

<a href="https://sillog.app"><img src="docs/readme/banner.png" alt="SILLOG, 쌓아 온 기록으로 다음 일을 시작해요. sillog.app 바로가기"></a>

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#준비할-것)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![CI](https://github.com/sillog-admin/SILLOG/actions/workflows/ci.yml/badge.svg)](https://github.com/sillog-admin/SILLOG/actions/workflows/ci.yml)

**[macOS용 다운로드](https://github.com/sillog-admin/sillog/releases/latest/download/SILLOG.dmg)** · [sillog.app](https://sillog.app) · [English](README.en.md)

<sub>macOS 14 이상, Apple 실리콘 Mac</sub>

<img src="landing/assets/m3.webp" width="64"> <img src="landing/assets/m5.webp" width="64"> <img src="landing/assets/m1.webp" width="64"> <img src="landing/assets/m4.webp" width="64"> <img src="landing/assets/m2.webp" width="64">

</div>

SILLOG(실록)는 Mac에서 쓰는 앱과 창, 웹페이지, 화면 글자, 파일, AI 코딩 도구에 보낸 요청, 녹음을 기록합니다. 기록은 LLM이 업무 단위로 묶어 그래프로 정리하고, 채팅에서는 이 기록을 근거로 보고서나 조사 결과, 계획을 만들어 줍니다. 답변마다 어떤 기록을 보고 썼는지 출처가 붙어 있어 바로 열어 볼 수 있습니다.

아직 초기 프로토타입입니다. 배포 파일이 Apple 공증을 받지 않아 처음 열 때 한 단계가 더 필요하고(아래 [설치](#설치) 참고), 업무 기록을 꽤 많이 모으니 쓰기 전에 [개인정보와 데이터](#개인정보와-데이터)를 먼저 읽어 주세요.

## 업무와 자료가 그래프로 이어져요

업무, 세션, 자료, 주제를 서로 연결해 저장해요. 2D와 3D 연결망, 원형 차트, 생키 다이어그램으로 바꿔 볼 수 있어요.

| 2D 연결망 | 3D 연결망 |
| :---: | :---: |
| <img src="docs/readme/graph-solar.gif" alt="2D 연결망"> | <img src="docs/readme/graph-3d.gif" alt="3D 연결망"> |
| **원형 차트** | **생키 다이어그램** |
| <img src="docs/readme/graph-sunburst.gif" alt="원형 차트"> | <img src="docs/readme/graph-branch.gif" alt="생키 다이어그램"> |

## 이렇게 부탁하면 돼요

스킬을 고르고 평소 말하듯 부탁하면, SILLOG이 기록에서 필요한 자료를 찾아요.

> 이번 주 업무 보고서 써 줘 · 이 프로젝트로 포트폴리오 항목 써 줘 · 어제 보던 자료를 비교표로 정리해 줘 · 남은 일 우선순위 정해 줘 · 최근 읽은 자료 개념 설명해 줘
>
> 발표자료 초안 만들어 줘 · 주간 보고서를 매주 만들어 줘 · 경력기술서 항목 정리해 줘 · 이 주제 자료 더 찾아서 출처 붙여 줘 · 다음 주 계획표 만들어 줘
>
> 복습 자료 만들어 줘 · 이번 작업으로 글 초안 써 줘 · 분기 보고서 써 줘 · 지난주에 찾은 자료 다시 보여 줘 · 매일 아침 어제 한 일 정리해 줘

## 입력하지 않아도 업무별로 정리돼요

처음 권한을 허용하면, 그 뒤로는 따로 입력하지 않아도 기록해요. 시장 조사 보고서.pdf, example.com, Word, 회의 메모, Keynote, Excel처럼 흩어진 기록이 이런 업무로 모여요.

| 업무 | 분야 |
| --- | --- |
| 신제품 출시 준비 | 산출물작성 › 기획서작성 |
| 경쟁사 가격 비교 | 정보수집 › 경쟁사조사 |
| 출시 일정 점검 | 행정처리 › 일정관리 |
| 공지 메일 작성 | 커뮤니케이션 › 메일처리 |
| 발표 자료 구성 | 산출물작성 › 발표자료 |

## 둘러보기

정리된 기록은 채팅에서 바로 써요. 기록을 근거로 보고서를 쓰고, 결과물을 저장하고, 그때 쓰던 자료를 다시 열 수 있어요.

| | |
| :---: | :---: |
| <img src="landing/assets/screen-answer.webp" alt="보고서 작성"><br>**보고서 작성**<br>문서 작성 스킬로 부탁하면 업무 기록을 읽어 보고서를 만들어요. | <img src="landing/assets/screen-result.webp" alt="결과물 저장"><br>**결과물 저장**<br>만든 결과물은 파일로 저장하거나 PDF로 내보내요. |
| <img src="landing/assets/screen-resume.webp" alt="다시 열기"><br>**다시 열기**<br>세션을 고르면 그때 쓰던 파일, 웹페이지, 앱을 다시 열어요. | <img src="landing/assets/screen-schedule.webp" alt="예약 작업"><br>**예약 작업**<br>반복할 일은 예약안을 먼저 보여 주고 승인하면 등록해요. |
| <img src="landing/assets/screen-file.webp" alt="파일 위치 추천"><br>**파일 위치 추천**<br>새로 받은 파일을 옮길 폴더를 추천하고 승인하면 옮겨요. | <img src="landing/assets/screen-log.webp" alt="보낸 내용 확인"><br>**보낸 내용 확인**<br>AI 계정으로 보낸 내용과 받은 결과를 활동 로그에서 확인해요. |

## 기록 원본은 내 Mac에 저장하고 보낸 내용은 직접 확인해요

SILLOG은 자체 서버를 두지 않아요. 업무 정리와 채팅은 내가 연결한 AI 계정으로 해요.

<img src="docs/readme/privacy-icons.webp" alt="저장: 기록은 내 Mac에 저장해요. 확인: 보낸 내용과 받은 결과를 활동 로그에서 봐요. 제어: 기능별로 전송을 끌 수 있어요.">

비밀번호 입력칸은 기록하지 않아요. 비밀번호 관리자와 키체인 같은 앱은 이름과 시간만 남겨요. 자세한 내용은 [개인정보와 데이터](#개인정보와-데이터)에 있습니다.

## 할 수 있는 일

<img src="docs/readme/section-features.webp" alt="">

- 지금 쓰는 앱, 창 제목, 주소, 화면 글자, 스크린샷, 다운로드한 파일, Claude Code와 Codex에 보낸 요청을 자동으로 기록합니다. 기록하고 싶지 않은 앱은 이름과 시간만 남깁니다.
- 5분마다 새 기록을 업무, 세션, 자료, 문제, 주제로 나눠 그래프로 보여 줍니다. 업무마다 썼던 파일과 페이지를 다시 열 수 있고, 필요 없는 노드는 원본 기록과 함께 지울 수 있습니다.
- 채팅에서 "지난주 결제 버그 때 뭐 했지?", "이번 주 주간 보고 써 줘"처럼 물어보면 기록을 찾아 답합니다. 대화마다 특정 업무나 분야로 범위를 좁힐 수 있습니다.
- 문서 작성, 리서치, 기획, 학습, 콘텐츠 제작, 작업 자동화 스킬을 고를 수 있고, 직접 고치거나 새로 만들 수도 있습니다.
- 결과물은 Markdown, HTML(슬라이드 포함), CSV, JSON, TXT로 저장하고 PDF로 내보낼 수 있습니다. 만든 결과물은 보관함에 모입니다.
- 반복할 조사나 보고는 예약 작업으로 등록합니다. 승인하기 전에는 실행하지 않습니다.
- 메뉴 막대에서 강의나 회의를 녹음하면 Mac 안에서 Whisper로 받아쓰고 제목과 요약을 붙입니다.
- 하루 한 번 겹치는 업무를 합치거나 끝난 할 일을 정리하자고 제안하고, 새로 받은 파일은 둘 폴더를 제안합니다. 승인한 것만 반영합니다.
- 오래된 원본 기록은 정해 둔 기간이 지나면 지우고, 그 자리는 주간·월간 요약이 대신합니다.

## 동작 방식

<img src="docs/readme/section-how.webp" alt="">

<img src="docs/readme/how-it-works.webp" alt="내 Mac 안에서 수집, SQLite 저장, 5분마다 정리, 업무 그래프, 채팅과 결과물로 이어지고, 기록 요약과 질문만 설정한 LLM으로, 허용한 경우에만 웹 검색과 커넥터로 나갑니다.">

기록은 모두 Mac 안의 SQLite에 저장됩니다. 밖으로 나가는 것은 정리와 채팅을 위해 설정한 LLM에 보내는 내용, 그리고 허용한 웹 검색과 커넥터 요청뿐입니다.

## 설치

<a href="https://github.com/sillog-admin/sillog/releases/latest/download/SILLOG.dmg"><img src="docs/readme/section-install.webp" alt=""></a>

### 준비할 것

- macOS 14 Sonoma 이상
- ChatGPT 계정. 처음 실행할 때 ChatGPT로 로그인하고, 로그인 전에는 아무것도 기록하지 않습니다.
- ChatGPT 구독으로 채팅하려면 [Codex 앱이나 Codex CLI](https://developers.openai.com/codex)가 설치되어 있어야 합니다. OpenAI 호환 API 서버를 연결해서 써도 됩니다.

### 다운로드

1. [sillog.app](https://sillog.app)에서 **macOS용 다운로드**를 누릅니다. GitHub [최신 릴리스](https://github.com/sillog-admin/SILLOG/releases/latest)의 `SILLOG.dmg`가 받아집니다.
2. dmg를 열고 SILLOG를 응용 프로그램 폴더로 옮깁니다.
3. SILLOG를 처음 열면 "'SILLOG'을(를) 열지 않음" 창이 뜹니다. 공증을 받지 않은 앱이라 그렇습니다. **완료**를 누르고, 시스템 설정 → 개인정보 보호 및 보안 맨 아래의 **그래도 열기**를 누른 다음 한 번 더 **열기**를 누르면 됩니다. macOS 15부터는 Control-클릭으로 여는 방법이 막혔습니다.

배포 파일은 매번 같은 인증서로 서명하므로, 업데이트해도 키체인 접근과 권한이 그대로 유지됩니다. 서명 방식을 바꾸기 전 버전을 쓰고 있었다면 첫 업데이트에서 한 번 더 묻습니다. 키체인 접근을 허용하고, 손쉬운 사용·화면 기록 권한을 다시 허용해 주세요.

### 처음 실행

1. 브라우저에 나오는 기기 코드로 ChatGPT에 로그인합니다.
2. 손쉬운 사용과 화면 기록 권한을 허용합니다. 화면 기록은 허용한 뒤 앱을 다시 실행해야 적용됩니다. 마이크, 음성 인식, 캘린더 권한은 그 기능을 처음 쓸 때 묻습니다.
3. 설정에서 무엇을 기록할지 고릅니다. 화면 글자, 스크린샷, AI 코딩 도구 대화, 제외할 앱을 정할 수 있습니다.
4. 설정 → AI에서 정리에 쓸 모델과 채팅에 쓸 모델을 고릅니다.

기록 일시정지와 지금 정리는 메뉴 막대에서 할 수 있습니다.

## AI 연결

<img src="docs/readme/section-ai.webp" alt="">

| 연결 | 쓰는 곳 | 설명 |
| --- | --- | --- |
| ChatGPT 구독 | 정리, 채팅, 판단 | 앱 전용 ChatGPT 로그인으로 Codex 백엔드를 씁니다. 요금제 사용량 안에서 쓰므로 따로 요금이 나가지 않습니다. 공개 API가 아니어서 규격이 바뀔 수 있습니다. 채팅은 셸 실행과 파일 쓰기를 끈 로컬 `codex app-server`로 돌아갑니다. |
| API 서버 | 정리, 채팅, 판단 | OpenAI 호환 `/chat/completions` 서버면 됩니다. OpenAI 같은 클라우드 서비스나 Ollama, LM Studio 같은 로컬 모델을 쓸 수 있습니다. 요금은 각 서비스 기준이고, 웹 검색은 공식 OpenAI API에서만 됩니다. |
| OpenAI Decisions, Jev | 판단 | 기록 한 줄마다 어느 업무인지 고르기만 하는 모델입니다. |

## 커넥터

커넥터는 읽기만 합니다. 메일을 보내거나 파일을 고치거나 저장소를 바꾸지 않습니다. 연결 정보는 macOS 키체인에 저장합니다.

| 커넥터 | 연결 방법 | 지금 상태 |
| --- | --- | --- |
| Notion, Lovable, Higgsfield, Canva | 브라우저에서 로그인하고 승인 | 키를 따로 만들 필요 없이 연결됩니다 |
| Slack | 브라우저에서 로그인하고 승인 | 워크스페이스 설정에 따라 관리자 승인이 필요할 수 있습니다 |
| Gmail, Google Drive | Google 로그인 후 승인 | Google 앱이 테스트 상태라 초대된 계정만 쓸 수 있고, 7일마다 다시 연결해야 합니다 |
| GitHub | 기기 코드 입력 | 배포 버전에서는 아직 쓸 수 없습니다 |
| Figma, Discord | 직접 발급한 토큰 입력 | 연결 창의 안내대로 토큰을 만들어야 합니다 |

직접 빌드해서 커넥터를 설정하는 방법은 [docs/connectors.md](docs/connectors.md)에 있습니다.

## 개인정보와 데이터

<img src="docs/readme/section-privacy.webp" alt="">

기록은 Mac에 저장되지만, 정리와 채팅에 쓰는 내용은 설정한 모델로 보내집니다. 클라우드 모델을 쓰면 그 내용이 Mac 밖으로 나간다는 뜻입니다.

- 기록하는 것: 앱 이름, 창 제목, 주소, 화면 글자, 켜 둔 경우 스크린샷, 다운로드 폴더의 새 파일, Claude Code와 Codex에 보낸 요청, 직접 시작한 녹음. 제외한 앱과 SILLOG 자신은 앱 이름과 시간만 남깁니다.
- 채팅이 읽는 것: 대화에서 고른 범위의 기록, 연결한 파일과 폴더, 보관함 자료, 그 대화에서 켠 커넥터. 기록에 파일 경로가 나왔다고 해서 그 파일을 읽지는 않습니다.
- 채팅이 하지 않는 것: 명령 실행, 파일 수정이나 이동, 메시지 발송, 커넥터에 쓰기.
- 비밀값: API 키와 커넥터 토큰은 키체인에, ChatGPT 로그인 정보는 권한 `600` 파일에 두고 백업에서 뺍니다. 도구 결과에서 찾은 주민등록번호 같은 식별 번호는 모델에 보내기 전에 가립니다.
- 보관 기간 기본값: 화면 글자 30일, 스크린샷 7일, 활동 기록 90일, 화면 카드 180일, AI 도구 요청과 파일 기록 365일. 설정 → 일반에서 바꿀 수 있고, 처음 지우기 전에 한 번 묻습니다.
- 지우기: 업무, 분야, 그래프 노드를 오른쪽 클릭하면 원본 기록까지 함께 지울 수 있습니다.

```text
~/Library/Application Support/Sillog/
├── sillog.sqlite   # 활동, 그래프, 대화, 결과물, 예약
├── captures/       # 스크린샷
├── library/        # 올린 파일, 결과물, 저장한 답변
├── codex-auth.json # 앱 전용 ChatGPT 로그인
└── app.log         # 실행 로그
```

## 자주 묻는 질문

<details>
<summary><b>SILLOG은 무엇을 기록하나요?</b></summary>

앱, 창 제목, 주소, 파일 경로, 화면 글자, 스크린샷, 다운로드한 파일, AI 코딩 도구(Claude Code, Codex CLI)에 입력한 메시지를 기록해요. 2분 넘게 입력이 없으면 자리 비움으로 기록해요. 녹음은 직접 시작했을 때만 하고 Mac 안에서 글로 받아써요.
</details>

<details>
<summary><b>기록은 어디에 저장되나요?</b></summary>

내 Mac에 저장해요. SILLOG은 자체 서버를 두지 않아요.
</details>

<details>
<summary><b>밖으로 나가는 내용은 무엇인가요?</b></summary>

업무를 정리하고 채팅에 답하려고 기록 내용을 내가 연결한 AI 계정으로 보내요. 대표 화면의 스크린샷도 함께 보내요. 채팅에서 찾아본 자료, 허용한 웹 검색과 커넥터 통신도 밖으로 나가요. 보낸 내용은 활동 로그에서 확인하고 기능별로 전송을 끌 수 있어요.
</details>

<details>
<summary><b>어떤 AI 계정이 필요한가요?</b></summary>

ChatGPT 구독과 API(OpenAI 호환) 가운데 하나를 연결해요. ChatGPT 구독으로 채팅하려면 Codex CLI나 Codex 앱이 설치되어 있어야 해요. API로 연결하면 호출 요금이 나와요.
</details>

<details>
<summary><b>기록하고 싶지 않은 앱이 있어요.</b></summary>

기록하지 않을 앱을 추가하면 그 앱은 이름과 시간만 남겨요. 비밀번호 관리자와 키체인은 처음부터 제외되어 있고 비밀번호 입력칸은 기록하지 않아요.
</details>

<details>
<summary><b>스크린샷은 얼마나 보관하나요?</b></summary>

기본 7일이고 1일에서 90일 사이로 바꿀 수 있어요.
</details>

<details>
<summary><b>어떤 컴퓨터에서 쓸 수 있나요?</b></summary>

지금은 macOS 14 이상의 Apple 실리콘 Mac에서 쓸 수 있어요. Windows와 모바일은 아직 준비 중이에요.
</details>

## 아직 안 되는 것

- macOS에서만 돌아가고, 배포 파일은 아직 공증 전입니다.
- 결과물은 텍스트 형식과 PDF 내보내기까지만 됩니다. DOCX, PPTX, XLSX는 읽을 수는 있지만 만들지는 못합니다.
- 예약 작업은 몇 시간마다 반복하는 방식이고 SILLOG가 켜져 있을 때만 돕니다. 요일이나 시각은 지정할 수 없습니다.
- 스캔한 PDF는 글자를 인식하지 않고, 이미지는 안에 있는 글자만 읽습니다.
- Gmail과 Drive는 Google 검수가 끝날 때까지 테스트 계정만 쓸 수 있습니다.

## 소스에서 빌드하기

Xcode 26(Swift 6.2)이 필요합니다. Command Line Tools만 있으면 빌드는 되지만 테스트는 돌릴 수 없습니다. 직접 빌드한 앱은 인터넷에서 받은 파일이 아니어서 위의 "열지 않음" 창이 뜨지 않습니다.

예상 소요 시간: 약 2분

```bash
git clone https://github.com/sillog-admin/SILLOG.git
cd SILLOG
./scripts/make-app.sh
open build/SILLOG.app
```

`make-app.sh`는 릴리스 빌드와 서명을 하고 `~/Applications`에 설치합니다. 개발할 때는 아래 명령을 씁니다.

```bash
swift build
swift test
swift run sillogctl --help
```

`sillogctl`은 기본으로 실제 기록 DB를 엽니다. 실험할 때는 `--db`로 다른 파일을 지정하세요. 더 자세한 내용은 아래 문서에 있습니다.

- [docs/development.md](docs/development.md): 빌드해도 권한을 유지하는 방법, 환경변수, 모델 없이 흐름 확인하기
- [docs/connectors.md](docs/connectors.md): 커넥터별 OAuth 설정
- [CLAUDE.md](CLAUDE.md): 코드 구조와 작성 규칙
- [채팅 시스템 프롬프트](Sources/SillogCore/Chat/Prompts/chat-system-prompt.md), [스킬](Sources/SillogCore/Chat/Skills)

## 기여하기

이슈와 PR 모두 환영합니다. PR을 올리기 전에 로컬에서 `swift build`와 `swift test`를 돌려 주세요. CI에서는 OCR로 확인하는 UI 테스트 몇 개를 건너뛰기 때문입니다. 커밋 메시지는 `fix: 로그인 오류 수정`처럼 `태그: 요약` 한 줄로 씁니다. `.env`나 API 키, 내 기록을 덤프한 파일은 올리지 마세요. 보내 주신 코드는 AGPL-3.0으로 배포됩니다.

보안 문제는 공개 이슈 대신 [비공개 취약점 신고](https://github.com/sillog-admin/SILLOG/security/advisories/new)로 알려 주세요.

## 라이선스

SILLOG는 [GNU Affero General Public License v3.0](LICENSE)으로 배포합니다. 누구나 쓰고 고치고 다시 배포할 수 있습니다. 다만 고친 버전을 배포하거나 웹 서비스처럼 네트워크로 제공한다면, 그 버전의 소스 코드 전체를 같은 라이선스로 공개해야 합니다.

함께 쓰는 라이브러리는 각자의 라이선스를 따릅니다. [GRDB.swift](https://github.com/groue/GRDB.swift), [WhisperKit](https://github.com/argmaxinc/WhisperKit), [SwiftMath](https://github.com/mgriebling/SwiftMath), [LangGraph-Swift](https://github.com/bsorrentino/LangGraph-Swift), [force-graph](https://github.com/vasturiano/force-graph), [FullCalendar](https://github.com/fullcalendar/fullcalendar), [Mermaid](https://github.com/mermaid-js/mermaid)는 MIT이고, SUIT와 Jost 글꼴은 [SIL OFL 1.1](Sources/SillogApp/Resources/Brand/Fonts)입니다. 그 밖의 고지는 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)에 있습니다.

---

<div align="center">

<img src="landing/assets/m2.webp" width="56"> <img src="landing/assets/m3.webp" width="56"> <img src="landing/assets/m1.webp" width="56"> <img src="landing/assets/m5.webp" width="56"> <img src="landing/assets/m4.webp" width="56">

### 지금 SILLOG을 만나 보세요

**[macOS용 다운로드](https://github.com/sillog-admin/sillog/releases/latest/download/SILLOG.dmg)** · [sillog.app](https://sillog.app)

</div>
