# 기여하기

[English](#contributing)

이슈와 PR 모두 환영합니다.

## 이슈

- 버그는 macOS 버전, SILLOG 버전(내려받은 릴리스 이름, 예: SILLOG 0.1.0 (build 22)), 재현 순서를 적어 주세요.
- 로그(`~/Library/Application Support/Sillog/app.log`)를 붙일 때는 내 기록, 파일 경로, 계정 정보가 들어 있지 않은지 먼저 확인해 주세요.
- 보안 문제는 이슈로 올리지 말고 [보안 정책](SECURITY.md)을 따라 주세요.

## PR

1. 빌드 방법은 README의 [소스에서 빌드하기](README.md#소스에서-빌드하기)에 있습니다. Xcode 26(Swift 6.2)이 필요합니다.
2. PR을 올리기 전에 로컬에서 `swift build`와 `swift test`를 돌려 주세요. CI에서는 OCR로 확인하는 UI 테스트 몇 개를 건너뛰기 때문입니다.
3. 커밋 메시지는 `fix: 로그인 오류 수정`처럼 `태그: 요약` 한 줄로 씁니다. 태그는 `feat`, `fix`, `refactor`, `test`, `docs`, `ci`를 씁니다.
4. `.env`나 API 키, 내 기록을 덤프한 파일은 올리지 마세요. `sillogctl`로 실험할 때는 `--db`로 다른 파일을 지정하세요.

코드 구조와 작성 규칙은 [CLAUDE.md](CLAUDE.md), 개발 환경은 [docs/development.md](docs/development.md), 커넥터 설정은 [docs/connectors.md](docs/connectors.md)에 있습니다.

## 라이선스

보내 주신 코드는 [AGPL-3.0](LICENSE)으로 배포됩니다.

---

# Contributing

[한국어](#기여하기)

Issues and pull requests are welcome.

## Issues

- For bugs, include your macOS version, SILLOG version (the release you downloaded, like SILLOG 0.1.0 (build 22)), and steps to reproduce.
- If you attach the log (`~/Library/Application Support/Sillog/app.log`), check first that it doesn't contain your records, file paths, or account details.
- Don't file security issues publicly. Follow the [security policy](SECURITY.md) instead.

## Pull requests

1. Build steps are in [Build from source](README.en.md#build-from-source). You need Xcode 26 (Swift 6.2).
2. Run `swift build` and `swift test` locally before you open a PR, since CI skips a few OCR-based UI tests.
3. Commit messages are one line in the form `type: summary`, like `fix: handle expired token`. Types are `feat`, `fix`, `refactor`, `test`, `docs`, and `ci`.
4. Don't commit `.env`, API keys, or dumps of your own records. When you experiment with `sillogctl`, pass `--db` with a scratch file.

Code structure and conventions are in [CLAUDE.md](CLAUDE.md), the development setup is in [docs/development.md](docs/development.md), and connector setup is in [docs/connectors.md](docs/connectors.md).

## License

Contributions are distributed under [AGPL-3.0](LICENSE).
