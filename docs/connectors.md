# 커넥터 설정

[README로 돌아가기](../README.ko.md)

Sillog의 커넥터는 외부 서비스의 자료를 검색하고 읽기 위한 계정 연결입니다. 메일 발송, 파일 수정, 저장소 변경은 지원하지 않습니다.

## 제공자와 사용자 역할

**앱 제공자**가 각 서비스에 OAuth 앱을 등록하고 클라이언트 ID를 설정합니다. **사용자**는 Sillog에서 설치할 커넥터를 고른 뒤 서비스의 로그인·권한 승인 화면만 거칩니다. 일반 사용자가 OAuth 앱을 직접 등록하는 방식이 아닙니다.

공식 배포용 공개 클라이언트 정보는 `Config/OAuthClients.plist`에서 읽어 앱 번들에 넣습니다. 등록된 서비스는 소스에서 빌드할 때도 사용자가 키를 발급할 필요가 없습니다. 별도 배포자는 아래 환경 변수로 자신의 OAuth 앱 설정을 지정할 수 있습니다. 이 파일에는 사용자 토큰이나 서버용 클라이언트 비밀키를 넣지 않습니다. GitHub 디바이스 인증에는 최초 연결 때 짧은 승인 코드 입력이 추가됩니다.

ChatGPT의 앱 연결은 별개입니다. 해당 권한이나 토큰을 Sillog에 복사할 수 없습니다.

Gmail·Google Drive·Slack은 설치형 OAuth로, Notion·Higgsfield·Lovable·Canva는 공급자가 운영하는 MCP의 OAuth로 연결합니다. 이 경로에는 Sillog 운영 서버가 필요하지 않습니다. 계정 연결 성공과 실제 자료 조회 성공은 별도로 확인합니다. 연결 상세의 **검색·읽기 확인**은 검색 결과를 바탕으로 원문을 읽으며, 자료가 없으면 읽기 성공으로 표시하지 않습니다.

## Google: Gmail · Google Drive · Google Calendar

**진행 보류 (2026-11-09 사용자 결정):** Gmail·Drive 일반 공개를 위한 홈페이지·개인정보 안내 게시, 도메인 등록·구매, Google 검증·심사, 관련 AI 연결 제한 변경은 보류합니다. 사용자가 다시 요청하기 전에는 진행하거나 추가 결정을 요청하지 않습니다. 현재 테스트 계정의 기존 연결은 유지합니다. 미완료한 커넥터 검수의 추가 로그인·승인 요청도 중단합니다.

- [데스크톱 앱용 OAuth 클라이언트](https://developers.google.com/identity/protocols/oauth2/native-app)를 등록합니다.
- Gmail·Drive·Calendar API를 사용할 수 있도록 프로젝트를 설정합니다. Gmail·Drive는 읽기 전용, 캘린더(캘린더 탭의 [구글 계정 연결])는 캘린더 목록 읽기(`calendar.calendarlist.readonly`)와 일정 읽기·쓰기(`calendar.events`)를 요청합니다. 캘린더 권한은 구글이 민감한 권한으로 분류해, 앱 검수 전에는 OAuth 동의 화면에 등록한 테스트 사용자만 로그인할 수 있습니다.
- 빌드할 때 `SILLOG_GOOGLE_CLIENT_ID`를 설정합니다. 데스크톱 앱 클라이언트는 토큰 교환에 클라이언트 시크릿도 요구하므로 `SILLOG_GOOGLE_CLIENT_SECRET`도 함께 넣습니다(설치형 앱의 시크릿은 비밀로 취급되지 않습니다).
- 캘린더 탭에서 연결하면 맥 캘린더에 이미 같은 구글 계정이 있을 때 같은 이름의 캘린더는 맥 쪽만 보여 줍니다. [등록할 캘린더]에서 구글 캘린더를 고르면 [등록]이 구글 API로 바로 넣습니다.
- 사용자는 필요한 Gmail·Drive 항목만 고르고 Google에서 승인합니다. 선택한 항목에 해당하는 권한을 요청합니다.
- 로컬 콜백은 `http://127.0.0.1:8765/callback`입니다. 승인 중 앱이 실행되고 포트를 사용할 수 있어야 합니다.

TODO (정식 게시 전):
- [ ] 브랜드 인증: sillog.app에 개인정보처리방침 추가, Search Console 도메인 확인, Google Auth Platform → 브랜딩에서 신청. 권한 수정과 상관없이 먼저 할 수 있습니다.
- [ ] Gmail: 제한 권한이라 매년 유료 보안 평가(CASA)가 필요해 배포 버전에서 숨깁니다.
- [ ] Drive: `drive.readonly`를 `drive.file`과 파일 선택창으로 바꿉니다.
- [ ] 캘린더: 권한 심사 동안 Google 연결 버튼을 숨깁니다(`CalendarService.googleAvailable`).
- [ ] 권한 심사: 브랜드 인증과 Drive 변경을 마친 뒤 캘린더·Drive 권한으로 신청합니다.

```bash
SILLOG_GOOGLE_CLIENT_ID="등록한 클라이언트 ID" SILLOG_GOOGLE_CLIENT_SECRET="클라이언트 시크릿" ./scripts/make-app.sh
```

## GitHub

`sillog-admin` 계정에 GitHub App을 등록하고, 기기 코드 승인(디바이스 인증)으로 연결합니다. 로컬 콜백 포트와 클라이언트 비밀키는 쓰지 않습니다.

- GitHub App은 **Contents**, **Pull requests** 읽기 전용 권한과 **Enable Device Flow**, **Expire user authorization tokens**를 켜고, 어느 계정에나 설치할 수 있게 등록합니다.
- `Config/OAuthClients.plist`에 `SILLOG_GITHUB_CLIENT_ID`(앱의 Client ID)와 `SILLOG_GITHUB_APP_SLUG`(앱 주소 `github.com/apps/<slug>`의 slug)를 넣습니다.
- 사용자는 SILLOG에 표시된 코드를 GitHub에 입력해 로그인한 뒤, 이어서 열리는 GitHub 화면에서 SILLOG이 읽을 Repository를 고릅니다. 고르지 않으면 로그인은 되어도 Repository가 보이지 않습니다. 나중에는 커넥터 상세의 **Repository 선택**에서 바꿉니다.

```bash
SILLOG_GITHUB_CLIENT_ID="Client ID" SILLOG_GITHUB_APP_SLUG="앱 slug" ./scripts/make-app.sh
```

디바이스 인증으로 발급한 토큰은 클라이언트 비밀키나 별도 서버 없이 자동 갱신합니다. GitHub App의 기본 액세스 토큰은 8시간 후 만료되며 갱신 토큰은 6개월 동안 유효합니다. 갱신 토큰이 만료되거나 사용자가 권한을 철회하면 다시 연결해야 합니다. [GitHub 토큰 갱신 안내](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens)

## Slack

- 앱 제공자가 Slack 앱을 등록하고 `oauth_config.pkce_enabled`를 활성화합니다. 공개 클라이언트로 전환하면 되돌리기 위해 Slack 지원이 필요하므로 별도 배포 앱을 등록하세요.
- 사용자 범위는 `search:read`만 요청합니다. 봇 범위는 요청하지 않습니다.
- 리다이렉트 URI는 `sillog://oauth/slack`입니다. 공개 배포에서 HTTP localhost 주소가 거부되므로 앱 매니페스트의 `oauth_config.redirect_urls`에 등록합니다. macOS URL 등록과 앱의 콜백 처리도 같은 주소를 사용합니다.
- 빌드할 때 `SILLOG_SLACK_CLIENT_ID`를 설정합니다. 클라이언트 비밀키는 사용하거나 배포하지 않습니다.
- 브라우저에서 선택한 워크스페이스를 승인하면 사용자 토큰을 저장합니다. PKCE 토큰 교환과 갱신을 앱에서 수행합니다. 워크스페이스의 앱 승인 정책에 따라 관리자 승인이 필요할 수 있습니다.
- 배포 시 Slack의 외부 워크스페이스 설치·배포 설정도 별도로 완료해야 합니다.

[Slack PKCE 안내](https://docs.slack.dev/authentication/using-pkce/)

## Notion · Higgsfield · Lovable · Canva

앱이 공급자에게 설치형 클라이언트를 자동 등록하고, PKCE와 브라우저 승인으로 연결합니다. 사용자가 개발자 앱을 만들거나 API 키를 붙여 넣을 필요가 없습니다.

| 서비스 | 공식 연결 주소 | 요청 범위 |
| --- | --- | --- |
| Notion | `https://mcp.notion.com/mcp` | `default` |
| Higgsfield | `https://mcp.higgsfield.ai/mcp` | `openid email offline_access` |
| Lovable | `https://mcp.lovable.dev` | `offline projects:read workspaces:read` |
| Canva | `https://mcp.canva.com/mcp` | `profile:read design:meta:read design:content:read folder:read comment:read` |

- 로컬 콜백은 `http://127.0.0.1:8765/callback`입니다.
- 등록한 클라이언트 ID와 갱신 토큰은 Keychain에 보관해 재사용합니다. 공유 클라이언트 비밀키를 번들에 넣지 않습니다.
- Notion·Higgsfield의 공급자 승인 범위에는 쓰기 기능이 포함될 수 있습니다. Sillog은 별도의 **명시적 읽기 도구 허용 목록**을 실행 직전에 검사합니다. 공급자가 `readOnlyHint`를 표시하더라도 허용 목록에 없는 도구는 실행하지 않습니다.
- Canva에는 읽기 범위만 요청하고, 디자인 검색·페이지·글자·댓글·폴더 읽기 도구만 허용합니다.
- Lovable에는 프로젝트·워크스페이스 읽기 범위만 요청합니다. 코드 읽기를 제공하며 생성·메시지 전송·배포·SQL 실행은 허용하지 않습니다.
- 기존에 수동 토큰으로 연결한 계정은 다시 연결하기 전까지 기존 읽기 경로를 유지합니다. MCP 토큰을 REST API에 전달하지 않습니다.
- 구독·관리자 정책·자료 접근 범위는 서비스마다 다릅니다. 연결됐더라도 자료가 없거나 접근이 제한되면 검색·읽기 검사를 통과하지 못할 수 있습니다.

[Notion 클라이언트 구현 안내](https://developers.notion.com/guides/mcp/build-mcp-client), [Higgsfield MCP](https://higgsfield.ai/mcp), [Lovable MCP](https://docs.lovable.dev/integrations/lovable-mcp-server), [Canva MCP](https://www.canva.dev/docs/mcp/tools/)

## 인증 정보와 배포

- 검수 중에는 기존 설치본을 유지하고 불필요한 재빌드·재연결을 피합니다. 키체인 승인은 실제 macOS 요청이 표시되어 필요한 작업이 막혔을 때만 사용자에게 요청합니다. 단순한 지연이나 오류를 키체인 승인 대기로 추정하지 않습니다. 현재 임시 서명 빌드는 교체 시 다시 신뢰 확인이 필요할 수 있으며, 배포용 서명·공증은 별도 작업입니다.
- Google 설치형 클라이언트 정보와 공개 클라이언트 ID를 빌드 시 설정합니다. 각 변수는 함께 설정할 수 있습니다.
- 승인 후 받은 커넥터 토큰은 macOS Keychain에 저장합니다.
- 계정 연결·해제 상태는 커넥터 화면에서 확인합니다. 연결한 서비스도 대화의 자료 설정에서 사용을 허용해야 조회합니다.
- 공급자 앱 등록과 필요한 검증·권한 설정이 끝나기 전에는 실제 연결을 사용할 수 없습니다.
- Google·Notion·Higgsfield·Lovable·Canva는 승인 중 로컬 포트 8765를 사용합니다. 같은 포트를 쓰는 다른 실행이 있으면 먼저 종료해야 합니다. Slack은 앱 전용 URL로 돌아오므로 이 포트를 사용하지 않습니다.

Google의 테스트 모드 연결 성공은 일반 사용자용 공개 검수 완료를 뜻하지 않습니다. Gmail·Drive의 읽기 범위와 조회 자료를 AI에 전달하는 흐름을 포함해 공개 배포 요건을 확인해야 합니다. Figma·Discord는 사용자가 직접 발급한 토큰으로 연결하고, 연결 창에 발급 순서를 안내합니다.
