"""
Step 3: RAG + AgentCore Gateway 버전

- 사내 문서 질문은 search_kb로 처리
- Helpdesk 작업은 Gateway MCP tool로 처리
"""
import json
from contextlib import nullcontext

import chainlit as cl
from langchain_core.messages import HumanMessage

from agent_gateway import create_agent_graph
from config import AVAILABLE_MODELS, get_settings

try:
    from ddtrace.llmobs import LLMObs
except ImportError:
    LLMObs = None


settings = get_settings()
agent_graph = None


def _build_rag_tags(rag_metadata: dict) -> dict[str, str]:
    return {
        "workflow_step": "step3_gateway",
        "rag_failure_reason": str(rag_metadata.get("rag.failure_reason", "")),
        "rag_is_security_query": str(rag_metadata.get("rag.is_security_query", False)).lower(),
        "rag_threshold": str(rag_metadata.get("rag.threshold", "")),
        "rag_top_score": str(rag_metadata.get("rag.top_score", "")),
        "rag_retrieved_count": str(rag_metadata.get("rag.retrieved_count", "")),
        "rag_filtered_count": str(rag_metadata.get("rag.filtered_count", "")),
        "rag_filtered_out_count": str(rag_metadata.get("rag.filtered_out_count", "")),
        "rag_threshold_profile": str(rag_metadata.get("rag.threshold_profile", "")),
    }


def _annotate_gateway_workflow(message_content: str, final_response: str, rag_sources: list[str], rag_metadata: dict):
    if not LLMObs:
        return

    try:
        LLMObs.annotate(
            input_data=message_content,
            output_data=final_response,
            metadata={
                **rag_metadata,
                "source_count": len(rag_sources),
                "workflow_step": "step3_gateway",
            },
            tags=_build_rag_tags(rag_metadata),
        )
    except Exception as exc:
        print(f"LLMObs annotation skipped in step3_gateway: {exc}")


def _parse_search_kb_result(raw_content: str):
    try:
        parsed = json.loads(raw_content)
    except (json.JSONDecodeError, TypeError):
        return None

    if isinstance(parsed, dict) and parsed.get("tool") == "search_kb":
        return parsed
    return None


@cl.on_chat_start
async def on_chat_start():
    global agent_graph

    cl.user_session.set("current_model", settings.bedrock_model_id)
    cl.user_session.set("chat_history", [])

    await cl.ChatSettings(
        [
            cl.input_widget.Select(
                id="model",
                label="Bedrock Model",
                values=list(AVAILABLE_MODELS.keys()),
                initial_value=next(
                    (name for name, model_id in AVAILABLE_MODELS.items() if model_id == settings.bedrock_model_id),
                    "sonnet-4.5",
                ),
            )
        ]
    ).send()

    try:
        agent_graph = await create_agent_graph()
        await cl.Message(content="사내 업무 에이전트입니다.").send()
    except Exception as exc:
        agent_graph = None
        await cl.Message(content=f"❌ Gateway 초기화에 실패했습니다: {exc}").send()


@cl.on_settings_update
async def on_settings_update(settings_dict):
    model_name = settings_dict.get("model")
    if model_name in AVAILABLE_MODELS:
        cl.user_session.set("current_model", AVAILABLE_MODELS[model_name])
        await cl.Message(content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!").send()


@cl.on_message
async def on_message(message: cl.Message):
    global agent_graph

    if agent_graph is None:
        try:
            agent_graph = await create_agent_graph()
        except Exception as exc:
            await cl.Message(content=f"❌ Gateway 초기화에 실패했습니다: {exc}").send()
            return

    current_model = cl.user_session.get("current_model", settings.bedrock_model_id)
    original_model = settings.bedrock_model_id
    settings.bedrock_model_id = current_model

    chat_history = cl.user_session.get("chat_history", [])
    initial_state = {"messages": chat_history + [HumanMessage(content=message.content)]}

    msg = cl.Message(content="")
    await msg.send()

    try:
        workflow = LLMObs.workflow(name="gateway_chat_interaction") if LLMObs else nullcontext()
        with workflow as span:
            final_response = ""
            all_messages = []
            rag_sources: list[str] = []
            rag_metadata: dict[str, object] = {}

            async for chunk in agent_graph.astream(initial_state):
                if "agent" in chunk:
                    agent_output = chunk["agent"]
                    if "messages" in agent_output:
                        all_messages.extend(agent_output["messages"])
                        last_msg = agent_output["messages"][-1]

                        if hasattr(last_msg, "tool_calls") and last_msg.tool_calls:
                            for tool_call in last_msg.tool_calls:
                                tool_name = tool_call.get("name", "")
                                tool_display = {
                                    "search_kb": ("🔍", "사내 문서 검색"),
                                    "createTicket": ("🎫", "헬프데스크 티켓 생성"),
                                    "getTickets": ("📋", "티켓 목록 조회"),
                                    "getTicket": ("📋", "티켓 상세 조회"),
                                    "updateTicket": ("✏️", "티켓 업데이트"),
                                    "getStatistics": ("📊", "티켓 통계 조회"),
                                }
                                emoji, display = tool_display.get(tool_name, ("🔧", tool_name))
                                msg.content = f"{emoji} **{display}** 중...\n"
                                await msg.update()
                        elif hasattr(last_msg, "content") and last_msg.content:
                            final_response = last_msg.content

                if "tools" in chunk and "messages" in chunk["tools"]:
                    tool_messages = chunk["tools"]["messages"]
                    all_messages.extend(tool_messages)

                    for tool_msg in tool_messages:
                        parsed = _parse_search_kb_result(getattr(tool_msg, "content", ""))
                        if parsed:
                            rag_sources = parsed.get("sources", []) or []
                            rag_metadata = parsed.get("rag_metadata", {}) or {}

            if final_response:
                if rag_sources:
                    source_text = "\n".join(f"- {source}" for source in rag_sources)
                    msg.content = f"{final_response}\n\n---\n**근거 문서**\n{source_text}"
                else:
                    msg.content = final_response
                await msg.update()

            updated_history = chat_history + [HumanMessage(content=message.content)] + all_messages
            cl.user_session.set("chat_history", updated_history)

            _annotate_gateway_workflow(message.content, final_response, rag_sources, rag_metadata)

    except Exception as exc:
        msg.content = f"❌ Step 3 실행 중 오류가 발생했습니다: {exc}"
        await msg.update()
    finally:
        settings.bedrock_model_id = original_model
