---
license: {license}
language:
- ko
- en
base_model: {base}
library_name: coreml
pipeline_tag: text-classification
tags:
- privacy
- sensitive-information
- coreml
---

# 수문장 (SUMUNJANG)

[SILLOG](https://github.com/sillog-admin/SILLOG)이 화면 기록을 AI에 보내기 전에 Mac 안에서 먼저 살펴보는 모델입니다. 살아 있는 특정 개인의 민감정보가 보이는 화면을 찾으면, SILLOG은 그 화면의 제목, 주소, 본문, 스크린샷을 빼고 보냅니다.

## 찾는 내용

개인정보 보호법 제23조의 민감정보 가운데 아래 다섯 범주를 찾습니다.

| 범주 | 보는 내용 |
|---|---|
| `thought_belief` | 종교와 신앙 활동, 사상과 신념 |
| `union_party` | 노동조합이나 정당 가입과 탈퇴, 조합원이나 당원 신분, 조합비와 당비 |
| `political_view` | 지지하거나 반대하는 정당과 정치인, 정책이나 선거 같은 정치 사안에 대한 입장 |
| `health` | 병력, 진료, 처방약, 정신건강, 장애 (가벼운 일시 증상은 빼요) |
| `sex_life` | 성적 지향, 성 정체성, 성생활 |

일반 지식, 기사나 글을 읽은 화면, 공인의 공적 활동은 민감정보로 보지 않습니다.

## 점수 내는 방법

1. 화면 기록 하나에서 머리글(앱, 창 제목, 주소, 파일 경로)과 화면 글을 만듭니다.
2. 화면 글을 토큰 창으로 자르고 창마다 머리글을 붙입니다. 창은 64토큰씩 겹칩니다.
3. 창마다 질문과 범주를 앞에 붙여 512토큰 입력을 만들고, 범주별 확률을 받습니다.
4. 창들 가운데 가장 높은 `1 - P(none)`이 기록 점수입니다. 0.8 이상이면 민감한 화면으로 봅니다.

질문의 토큰, 창 설정, 범주 순서는 `sumunjang.json`에 있습니다. 같은 계산을 하는 Python 코드는 SILLOG 저장소의 `scripts/sumunjang/convert.py`에 있습니다.

## 성능

실제 사용 중에 모은 화면 기록 400건(민감한 기록 160건)에서 0.8 기준으로 잰 결과입니다.

| 재현율 | 정밀도 |
|---|---|
| 91.2% (146/160) | 86.9% (146/168) |

놓치는 화면이 있으므로 이 모델만 믿고 민감정보를 다루면 안 됩니다.

## 학습

- 시작 모델: [`{base}`](https://huggingface.co/{base}) (`{base_revision}`)
- 학습 데이터: 가상 인물로 만든 합성 화면 기록 14,500건(민감한 기록 5,800건, 헷갈리기 쉬운 일반 기록 5,800건, 일상 기록 2,900건)과 검증용 500건. 실제 사용자 기록은 학습에 쓰지 않았습니다.
- 학습 코드: [laya](https://pypi.org/project/laya/) 0.4.37

## 파일

| 경로 | 내용 |
|---|---|
| `coreml/Sumunjang.mlpackage` | Core ML 모델 (fp16, 입력 1×512) |
| `tokenizer/` | 토크나이저 |
| `sumunjang.json` | 질문 토큰, 창 설정, 범주 순서 |
| `pytorch/` | 학습한 PyTorch 가중치와 설정 |
