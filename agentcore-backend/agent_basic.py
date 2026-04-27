"""
Step 1: Chainlit 챗봇용 LLM 래퍼
"""
from langchain_aws import ChatBedrock

from config import get_settings


settings = get_settings()


def get_basic_llm(model_id: str | None = None) -> ChatBedrock:
    """도구 없이 직접 답변하는 최소 Bedrock LLM 반환"""
    return ChatBedrock(
        model_id=model_id or settings.bedrock_model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.7, "max_tokens": settings.bedrock_max_tokens},
    )
