"""
Step 2: RAG 전용 로직

- Knowledge Base 검색
- 검색 결과를 context로 넣어 답변 생성

"""
from typing import Any

from langchain_aws import AmazonKnowledgeBasesRetriever, ChatBedrock
from langchain_core.messages import HumanMessage, SystemMessage

from config import get_settings


settings = get_settings()


SECURITY_CLASSIFICATION_PROMPT = """당신은 사용자의 질문이 사내 보안 관련 질문인지 분류하는 역할입니다.

보안 관련 질문으로 볼 수 있는 예:
- VPN 접속
- 비밀번호 변경 또는 재설정
- MFA, 인증, 계정 보호
- 보안 정책, 암호화, 피싱 대응

출력 규칙:
- 보안 관련 질문이면 SECURITY
- 그 외 질문이면 GENERAL
- 반드시 SECURITY 또는 GENERAL 둘 중 하나만 출력하세요.
"""


def _extract_doc_score(doc: Any) -> float:
    score = doc.metadata.get("score", 0.0)
    try:
        return float(score)
    except (TypeError, ValueError):
        return 0.0


def _extract_doc_source(doc: Any, index: int) -> str:
    uri = doc.metadata.get("location", {}).get("s3Location", {}).get("uri", "")
    return uri.split("/")[-1] if uri else f"document-{index}"


def retrieve_kb_documents(query: str, number_of_results: int | None = None):
    if not settings.bedrock_kb_id:
        raise ValueError("BEDROCK_KB_ID가 설정되지 않았습니다.")

    result_count = number_of_results or settings.rag_number_of_results
    retriever = AmazonKnowledgeBasesRetriever(
        knowledge_base_id=settings.bedrock_kb_id,
        retrieval_config={"vectorSearchConfiguration": {"numberOfResults": result_count}},
    )
    return retriever.invoke(query)


def _classify_security_query(query: str) -> bool:
    classifier = ChatBedrock(
        model_id=settings.bedrock_model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.0, "max_tokens": 10},
    )

    messages = [
        SystemMessage(content=SECURITY_CLASSIFICATION_PROMPT),
        HumanMessage(content=query),
    ]
    response = classifier.invoke(messages)
    label = response.content.strip().upper() if hasattr(response, "content") else str(response).strip().upper()
    return label == "SECURITY"


def _resolve_threshold(query: str) -> tuple[float, str, bool]:
    try:
        is_security_query = _classify_security_query(query)
    except Exception:
        is_security_query = False

    if is_security_query:
        return settings.rag_security_score_threshold, "security_high_threshold", True
    return settings.rag_score_threshold, "default_threshold", False


def filter_documents_by_threshold(query: str, docs) -> tuple[list[Any], dict[str, Any]]:
    threshold, threshold_profile, is_security_query = _resolve_threshold(query)
    retrieved_count = len(docs)
    top_score = max((_extract_doc_score(doc) for doc in docs), default=0.0)
    filtered_docs = [doc for doc in docs if _extract_doc_score(doc) >= threshold]
    filtered_count = len(filtered_docs)
    filtered_out_count = retrieved_count - filtered_count

    metadata = {
        "rag.threshold": threshold,
        "rag.top_score": top_score,
        "rag.retrieved_count": retrieved_count,
        "rag.filtered_count": filtered_count,
        "rag.filtered_out_count": filtered_out_count,
        "rag.threshold_profile": threshold_profile,
        "rag.is_security_query": is_security_query,
        "rag.failure_reason": "threshold_too_high" if retrieved_count > 0 and filtered_count == 0 else "",
    }
    return filtered_docs, metadata


def format_retrieved_context(docs) -> tuple[str, list[str]]:
    if not docs:
        return "", []

    sources = []
    parts = []
    for idx, doc in enumerate(docs, 1):
        source = _extract_doc_source(doc, idx)
        sources.append(source)
        parts.append(f"[문서 {idx} | {source}]\n{doc.page_content}")
    return "\n\n".join(parts), sources


def answer_with_rag(query: str) -> tuple[str, list[str], dict[str, Any]]:
    docs = retrieve_kb_documents(query)
    filtered_docs, rag_metadata = filter_documents_by_threshold(query, docs)
    context, sources = format_retrieved_context(filtered_docs)

    if rag_metadata["rag.retrieved_count"] == 0:
        rag_metadata["rag.failure_reason"] = "no_results"
        return "관련 근거 문서를 찾지 못했습니다.", [], rag_metadata

    if rag_metadata["rag.filtered_count"] == 0:
        return "현재 검색 기준을 통과한 문서가 없습니다.", [], rag_metadata

    llm = ChatBedrock(
        model_id=settings.bedrock_model_id,
        region_name=settings.aws_region,
        model_kwargs={"temperature": 0.2, "max_tokens": settings.bedrock_max_tokens},
    )

    messages = [
        SystemMessage(
            content="""당신은 사내 업무 도우미입니다.
- 반드시 제공된 문서 내용만 바탕으로 답변하세요.
- 문서에 없는 내용은 추측하지 마세요.
- 항상 한국어로 답변하세요."""
        ),
        HumanMessage(
            content=(
                f"질문:\n{query}\n\n"
                f"참고 문서:\n{context}\n\n"
                "위 참고 문서만 바탕으로 답변해줘."
            )
        ),
    ]

    response = llm.invoke(messages)
    answer = response.content if hasattr(response, "content") else str(response)
    return answer, sources, rag_metadata
