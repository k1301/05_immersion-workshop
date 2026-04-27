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

## 리소스 정리

```bash

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
