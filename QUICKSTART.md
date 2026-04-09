# 워크샵 전체 진행 가이드

기업용 업무 에이전트(LangGraph + Bedrock) 구축 → AgentCore Gateway 연동 → Datadog LLM Observability 실습

---

## 사전 준비

- AWS 계정 (Bedrock 모델 액세스 활성화, 리전: us-east-1)
- AWS CLI 설정 완료 (`aws configure`)
- Docker Desktop 설치 및 실행
- Python 3.11+
- Datadog 계정 + API Key

---

## Part 1. 인프라 배포

### 1-1. 리포지토리 클론

```bash
git clone <REPO_URL>
cd 05_immersion-workshop
```

### 1-2. 전체 인프라 배포 (한 번에)

```bash
./deploy-master.sh
```

스크립트가 자동으로 처리하는 것:
- S3에 CloudFormation 자식 템플릿 업로드
- 1차 배포: VPC, 서브넷, IGW, ALB, ECR, Bedrock KB, S3 등 생성
- Docker 이미지 빌드 (linux/amd64) & ECR 푸시 (helpdesk-api + agentcore-backend)
- 2차 배포: ECS 서비스 생성 (이미지 URI 연결)
- KB 문서 S3 업로드

파라미터 입력 시:
- 환경 이름: 기본값 Enter
- Bedrock Model ID: 기본값 Enter
- Gateway MCP URL: 아직 없으므로 Enter (나중에 업데이트)
- Helpdesk API URL: Enter

> 약 15~20분 소요. 완료되면 Output 테이블에 URL들이 출력됩니다.

### 1-3. 배포 확인

```bash
# Helpdesk API 동작 확인
curl https://<Helpdesk-CloudFront-URL>/tickets

# AgentCore Backend (Chainlit) 접속
# 브라우저에서: https://<AgentCore-CloudFront-URL>
```

---

## Part 2. AgentCore Gateway 연동

### 2-1. Gateway 생성

1. AWS 콘솔 → Bedrock → AgentCore → Gateway → 생성
2. 이름: `helpdesk-gateway`
3. Semantic Search: 비활성화

### 2-2. 타겟 추가 (OpenAPI 스펙)

1. Gateway → 타겟 추가
2. 타겟 유형: REST API (OpenAPI 스키마)
3. OpenAPI 스키마: `it-helpdesk-api/openapi.json` 내용 붙여넣기
   - 서버 URL을 Helpdesk CloudFront URL(https://)로 변경
4. 인증: No authorization (또는 API Key 설정)

등록 후 5개 MCP Tool이 자동 생성됩니다:
- createTicket, getTickets, getTicket, updateTicket, getStatistics

### 2-3. Gateway MCP URL 연결

Gateway 상세 페이지에서 "게이트웨이 리소스 URL" 복사 후 스택 업데이트:

```bash
./deploy-master.sh
# → Gateway MCP URL 입력란에 붙여넣기
```

### 2-4. 통합 테스트

Chainlit UI(AgentCore CloudFront URL)에서:

| 테스트 | 입력 | 예상 동작 |
|---|---|---|
| RAG 검색 | "연차 휴가 신청 방법 알려줘" | search_kb → KB 검색 결과 기반 답변 |
| 티켓 생성 | "노트북이 고장났어요" | createTicket → 티켓 ID 반환 |
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

### 3-2. 연동 확인

1. Chainlit UI에서 아무 질문 입력
2. Datadog 콘솔 → LLM Observability → Traces
3. 1~2분 후 트레이스 확인

---

## Part 4. Troubleshooting 시나리오

### 시나리오 1: 토큰 에러 진단 (15분)

**에러 재현:**
ECS 콘솔 → Task Definition → 새 리비전 생성 → 환경변수 변경:
```
WORKSHOP_SCENARIO = token_error
```
서비스 업데이트 → 새 Task Definition 선택 → 배포

**테스트:**
Chainlit에서 "연차 휴가는 어떻게 신청하나요?" → 응답이 잘리거나 에러 발생

**Datadog에서 확인:**
- Traces → 에러 트레이스 클릭
- LLM span에서 `stop_reason: max_tokens` 확인
- 출력이 불완전한 JSON으로 끝남

**해결:**
환경변수를 `WORKSHOP_SCENARIO = normal`로 변경 → 서비스 재배포

---

### 시나리오 2: Failure to Answer 진단 (15분)

**에러 재현:**
환경변수 변경:
```
WORKSHOP_SCENARIO = failure_to_answer
```

**테스트:**

| 질문 | 결과 |
|---|---|
| "휴가 신청 방법 알려줘" | 정상 ✅ |
| "경비 처리 절차 알려줘" | 정상 ✅ |
| "IT 보안 정책 알려줘" | 에러 ❌ |
| "VPN 접속 방법 알려줘" | 에러 ❌ |

**Datadog에서 확인:**
- 에러 트레이스 vs 정상 트레이스 비교
- search_kb span에서 `ResourceNotFoundException` 확인
- 보안 키워드 질문에서만 잘못된 KB ID 사용하는 패턴 발견

**해결:**
환경변수를 `WORKSHOP_SCENARIO = normal`로 변경 → 서비스 재배포

---

## Part 5. 모델별 퍼포먼스 비교 (20분)

### 5-1. 벤치마크 실행

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

### 5-2. Datadog에서 비교

1. LLM Observability → Traces → 필터: `ML App = agentcore-benchmark`
2. 모델별 레이턴시, 토큰 사용량, 응답 품질 비교
3. Experiments 탭에서 멀티 모델 비교 차트 확인

---

## 리소스 정리

```bash
# Datadog 스택 삭제
aws cloudformation delete-stack --stack-name agentcore-datadog-stack --region us-east-1

# 마스터 스택 삭제 (VPC + 전체 인프라)
# ECR에 이미지가 있으면 먼저 삭제
aws ecr delete-repository --repository-name agentcore-backend --force --region us-east-1
aws ecr delete-repository --repository-name it-helpdesk-api --force --region us-east-1

aws cloudformation delete-stack --stack-name agentcore-master-stack --region us-east-1

# 템플릿 S3 버킷 삭제
aws s3 rb s3://agentcore-cfn-templates-<ACCOUNT_ID>-us-east-1 --force
```

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| ECS 서비스 생성 실패 (Circuit Breaker) | Mac에서 ARM 이미지 빌드 | `docker buildx build --platform linux/amd64`로 재빌드 |
| KnowledgeBase 생성 실패 | S3 Vector Bucket 리전 불일치 | 같은 스택에서 VectorBucket → Index → KB 순서로 생성 |
| IAM Role 생성 실패 | 이전 스택의 Role 이름 충돌 | RoleName 제거 (CloudFormation 자동 생성) |
| ECR 삭제 실패 | 이미지가 남아있음 | `aws ecr delete-repository --force` |
| CloudFormation Description에 ??? | 한글 인코딩 문제 | Description을 영어로 작성 |
