# 사내 업무 에이전트 Backend

LangGraph + Amazon Bedrock을 사용한 사내 업무 에이전트 백엔드

업무 가이드 검색(RAG), IT 헬프데스크 티켓 자동 생성(MCP), 일반 대화를 지원합니다.

## 프로젝트 구조

```
enterprise-agent-backend/
├── agent.py              # LangGraph 에이전트 메인 코드
├── config.py             # 설정 관리
├── requirements.txt      # Python 의존성
├── .env.example         # 환경 변수 예시
└── README.md            # 이 파일
```

## 기능

- ✅ LangGraph + Bedrock Claude 기반 채팅 에이전트
- ✅ Chainlit 프론트엔드 (모델 선택 드롭다운, 실시간 스트리밍)
- ✅ RAG 노드: Bedrock Knowledge Base를 통한 사내 문서 검색
  - 연차 휴가 정책, IT 보안 가이드, 경비 처리 절차, 온보딩 가이드
- ✅ MCP 노드: IT 헬프데스크 API 연결
  - 자동 티켓 생성 (ECS Fargate 배포 완료)
- 🔄 지능형 라우팅: 질문 유형에 따라 적절한 노드로 자동 분기

## 시작하기

### 1. 의존성 설치

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. 환경 변수 설정

```bash
cp .env.example .env
# .env 파일을 편집하여 AWS 설정 입력
```

### 3. Chainlit UI 실행 (권장)

```bash
chainlit run chainlit_app.py --port 8001
```

브라우저에서 `http://localhost:8001` 접속

### 4. 터미널에서 에이전트 직접 테스트 (선택)

```bash
python agent.py
```

## AWS Bedrock 설정

Bedrock 사용을 위해 AWS 자격 증명이 필요합니다:

```bash
aws configure
```

또는 `.env` 파일에 설정:
```
AWS_REGION=us-east-1
AWS_PROFILE=default
```

## 개발 로드맵

- [x] 1단계: 기본 프로젝트 구조 ✅
- [x] 2단계: LangGraph + Bedrock 기본 에이전트 ✅
- [x] 3단계: Chainlit 프론트엔드 ✅
- [x] 4단계: RAG 시스템 통합 (Bedrock Knowledge Base + S3 Vectors) ✅
- [x] 5단계: MCP 도구 연결 (IT 헬프데스크 API, ECS 배포) ✅
- [ ] 6단계: 구글 검색 도구 추가 (외부 정보 검색)
- [ ] 7단계: Datadog 모니터링 (도구 호출 추적, 응답 속도 측정)
- [ ] 8단계: 에이전트 백엔드 ECS 배포

## ⚙️ 중요: 환경 설정

### AWS 리전 설정
**반드시 US 리전을 사용해야 합니다** (Inference Profile 사용 시):

```bash
# 실행 시 환경변수 명시
AWS_DEFAULT_REGION=us-east-1 AWS_REGION=us-east-1 python agent.py
```

또는 `.env` 파일이 제대로 로드되도록 설정하세요.

### 사용 가능한 모델

US Inference Profile 모델 (us-east-1 리전):
- ✅ Sonnet 4.6: `us.anthropic.claude-sonnet-4-6` (최신!)
- ✅ Opus 4.6: `us.anthropic.claude-opus-4-6-v1`
- ✅ Sonnet 4.5: `us.anthropic.claude-sonnet-4-5-20250929-v1:0` (기본값)
- ✅ Opus 4.5: `us.anthropic.claude-opus-4-5-20251101-v1:0`
- ✅ Sonnet 3.7: `us.anthropic.claude-3-7-sonnet-20250219-v1:0`
- ✅ Haiku 4.5: `us.anthropic.claude-haiku-4-5-20251001-v1:0`
- ✅ Haiku 3.5: `us.anthropic.claude-3-5-haiku-20241022-v1:0`

Chainlit UI에서 드롭다운으로 실시간 모델 변경 가능!

### 모델 비교 기능

여러 모델을 동시에 테스트하려면 `.env` 파일에:

```bash
COMPARE_MODELS=sonnet-4.6,haiku-3.5,opus-4.6
```

## 🧪 사용 예시

### RAG 검색 (업무 가이드)
```
사용자: "연차 휴가는 어떻게 신청하나요?"
에이전트: [📚 업무 가이드 검색]
         Knowledge Base에서 연차 휴가 정책 문서를 검색하여
         신청 방법, 승인 절차, 유의사항을 안내합니다.
```

### IT 헬프데스크 티켓 생성
```
사용자: "노트북이 고장났어요. 화면이 안 켜집니다."
에이전트: [🎫 헬프데스크 티켓 생성]
         자동으로 티켓을 생성하고 티켓 ID를 반환합니다.
         ✅ 티켓 ID: TICKET-0042
```

### 일반 대화
```
사용자: "파이썬으로 리스트 합계 구하는 함수 만들어줘"
에이전트: [💬 일반 대화]
         def sum_list(items):
             return sum(items)
```

## 🔗 관련 프로젝트

- [IT Helpdesk API](../it-helpdesk-api) - MCP 도구로 연결될 REST API
