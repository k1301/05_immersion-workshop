#!/bin/bash
# EC2 배포 스크립트

set -e

echo "=========================================="
echo "IT Helpdesk API EC2 배포 스크립트"
echo "=========================================="

# Python 및 필수 패키지 설치
echo "1. 시스템 업데이트 및 Python 설치..."
sudo yum update -y || sudo apt update -y
sudo yum install -y python3 python3-pip git || sudo apt install -y python3 python3-pip git

# 프로젝트 디렉토리 생성
echo "2. 프로젝트 디렉토리 설정..."
mkdir -p ~/it-helpdesk-api
cd ~/it-helpdesk-api

# 가상환경 생성
echo "3. Python 가상환경 생성..."
python3 -m venv venv
source venv/bin/activate

# 의존성 설치
echo "4. 의존성 설치..."
pip install --upgrade pip
pip install fastapi uvicorn pydantic python-dateutil

echo "=========================================="
echo "설치 완료!"
echo "=========================================="
echo ""
echo "다음 단계:"
echo "1. 코드 파일들을 업로드하세요 (main.py, models.py)"
echo "2. 서버를 실행하세요: uvicorn main:app --host 0.0.0.0 --port 8000"
