# 워크샵 빠른 시작 가이드

이 저장소는 **사내용 업무 에이전트 워크샵 실행본**입니다.

아래 스크립트 순서로 진행합니다.

1. `./create-workshop-stack.sh`
   기본 인프라와 기본 챗봇 앱을 배포합니다.
2. `./deploy-rag.sh`
   Bedrock Knowledge Base 기반 RAG 앱으로 업데이트합니다.
3. `./deploy-gateway.sh`
   AgentCore Gateway MCP URL을 연결하고 Helpdesk API tool을 활성화합니다.
4. `./enable-datadog.sh`
   Datadog API Key를 적용하고 LLM Observability 관측 설정을 활성화합니다.

이 저장소는 워크샵 진행에 맞춰 **배포 스크립트 중심**으로 정리한 버전입니다.

---

## 사전 준비

- AWS 계정
- Bedrock 모델 액세스 활성화
- 리전: `us-east-1`
- AWS CLI 설정 완료
- Docker
- Datadog 계정 및 API Key

---

## 1. 리포지토리 준비

```bash
git clone https://github.com/k1301/05_immersion-workshop.git
cd 05_immersion-workshop
```

---

## 2. Step 1: 워크샵 스택 생성

```bash
./create-workshop-stack.sh
```

생성되는 주요 리소스:

- ECS Cluster / Service
- AgentCore Backend ALB
- Helpdesk API ALB
- Bedrock Knowledge Base
- Route53 / ACM
- Gateway outbound 인증용 API Key Secret

완료 후 주요 출력:

- `WorkshopAppUrl`
- `HelpdeskUrl`
- `KnowledgeBaseId`
- `KBDocsBucketName`
- `GatewayApiKeySecretName`
- `GatewayApiKeySecretArn`

처음 배포되는 앱은 기본 Chainlit 챗봇입니다. Knowledge Base 리소스는 생성되지만, Step 1 앱은 KB를 사용하지 않습니다.

---

## 3. Step 2: RAG 앱 배포

```bash
./deploy-rag.sh
```

Step 2는 기본 챗봇에 Bedrock Knowledge Base 검색을 추가합니다.

특징:

- 사내 문서성 질문은 `search_kb` tool로 검색
- 답변과 함께 근거 문서 표시
- 검색 결과와 근거 문서를 바탕으로 답변
- Datadog LLM Observability에서 RAG 검색 흐름을 확인 가능

확인 질문 예시:

```text
연차 휴가 신청 방법 알려줘
경비 처리 절차 알려줘
온보딩 절차 알려줘
```

---

## 4. Step 3: AgentCore Gateway 연결

먼저 AWS 콘솔에서 Helpdesk API Key를 AgentCore credential로 등록한 뒤, AgentCore Gateway와 REST API target을 생성합니다.

API Key 값 확인
- 이름: `helpdesk-api-gateway-key`
- API 키 값은 Step 1에서 Secrets Manager에 생성된 값을 사용합니다.

```bash
aws secretsmanager get-secret-value \
  --secret-id helpdesk-api-gateway-key \
  --region us-east-1 \
  --query SecretString \
  --output text \
  --no-cli-pager
```

AgentCore API Key credential 등록:

- AgentCore 콘솔에서 API Key credential/provider를 생성합니다.
- 이름: `helpdesk-api-gateway-key`
- API Key 값: 위 명령어로 확인한 Secrets Manager 값
- 위치: Header
- Header 이름: `x-api-key`

Gateway 생성 권장값:

- 이름: `it-helpdesk-gateway`
- 인바운드 인증: `IAM (SigV4)`
- Target 이름: `helpdesk-rest-target`
- Target 유형: REST API (OpenAPI)
- OpenAPI 파일: `it-helpdesk-api/openapi.json`
- 서버 URL: Step 1 출력의 `HelpdeskUrl`
- outbound 인증: API Key
- API Key: 위에서 등록한 `helpdesk-api-gateway-key` credential 선택
- API Key header 이름: `x-api-key`

생성되는 주요 tool:

- `createTicket`
- `getTickets`
- `getTicket`
- `updateTicket`
- `getStatistics`

Gateway MCP URL을 확인한 뒤 실행합니다.

```bash
./deploy-gateway.sh
```

스크립트가 `Gateway MCP URL`을 물어보면 Gateway 콘솔의 MCP URL을 입력합니다.

Step 3 특징:

- RAG 동작 유지
- Helpdesk 작업은 Gateway MCP tool로만 수행
- direct REST fallback 없음
- 티켓 조회/수정/통계 요청은 Gateway tool 사용
- IT 장애 요청은 사내 문서 확인 후 필요하면 티켓 생성 여부를 물어봄

확인 질문 예시:

```text
현재 티켓 통계 알려줘
우선순위 높은 티켓 보여줘
노트북이 안 켜져요
```

---

## 5. Step 4: Datadog LLM Observability 활성화

Datadog API Key가 환경변수 또는 `.env`에 있으면 자동으로 사용합니다.

지원하는 위치:

- `./.env`
- `./agentcore-backend/.env`
- 현재 shell 환경변수

예시:

```bash
export DD_API_KEY="<DATADOG_API_KEY>"
./enable-datadog.sh
```

또는 `.env`에 이미 아래 값이 있으면 바로 실행합니다.

```bash
DD_API_KEY=<DATADOG_API_KEY>
GATEWAY_MCP_URL=<GATEWAY_MCP_URL>
```

`enable-datadog.sh`는 다음을 수행합니다.

- Datadog LLM Observability 설정 적용
- 워크샵 앱을 Datadog 관측 대상으로 등록
- Gateway 앱 재배포
- Datadog LLM Observability trace 수집 활성화

확인 위치:

```text
Datadog > LLM Observability > Traces
앱: agentcore-backend
```

---

## 6. 주요 URL 확인 명령어

Workshop App URL:

```bash
aws cloudformation describe-stacks \
  --stack-name agentcore-workshop-stack \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='WorkshopAppUrl'].OutputValue" \
  --output text \
  --no-cli-pager
```

Helpdesk API URL:

```bash
aws cloudformation describe-stacks \
  --stack-name agentcore-workshop-stack \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='HelpdeskUrl'].OutputValue" \
  --output text \
  --no-cli-pager
```

Knowledge Base ID:

```bash
aws cloudformation describe-stacks \
  --stack-name agentcore-workshop-stack \
  --region us-east-1 \
  --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" \
  --output text \
  --no-cli-pager
```

---

## 7. 리소스 정리

```bash
aws cloudformation delete-stack \
  --stack-name agentcore-workshop-stack \
  --region us-east-1 \
  --no-cli-pager
```

---

## 핵심 요약

- Step 1: 기본 챗봇 및 인프라 배포
- Step 2: RAG 및 Knowledge Base 검색
- Step 3: AgentCore Gateway로 Helpdesk API tool 연결
- Step 4: Datadog LLM Observability 활성화 및 trace 확인
