"""
Step 2: RAG 추가 버전

- Bedrock Knowledge Base 검색
- 검색 결과를 context로 LLM에 전달
"""
from contextlib import nullcontext

import chainlit as cl

from agent_rag import answer_with_rag
from config import AVAILABLE_MODELS, get_settings

try:
    from ddtrace.llmobs import LLMObs
except ImportError:
    LLMObs = None


settings = get_settings()


def _build_rag_tags(rag_metadata: dict) -> dict[str, str]:
    return {
        "workflow_step": "step2_rag",
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


@cl.on_chat_start
async def on_chat_start():
    cl.user_session.set("current_model", settings.bedrock_model_id)

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

    await cl.Message(content="사내 업무 에이전트입니다.").send()


@cl.on_settings_update
async def on_settings_update(settings_dict):
    model_name = settings_dict.get("model")
    if model_name in AVAILABLE_MODELS:
        settings.bedrock_model_id = AVAILABLE_MODELS[model_name]
        cl.user_session.set("current_model", AVAILABLE_MODELS[model_name])
        await cl.Message(content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!").send()


@cl.on_message
async def on_message(message: cl.Message):
    current_model = cl.user_session.get("current_model", settings.bedrock_model_id)
    original_model = settings.bedrock_model_id
    settings.bedrock_model_id = current_model

    msg = cl.Message(content="🔍 Knowledge Base 검색 중...")
    await msg.send()

    try:
        workflow = LLMObs.workflow(name="rag_chat_interaction") if LLMObs else nullcontext()
        with workflow as span:
            answer, sources, rag_metadata = answer_with_rag(message.content)
            if sources:
                source_text = "\n".join(f"- {source}" for source in sources)
                msg.content = f"{answer}\n\n---\n**근거 문서**\n{source_text}"
            else:
                msg.content = answer
            await msg.update()

            _annotate_rag_workflow(message.content, answer, sources, rag_metadata)
    except Exception as exc:
        msg.content = f"❌ RAG 실행 중 오류가 발생했습니다: {exc}"
        await msg.update()
    finally:
        settings.bedrock_model_id = original_model
