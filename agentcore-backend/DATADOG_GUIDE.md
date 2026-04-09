# 🐶 Datadog LLM Observability 실습 가이드

## 실습 개요

AgentCore Backend에 Datadog LLM Observability를 연동하여 에이전트의 동작을 모니터링하고, 문제를 진단/해결하고, 모델별 퍼포먼스를 비교합니다.

**사전 준비**:
- Part 1 (AWS 인프라 + 에이전트 구축) 완료
- Datadog 계정 + API Key
- ECS에 에이전트 배포 완료

---

## Step 1. Datadog LLM Observability 연동

### 1-1. Datadog 스택 배포

```bash
cd agentcore-backend
./deploy-datadog.sh
```

입력 항목:
- Datadog API Key (필수)
- Datadog Site (기본: `datadoghq.com`)
- ML App 이름 (기본: `agentcore-backend`)

스크립트가 자동으로:
1. Datadog 환경변수가 포함된 새 Task Definition 생성
2. ECS Service를 새 Task Definition으로 업데이트

### 1-2. 연동 확인

Datadog 콘솔에서 확인:
1. **LLM Observability** → **Traces** 탭 이동
2. Chainlit UI에서 아무 질문 입력 (예: "연차 휴가 신청 방법 알려줘")
3. 1~2분 후 Traces에 트레이스가 나타나는지 확인

트레이스에서 확인할 수 있는 정보:
- LLM 호출 (모델, 입력/출력, 토큰 수, 레이턴시)
- Tool 호출 (search_kb, createTicket 등)
- 에러 발생 시 에러 메시지 및 스택 트레이스

### 1-3. 주요 환경변수

| 환경변수 | 값 | 설명 |
|---|---|---|
| `DD_LLMOBS_ENABLED` | `1` | LLM Observability 활성화 |
| `DD_LLMOBS_ML_APP` | `agentcore-backend` | Datadog에서 앱 이름 |
| `DD_LLMOBS_AGENTLESS_ENABLED` | `1` | Agent 없이 직접 전송 |
| `DD_PATCH_MODULES` | `langchain:true,botocore:true` | 자동 계측 대상 |
| `DD_SERVICE` | `agentcore-backend` | 서비스 이름 |
| `DD_ENV` | `workshop` | 환경 태그 |

---

## Step 2. Troubleshooting 시나리오

> 오류 시나리오는 에이전트에 내장되어 있어 별도 환경변수 변경이 필요 없습니다.
> 질문 내용에 따라 자동으로 정상/오류가 분기됩니다.

### 시나리오 1: 토큰 에러 진단

**상황**: 특정 질문에서 에이전트가 응답을 제대로 생성하지 못하고 잘린 응답이나 에러가 발생

#### 에러 재현

"요약", "정리", "상세히", "자세히", "모두", "알려줘" 등의 키워드가 포함된 질문을 하면 자동으로 `max_tokens=10`이 적용되어 토큰 에러가 발생합니다.

Chainlit UI에서 질문:
```
"휴가 정책을 상세히 요약 정리해줘"
"경비 처리 절차를 자세히 모두 알려줘"
```

→ 응답이 잘리거나 tool calling JSON 파싱 에러 발생

#### 정상 질문과 비교

```
"연차 휴가는 며칠까지 쓸 수 있나요?"  → 정상 ✅
"경비 처리 절차를 알려주세요"          → 정상 ✅
"휴가 정책을 상세히 요약 정리해줘"     → 에러 ❌ (토큰 초과)
```

#### Datadog에서 원인 파악

1. **LLM Observability** → **Traces** 이동
2. 에러가 있는 트레이스 클릭
3. LLM span에서 확인:
   - `stop_reason: max_tokens` ← 토큰 한도 초과로 응답이 잘림
   - 출력이 불완전한 JSON으로 끝남
   - 후속 span에서 파싱 에러 발생
4. 정상 트레이스와 비교:
   - 정상 트레이스는 `stop_reason: end_turn`
   - 토큰 에러 트레이스만 `max_tokens`가 비정상적으로 낮음

---

### 시나리오 2: Failure to Answer 진단

**상황**: 특정 질문(보안 관련)만 KB 검색이 실패하고, 나머지 질문은 정상 동작

#### 에러 재현

"보안", "VPN", "비밀번호", "MFA", "인증", "암호화", "피싱" 등 보안 관련 키워드가 포함된 질문을 하면 자동으로 잘못된 KB ID로 검색을 시도하여 에러가 발생합니다.

Chainlit UI에서 테스트:
```
"휴가 신청 방법 알려줘"     → 정상 ✅
"경비 처리 절차 알려줘"     → 정상 ✅
"IT 보안 정책 알려줘"       → 에러 ❌
"VPN 접속 방법 알려줘"      → 에러 ❌
"비밀번호 변경 방법 알려줘"  → 에러 ❌
```

#### Datadog에서 원인 파악

1. **Traces** 에서 에러가 있는 트레이스와 정상 트레이스를 비교
2. 에러 트레이스의 `search_kb` tool span 확인:
   - 에러: `ResourceNotFoundException` 또는 `ValidationException`
   - 에러 메시지에 `INVALID_KB_ID_WORKSHOP` 관련 내용
   - 보안 관련 질문에서만 발생하는 패턴 확인
3. 정상 트레이스의 `search_kb` span과 비교:
   - 정상 트레이스는 올바른 KB ID 사용
   - 보안 키워드가 없는 질문은 정상 동작

### 테스트 스크립트로 한번에 실행

정상 + 오류 질문을 한번에 보내서 Datadog에 트레이스를 생성할 수 있습니다:

```bash
DD_LLMOBS_ENABLED=1 \
DD_LLMOBS_ML_APP=agentcore-backend \
DD_LLMOBS_AGENTLESS_ENABLED=1 \
DD_API_KEY=<YOUR_DATADOG_API_KEY> \
DD_SITE=<YOUR_DD_SITE> \
DD_PATCH_MODULES=langchain:true,botocore:true \
ddtrace-run python test_scenarios.py
```

실행되는 테스트:
| 질문 | 예상 결과 |
|---|---|
| 연차 휴가는 며칠까지 쓸 수 있나요? | 정상 ✅ |
| 경비 처리 절차를 알려주세요 | 정상 ✅ |
| 신입 직원 온보딩 첫날 일정이 어떻게 되나요? | 정상 ✅ |
| 휴가 정책을 상세히 요약 정리해줘 | 토큰 에러 ❌ |
| 경비 처리 절차를 자세히 모두 알려줘 | 토큰 에러 ❌ |
| IT 보안 정책 알려줘 | KB 에러 ❌ |
| VPN 접속 방법을 알려주세요 | KB 에러 ❌ |
| 비밀번호 변경은 어떻게 하나요? | KB 에러 ❌ |
| 안녕하세요, 간단히 자기소개 해주세요 | 정상 ✅ |

---

## Step 3. 모델별 퍼포먼스 비교

### 3-1. 벤치마크 실행

여러 모델에 동일한 질문 세트를 실행하여 트레이스를 생성합니다.

```bash
cd agentcore-backend
source venv/bin/activate

DD_LLMOBS_ENABLED=1 \
DD_LLMOBS_ML_APP=agentcore-benchmark \
DD_LLMOBS_AGENTLESS_ENABLED=1 \
DD_API_KEY=<YOUR_DATADOG_API_KEY> \
DD_SITE=<YOUR_DD_SITE> \
DD_PATCH_MODULES=botocore:true \
ddtrace-run python benchmark.py --models sonnet-4.5,haiku-3.5,sonnet-3.7
```

실행 결과:
- 7개 질문 × 3개 모델 = 21회 LLM 호출
- 각 호출이 Datadog 트레이스로 기록됨
- 터미널에 모델별 평균 레이턴시 요약 출력
- `benchmark_results.json`에 상세 결과 저장

### 3-2. Datadog에서 비교

1. **LLM Observability** → **Traces** 이동
2. 필터: `ML App = agentcore-benchmark`
3. 모델별로 확인할 수 있는 항목:

| 비교 항목 | 확인 방법 |
|---|---|
| 레이턴시 | 트레이스 duration (ms) |
| 토큰 사용량 | LLM span의 input/output tokens |
| 비용 | 토큰 수 × 모델별 단가 |
| 응답 품질 | LLM span의 output 내용 비교 |

### 3-3. 비교 대상 모델 참고

| 모델 | 특징 | 예상 레이턴시 | 비용 |
|---|---|---|---|
| `sonnet-4.5` | 균형 (기본값) | 중간 | 중간 |
| `haiku-3.5` | 빠르고 저렴 | 빠름 | 낮음 |
| `sonnet-3.7` | 이전 세대 | 중간 | 중간 |
| `opus-4` | 고품질 | 느림 | 높음 |

---

## 리소스 정리

```bash
# Datadog 스택 삭제 (Datadog 연동 해제)
aws cloudformation delete-stack --stack-name agentcore-datadog-stack

# ECS Service를 원래 Task Definition으로 복원
aws ecs update-service \
  --cluster agent-backend-cluster \
  --service agent-backend-service \
  --task-definition agentcore-backend \
  --force-new-deployment
```
