"""
사내 업무 에이전트 - Chainlit Frontend (v2 - ReAct 패턴)

LangGraph ReAct 에이전트를 Chainlit UI로 연결합니다.
- Tool 기반: search_kb, create_ticket, google_search
- LLM이 스스로 필요한 tool을 선택하여 실행
"""
import chainlit as cl
from langchain_core.messages import HumanMessage
from agent import create_agent_graph
from config import get_settings, AVAILABLE_MODELS

settings = get_settings()

# 에이전트 그래프 초기화
agent_graph = None

# 사용 가능한 모델 목록 (드롭다운용)
MODEL_OPTIONS = [
    {"label": f"{name.upper()} - {model_id}", "value": model_id}
    for name, model_id in AVAILABLE_MODELS.items()
]


@cl.on_chat_start
async def on_chat_start():
    """채팅 세션 시작 시 호출"""
    global agent_graph

    # 세션에 기본 모델 저장
    cl.user_session.set("current_model", settings.bedrock_model_id)

    # 대화 히스토리 초기화
    cl.user_session.set("chat_history", [])

    # 에이전트 초기化
    agent_graph = await create_agent_graph()

    # 환영 메시지
    current_model = cl.user_session.get("current_model")
    model_name = [name for name, mid in AVAILABLE_MODELS.items() if mid == current_model]
    model_display = model_name[0].upper() if model_name else current_model

    # 채팅 설정 (드롭다운)
    settings_items = [
        cl.input_widget.Select(
            id="model",
            label="🤖 Bedrock Model",
            values=list(AVAILABLE_MODELS.keys()),
            initial_value=[k for k, v in AVAILABLE_MODELS.items() if v == settings.bedrock_model_id][0] if settings.bedrock_model_id in AVAILABLE_MODELS.values() else "sonnet-4.5",
        )
    ]

    await cl.ChatSettings(settings_items).send()

    await cl.Message(
        content=f"""
👋 **사내 업무 에이전트에 오신 것을 환영합니다!**

이 에이전트는 ReAct 패턴을 사용하여 스스로 판단하고 도구를 선택합니다:

🔍 **search_kb**: 사내 업무 가이드 검색 (연차, 경비, IT 보안 등)
🎫 **create_ticket**: 헬프데스크 티켓 자동 생성 (담당자 지원 필요 시)
🌐 **google_search**: 외부 정보 검색 (일반 질문)

**현재 모델**: {model_display}
**리전**: {settings.aws_region}

💡 **사용 예시:**
- "연차 휴가는 어떻게 신청하나요?" → KB 검색
- "노트북이 고장났어요" → 티켓 생성
- "파이썬 최신 버전은?" → 구글 검색

무엇을 도와드릴까요?
        """
    ).send()


@cl.on_settings_update
async def on_settings_update(settings_dict):
    """설정 변경 시 호출"""
    model_name = settings_dict.get("model")

    if model_name and model_name in AVAILABLE_MODELS:
        new_model = AVAILABLE_MODELS[model_name]
        cl.user_session.set("current_model", new_model)

        await cl.Message(
            content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!"
        ).send()


@cl.on_message
async def on_message(message: cl.Message):
    """사용자 메시지 처리"""
    global agent_graph

    if agent_graph is None:
        agent_graph = await create_agent_graph()

    # 사용자 메시지
    user_content = message.content

    # /model 명령어 처리
    if user_content.startswith("/model "):
        model_name = user_content.split(" ", 1)[1].strip()

        # 모델 이름으로 모델 ID 찾기
        if model_name in AVAILABLE_MODELS:
            new_model = AVAILABLE_MODELS[model_name]
            cl.user_session.set("current_model", new_model)

            await cl.Message(
                content=f"✅ 모델이 **{model_name.upper()}**로 변경되었습니다!\n\n모델 ID: `{new_model}`"
            ).send()
        else:
            await cl.Message(
                content=f"❌ 알 수 없는 모델: **{model_name}**\n\n사용 가능한 모델: {', '.join(AVAILABLE_MODELS.keys())}"
            ).send()
        return

    # 세션에서 현재 모델 가져오기
    current_model = cl.user_session.get("current_model", settings.bedrock_model_id)

    # 임시로 모델 변경 (settings 객체는 전역이므로 원복 필요)
    original_model = settings.bedrock_model_id
    settings.bedrock_model_id = current_model

    # 초기 상태 (대화 히스토리 포함)
    chat_history = cl.user_session.get("chat_history", [])
    initial_state = {
        "messages": chat_history + [HumanMessage(content=user_content)]
    }

    # 응답 메시지 초기화
    msg = cl.Message(content="")
    await msg.send()

    try:
        # LangGraph 실행 (노드 단위 스트리밍)
        final_response = ""
        all_messages = []
        async for chunk in agent_graph.astream(initial_state):
            # 각 노드의 출력을 처리
            if "agent" in chunk:
                agent_output = chunk["agent"]
                if "messages" in agent_output:
                    all_messages.extend(agent_output["messages"])
                    last_msg = agent_output["messages"][-1]
                    # tool_calls가 있으면 tool 호출 표시
                    if hasattr(last_msg, "tool_calls") and last_msg.tool_calls:
                        for tc in last_msg.tool_calls:
                            tool_name = tc.get("name", "")
                            tool_emoji = {
                                "search_kb": "🔍",
                                "test-target___createTicket": "🎫",
                                "test-target___getTickets": "📋",
                                "test-target___getTicket": "📋",
                                "test-target___updateTicket": "✏️",
                                "test-target___getStatistics": "📊",
                                "google_search": "🌐"
                            }
                            emoji = tool_emoji.get(tool_name, "🔧")
                            msg.content = f"{emoji} **{tool_name}** 실행 중...\n"
                            await msg.update()
                    # 최종 응답 (tool_calls 없음)
                    elif hasattr(last_msg, "content") and last_msg.content:
                        final_response = last_msg.content

            elif "tools" in chunk:
                if "messages" in chunk["tools"]:
                    all_messages.extend(chunk["tools"]["messages"])

        # 최종 응답 표시
        if final_response:
            msg.content = final_response
            await msg.update()

            # 대화 히스토리 업데이트 (전체 메시지 포함)
            chat_history = cl.user_session.get("chat_history", [])
            chat_history.append(HumanMessage(content=user_content))
            chat_history.extend(all_messages)
            cl.user_session.set("chat_history", chat_history)

    except Exception as e:
        error_msg = f"❌ **오류 발생**: {str(e)}\n\n"
        error_msg += "에이전트 실행 중 문제가 발생했습니다. 다시 시도해주세요."
        msg.content = error_msg
        await msg.update()

    finally:
        # 모델 원복
        settings.bedrock_model_id = original_model


@cl.on_chat_end
async def on_chat_end():
    """채팅 세션 종료 시 호출"""
    print("Chat session ended")


if __name__ == "__main__":
    # Chainlit 앱 실행 안내
    print("🚀 Chainlit 앱을 실행하려면:")
    print("   chainlit run chainlit_app.py -w")
    print()
    print("📖 브라우저에서 자동으로 열립니다: http://localhost:8000")
