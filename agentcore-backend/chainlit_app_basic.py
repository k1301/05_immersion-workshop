"""
Step 1: Chainlit 챗봇

- Tool, RAG가 없는 단순 챗봇
- 사용자의 입력을 바로 Bedrock 모델로 전달
"""
import chainlit as cl
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage

from agent_basic import get_basic_llm
from config import AVAILABLE_MODELS, get_settings


settings = get_settings()

SYSTEM_PROMPT = """당신은 기본 한국어 AI 챗봇입니다.
- 항상 한국어로 답변하세요.
- 일반적인 공개 지식 질문에는 답변할 수 있습니다.
- 답변 톤은 친절하고 자연스럽게 유지하되, 필요하면 가벼운 이모지를 1개 정도 사용할 수 있습니다.
- 당신은 회사 내부 문서, 사내 정책, 사내 시스템, 헬프데스크 데이터에 접근할 수 없습니다.
- 사용자가 회사별 내부 정보가 필요한 질문을 하면, 정확한 내부 근거가 없어 답할 수 없다고 분명하고 간결하게 말하세요.
- 내부 정보 질문을 거절할 때는 1~2문장으로 짧게 답하고, 일반적인 절차나 예시를 길게 덧붙이지 마세요.
- 내부 정보 질문에 대한 답변 끝에 새로운 설명이나 추가 가이드를 이어서 쓰지 마세요.
- 모르면 모른다고 말하세요."""


@cl.on_chat_start
async def on_chat_start():
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

    await cl.Message(content="무엇이든 물어보세요. 😊").send()


@cl.on_settings_update
async def on_settings_update(settings_dict):
    model_name = settings_dict.get("model")
    if model_name in AVAILABLE_MODELS:
        cl.user_session.set("current_model", AVAILABLE_MODELS[model_name])
        await cl.Message(content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!").send()


@cl.on_message
async def on_message(message: cl.Message):
    chat_history = cl.user_session.get("chat_history", [])

    msg = cl.Message(content="🤖 LLM 응답 생성 중...")
    await msg.send()

    try:
        current_model = cl.user_session.get("current_model", settings.bedrock_model_id)
        llm = get_basic_llm(current_model)
        messages = [SystemMessage(content=SYSTEM_PROMPT)] + chat_history + [HumanMessage(content=message.content)]

        response = llm.invoke(messages)
        answer = response.content if hasattr(response, "content") else str(response)
        msg.content = answer
        await msg.update()

        chat_history.extend([HumanMessage(content=message.content), AIMessage(content=answer)])
        cl.user_session.set("chat_history", chat_history)
    except Exception as exc:
        msg.content = f"❌ 챗봇 실행 중 오류가 발생했습니다: {exc}"
        await msg.update()
