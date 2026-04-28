"""
Step 2: 기본 챗봇 + search_kb tool routing

- 일반 질문은 기본 챗봇처럼 직접 답변
- 사내 문서성 질문만 search_kb tool을 통해 Knowledge Base 검색
"""
import json
from contextlib import nullcontext

import chainlit as cl
from langchain_core.messages import HumanMessage

from agent_rag import create_rag_agent_graph
from config import AVAILABLE_MODELS, get_settings

try:
    from ddtrace.llmobs import LLMObs
except ImportError:
    LLMObs = None


settings = get_settings()
agent_graph = None


def _build_rag_tags(rag_metadata: dict) -> dict[str, str]:
    return {
        "workflow_step": "step2_rag",
        "route": str(rag_metadata.get("route", "")),
        "rag.used": str(rag_metadata.get("rag.used", False)).lower(),
        "tool.called": str(rag_metadata.get("tool.called", "")),
        "tool.calls": str(rag_metadata.get("tool.calls", "")),
        "rag_failure_reason": str(rag_metadata.get("rag.failure_reason", "")),
        "rag_is_security_query": str(rag_metadata.get("rag.is_security_query", False)).lower(),
        "rag_threshold": str(rag_metadata.get("rag.threshold", "")),
        "rag_top_score": str(rag_metadata.get("rag.top_score", "")),
        "rag_retrieved_count": str(rag_metadata.get("rag.retrieved_count", "")),
        "rag_filtered_count": str(rag_metadata.get("rag.filtered_count", "")),
        "rag_filtered_out_count": str(rag_metadata.get("rag.filtered_out_count", "")),
        "rag_threshold_profile": str(rag_metadata.get("rag.threshold_profile", "")),
    }


def _annotate_rag_workflow(message_content: str, answer: str, sources: list[str], rag_metadata: dict):
    if not LLMObs:
        return

    try:
        LLMObs.annotate(
            input_data=message_content,
            output_data=answer,
            metadata={
                **rag_metadata,
                "source_count": len(sources),
                "workflow_step": "step2_rag",
            },
            tags=_build_rag_tags(rag_metadata),
        )
    except Exception as exc:
        print(f"LLMObs annotation skipped in step2_rag: {exc}")


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
        agent_graph = create_rag_agent_graph()
        await cl.Message(content="사내 업무 에이전트입니다.").send()
    except Exception as exc:
        agent_graph = None
        await cl.Message(content=f"❌ RAG 에이전트 초기화에 실패했습니다: {exc}").send()


@cl.on_settings_update
async def on_settings_update(settings_dict):
    model_name = settings_dict.get("model")
    if model_name in AVAILABLE_MODELS:
        settings.bedrock_model_id = AVAILABLE_MODELS[model_name]
        cl.user_session.set("current_model", AVAILABLE_MODELS[model_name])
        await cl.Message(content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!").send()


@cl.on_message
async def on_message(message: cl.Message):
    global agent_graph

    if agent_graph is None:
        try:
            agent_graph = create_rag_agent_graph()
        except Exception as exc:
            await cl.Message(content=f"❌ RAG 에이전트 초기화에 실패했습니다: {exc}").send()
            return

    current_model = cl.user_session.get("current_model", settings.bedrock_model_id)
    original_model = settings.bedrock_model_id
    settings.bedrock_model_id = current_model
    chat_history = cl.user_session.get("chat_history", [])
    initial_state = {"messages": chat_history + [HumanMessage(content=message.content)]}

    msg = cl.Message(content="🧭 요청을 분석 중입니다...")
    await msg.send()

    try:
        workflow = LLMObs.workflow(name="rag_chat_interaction") if LLMObs else nullcontext()
        with workflow as span:
            final_response = ""
            all_messages = []
            sources: list[str] = []
            rag_metadata: dict[str, object] = {}
            tool_calls: list[str] = []

            async for chunk in agent_graph.astream(initial_state):
                if "agent" in chunk:
                    agent_output = chunk["agent"]
                    if "messages" in agent_output:
                        all_messages.extend(agent_output["messages"])
                        last_msg = agent_output["messages"][-1]

                        if hasattr(last_msg, "tool_calls") and last_msg.tool_calls:
                            for tool_call in last_msg.tool_calls:
                                tool_name = tool_call.get("name", "")
                                if tool_name:
                                    tool_calls.append(tool_name)
                                if tool_name == "search_kb":
                                    msg.content = "🔍 사내 문서 검색 중..."
                                    await msg.update()
                        elif hasattr(last_msg, "content") and last_msg.content:
                            final_response = last_msg.content

                if "tools" in chunk and "messages" in chunk["tools"]:
                    tool_messages = chunk["tools"]["messages"]
                    all_messages.extend(tool_messages)

                    for tool_msg in tool_messages:
                        parsed = _parse_search_kb_result(getattr(tool_msg, "content", ""))
                        if parsed:
                            sources = parsed.get("sources", []) or []
                            rag_metadata = parsed.get("rag_metadata", {}) or {}

            unique_tool_calls = list(dict.fromkeys(tool_calls))
            used_rag = "search_kb" in unique_tool_calls
            rag_metadata["route"] = "RAG" if used_rag else "GENERAL"
            rag_metadata["rag.used"] = used_rag
            rag_metadata["tool.called"] = "search_kb" if used_rag else "none"
            rag_metadata["tool.calls"] = ",".join(unique_tool_calls) if unique_tool_calls else "none"

            if final_response:
                if sources:
                    source_text = "\n".join(f"- {source}" for source in sources)
                    msg.content = f"{final_response}\n\n---\n**근거 문서**\n{source_text}"
                else:
                    msg.content = final_response
                await msg.update()

            updated_history = chat_history + [HumanMessage(content=message.content)] + all_messages
            cl.user_session.set("chat_history", updated_history)

            _annotate_rag_workflow(message.content, final_response, sources, rag_metadata)
    except Exception as exc:
        msg.content = f"❌ RAG 실행 중 오류가 발생했습니다: {exc}"
        await msg.update()
    finally:
        settings.bedrock_model_id = original_model
