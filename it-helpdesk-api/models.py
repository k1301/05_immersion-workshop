from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime
from enum import Enum


class TicketStatus(str, Enum):
    """티켓 상태"""
    OPEN = "open"
    IN_PROGRESS = "in_progress"
    RESOLVED = "resolved"
    CLOSED = "closed"


class TicketPriority(str, Enum):
    """티켓 우선순위"""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    URGENT = "urgent"


class TicketCategory(str, Enum):
    """티켓 카테고리"""
    HARDWARE = "hardware"  # 하드웨어 (PC, 모니터, 키보드 등)
    SOFTWARE = "software"  # 소프트웨어 (프로그램 설치, 오류 등)
    NETWORK = "network"    # 네트워크 (인터넷, VPN 등)
    ACCOUNT = "account"    # 계정 (비밀번호, 권한 등)
    OTHER = "other"        # 기타


class TicketCreate(BaseModel):
    """티켓 생성 요청"""
    title: str = Field(..., description="티켓 제목", min_length=1, max_length=200)
    description: str = Field(..., description="상세 설명", min_length=1)
    priority: TicketPriority = Field(default=TicketPriority.MEDIUM, description="우선순위")
    category: TicketCategory = Field(..., description="카테고리")
    requester: str = Field(..., description="요청자 이름", min_length=1, max_length=100)

    class Config:
        json_schema_extra = {
            "example": {
                "title": "노트북이 부팅되지 않습니다",
                "description": "전원 버튼을 눌러도 화면이 켜지지 않고 팬 소리만 들립니다.",
                "priority": "high",
                "category": "hardware",
                "requester": "김철수"
            }
        }


class TicketUpdate(BaseModel):
    """티켓 업데이트 요청"""
    status: Optional[TicketStatus] = Field(None, description="티켓 상태")
    assigned_to: Optional[str] = Field(None, description="담당자", max_length=100)
    priority: Optional[TicketPriority] = Field(None, description="우선순위")

    class Config:
        json_schema_extra = {
            "example": {
                "status": "in_progress",
                "assigned_to": "IT지원팀 박영희"
            }
        }


class Ticket(BaseModel):
    """티켓 전체 정보"""
    id: str = Field(..., description="티켓 ID")
    title: str = Field(..., description="티켓 제목")
    description: str = Field(..., description="상세 설명")
    status: TicketStatus = Field(..., description="티켓 상태")
    priority: TicketPriority = Field(..., description="우선순위")
    category: TicketCategory = Field(..., description="카테고리")
    requester: str = Field(..., description="요청자 이름")
    assigned_to: Optional[str] = Field(None, description="담당자")
    created_at: datetime = Field(..., description="생성일시")
    updated_at: datetime = Field(..., description="수정일시")

    class Config:
        json_schema_extra = {
            "example": {
                "id": "TICKET-001",
                "title": "노트북이 부팅되지 않습니다",
                "description": "전원 버튼을 눌러도 화면이 켜지지 않고 팬 소리만 들립니다.",
                "status": "in_progress",
                "priority": "high",
                "category": "hardware",
                "requester": "김철수",
                "assigned_to": "IT지원팀 박영희",
                "created_at": "2026-04-03T09:30:00",
                "updated_at": "2026-04-03T10:15:00"
            }
        }
