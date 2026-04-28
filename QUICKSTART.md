# 워크샵 빠른 시작 가이드

이 저장소는 **단계형 기업용 업무 에이전트 워크샵**을 위한 예제입니다.

워크샵 흐름은 아래 3단계로 구성됩니다.

1. `chatbot`
   기본 Chainlit 챗봇
2. `rag`
   챗봇 + Bedrock Knowledge Base 기반 RAG
3. `gateway`
   챗봇 + RAG + AgentCore Gateway + Helpdesk REST API

Datadog 실습은 앱을 새로 만드는 단계가 아니라, **Step 2/3에 이미 존재하는 동작과 이슈를 관측하는 단계**로 봅니다.

---

## 사전 준비

- AWS 계정
- Bedrock 모델 액세스 활성화
- 리전: `us-east-1`
- AWS CLI 설정 완료: `aws configure`
- Docker
- Python 3.11+
- Datadog 계정 + API Key

---

## 1. 리포지토리 준비

```bash
git clone <REPO_URL>
cd 05_immersion-workshop
```

---

## 2. 인프라 배포

CloudFormation으로 워크샵 인프라를 먼저 배포합니다.

권장 스택 이름:
- `agentcore-workshop-stack`

생성되는 주요 리소스:
- ECS Cluster / Service
- AgentCore Backend ALB
- Helpdesk API ALB
- Bedrock Knowledge Base
- Route53 / ACM

스택 생성 후 CloudFormation Outputs에서 아래 값을 확인합니다.

- `WorkshopAppUrl`
- `HelpdeskUrl`
- `KnowledgeBaseId`
- `GatewayApiKeySecretName`

예시:

```bash
aws cloudformation describe-stacks \
  --stack-name agentcore-workshop-stack \
  --region us-east-1 \
  --query "Stacks[0].Outputs"
```

참고:
- Step 1에서도 Knowledge Base 리소스는 이미 생성되어 있습니다.
- 하지만 Step 1 앱은 KB를 사용하지 않으므로, 사용자에게는 일반 챗봇처럼 보입니다.

---

## 3. Step 1 배포: `chatbot`

Step 1은 **LLM만 사용하는 기본 Chainlit 챗봇**입니다.

사용 파일:
- `agentcore-backend/agent_basic.py`
- `agentcore-backend/chainlit_app_basic.py`

특징:
- RAG 없음
- Gateway 없음
- Helpdesk API 실행 없음

### 3-1. 이미지

ECR 태그:
- `chatbot`

### 3-2. 배포

```bash
aws cloudformation update-stack \
  --stack-name agentcore-workshop-stack \
  --use-previous-template \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
    ParameterKey=AgentcoreContainerImage,ParameterValue=654251711600.dkr.ecr.us-east-1.amazonaws.com/agentcore-backend:chatbot \
    ParameterKey=GatewayMcpUrl,UsePreviousValue=true \
  --region us-east-1
```

```bash
aws cloudformation wait stack-update-complete \
  --stack-name agentcore-workshop-stack \
  --region us-east-1
```

### 3-3. 확인

브라우저:
- `https://workshop.<ACCOUNT_ID>.fitcloud.click`

추천 질문:
- `안녕하세요`
- `연차 휴가 신청 방법 알려줘`
- `헬프데스크 티켓 생성해줘`

기대 결과:
- 기본 대화는 됨
- 사내 문서 근거는 없음
- 실제 업무 실행은 안 됨

---

## 4. Step 2 배포: `rag`

Step 2는 **기본 챗봇에 search_kb tool routing과 RAG를 추가한 버전**입니다.

사용 파일:
- `agentcore-backend/agent_rag.py`
- `agentcore-backend/chainlit_app_rag.py`

특징:
- 일반 질문은 기본 챗봇처럼 직접 답변
- 사내 문서성 질문만 Bedrock Knowledge Base 검색
- 답변과 함께 `근거 문서` 표시
- score는 사용자에게 직접 노출하지 않음
- Step 2부터 RAG 품질 이슈가 내장됨

### 4-1. RAG 품질 이슈

보안 질문은 일반 질문보다 더 높은 threshold를 사용합니다.

- 기본 threshold: `rag_score_threshold`
- 보안 질문 threshold: `rag_security_score_threshold = 0.95`

보안 질문 여부는 LLM 분류로 결정합니다.

의도된 시나리오:
- 검색 후보는 존재함
- 하지만 threshold filtering 이후 `filtered_count = 0`
- 사용자에게는 자연스럽게 실패처럼 보임

즉 Datadog에서 볼 핵심은:
- `route`
- `rag.used`
- `tool.called`
- `tool.calls`
- `rag.threshold`
- `rag.top_score`
- `rag.retrieved_count`
- `rag.filtered_count`
- `rag.filtered_out_count`
- `rag.failure_reason`
- `rag.is_security_query`

### 4-2. 이미지

ECR 태그:
- `rag`

### 4-3. 배포

```bash
aws cloudformation update-stack \
  --stack-name agentcore-workshop-stack \
  --use-previous-template \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
    ParameterKey=AgentcoreContainerImage,ParameterValue=654251711600.dkr.ecr.us-east-1.amazonaws.com/agentcore-backend:rag \
    ParameterKey=GatewayMcpUrl,UsePreviousValue=true \
  --region us-east-1
```

```bash
aws cloudformation wait stack-update-complete \
  --stack-name agentcore-workshop-stack \
  --region us-east-1
```

### 4-4. 확인

정상 질문:
- `연차 휴가 신청 방법 알려줘`

오류 시나리오 질문:
- `VPN 접속 방법 알려줘`
- `비밀번호 변경 방법 알려줘`

기대 결과:
- 정상 질문: KB 기반 답변 + `근거 문서`
- 보안 질문: `현재 검색 기준을 통과한 문서가 없습니다.` 같은 응답

---

## 5. Step 3 배포: `gateway`

Step 3는 **Step 2에 AgentCore Gateway와 Helpdesk REST API 실행을 추가한 버전**입니다.

사용 파일:
- `agentcore-backend/agent_gateway.py`
- `agentcore-backend/chainlit_app_gateway.py`

특징:
- Step 2의 RAG 동작 유지
- Helpdesk 작업은 Gateway MCP Tool을 통해서만 실행
- direct REST fallback 없음
- `GATEWAY_MCP_URL`이 없거나 Gateway 로딩에 실패하면 명확히 실패

### 5-1. Gateway 생성

1. AWS 콘솔 → Bedrock → AgentCore → Gateway 생성
2. 이름: `helpdesk-gateway`
3. 인바운드 인증: `IAM (SigV4)`
4. Semantic Search: 비활성화

주의:
- 기본값인 JWT를 그대로 두면 연결이 실패할 수 있습니다.

### 5-2. 타겟 추가

1. Gateway → 타겟 추가
2. 타겟 유형: REST API (OpenAPI)
3. `it-helpdesk-api/openapi.json` 사용
4. 서버 URL을 `HelpdeskUrl`로 맞춤
5. 인증: API Key

생성되는 주요 tool:
- `createTicket`
- `getTickets`
- `getTicket`
- `updateTicket`
- `getStatistics`

### 5-3. Gateway URL 연결

Gateway의 MCP URL을 스택 파라미터에 반영합니다.

```bash
./update-gateway.sh
```

또는 CloudFormation 파라미터 `GatewayMcpUrl`만 직접 업데이트해도 됩니다.

### 5-4. 이미지

ECR 태그:
- `gateway`

### 5-5. 배포

```bash
aws cloudformation update-stack \
  --stack-name agentcore-workshop-stack \
  --use-previous-template \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
    ParameterKey=AgentcoreContainerImage,ParameterValue=654251711600.dkr.ecr.us-east-1.amazonaws.com/agentcore-backend:gateway \
    ParameterKey=GatewayMcpUrl,ParameterValue=<GATEWAY_MCP_URL> \
  --region us-east-1
```

```bash
aws cloudformation wait stack-update-complete \
  --stack-name agentcore-workshop-stack \
  --region us-east-1
```

### 5-6. 확인

RAG 질문:
- `연차 휴가 신청 방법 알려줘`

Gateway 질문:
- `현재 티켓 통계 알려줘`
- `우선순위 높은 티켓 보여줘`
- `노트북이 고장났어요`

기대 결과:
- 문서형 질문은 RAG
- 티켓/통계/조회 요청은 Gateway MCP Tool 사용

---

## 6. 로컬 실행

### Step 1

```bash
cd agentcore-backend
DEBUG=false chainlit run chainlit_app_basic.py --headless --host 127.0.0.1 --port 8011
```

브라우저:
- `http://localhost:8011`

### Step 2

```bash
cd agentcore-backend
DEBUG=false chainlit run chainlit_app_rag.py --headless --host 127.0.0.1 --port 8012
```

브라우저:
- `http://localhost:8012`

필수:
- `BEDROCK_KB_ID`

### Step 3

```bash
cd agentcore-backend
DEBUG=false chainlit run chainlit_app_gateway.py --headless --host 127.0.0.1 --port 8013
```

브라우저:
- `http://localhost:8013`

필수:
- `BEDROCK_KB_ID`
- `GATEWAY_MCP_URL`

---

## 7. 리소스 정리

스택 삭제:

```bash
aws cloudformation delete-stack \
  --stack-name agentcore-workshop-stack \
  --region us-east-1
```

---

## 9. 핵심 요약

- `chatbot`
  - LLM only
- `rag`
  - LLM + Knowledge Base
  - 근거 문서 표시
  - threshold 기반 RAG 품질 이슈 포함
- `gateway`
  - LLM + RAG + AgentCore Gateway + Helpdesk REST API
  - direct REST fallback 없음
