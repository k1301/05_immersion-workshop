# 🏢 기업용 업무 에이전트 구축 실습 가이드

## 실습 개요

**시나리오**: 기업용 업무 에이전트를 구축하여 사내 업무 가이드 검색(RAG), 헬프데스크 티켓 관리(MCP), 외부 검색(Google Search)을 하나의 에이전트로 통합합니다.

**아키텍처**:
```
사용자 → Chainlit(프론트엔드) → LangGraph + Bedrock(백엔드)
                                      ↓
                              Tool Calling (ReAct 패턴)
                    ┌─────────────┼─────────────┐
                 search_kb   Gateway MCP tools  google_search
                    │              │                  │
              Bedrock KB    AgentCore Gateway     Google API
                                   │
                          CloudFront → ALB → ECS
                          (REST API - 헬프데스크)
                                   │
                          5개 엔드포인트 자동 변환:
                          createTicket, getTickets,
                          getTicket, updateTicket,
                          getStatistics
```

**소요 시간**: 약 2시간

**사전 준비**:
- AWS 계정 (Bedrock 모델 액세스 활성화)
- Python 3.11+
- AWS CLI 설정 완료

---

## 실습 순서

### Step 1. 기본 인프라 배포 (CloudFormation) — 15분

헬프데스크 REST API 인프라를 CloudFormation으로 배포합니다.

**배포되는 리소스**:
- ECS Cluster + Fargate Service (헬프데스크 API 서버)
- ALB (로드밸런서)
- CloudFront (HTTPS 제공 — AgentCore Gateway는 HTTPS 필수)
- ECR Repository (Docker 이미지 저장소)
- Secrets Manager (AgentCore Gateway API Key 자동 생성)

```bash
# it-helpdesk-api 폴더에서 실행
cd it-helpdesk-api
./deploy-cloudformation.sh
```

배포 완료 후 Output 확인:
```bash
aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs" \
  --output table \
  --region ap-northeast-2
```

주요 Output:
- `CloudFrontURL`: AgentCore Gateway에 등록할 HTTPS URL
- `GatewayApiKeySecretName`: Gateway 인증용 API Key (Secrets Manager)

API 동작 확인:
```bash
curl https://<CloudFront-URL>/tickets
```

---

### Step 2. 코드 구조 이해 — 20분

> ⚠️ **venv 주의**: `enterprise-agent-backend`와 `it-helpdesk-api`는 각각 별도의 venv를 사용합니다.
> 반드시 `enterprise-agent-backend/venv`를 활성화한 상태에서 작업하세요.
> ```bash
> cd enterprise-agent-backend
> source venv/bin/activate
> ```

#### 2-1. agent.py (백엔드 — LangGraph 에이전트)

에이전트의 핵심 로직입니다. ReAct 패턴으로 LLM이 스스로 tool을 선택하고 실행합니다.

**주요 구성요소**:

```python
# 1. 상태 정의 — add_messages reducer로 대화 히스토리 자동 누적
class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]
```

```python
# 2. Tool 정의 — @tool 데코레이터로 LLM이 호출할 수 있는 도구 정의
# docstring이 LLM에게 "이 tool은 언제 쓰는지" 알려주는 역할

@tool
def search_kb(query: str) -> str:
    """사내 업무 가이드를 검색합니다."""
    # Bedrock Knowledge Base에서 검색

@tool
def google_search(query: str) -> str:
    """회사 내부 가이드와 관련 없는 일반적인 질문에 대해 외부 검색"""
```

```python
# 3. Gateway MCP Tool 로딩 — AgentCore Gateway에서 MCP tool을 자동으로 가져옴
# SigV4 인증으로 Gateway에 연결, tool 목록 조회 후 LangChain tool로 래핑
async def load_gateway_tools():
    # Gateway MCP URL이 설정되어 있으면 → 5개 tool 자동 로딩
    # 설정 안 되어 있으면 → fallback (create_ticket 직접 REST API 호출)
```

```python
# 4. LLM 초기화 — Bedrock Claude에 tool을 바인딩
def get_llm(tool_list):
    llm = ChatBedrock(model_id=...).bind_tools(tool_list)
```

```python
# 5. 그래프 생성 — ReAct 패턴 (agent ⇄ tools 루프)
#
#   __start__ → agent → (tool 필요?) → tools → agent → ... → __end__
#
workflow = StateGraph(AgentState)
workflow.add_node("agent", agent_node)      # LLM이 tool 호출 여부 판단
workflow.add_node("tools", ToolNode(tools)) # 실제 tool 실행
workflow.set_entry_point("agent")
workflow.add_conditional_edges("agent", should_continue, {"tools": "tools", "end": END})
workflow.add_edge("tools", "agent")         # tool 결과를 다시 LLM에 전달
```

**핵심 포인트**: 키워드 기반 라우팅이 아니라, LLM이 tool의 description을 보고 알아서 판단합니다.

#### 2-2. chainlit_app.py (프론트엔드 — Chainlit UI)

채팅 UI를 제공하고, 사용자 메시지를 에이전트에 전달합니다.

```python
@cl.on_chat_start    # 채팅 시작 → 에이전트 초기화, 대화 히스토리 초기화
@cl.on_message       # 메시지 수신 → 히스토리 포함하여 에이전트 실행
@cl.on_settings_update  # 설정 변경 → 모델 변경
```

```python
# 대화 히스토리 관리 — 세션 내 맥락 유지
cl.user_session.set("chat_history", [])

# 에이전트 실행 — astream으로 노드 단위 스트리밍
async for chunk in agent_graph.astream(initial_state):
    if "agent" in chunk:   # LLM 응답 또는 tool 호출 결정
    elif "tools" in chunk: # tool 실행 결과
```

#### 2-3. config.py (설정 관리)

```python
class Settings(BaseSettings):
    aws_region: str = "us-east-1"
    bedrock_model_id: str = "..."      # Bedrock 모델
    bedrock_kb_id: Optional[str]        # Knowledge Base ID (RAG)
    helpdesk_api_url: str = "..."       # 헬프데스크 API URL (fallback용)
    gateway_mcp_url: str = ""           # AgentCore Gateway MCP URL
```

---

### Step 3. Bedrock Knowledge Base 설정 (RAG) — 15분

사내 업무 가이드 문서를 Bedrock Knowledge Base에 등록합니다.

**문서 목록** (`kb_docs/`):
- `vacation_policy.md` — 휴가 정책
- `expense_guide.md` — 경비 처리 가이드
- `onboarding_guide.md` — 온보딩 가이드
- `it_security_guide.md` — IT 보안 가이드

**설정 순서**:
1. S3 버킷 생성 → `kb_docs/` 파일 업로드
2. Bedrock 콘솔 → Knowledge Base 생성
3. 데이터 소스: S3 버킷 연결
4. 임베딩 모델: Titan Embeddings V2
5. 벡터 스토어: 기본 설정 (OpenSearch Serverless)
6. Knowledge Base ID를 `.env`에 설정:

```bash
# .env
BEDROCK_KB_ID=<Knowledge-Base-ID>
```

**테스트** (Gateway 연결 전, fallback 모드):
```bash
cd enterprise-agent-backend
source venv/bin/activate
chainlit run chainlit_app.py -w --port 8001
```

채팅에서 "휴가 신청은 어떻게 하나요?" → `search_kb` tool 호출 → KB 검색 결과 기반 답변

---

### Step 4. AgentCore Gateway 생성 및 연결 (MCP) — 30분

REST API를 AgentCore Gateway에 연결하여 MCP tool로 변환합니다.

#### 4-1. Gateway 생성

1. Bedrock AgentCore 콘솔 → Gateway → 생성
2. 이름: `helpdesk-gateway`
3. Semantic Search: 비활성화 (tool 5개이므로 불필요)

#### 4-2. Outbound Auth 설정 (API Key)

1. AgentCore 콘솔 → Identity → Outbound Auth → "Add API Key"
2. 이름: `helpdesk-api-key`
3. API 키 값 가져오기:
```bash
aws secretsmanager get-secret-value \
  --secret-id helpdesk-api-gateway-key \
  --query SecretString \
  --output text \
  --region ap-northeast-2
```
4. 위 값을 "API 키" 필드에 붙여넣기

#### 4-3. 타겟 추가 (OpenAPI 스펙)

1. Gateway → 타겟 추가
2. 타겟 유형: REST API (OpenAPI 스키마)
3. OpenAPI 스키마: `openapi.json` 내용 붙여넣기
   - ⚠️ 서버 URL이 `https://` (CloudFront URL)인지 반드시 확인 — HTTP는 거부됨
4. Outbound Auth: 위에서 만든 API Key 선택 (또는 No authorization)

**등록되는 MCP Tool 목록** (OpenAPI 엔드포인트 → MCP Tool 자동 변환):
| 엔드포인트 | MCP Tool | 설명 |
|---|---|---|
| `GET /tickets` | getTickets | 티켓 목록 조회 (필터링 지원) |
| `POST /tickets` | createTicket | 새 티켓 생성 |
| `GET /tickets/{id}` | getTicket | 티켓 상세 조회 |
| `PATCH /tickets/{id}` | updateTicket | 티켓 업데이트 |
| `GET /stats` | getStatistics | 티켓 통계 조회 |

> **핵심 포인트**: 기존 REST API 코드를 한 줄도 수정하지 않고, OpenAPI 스펙만으로 5개 API가 MCP tool로 변환됩니다.
> 이미 CloudFront → ALB → ECS로 운영 중인 API가 있다면 그대로 연결 가능합니다.

#### 4-4. agent.py에 Gateway MCP URL 설정

`.env` 파일에 Gateway MCP URL을 추가합니다:

```bash
# .env에 추가
GATEWAY_MCP_URL=https://<gateway-id>.gateway.bedrock-agentcore.ap-northeast-2.amazonaws.com/mcp
```

Gateway MCP URL은 콘솔의 Gateway 상세 페이지 → "게이트웨이 리소스 URL"에서 확인할 수 있습니다.

**필요 패키지 설치**:
```bash
source venv/bin/activate  # enterprise-agent-backend의 venv!
pip install langchain-mcp-adapters httpx-auth-awssigv4
```

**동작 방식**:
- `GATEWAY_MCP_URL`이 설정되면 → Gateway에서 5개 MCP tool 자동 로딩
- 설정 안 되어 있으면 → fallback으로 `create_ticket` (직접 REST API 호출) 사용
- SigV4 인증으로 Gateway에 연결 (AWS CLI 자격 증명 사용)

Chainlit 재시작:
```bash
chainlit run chainlit_app.py -w --port 8001
```

터미널에서 확인:
```
✅ Gateway에서 5개 MCP tool 로딩 완료
   - test-target___createTicket
   - test-target___getStatistics
   - test-target___getTicket
   - test-target___getTickets
   - test-target___updateTicket
🔧 Tool 목록: ['search_kb', 'test-target___createTicket', ...]
```

---

### Step 5. 통합 테스트 — 20분

Chainlit UI에서 전체 시나리오를 테스트합니다.

#### 테스트 시나리오

**시나리오 1: RAG 검색으로 해결**
```
사용자: "연차 휴가는 며칠까지 쓸 수 있나요?"
→ search_kb tool 호출 → KB에서 휴가 정책 검색 → 답변
```

**시나리오 2: RAG로 해결 안 됨 → 티켓 생성**
```
사용자: "데스크탑 전원이 안 켜져요"
→ search_kb tool 호출 → 관련 내용 부족
→ "헬프데스크 티켓을 생성해드릴까요?" 제안
사용자: "네, 부탁해요"
→ createTicket tool 호출 (Gateway MCP) → 티켓 자동 생성
```

**시나리오 3: 티켓 조회 (필터링)**
```
사용자: "우선순위 높은 티켓 보여줘"
→ getTickets(priority='high') tool 호출 → 필터링된 목록 반환
```

**시나리오 4: 티켓 통계**
```
사용자: "현재 티켓 통계 알려줘"
→ getStatistics tool 호출 → 상태별/우선순위별/카테고리별 통계
```

**시나리오 5: 외부 검색**
```
사용자: "파이썬 3.13의 새로운 기능이 뭐야?"
→ google_search tool 호출 → 외부 검색 결과 반환
```

**시나리오 6: 대화 맥락 유지**
```
사용자: "전원이 안 켜져요"
에이전트: "어떤 기기인가요?"
사용자: "데스크탑이요"
→ 이전 대화 맥락을 기억하고 이어서 처리
```

---

### Step 6. (선택) LangGraph Studio로 시각화 — 10분

에이전트 그래프 구조를 시각적으로 확인합니다.

```bash
pip install -U "langgraph-cli[inmem]"
langgraph dev
```

LangSmith Studio (https://smith.langchain.com) → Studio 탭에서:
- `agent ⇄ tools` ReAct 루프 구조 확인
- v1(키워드 라우팅)과 v2(tool calling) 그래프 비교

---

## 주요 개념 정리

### ReAct 패턴
LLM이 "Reasoning(추론) → Action(도구 실행) → Observation(결과 확인)"을 반복하는 패턴.
키워드 라우팅과 달리 LLM이 tool의 description을 보고 스스로 판단합니다.

### AgentCore Gateway
기존 REST API를 MCP(Model Context Protocol) tool로 변환하는 관리형 서비스.
- OpenAPI 스펙 등록 → 엔드포인트가 자동으로 MCP tool로 변환
- 기존 API 코드 수정 불필요
- 인증(SigV4, API Key), 관측성 내장
- 이미 CloudFront → ALB → ECS로 운영 중인 API도 그대로 연결 가능

### Tool Calling vs 키워드 라우팅
| | 키워드 라우팅 | Tool Calling |
|---|---|---|
| 판단 주체 | 개발자가 정한 키워드 | LLM이 자연어 이해 |
| 정확도 | 키워드 누락 시 실패 | 의도 기반 판단 |
| 확장성 | 키워드 추가 필요 | tool 추가만 하면 됨 |
| 복합 요청 | 하나만 선택 | 여러 tool 순차 호출 가능 |

### Gateway 연결 vs 직접 API 호출
| | 직접 REST API 호출 | AgentCore Gateway |
|---|---|---|
| 코드 변경 | 엔드포인트마다 @tool 작성 | Gateway 설정만 |
| API 추가 시 | 코드 수정 + 재배포 | Gateway에 등록만 |
| 인증 | 코드에 하드코딩 | Gateway가 관리 |
| 관측성 | 직접 구현 | 내장 |

---

## 리소스 정리

실습 완료 후 리소스를 삭제합니다:

```bash
# CloudFormation 스택 삭제
aws cloudformation delete-stack --stack-name helpdesk-api-stack --region ap-northeast-2

# Bedrock Knowledge Base 삭제 (콘솔에서)
# AgentCore Gateway 삭제 (콘솔에서)
```
