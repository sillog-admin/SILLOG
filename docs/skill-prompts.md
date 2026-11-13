# 스킬 지침 개선과 평가

기본 6개 스킬은 영어로 쓰며 Purpose, Procedure, Output, Definition of done으로 나눕니다. 답변 언어는 사용자 언어를 따르고, `[확인 필요: …]` 같은 표식은 시스템 프롬프트와 같은 한국어를 씁니다. 공통 규칙(근거, 보고서 구조, 결과물 형식)은 [채팅 시스템 프롬프트](../Sources/SillogCore/Chat/Prompts/chat-system-prompt.md)에 두고, 스킬에는 그 작업에만 필요한 절차를 적습니다. 사용자 편집본은 기본 리소스보다 우선하므로 업데이트로 덮어쓰지 않습니다.

아래 공개 자료에서 방법만 참고했고 문장은 옮기지 않았습니다.

| 스킬 | 참고 자료 (라이선스) |
| --- | --- |
| 문서 작성 | [anthropics/skills doc-coauthoring·internal-comms](https://github.com/anthropics/skills) (Apache-2.0), [mattpocock/skills](https://github.com/mattpocock/skills) (MIT) |
| 리서치 | [anthropics/claude-cookbooks 연구 에이전트 프롬프트](https://github.com/anthropics/claude-cookbooks/tree/main/patterns/agents/prompts) (MIT), [dzhng/deep-research](https://github.com/dzhng/deep-research) (MIT), [assafelovic/gpt-researcher](https://github.com/assafelovic/gpt-researcher) (Apache-2.0) |
| 기획·계획 | [snarktank/ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) (Apache-2.0), [obra/superpowers](https://github.com/obra/superpowers) (MIT), mattpocock/skills grilling (MIT) |
| 학습 | Google LearnLM 튜터링 가이드(google-gemini/cookbook, Apache-2.0), mattpocock/skills teach (MIT) |
| 콘텐츠 제작 | [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills) (MIT), anthropics/skills pptx (Apache-2.0) |
| 작업 자동화 | Claude Code 예약 작업 문서의 독립 실행 프롬프트 원칙 |

| 스킬 | 중점 |
| --- | --- |
| 문서 작성 | 독자·결정·양식에 맞는 초안, 상태와 개인 기여의 근거 |
| 리서치 | 동일 비교 기준, 원문·시점·상충 자료, 미확인과 부정적 결과 구분 |
| 기획·계획 | 의존성·작업 용량·완료 검사, 확정과 추정 구분 |
| 학습 | 수준에 맞는 예제, 오개념 피드백, 한 문제씩 답을 기다리는 흐름 |
| 콘텐츠 제작 | 독자·매체·핵심 메시지, 사실과 창작 분리, 공개 범위 |
| 작업 자동화 | 일회성과 반복 구분, 독립 실행 프롬프트, 0건과 실패, 승인 전 등록 금지 |

## 평가 방법

Promptfoo의 Python provider와 `llm-rubric`을 사용합니다. 12개 합성 문항을 이전·변경 지침으로 각각 실행하고 같은 기준으로 채점합니다. 실행기는 SILLOG의 인증·Responses 클라이언트를 재사용하며 개인 자료를 읽거나 실제 예약·커넥터 도구를 실행하지 않습니다. Promptfoo 공유·업로드는 사용하지 않습니다.

```sh
python3 scripts/skill-evals/build-runner.py
export SILLOG_EVAL_BINARY="$(cat build/skill-evals/binary-path.txt)"
export SILLOG_EVAL_MODEL="사용할 모델 ID"
export SILLOG_SKILL_BASE_REF="비교할 커밋"
PROMPTFOO_DISABLE_TELEMETRY=1 npx promptfoo@0.125.1 eval \
  -c scripts/skill-evals/promptfooconfig.yaml --max-concurrency 2 \
  -o build/skill-evals/results.json
```

기존 SILLOG ChatGPT 로그인이 필요하며 모델 사용량이 발생합니다. 인증값은 평가 출력에 기록하지 않습니다. `SILLOG_EVAL_SCRATCH`로 SwiftPM 빌드 경로를 지정할 수 있습니다.

이 평가는 제공 자료에 대한 답변 품질을 비교합니다. 실제 앱 도구 연동·모든 모델·모든 사용자 요청을 검증하는 테스트는 아닙니다. 모델 채점에는 변동과 편향이 있으므로 답변과 채점 이유도 확인합니다.

## 2026-11-09 실행 결과

- 도구: Promptfoo 0.125.1, `llm-rubric`, 동시 요청 2개
- 응답·채점 모델: `gpt-6.1-sol`, reasoning effort `low`
- 비교: `ff325ec`의 6개 지침과 이번 변경 지침
- 결과: 이전 12/12, 변경 12/12 통과. 오류 0건. 각 문항 1회 실행
- 검수: 변경 답변 12개를 읽어 상태·기여 구분, 동일 비교 기준, 일정 제약, 연습 진행, 공개 범위, 일회성/반복 구분을 확인

양쪽 모두 통과했으므로 이번 평가로 품질 향상을 수치로 입증하지는 못했습니다. 목표·작업 순서·결과물·완료 기준을 명확히 한 변경이며, 이 문항 범위에서 회귀가 관찰되지 않았습니다. 단일 모델이 답변과 채점을 맡는 한계가 있고, 앱 전체 시스템 지침과 실제 도구 호출을 포함한 종합 평가는 아닙니다.

문항과 재현 명령은 이 저장소에 포함합니다. 원본 응답·채점 결과는 실행 시 `build/skill-evals/results.json`에 저장되며 Git에는 포함하지 않습니다.

참고: [OpenAI Prompt engineering](https://developers.openai.com/api/docs/guides/prompt-engineering), [Promptfoo Python integration](https://www.promptfoo.dev/docs/integrations/python/), [LLM rubric](https://www.promptfoo.dev/docs/configuration/expected-outputs/model-graded/llm-rubric/).
