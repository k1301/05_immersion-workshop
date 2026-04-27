# Python 3.13 slim 베이스 이미지
FROM python:3.13-slim

WORKDIR /app

ARG CHAINLIT_APP_FILE=chainlit_app_basic.py
ENV CHAINLIT_APP_FILE=${CHAINLIT_APP_FILE}

# 시스템 패키지 (curl: healthcheck용)
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Python 의존성 설치
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# 애플리케이션 코드 복사
COPY *.py ./
COPY *.md ./
COPY .chainlit/ .chainlit/

# Chainlit 포트
EXPOSE 8000

# Health check (Chainlit은 / 에서 200 반환)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8000/ || exit 1

# 비root 사용자 (보안)
RUN useradd -m -u 1000 appuser && chown -R appuser:appuser /app
USER appuser

# Chainlit 실행 (ddtrace 계측 포함)
CMD ["sh", "-c", "ddtrace-run chainlit run ${CHAINLIT_APP_FILE:-chainlit_app_basic.py} --host 0.0.0.0 --port 8000"]
