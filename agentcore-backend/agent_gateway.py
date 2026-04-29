"""
Step 3: RAG + AgentCore Gateway

- Step 2의 RAG 및 챗봇 기능 포함
- Helpdesk 작업은 Gateway MCP tool로만 수행

"""
import json
import os
from typing import Annotated, Any, Optional, TypedDict

import boto3
from langchain_aws import ChatBedrock
from langchain_core.messages import BaseMessage, SystemMessage
from langchain_core.tools import StructuredTool, tool
from langgraph.graph import END, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode
from pydantic import Field, create_model

from agent_rag import answer_with_rag
from config import get_settings


settings = get_settings()
os.environ["AWS_DEFAULT_REGION"] = settings.aws_region
os.environ["AWS_REGION"] = settings.aws_region


class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]


@tool
def search_kb(query: str) -> str:
    """사내 업무 가이드를 검색합니다.
    휴가 정책, 경비 처리, 온보딩, IT 보안 등 회사 내부 문서에서 관련 정보를 찾을 때 사용합니다."""
    answer, sources, rag_metadata = answer_with_rag(query)
    return json.dumps(
        {
            "tool": "search_kb",
            "answer": answer,
            "sources": sources,
            "rag_metadata": rag_metadata,
        },
        ensure_ascii=False,
    )


async def _call_gateway_tool(tool_name: str, arguments: dict[str, Any]) -> str:
    """Gateway MCP tool 호출"""
    from httpx_auth_awssigv4 import SigV4Auth as HttpxSigV4Auth
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    session = boto3.Session()
    creds = session.get_credentials().get_frozen_credentials()
    auth = HttpxSigV4Auth(
        access_key=creds.access_key,
        secret_key=creds.secret_key,
        token=creds.token if creds.token else None,
        service="bedrock-agentcore",
        region=settings.aws_region,
    )

    async with streamablehttp_client(url=settings.gateway_mcp_url, auth=auth) as (read, write, _):
        async with ClientSession(read, write) as mcp_session:
            await mcp_session.initialize()
            clean_args = {key: value for key, value in arguments.items() if value is not None}
            result = await mcp_session.call_tool(tool_name, clean_args)

            if result.content:
                parts = []
                for item in result.content:
                    parts.append(item.text if hasattr(item, "text") else str(item))
                return "\n".join(parts)
            return "결과 없음"


async def load_gateway_tools() -> list[StructuredTool]:
    """AgentCore Gateway에서 MCP tool 목록을 가져와 LangChain tool로 변환"""
    if not settings.gateway_mcp_url:
        raise RuntimeError("GATEWAY_MCP_URL이 설정되지 않았습니다. Step 3에서는 Gateway 연결이 필수입니다.")

    try:
        from httpx_auth_awssigv4 import SigV4Auth as HttpxSigV4Auth
        from mcp import ClientSession
        from mcp.client.streamable_http import streamablehttp_client

        session = boto3.Session()
        creds = session.get_credentials().get_frozen_credentials()
        auth = HttpxSigV4Auth(
            access_key=creds.access_key,
            secret_key=creds.secret_key,
            token=creds.token if creds.token else None,
            service="bedrock-agentcore",
            region=settings.aws_region,
        )

        async with streamablehttp_client(url=settings.gateway_mcp_url, auth=auth) as (read, write, _):
            async with ClientSession(read, write) as mcp_session:
                await mcp_session.initialize()
                tools_response = await mcp_session.list_tools()

        gateway_tools = []
        for mcp_tool in tools_response.tools:
            mcp_name = mcp_tool.name
            display_name = mcp_name.split("___")[-1] if "___" in mcp_name else mcp_name
            tool_desc = mcp_tool.description or display_name
            schema = mcp_tool.inputSchema if mcp_tool.inputSchema else {"type": "object", "properties": {}}

            def make_tool_func(name: str):
                async def tool_func(**kwargs) -> str:
                    return await _call_gateway_tool(name, kwargs)

                return tool_func

            fields: dict[str, tuple[type[Any], Any]] = {}
            properties = schema.get("properties", {})
            required = schema.get("required", [])
            for prop_name, prop_info in properties.items():
                prop_type = prop_info.get("type", "string")
                prop_desc = prop_info.get("description", "")
                py_type: type[Any] = str
                if prop_type == "integer":
                    py_type = int
                elif prop_type == "boolean":
                    py_type = bool

                if prop_name in required:
                    fields[prop_name] = (py_type, Field(description=prop_desc))
                else:
                    fields[prop_name] = (Optional[py_type], Field(default=None, description=prop_desc))

            args_model = create_model(f"{display_name}_args", **fields) if fields else None

            gateway_tools.append(
                StructuredTool.from_function(
                    coroutine=make_tool_func(mcp_name),
                    name=display_name,
                    description=tool_desc,
                    args_schema=args_model,
                )
            )

        return gateway_tools
    except Exception as exc:
        raise RuntimeError(f"Gateway MCP tool 로딩에 실패했습니다: {exc}") from exc


async def build_tools():
    gateway_tools = await load_gateway_tools()
    return [search_kb] + gateway_tools


tools = None


def get_llm(tool_list):
    llm = ChatBedrock(
        model_id=settings.bedrock_model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.4, "max_tokens": settings.bedrock_max_tokens},
    )
    return llm.bind_tools(tool_list) if tool_list else llm


SYSTEM_PROMPT = """당신은 사내 업무 에이전트입니다.

사용자의 질문에 따라 적절한 도구를 사용하세요.

1. 사내 정책, 절차, 보안, 온보딩, 경비 등 문서성 질문은 반드시 먼저 search_kb를 사용하세요.
2. 노트북 고장, 계정 문제, 소프트웨어 오류, 네트워크 장애처럼 IT 지원/장애성 요청도 먼저 search_kb를 사용해
   사내 대응 가이드나 점검 절차가 있는지 확인하세요.
3. 사용자가 단순히 장애 상황을 설명한 것만으로는 바로 티켓을 생성하지 마세요.
   먼저 사내 문서 기반의 점검/안내를 제공하고, 사용자가 티켓 생성을 원하거나 추가 지원이 필요할 때 생성 절차로 넘어가세요.
4. search_kb는 JSON 문자열을 반환합니다.
   - answer: 사용자에게 전달할 요약 답변
   - sources: 근거 문서 목록
   - rag_metadata: 검색 메타데이터
5. search_kb의 answer가 "관련 근거 문서를 찾지 못했습니다." 또는 "현재 검색 기준을 통과한 문서가 없습니다."이면
   그 사실을 사용자에게 자연스럽게 설명하세요.
6. 티켓 생성, 티켓 조회, 티켓 수정, 티켓 통계 요청은 Gateway MCP tool을 사용하세요.
7. Helpdesk 작업은 반드시 Gateway tool로만 수행하세요. 직접 REST API를 호출한다고 가정하지 마세요.
8. 사용자가 요청하지 않은 티켓을 자동으로 생성하지 마세요.
9. IT 장애/지원 요청에서 search_kb 결과가 없거나 부족하면, 간단한 기본 점검 안내 후
   "헬프데스크 티켓을 생성해드릴까요?"라고 물어보세요. 사용자가 동의하기 전에는 티켓을 생성하지 마세요.
10. 도구 호출 결과가 JSON이라면 사용자가 읽기 쉬운 형태로 정리해서 답변하세요.
11. 항상 한국어로 답변하세요.

중요:
- 사내 문서에 없는 내용을 추측하지 마세요.
- Gateway tool 호출이 실패하면 실패 사실을 숨기지 말고 안내하세요.
- 티켓 생성에 필요한 정보가 부족하면 먼저 사용자에게 보완 정보를 요청하세요.
- 장애/지원 요청은 가능한 경우 먼저 사내 가이드를 안내한 뒤, 사용자의 동의를 받아 티켓 생성으로 이어가세요.
- 티켓 목록을 정리할 때는 ID, 제목, 상태, 우선순위 위주로 간단히 보여주세요.
"""


def agent_node(state: AgentState) -> AgentState:
    messages = state["messages"]

    if not messages or not isinstance(messages[0], SystemMessage):
        messages = [SystemMessage(content=SYSTEM_PROMPT)] + list(messages)

    llm = get_llm(tools)
    response = llm.invoke(messages)
    return {"messages": [response]}


def should_continue(state: AgentState) -> str:
    last_message = state["messages"][-1]
    if hasattr(last_message, "tool_calls") and last_message.tool_calls:
        return "tools"
    return "end"


async def create_agent_graph():
    global tools

    if tools is None:
        tools = await build_tools()

    workflow = StateGraph(AgentState)
    workflow.add_node("agent", agent_node)
    workflow.add_node("tools", ToolNode(tools))
    workflow.set_entry_point("agent")
    workflow.add_conditional_edges("agent", should_continue, {"tools": "tools", "end": END})
    workflow.add_edge("tools", "agent")
    return workflow.compile()
