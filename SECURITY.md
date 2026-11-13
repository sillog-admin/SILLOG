# 보안 정책

[English](#security-policy)

## 신고하는 방법

보안 문제는 공개 이슈로 올리지 말고 [비공개 취약점 신고](https://github.com/sillog-admin/SILLOG/security/advisories/new)로 알려 주세요. 신고 내용은 저장소 관리자만 볼 수 있습니다.

다음을 적어 주시면 확인이 빠릅니다.

- 문제가 되는 기능과 SILLOG 버전
- 재현 순서
- 어떤 정보가 어디까지 노출되거나 바뀔 수 있는지

## 지원하는 버전

[최신 릴리스](https://github.com/sillog-admin/SILLOG/releases/latest)만 보안 수정을 받습니다.

## 특히 알려 주셨으면 하는 것

SILLOG은 Mac에서 한 일을 기록하는 앱이라 다음 문제를 중요하게 봅니다.

- 기록, 스크린샷, 녹음이 설정한 LLM이나 허용한 커넥터 밖으로 나가는 경우
- 제외한 앱이나 비밀번호 입력칸의 내용이 기록되는 경우
- API 키, 커넥터 토큰, ChatGPT 로그인 정보가 키체인이나 보호된 파일 밖으로 새는 경우
- 채팅이 명령 실행, 파일 수정, 메시지 발송, 커넥터 쓰기를 하게 되는 경우

---

# Security policy

[한국어](#보안-정책)

## Reporting

Don't file security issues publicly. Report them through [private vulnerability reporting](https://github.com/sillog-admin/SILLOG/security/advisories/new), which only the maintainers can see.

It helps to include:

- The affected feature and SILLOG version
- Steps to reproduce
- What information could be exposed or changed, and how far

## Supported versions

Only the [latest release](https://github.com/sillog-admin/SILLOG/releases/latest) gets security fixes.

## What we especially want to hear about

SILLOG records what you do on your Mac, so we treat these as important:

- Records, screenshots, or recordings leaving your Mac other than to the LLM you set up or connectors you allowed
- Content from excluded apps or password fields getting recorded
- API keys, connector tokens, or the ChatGPT sign-in leaking outside the Keychain or protected files
- Chat being able to run commands, edit files, send messages, or write to connectors
