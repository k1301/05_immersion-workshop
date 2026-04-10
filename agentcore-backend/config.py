"""
설정 관리 모듈
"""
import os
from pydantic_settings import BaseSettings
from typing import Optional, Dict


def _region_prefix(region: str) -> str:
    """리전에 따른 cross-region inference profile 프리픽스 반환"""
    if region.startswith("us-") or region.startswith("us."):
        return "us"
    elif region.startswith("eu-"):
        return "eu"
    elif region.startswith("ap-"):
        return "apac"
    return "us"


def _build_model_map(prefix: str) -> Dict[str, str]:
    """리전 프리픽스에 맞는 모델 목록 생성"""
    return {
        "sonnet-4.6": f"{prefix}.anthropic.claude-sonnet-4-6",
        "opus-4.6": f"{prefix}.anthropic.claude-opus-4-6-v1",
        "sonnet-4.5": f"{prefix}.anthropic.claude-sonnet-4-5-20250929-v1:0",
        "opus-4.5": f"{prefix}.anthropic.claude-opus-4-5-20251101-v1:0",
        "opus-4.1": f"{prefix}.anthropic.claude-opus-4-1-20250805-v1:0",
        "sonnet-4": f"{prefix}.anthropic.claude-sonnet-4-20250514-v1:0",
        "opus-4": f"{prefix}.anthropic.claude-opus-4-20250514-v1:0",
        "sonnet-3.7": f"{prefix}.anthropic.claude-3-7-sonnet-20250219-v1:0",
        "sonnet-3.5": f"{prefix}.anthropic.claude-3-5-sonnet-20241022-v2:0",
        "haiku-4.5": f"{prefix}.anthropic.claude-haiku-4-5-20251001-v1:0",
        "haiku-3.5": f"{prefix}.anthropic.claude-3-5-haiku-20241022-v1:0",
        "haiku-3": f"{prefix}.anthropic.claude-3-haiku-20240307-v1:0",
    }


def _default_model_id(region: str) -> str:
    """리전에 맞는 기본 모델 ID 반환"""
    prefix = _region_prefix(region)
    return f"{prefix}.anthropic.claude-sonnet-4-5-20250929-v1:0"


class Settings(BaseSettings):
    """애플리케이션 설정"""

    # AWS 설정
    aws_region: str = "us-east-1"
    aws_profile: Optional[str] = None

    # Bedrock 모델 (기본값: 리전에 맞는 Sonnet 4.5 inference profile)
    bedrock_model_id: str = ""

    # 비교할 모델들 (쉼표로 구분, 예: "sonnet-4.6,opus-4.6,haiku-3.5")
    compare_models: Optional[str] = None

    # Bedrock Knowledge Base
    bedrock_kb_id: Optional[str] = None

    # IT Helpdesk API
    helpdesk_api_url: str = "http://helpdesk-api-alb-799491602.ap-northeast-2.elb.amazonaws.com"

    # AgentCore Gateway MCP URL
    gateway_mcp_url: str = ""

    # API 설정
    api_port: int = 8001
    api_host: str = "0.0.0.0"

    # 로그 레벨
    log_level: str = "INFO"

    # 워크샵 시나리오 (normal / token_error / failure_to_answer)
    workshop_scenario: str = "normal"

    # Bedrock max_tokens (시나리오용 - 낮추면 토큰 에러 재현)
    bedrock_max_tokens: int = 4096

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False

    def get_compare_model_ids(self) -> list[str]:
        """비교할 모델 ID 목록 반환"""
        if not self.compare_models:
            return []

        models = _build_model_map(_region_prefix(self.aws_region))
        model_names = [m.strip() for m in self.compare_models.split(",")]
        return [models.get(name, name) for name in model_names]


# 전역 설정 인스턴스
settings = Settings()

# bedrock_model_id가 비어있으면 리전 기반 기본값 설정
if not settings.bedrock_model_id:
    settings.bedrock_model_id = _default_model_id(settings.aws_region)

# 리전에 맞는 모델 목록
AVAILABLE_MODELS: Dict[str, str] = _build_model_map(_region_prefix(settings.aws_region))


def get_settings() -> Settings:
    """설정 객체 반환"""
    return settings


def list_available_models() -> Dict[str, str]:
    """사용 가능한 모델 목록 반환"""
    return AVAILABLE_MODELS
