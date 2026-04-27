# 워크샵 전체 진행 가이드

기업용 업무 에이전트(LangGraph + Bedrock) 구축 → AgentCore Gateway 연동 → Datadog LLM Observability 실습

---

## 사전 준비

- AWS 계정 (Bedrock 모델 액세스 활성화, 리전: us-east-1)
- AWS CLI 설정 완료 (`aws configure`)
- Python 3.11+
- Datadog 계정 + API Key

---

## Part 1. 인프라 배포

### 1-1. 리포지토리 클론

```bash
git clone <REPO_URL>
cd 05_immersion-workshop
```

### 1-2. 전체 인프라 배포

실습 페이지의 **스택 생성 버튼**을 클릭하여 CloudFormation 스택을 생성합니다.

권장 스택 이름:
- `agentcore-workshop-stack`

생성되는 리소스:
- VPC, 서브넷, IGW, ALB, ECS 서비스, Bedrock KB, Route53 DNS, ACM 인증서 등
- Public ECR의 사전 빌드 이미지 사용 (helpdesk-api + agentcore-backend)

> 약 15~20분 소요. CloudFormation 콘솔에서 스택 상태를 확인하세요.

### 1-3. 배포 확인

```bash
# Helpdesk API 동작 확인
curl https://helpdesk.<ACCOUNT_ID>.fitcloud.click/tickets

# AgentCore Backend (Chainlit) 접속
# 브라우저에서: https://agentcore.<ACCOUNT_ID>.fitcloud.click
```

CloudFormation 출력값에서 함께 확인할 항목:
- `HelpdeskUrl`
- `AgentcoreUrl`
- `KnowledgeBaseId`
- `GatewayApiKeySecretName`

---

## Part 2. AgentCore Gateway 연동

### 2-1. Gateway 생성

1. AWS 콘솔 → Bedrock → AgentCore → Gateway → 생성
2. 이름: `helpdesk-gateway`
3. 인바운드 인증: **IAM (SigV4)** 선택 (기본값이 JWT이므로 반드시 변경)
4. Semantic Search: 비활성화

> ⚠️ 인바운드 인증을 JWT(기본값)로 두면 에이전트가 SigV4로 인증하기 때문에 연결이 실패합니다.

### 2-2. 타겟 추가 (OpenAPI 스펙)

1. Gateway → 타겟 추가
2. 타겟 유형: REST API (OpenAPI 스키마)
3. OpenAPI 스키마: `it-helpdesk-api/openapi.json` 내용 붙여넣기
   - 서버 URL을 Helpdesk URL(`https://helpdesk.<ACCOUNT_ID>.fitcloud.click`)로 변경
4. 인증: API Key 설정

등록 후 5개 MCP Tool이 자동 생성됩니다:
- createTicket, getTickets, getTicket, updateTicket, getStatistics

### 2-3. Gateway MCP URL 연결

Gateway 상세 페이지에서 "게이트웨이 리소스 URL" 복사 후 스택 업데이트:

```bash
./update-gateway.sh
# → Gateway MCP URL 입력란에 붙여넣기
```

> 기존 파라미터(이미지 URI, 모델 등)는 자동으로 유지됩니다. Gateway URL만 업데이트합니다.

### 2-4. 통합 테스트

Chainlit UI(`https://agentcore.<ACCOUNT_ID>.fitcloud.click`)에서:

| 테스트 | 입력 | 예상 동작 |
|---|---|---|
| RAG 검색 | "연차 휴가 신청 방법 알려줘" | search_kb → KB 검색 결과 기반 답변 |
| 티켓 생성 흐름 | "노트북이 고장났어요" | KB 검색 후 해결 정보가 없으면 티켓 생성 여부를 먼저 확인 |
| 티켓 조회 | "우선순위 높은 티켓 보여줘" | getTickets(priority=high) |
| 티켓 통계 | "현재 티켓 통계 알려줘" | getStatistics |

---

## Part 3. Datadog LLM Observability

### 3-1. Datadog 스택 배포

```bash
cd agentcore-backend
./deploy-datadog.sh
```

입력 항목:
- Datadog API Key (필수)
- Datadog Site (기본: datadoghq.com)
- ML App 이름 (기본: agentcore-backend)

이 스크립트는 현재 배포된 `agentcore-workshop-stack`을 기준으로 동작합니다.

내부적으로 수행하는 작업:
- 워크샵 스택에서 `agentcore-backend` 관련 설정 조회
- Datadog 환경변수가 포함된 새 ECS Task Definition 생성
- ECS Service 강제 재배포

> 즉시 반영되지 않고, 새 ECS 태스크가 healthy 상태가 될 때까지 몇 분 정도 걸릴 수 있습니다.

### 3-2. 연동 확인

1. `deploy-datadog.sh` 실행 후 ECS 재배포가 끝날 때까지 잠시 대기
2. Chainlit UI에서 새 질문 입력
2. Datadog 콘솔 → LLM Observability → Traces
3. 1~2분 후 트레이스 확인

중요:
- Datadog 연동 전에 발생한 요청은 trace로 보이지 않습니다.
- Datadog 연동 후 **새로 보낸 요청부터** trace가 수집됩니다.

---

## Part 4. Troubleshooting 시나리오

> 오류 시나리오는 에이전트에 내장되어 있어 별도 환경변수 변경이 필요 없습니다.
> 질문 내용에 따라 자동으로 정상/오류가 분기됩니다.

### 시나리오 1: 토큰 에러 진단

**에러 재현:**
"요약", "정리", "상세히", "자세히" 등의 키워드가 포함된 질문을 하면 자동으로 토큰 에러가 발생합니다.

**테스트:**
Chainlit에서:
```
"휴가 정책을 상세히 요약 정리해줘"     → 에러 ❌ (토큰 초과)
"연차 휴가는 며칠까지 쓸 수 있나요?"   → 정상 ✅
```

**Datadog에서 확인:**
- Traces → 토큰 에러 질문의 트레이스 클릭
- `bedrock-runtime.command` span 선택 → `Output Tokens: 10` 확인 (정상 트레이스는 수백~수천)
- 응답 내용이 잘려있는 것을 Output Message에서 확인
- 정상 질문 트레이스와 Output Tokens 수를 비교하여 원인 파악

---

### 시나리오 2: Failure to Answer 진단

**에러 재현:**
보안 관련 키워드(보안, VPN, 비밀번호 등)가 포함된 질문을 하면 자동으로 잘못된 KB ID로 검색합니다.

**테스트:**

| 질문 | 결과 |
|---|---|
| "휴가 신청 방법 알려줘" | 정상 ✅ |
| "경비 처리 절차 알려줘" | 정상 ✅ |
| "IT 보안 정책 알려줘" | 에러 ❌ |
| "VPN 접속 방법 알려줘" | 에러 ❌ |

**Datadog에서 확인:**
- 정상 질문 트레이스와 보안 질문 트레이스를 비교
- `search_kb` span 클릭 → Output 내용 확인
  - 정상: KB 문서 내용이 정상적으로 반환됨
  - 에러: `❌ 사내 문서 검색 중 오류가 발생했습니다. 관리자에게 문의해주세요.` 메시지 반환
- 보안 키워드 질문에서만 search_kb가 실패하는 패턴 발견

---

## Part 5. 모델별 퍼포먼스 비교

### 5-1. 벤치마크 실행

```bash
cd agentcore-backend
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

DD_LLMOBS_ENABLED=1 \
DD_LLMOBS_ML_APP=agentcore-benchmark \
DD_LLMOBS_AGENTLESS_ENABLED=1 \
DD_API_KEY=<YOUR_DATADOG_API_KEY> \
DD_SITE=<YOUR_DD_SITE> \
DD_PATCH_MODULES=langchain:true,botocore:true \
ddtrace-run python benchmark.py --models sonnet-4.5,haiku-3.5,sonnet-3.7
```

### 5-2. Datadog에서 비교

1. LLM Observability → Traces → 필터: `ML App = agentcore-benchmark`
2. 모델별 레이턴시, 토큰 사용량, 응답 품질 비교
3. Experiments 탭에서 멀티 모델 비교 차트 확인

---

## 리소스 정리

```bash
# Datadog 스택 삭제
aws cloudformation delete-stack --stack-name agentcore-datadog-stack --region us-east-1

# 메인 스택 삭제 (VPC + 전체 인프라)
aws cloudformation delete-stack --stack-name agentcore-workshop-stack --region us-east-1
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| KnowledgeBase 생성 실패 | S3 Vector Bucket 리전 불일치 | 같은 스택에서 VectorBucket → Index → KB 순서로 생성 |
| IAM Role 생성 실패 | 이전 스택의 Role 이름 충돌 | RoleName 제거 (CloudFormation 자동 생성) |
| CloudFormation Description에 ??? | 한글 인코딩 문제 | Description을 영어로 작성 |
