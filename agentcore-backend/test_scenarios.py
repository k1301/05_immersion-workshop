"""
워크샵 시나리오 테스트 스크립트

에이전트에 정상 질문 + 에러 유발 질문을 보내서
Datadog LLM Observability에 트레이스를 생성합니다.

사용법:
  # Datadog 트레이싱과 함께 실행
  DD_LLMOBS_ENABLED=1 \
  DD_LLMOBS_ML_APP=agentcore-backend \
  DD_LLMOBS_AGENTLESS_ENABLED=1 \
  DD_API_KEY=<YOUR_KEY> \
  DD_SITE=datadoghq.com \
  DD_PATCH_MODULES=langchain:true,botocore:true \
  ddtrace-run python test_scenarios.py
"""
import asyncio
import time
from langchain_core.messages import HumanMessage
from agent import create_agent_graph
from config import get_settings

settings = get_settings()

# 테스트 질문: 정상 + 에러 유발 (보안 키워드)
TEST_CASES = [
    # 정상 질문 (search_kb 성공)
    {"question": "연차 휴가는 며칠까지 쓸 수 있나요?", "expect": "success"},
    {"question": "경비 처리 절차를 알려주세요", "expect": "success"},
    {"question": "신입 직원 온보딩 첫날 일정이 어떻게 되나요?", "expect": "success"},

    # 시나리오 1: 토큰 에러 (키워드: 요약, 정리, 상세히 등)
    {"question": "휴가 정책을 상세히 요약 정리해줘", "expect": "token_error"},
    {"question": "경비 처리 절차를 자세히 모두 알려줘", "expect": "token_error"},

    # 시나리오 2: Failure to Answer (보안 키워드)
    {"question": "IT 보안 정책 알려줘", "expect": "kb_error"},
    {"question": "VPN 접속 방법을 알려주세요", "expect": "kb_error"},
    {"question": "비밀번호 변경은 어떻게 하나요?", "expect": "kb_error"},

    # 일반 대화 (tool 호출 없음)
    {"question": "안녕하세요, 간단히 자기소개 해주세요", "expect": "success"},
]


async def main():
    print("=" * 60)
    print("🧪 워크샵 시나리오 테스트")
    print(f"   시나리오: {settings.workshop_scenario}")
    print(f"   모델: {settings.bedrock_model_id}")
    print(f"   KB ID: {settings.bedrock_kb_id}")
    print(f"   질문 수: {len(TEST_CASES)}")
    print("=" * 60)

    agent = await create_agent_graph()

    for i, tc in enumerate(TEST_CASES, 1):
        question = tc["question"]
        expect = tc["expect"]

        print(f"\n--- [{i}/{len(TEST_CASES)}] {expect.upper()} 예상 ---")
        print(f"👤 {question}")

        start = time.time()
        try:
            result = await agent.ainvoke({"messages": [HumanMessage(content=question)]})
            duration = int((time.time() - start) * 1000)
            response = result["messages"][-1].content
            preview = response[:150] + "..." if len(response) > 150 else response
            print(f"🤖 ({duration}ms) {preview}")

            if expect == "error":
                print(f"⚠️  에러가 예상되었지만 성공함")
        except Exception as e:
            duration = int((time.time() - start) * 1000)
            print(f"❌ ({duration}ms) 에러: {e}")

            if expect == "success":
                print(f"⚠️  성공이 예상되었지만 에러 발생")

    print("\n" + "=" * 60)
    print("✅ 테스트 완료!")
    print("   Datadog → LLM Observability → Traces 에서 확인하세요.")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
