import os

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from typing import List, Optional
from datetime import datetime
from models import (
    Ticket, TicketCreate, TicketUpdate,
    TicketStatus, TicketPriority, TicketCategory
)

app = FastAPI(
    title="IT 헬프데스크 API",
    description="사내 IT 헬프데스크 시스템 REST API",
    version="1.0.0"
)

HELPDESK_API_KEY = os.getenv("HELPDESK_API_KEY", "").strip()
AUTH_EXEMPT_PATHS = {"/", "/docs", "/openapi.json", "/redoc", "/favicon.ico"}

# 인메모리 데이터 저장소
tickets_db: dict[str, Ticket] = {}
ticket_counter = 1


def generate_ticket_id() -> str:
    """티켓 ID 생성"""
    global ticket_counter
    ticket_id = f"TICKET-{ticket_counter:04d}"
    ticket_counter += 1
    return ticket_id


# 샘플 데이터 초기화
def init_sample_data():
    """샘플 티켓 데이터 생성"""
    sample_tickets = [
        {
            "title": "노트북 화면이 깜빡입니다",
            "description": "업무 중 노트북 화면이 계속 깜빡거려서 작업하기 어렵습니다. 특히 문서 작업 시 심합니다.",
            "priority": TicketPriority.HIGH,
            "category": TicketCategory.HARDWARE,
            "requester": "김철수",
            "status": TicketStatus.OPEN,
            "assigned_to": None
        },
        {
            "title": "VPN 접속이 안 됩니다",
            "description": "재택근무를 위해 VPN 접속을 시도했으나 '인증 실패' 메시지가 나옵니다.",
            "priority": TicketPriority.URGENT,
            "category": TicketCategory.NETWORK,
            "requester": "이영희",
            "status": TicketStatus.IN_PROGRESS,
            "assigned_to": "IT지원팀 박민수"
        },
        {
            "title": "프린터 드라이버 설치 요청",
            "description": "3층 복합기를 사용하려는데 드라이버가 설치되어 있지 않습니다.",
            "priority": TicketPriority.MEDIUM,
            "category": TicketCategory.SOFTWARE,
            "requester": "박지훈",
            "status": TicketStatus.RESOLVED,
            "assigned_to": "IT지원팀 최수진"
        },
        {
            "title": "비밀번호 초기화 요청",
            "description": "사내 메일 비밀번호를 잊어버렸습니다. 초기화 부탁드립니다.",
            "priority": TicketPriority.HIGH,
            "category": TicketCategory.ACCOUNT,
            "requester": "정민아",
            "status": TicketStatus.OPEN,
            "assigned_to": None
        },
        {
            "title": "모니터 추가 신청",
            "description": "듀얼 모니터로 업무 효율을 높이고 싶습니다. 24인치 모니터 1대 신청합니다.",
            "priority": TicketPriority.LOW,
            "category": TicketCategory.HARDWARE,
            "requester": "최동욱",
            "status": TicketStatus.IN_PROGRESS,
            "assigned_to": "IT지원팀 박민수"
        }
    ]

    for sample in sample_tickets:
        ticket_id = generate_ticket_id()
        now = datetime.now()
        ticket = Ticket(
            id=ticket_id,
            title=sample["title"],
            description=sample["description"],
            status=sample["status"],
            priority=sample["priority"],
            category=sample["category"],
            requester=sample["requester"],
            assigned_to=sample["assigned_to"],
            created_at=now,
            updated_at=now
        )
        tickets_db[ticket_id] = ticket


# 앱 시작 시 샘플 데이터 로드
@app.on_event("startup")
async def startup_event():
    init_sample_data()


@app.middleware("http")
async def verify_api_key(request: Request, call_next):
    """API 키가 설정된 경우 x-api-key 헤더를 검증한다."""
    if not HELPDESK_API_KEY or request.url.path in AUTH_EXEMPT_PATHS:
        return await call_next(request)

    provided_api_key = request.headers.get("x-api-key", "").strip()
    if provided_api_key != HELPDESK_API_KEY:
        return JSONResponse(
            status_code=401,
            content={"detail": "유효한 x-api-key 헤더가 필요합니다."},
        )

    return await call_next(request)


@app.get("/", tags=["Root"])
async def root():
    """API 루트"""
    return {
        "message": "IT 헬프데스크 API에 오신 것을 환영합니다",
        "docs": "/docs",
        "version": "1.0.0"
    }


@app.post("/tickets", response_model=Ticket, status_code=201, tags=["Tickets"])
async def create_ticket(ticket_create: TicketCreate):
    """
    새 티켓 생성

    - **title**: 티켓 제목
    - **description**: 상세 설명
    - **priority**: 우선순위 (low, medium, high, urgent)
    - **category**: 카테고리 (hardware, software, network, account, other)
    - **requester**: 요청자 이름
    """
    ticket_id = generate_ticket_id()
    now = datetime.now()

    ticket = Ticket(
        id=ticket_id,
        title=ticket_create.title,
        description=ticket_create.description,
        status=TicketStatus.OPEN,
        priority=ticket_create.priority,
        category=ticket_create.category,
        requester=ticket_create.requester,
        assigned_to=None,
        created_at=now,
        updated_at=now
    )

    tickets_db[ticket_id] = ticket
    return ticket


@app.get("/tickets", response_model=List[Ticket], tags=["Tickets"])
async def get_tickets(
    status: Optional[TicketStatus] = Query(None, description="상태로 필터링"),
    priority: Optional[TicketPriority] = Query(None, description="우선순위로 필터링"),
    category: Optional[TicketCategory] = Query(None, description="카테고리로 필터링"),
    requester: Optional[str] = Query(None, description="요청자로 필터링")
):
    """
    티켓 목록 조회

    쿼리 파라미터를 사용하여 필터링할 수 있습니다:
    - **status**: 티켓 상태 (open, in_progress, resolved, closed)
    - **priority**: 우선순위 (low, medium, high, urgent)
    - **category**: 카테고리 (hardware, software, network, account, other)
    - **requester**: 요청자 이름
    """
    tickets = list(tickets_db.values())

    # 필터링
    if status:
        tickets = [t for t in tickets if t.status == status]
    if priority:
        tickets = [t for t in tickets if t.priority == priority]
    if category:
        tickets = [t for t in tickets if t.category == category]
    if requester:
        tickets = [t for t in tickets if requester.lower() in t.requester.lower()]

    # 최신순 정렬
    tickets.sort(key=lambda x: x.created_at, reverse=True)

    return tickets


@app.get("/tickets/{ticket_id}", response_model=Ticket, tags=["Tickets"])
async def get_ticket(ticket_id: str):
    """
    특정 티켓 상세 조회

    - **ticket_id**: 티켓 ID (예: TICKET-0001)
    """
    if ticket_id not in tickets_db:
        raise HTTPException(status_code=404, detail=f"티켓 {ticket_id}를 찾을 수 없습니다")

    return tickets_db[ticket_id]


@app.patch("/tickets/{ticket_id}", response_model=Ticket, tags=["Tickets"])
async def update_ticket(ticket_id: str, ticket_update: TicketUpdate):
    """
    티켓 정보 업데이트

    - **ticket_id**: 티켓 ID
    - **status**: 변경할 상태 (선택)
    - **assigned_to**: 담당자 (선택)
    - **priority**: 우선순위 (선택)
    """
    if ticket_id not in tickets_db:
        raise HTTPException(status_code=404, detail=f"티켓 {ticket_id}를 찾을 수 없습니다")

    ticket = tickets_db[ticket_id]

    # 업데이트할 필드만 변경
    if ticket_update.status is not None:
        ticket.status = ticket_update.status
    if ticket_update.assigned_to is not None:
        ticket.assigned_to = ticket_update.assigned_to
    if ticket_update.priority is not None:
        ticket.priority = ticket_update.priority

    ticket.updated_at = datetime.now()

    return ticket


@app.delete("/tickets/{ticket_id}", status_code=204, tags=["Tickets"])
async def delete_ticket(ticket_id: str):
    """
    티켓 삭제

    - **ticket_id**: 티켓 ID
    """
    if ticket_id not in tickets_db:
        raise HTTPException(status_code=404, detail=f"티켓 {ticket_id}를 찾을 수 없습니다")

    del tickets_db[ticket_id]
    return None


@app.get("/stats", tags=["Statistics"])
async def get_statistics():
    """
    티켓 통계 조회
    """
    tickets = list(tickets_db.values())

    return {
        "total": len(tickets),
        "by_status": {
            "open": len([t for t in tickets if t.status == TicketStatus.OPEN]),
            "in_progress": len([t for t in tickets if t.status == TicketStatus.IN_PROGRESS]),
            "resolved": len([t for t in tickets if t.status == TicketStatus.RESOLVED]),
            "closed": len([t for t in tickets if t.status == TicketStatus.CLOSED])
        },
        "by_priority": {
            "low": len([t for t in tickets if t.priority == TicketPriority.LOW]),
            "medium": len([t for t in tickets if t.priority == TicketPriority.MEDIUM]),
            "high": len([t for t in tickets if t.priority == TicketPriority.HIGH]),
            "urgent": len([t for t in tickets if t.priority == TicketPriority.URGENT])
        },
        "by_category": {
            "hardware": len([t for t in tickets if t.category == TicketCategory.HARDWARE]),
            "software": len([t for t in tickets if t.category == TicketCategory.SOFTWARE]),
            "network": len([t for t in tickets if t.category == TicketCategory.NETWORK]),
            "account": len([t for t in tickets if t.category == TicketCategory.ACCOUNT]),
            "other": len([t for t in tickets if t.category == TicketCategory.OTHER])
        }
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
