"""
LangGraph + Bedrock 기반 기업용 에이전트 (v2 - ReAct 패턴)

구조:
- agent 노드: LLM이 tool 호출 여부 판단
- tools 노드: ToolNode가 tool 실행
- tool 목록: search_kb + Gateway MCP tools + google_search
"""
import os
import asyncio
import json
import time
import logging
import requests
import boto3
import httpx
from typing import TypedDict, Annotated, Sequence

from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode
from langchain_aws import ChatBedrock
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage
from langchain_core.tools import tool
from config import get_settings

settings = get_settings()

os.environ["AWS_DEFAULT_REGION"] = settings.aws_region
os.environ["AWS_REGION"] = settings.aws_region

# ========== 로깅 설정 ==========
logger = logging.getLogger("agent")
logger.setLevel(getattr(logging, settings.log_level, logging.INFO))

# JSON 포맷 핸들러 (Datadog 로그 파싱 호환)
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_data = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # extra 필드 추가
        for key in ["tool_name", "duration_ms", "model_id", "node", "error_type", "status"]:
            if hasattr(record, key):
                log_data[key] = getattr(record, key)
        return json.dumps(log_data, ensure_ascii=False)

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)


# ========== 상태 정의 ==========
class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]


# ========== Tool 정의 ==========
@tool
def search_kb(query: str) -> str:
    """사내 업무 가이드를 검색합니다.
    휴가 정책, 경비 처리, 온보딩, IT 보안 등 회사 내부 문서에서 관련 정보를 찾을 때 사용합니다."""
    start = time.time()
    try:
        if not settings.bedrock_kb_id:
            logger.warning("KB ID 미설정", extra={"tool_name": "search_kb", "status": "error", "error_type": "config_missing"})
            return "[설정 오류] Knowledge Base ID가 설정되지 않았습니다."

        # 오류 시나리오 (항상 활성): 보안 관련 질문은 잘못된 KB ID로 검색
        # "보안", "VPN", "비밀번호" 등 보안 키워드가 포함된 query만 에러 발생
        # Datadog에서 "특정 질문만 실패하는 원인"을 추적하는 시나리오
        security_keywords = ["보안", "security", "비밀번호", "password", "vpn", "mfa", "인증", "암호화", "피싱"]
        if any(kw in query.lower() for kw in security_keywords):
            logger.warning(f"보안 키워드 감지 → 잘못된 KB ID 사용", extra={"tool_name": "search_kb", "status": "scenario_active"})
            from langchain_aws import AmazonKnowledgeBasesRetriever
            retriever = AmazonKnowledgeBasesRetriever(
                knowledge_base_id="INVALID_KB_ID_WORKSHOP",
                retrieval_config={"vectorSearchConfiguration": {"numberOfResults": 5}}
            )
            docs = retriever.invoke(query)
            return "\n\n".join([doc.page_content for doc in docs]) if docs else "관련 문서를 찾지 못했습니다."

        from langchain_aws import AmazonKnowledgeBasesRetriever

        retriever = AmazonKnowledgeBasesRetriever(
            knowledge_base_id=settings.bedrock_kb_id,
            retrieval_config={"vectorSearchConfiguration": {"numberOfResults": 5}}
        )
        docs = retriever.invoke(query)
        duration = int((time.time() - start) * 1000)

        if not docs:
            logger.info("KB 검색 결과 없음", extra={"tool_name": "search_kb", "duration_ms": duration, "status": "no_results"})
            return "관련 문서를 찾지 못했습니다."

        results = []
        for i, doc in enumerate(docs, 1):
            source = doc.metadata.get("source", "출처 미상")
            results.append(f"[문서 {i}] {source}\n{doc.page_content}")

        logger.info(f"KB 검색 완료: {len(docs)}건", extra={"tool_name": "search_kb", "duration_ms": duration, "status": "success"})
        return "\n\n".join(results)

    except Exception as e:
        duration = int((time.time() - start) * 1000)
        logger.error(f"KB 검색 오류: {e}", extra={"tool_name": "search_kb", "duration_ms": duration, "status": "error", "error_type": type(e).__name__})
        return f"[검색 오류] {str(e)}"


@tool
def create_ticket(title: str, description: str, category: str, priority: str = "medium") -> str:
    """사내 헬프데스크 티켓을 생성합니다. (Fallback - 직접 REST API 호출)
    RAG 검색으로 해결이 안 되거나, 담당자 지원이 필요한 경우 사용합니다.
    category: hardware, software, network, account, hr, facility, expense, other 중 하나
    priority: low, medium, high, urgent 중 하나"""
    start = time.time()
    try:
        api_url = f"{settings.helpdesk_api_url}/tickets"
        ticket_data = {
            "title": title,
            "description": description,
            "category": category,
            "priority": priority,
            "requester": "사용자"
        }
        response = requests.post(api_url, json=ticket_data, timeout=10)
        response.raise_for_status()
        ticket = response.json()
        duration = int((time.time() - start) * 1000)

        logger.info(f"티켓 생성 완료: {ticket['id']}", extra={"tool_name": "create_ticket", "duration_ms": duration, "status": "success"})
        return (
            f"✅ 헬프데스크 티켓이 생성되었습니다!\n"
            f"- 티켓 ID: {ticket['id']}\n"
            f"- 제목: {ticket['title']}\n"
            f"- 카테고리: {ticket['category']}\n"
            f"- 우선순위: {ticket['priority']}\n"
            f"- 상태: {ticket['status']}"
        )
    except Exception as e:
        duration = int((time.time() - start) * 1000)
        logger.error(f"티켓 생성 오류: {e}", extra={"tool_name": "create_ticket", "duration_ms": duration, "status": "error", "error_type": type(e).__name__})
        return f"[티켓 생성 오류] {str(e)}"


@tool
def google_search(query: str) -> str:
    """회사 내부 가이드와 관련 없는 일반적인 질문에 대해 외부 검색을 수행합니다.
    기술 질문, 최신 정보, 일반 지식 등을 검색할 때 사용합니다."""
    # TODO: 실제 구글 검색 API 연동
    return f"[구글 검색 결과] '{query}'에 대한 검색 기능은 준비 중입니다."


# ========== Gateway MCP Tool 로딩 ==========
async def _call_gateway_tool(tool_name: str, arguments: dict) -> str:
    """Gateway MCP tool을 호출하는 헬퍼 함수 (호출마다 새 세션)"""
    from httpx_auth_awssigv4 import SigV4Auth as HttpxSigV4Auth
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    start = time.time()
    session = boto3.Session()
    creds = session.get_credentials().get_frozen_credentials()
    auth = HttpxSigV4Auth(
        access_key=creds.access_key,
        secret_key=creds.secret_key,
        token=creds.token if creds.token else None,
        service="bedrock-agentcore",
        region=settings.aws_region,
    )

    try:
        async with streamablehttp_client(url=settings.gateway_mcp_url, auth=auth) as (read, write, _):
            async with ClientSession(read, write) as mcp_session:
                await mcp_session.initialize()
                clean_args = {k: v for k, v in arguments.items() if v is not None}
                result = await mcp_session.call_tool(tool_name, clean_args)
                duration = int((time.time() - start) * 1000)

                logger.info(f"Gateway tool 호출 완료: {tool_name}", extra={"tool_name": tool_name, "duration_ms": duration, "status": "success"})
                if result.content:
                    return "\n".join(
                        item.text if hasattr(item, "text") else str(item)
                        for item in result.content
                    )
                return "결과 없음"
    except Exception as e:
        duration = int((time.time() - start) * 1000)
        logger.error(f"Gateway tool 오류: {tool_name} - {e}", extra={"tool_name": tool_name, "duration_ms": duration, "status": "error", "error_type": type(e).__name__})
        raise


async def load_gateway_tools():
    """AgentCore Gateway에서 MCP tool 목록을 가져와 LangChain tool로 변환"""
    if not settings.gateway_mcp_url:
        print("⚠️ Gateway MCP URL 미설정. Fallback tool(create_ticket) 사용.")
        return [create_ticket]

    try:
        from httpx_auth_awssigv4 import SigV4Auth as HttpxSigV4Auth
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client
        from langchain_core.tools import StructuredTool
        import json

        # SigV4 인증
        session = boto3.Session()
        creds = session.get_credentials().get_frozen_credentials()
        auth = HttpxSigV4Auth(
            access_key=creds.access_key,
            secret_key=creds.secret_key,
            token=creds.token if creds.token else None,
            service="bedrock-agentcore",
            region=settings.aws_region,
        )

        # MCP 세션으로 tool 목록만 가져오기
        async with streamablehttp_client(url=settings.gateway_mcp_url, auth=auth) as (read, write, _):
            async with ClientSession(read, write) as mcp_session:
                await mcp_session.initialize()
                tools_response = await mcp_session.list_tools()

        # 각 MCP tool을 LangChain tool로 래핑
        gateway_tools = []
        for mcp_tool in tools_response.tools:
            tool_name = mcp_tool.name
            tool_desc = mcp_tool.description or tool_name
            schema = mcp_tool.inputSchema if mcp_tool.inputSchema else {"type": "object", "properties": {}}

            # 클로저로 tool_name 캡처
            def make_tool_func(name):
                async def tool_func(**kwargs) -> str:
                    return await _call_gateway_tool(name, kwargs)
                return tool_func

            # inputSchema에서 Pydantic 모델 동적 생성
            from pydantic import BaseModel, Field, create_model
            from typing import Optional
            fields = {}
            properties = schema.get("properties", {})
            required = schema.get("required", [])
            for prop_name, prop_info in properties.items():
                prop_type = prop_info.get("type", "string")
                prop_desc = prop_info.get("description", "")
                py_type = str  # 기본 string
                if prop_type == "integer":
                    py_type = int
                elif prop_type == "boolean":
                    py_type = bool

                if prop_name in required:
                    fields[prop_name] = (py_type, Field(description=prop_desc))
                else:
                    fields[prop_name] = (Optional[py_type], Field(default=None, description=prop_desc))

            args_model = create_model(f"{tool_name}_args", **fields) if fields else None

            structured_tool = StructuredTool.from_function(
                coroutine=make_tool_func(tool_name),
                name=tool_name,
                description=tool_desc,
                args_schema=args_model,
            )
            gateway_tools.append(structured_tool)

        print(f"✅ Gateway에서 {len(gateway_tools)}개 MCP tool 로딩 완료")
        for t in gateway_tools:
            print(f"   - {t.name}")
        return gateway_tools

    except Exception as e:
        print(f"⚠️ Gateway MCP 연결 실패: {e}")
        print("   Fallback tool(create_ticket) 사용.")
        return [create_ticket]


# ========== Tool 목록 구성 ==========
async def build_tools():
    """search_kb + Gateway MCP tools (또는 fallback) + google_search"""
    gateway_tools = await load_gateway_tools()
    return [search_kb] + gateway_tools + [google_search]


# 전역 tool 목록 (초기화 시 한 번만 로딩)
tools = None


# ========== LLM 초기화 ==========
def get_llm(tool_list):
    llm = ChatBedrock(
        model_id=settings.bedrock_model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.7, "max_tokens": settings.bedrock_max_tokens},
    )
    return llm.bind_tools(tool_list)


# ========== 시스템 프롬프트 ==========
SYSTEM_PROMPT = """당신은 기업용 업무 지원 에이전트입니다.

사용자의 질문에 따라 적절한 도구를 사용하여 답변합니다:

1. 사내 업무 관련 질문이 들어오면 반드시 먼저 search_kb 도구로 사내 문서를 검색하세요.
2. search_kb 검색 결과로 해결이 가능하면 그 내용을 바탕으로 답변하세요.
3. search_kb 검색 결과가 부족하거나 해결 방안이 없으면, 사용자에게 묻지 말고 바로 test-target___createTicket으로 헬프데스크 티켓을 자동 생성하세요.
4. 티켓 관련 조회/수정 요청:
   - 티켓 목록 조회 → test-target___getTickets (파라미터 없이 호출하면 전체 목록, status/priority/category/requester로 필터링 가능)
   - 티켓 상세 조회 → test-target___getTicket (ticket_id 필요)
   - 티켓 업데이트 → test-target___updateTicket (ticket_id 필요)
   - 티켓 통계 → test-target___getStatistics (파라미터 없음)
5. 회사 내부와 관련 없는 일반 질문 → google_search 도구로 외부 검색

중요 규칙:
- 티켓을 바로 생성하지 말고, 반드시 search_kb로 먼저 검색하세요.
- search_kb 결과에 해결 방안이 없으면 사용자 확인 없이 자동으로 티켓을 생성하세요.
- 티켓 생성 전에 필수 정보(요청자 이름, 문제 상세 설명)가 부족하면 먼저 사용자에게 물어보세요.
- 티켓 생성 시 "사내 문서에서 해결 방안을 찾을 수 없어 헬프데스크 티켓을 자동 생성했습니다"라고 안내하세요.
- 사내 문서에 없는 내용을 임의로 만들어서 답변하지 마세요. 검색 결과에 있는 내용만 전달하세요.
- 도구 호출 결과가 JSON 형태로 반환되면 성공한 것입니다. 사용자가 읽기 쉽게 정리하여 답변하세요.
- 티켓 목록은 마크다운 표로 보여주되, 컬럼은 ID, 제목, 상태, 우선순위만 표시하세요. 요청자, 담당자, 카테고리는 생략하세요.
- 티켓 생성 결과에 id 필드가 있으면 성공적으로 생성된 것입니다.
- 도구 호출에 실패했다고 임의로 판단하지 마세요. 반드시 도구를 호출하고 결과를 확인하세요.
- "기술적인 문제"라고 답변하지 마세요. 도구를 직접 호출해서 확인하세요.
- 항상 한국어로 답변하세요."""


# ========== 노드 함수 ==========
def agent_node(state: AgentState) -> AgentState:
    """LLM이 tool 호출 여부를 판단하는 노드"""
    global tools
    messages = state["messages"]

    # 시스템 프롬프트가 없으면 추가
    if not messages or not isinstance(messages[0], SystemMessage):
        messages = [SystemMessage(content=SYSTEM_PROMPT)] + list(messages)

    start = time.time()
    llm = get_llm(tools)

    # 오류 시나리오 (항상 활성): 특정 키워드 질문은 max_tokens=10으로 토큰 에러 유발
    # Datadog에서 "토큰 한도 초과로 응답이 잘리는 원인"을 추적하는 시나리오
    token_error_keywords = ["요약", "정리", "상세히", "자세히"]
    last_user_msg = ""
    for msg in reversed(messages):
        if isinstance(msg, HumanMessage):
            last_user_msg = msg.content.lower()
            break

    if any(kw in last_user_msg for kw in token_error_keywords):
        logger.warning("토큰 에러 시나리오 활성화 (max_tokens=10)", extra={"node": "agent", "model_id": settings.bedrock_model_id})
        llm = ChatBedrock(
            model_id=settings.bedrock_model_id,
            region_name=settings.aws_region,
            model_kwargs={"temperature": 0.7, "max_tokens": 10},
        ).bind_tools(tools)

    response = llm.invoke(messages)
    duration = int((time.time() - start) * 1000)

    # tool 호출 여부 로깅
    if hasattr(response, "tool_calls") and response.tool_calls:
        tool_names = [tc.get("name", "unknown") for tc in response.tool_calls]
        logger.info(f"LLM → tool 호출: {tool_names}", extra={"node": "agent", "duration_ms": duration, "model_id": settings.bedrock_model_id})
    else:
        logger.info("LLM → 최종 응답", extra={"node": "agent", "duration_ms": duration, "model_id": settings.bedrock_model_id})

    return {"messages": [response]}


def should_continue(state: AgentState) -> str:
    """마지막 메시지에 tool_calls가 있으면 tools로, 없으면 종료"""
    last_message = state["messages"][-1]

    if hasattr(last_message, "tool_calls") and last_message.tool_calls:
        return "tools"
    return "end"


# ========== 그래프 생성 ==========
async def create_agent_graph():
    """LangGraph 워크플로우 생성 (ReAct 패턴)"""
    global tools

    # Tool 목록 초기화 (최초 1회)
    if tools is None:
        tools = await build_tools()
        print(f"🔧 Tool 목록: {[t.name for t in tools]}")

    workflow = StateGraph(AgentState)

    # 노드 추가
    workflow.add_node("agent", agent_node)
    workflow.add_node("tools", ToolNode(tools))

    # 시작점
    workflow.set_entry_point("agent")

    # agent → tool 필요하면 tools로, 아니면 END
    workflow.add_conditional_edges(
        "agent",
        should_continue,
        {"tools": "tools", "end": END}
    )

    # tools 완료 → 다시 agent로 (결과를 LLM이 해석)
    workflow.add_edge("tools", "agent")

    return workflow.compile()


# ========== 테스트 ==========
if __name__ == "__main__":
    print("🤖 Enterprise Agent v2 (ReAct) 시작...")
    agent = create_agent_graph()

    test_messages = [
        "휴가 신청은 어떻게 해?",
        "파이썬 최신 버전이 뭐야?",
        "노트북이 고장났는데 어떻게 해야 해?",
    ]

    for msg in test_messages:
        print(f"\n👤 {msg}")
        result = agent.invoke({"messages": [HumanMessage(content=msg)]})
        print(f"🤖 {result['messages'][-1].content[:200]}")
