"""
모델별 퍼포먼스 비교 벤치마크

여러 Bedrock 모델에 동일한 질문 세트를 실행하여
Datadog LLM Observability에서 비교할 수 있는 트레이스를 생성합니다.

사용법:
  # 기본 모델 3개로 벤치마크
  ddtrace-run python benchmark.py

  # 특정 모델 지정
  ddtrace-run python benchmark.py --models sonnet-4.5,haiku-3.5,sonnet-3.7

  # 반복 횟수 지정
  ddtrace-run python benchmark.py --repeat 3
"""
import asyncio
import argparse
import time
import json
import logging
from typing import Optional

from langchain_aws import ChatBedrock
from langchain_core.messages import HumanMessage, SystemMessage
from config import get_settings, AVAILABLE_MODELS

settings = get_settings()

logger = logging.getLogger("benchmark")
logging.basicConfig(level=logging.INFO, format="%(message)s")

# ========== 테스트 질문 세트 ==========
TEST_QUESTIONS = [
    # RAG 검색 질문 (KB 관련)
    {
        "question": "연차 휴가는 며칠까지 쓸 수 있나요?",
        "category": "rag",
        "expected_tool": "search_kb",
    },
    {
        "question": "경비 처리 절차를 알려주세요",
        "category": "rag",
        "expected_tool": "search_kb",
    },
    {
        "question": "신입 직원 온보딩 첫날 일정이 어떻게 되나요?",
        "category": "rag",
        "expected_tool": "search_kb",
    },
    {
        "question": "VPN 접속 방법을 알려주세요",
        "category": "rag",
        "expected_tool": "search_kb",
    },
    # 일반 대화 (tool 없이 직접 응답)
    {
        "question": "파이썬에서 리스트 컴프리헨션 예제를 보여줘",
        "category": "general",
        "expected_tool": None,
    },
    {
        "question": "안녕하세요, 오늘 날씨가 어떤가요?",
        "category": "general",
        "expected_tool": None,
    },
    # 복합 질문 (RAG → 티켓 생성 가능)
    {
        "question": "노트북 화면이 깜빡거려요. 해결 방법이 있나요?",
        "category": "complex",
        "expected_tool": "search_kb",
    },
]

SYSTEM_PROMPT = """당신은 기업용 업무 지원 에이전트입니다.
사용자의 질문에 간결하게 답변하세요. 한국어로 답변하세요."""


# ========== 벤치마크 실행 ==========
def run_single_query(model_id: str, model_name: str, question: dict) -> dict:
    """단일 모델 + 단일 질문 실행"""
    llm = ChatBedrock(
        model_id=model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.7, "max_tokens": 4096},
    )

    messages = [
        SystemMessage(content=SYSTEM_PROMPT),
        HumanMessage(content=question["question"]),
    ]

    start = time.time()
    error = None
    response_text = ""
    try:
        response = llm.invoke(messages)
        response_text = response.content if hasattr(response, "content") else str(response)
    except Exception as e:
        error = str(e)

    duration_ms = int((time.time() - start) * 1000)

    result = {
        "model_name": model_name,
        "model_id": model_id,
        "question": question["question"],
        "category": question["category"],
        "duration_ms": duration_ms,
        "response_length": len(response_text),
        "error": error,
    }

    status = "✅" if not error else "❌"
    logger.info(f"  {status} {model_name:12s} | {duration_ms:5d}ms | {question['category']:8s} | {question['question'][:30]}...")

    return result


def run_benchmark(model_names: list[str], repeat: int = 1):
    """전체 벤치마크 실행"""
    # 모델 검증
    models = []
    for name in model_names:
        if name in AVAILABLE_MODELS:
            models.append((name, AVAILABLE_MODELS[name]))
        else:
            logger.warning(f"⚠️  알 수 없는 모델: {name} (건너뜀)")

    if not models:
        logger.error("❌ 실행할 모델이 없습니다.")
        return

    logger.info("=" * 70)
    logger.info("🏁 모델 퍼포먼스 벤치마크")
    logger.info(f"   모델: {[m[0] for m in models]}")
    logger.info(f"   질문: {len(TEST_QUESTIONS)}개")
    logger.info(f"   반복: {repeat}회")
    logger.info(f"   총 호출: {len(models) * len(TEST_QUESTIONS) * repeat}회")
    logger.info("=" * 70)

    all_results = []

    for run in range(1, repeat + 1):
        if repeat > 1:
            logger.info(f"\n--- Run {run}/{repeat} ---")

        for model_name, model_id in models:
            logger.info(f"\n📡 {model_name.upper()} ({model_id})")

            for question in TEST_QUESTIONS:
                result = run_single_query(model_id, model_name, question)
                result["run"] = run
                all_results.append(result)

    # 결과 요약
    logger.info("\n" + "=" * 70)
    logger.info("📊 결과 요약")
    logger.info("=" * 70)

    for model_name, model_id in models:
        model_results = [r for r in all_results if r["model_name"] == model_name]
        success = [r for r in model_results if not r["error"]]
        errors = [r for r in model_results if r["error"]]
        avg_ms = sum(r["duration_ms"] for r in success) / len(success) if success else 0

        logger.info(f"\n  {model_name.upper()}:")
        logger.info(f"    성공: {len(success)}/{len(model_results)}")
        logger.info(f"    평균 레이턴시: {avg_ms:.0f}ms")
        if errors:
            logger.info(f"    에러: {len(errors)}건")

    # JSON 결과 저장
    output_file = "benchmark_results.json"
    with open(output_file, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    logger.info(f"\n💾 결과 저장: {output_file}")

    logger.info("\n✅ 벤치마크 완료!")
    logger.info("   Datadog → LLM Observability → Traces 에서 모델별 트레이스를 확인하세요.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="모델별 퍼포먼스 벤치마크")
    parser.add_argument(
        "--models",
        type=str,
        default="sonnet-4.5,haiku-3.5,sonnet-3.7",
        help="비교할 모델 (쉼표 구분). 예: sonnet-4.5,haiku-3.5,opus-4",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="반복 횟수 (기본: 1)",
    )
    args = parser.parse_args()

    model_list = [m.strip() for m in args.models.split(",")]
    run_benchmark(model_list, args.repeat)
