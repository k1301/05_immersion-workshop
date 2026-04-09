#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo "=========================================="
echo "  ECR 리포지토리 생성 + Docker 이미지 푸시"
echo "=========================================="
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}❌ AWS CLI가 설정되지 않았습니다.${NC}"
    exit 1
fi
REGION=$(aws configure get region || echo "us-east-1")
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo -e "${GREEN}✓ 계정: $ACCOUNT_ID / 리전: $REGION${NC}"
echo ""

# ECR 로그인
echo -e "${YELLOW}[1/4] ECR 로그인...${NC}"
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin "$ECR_BASE"
echo ""

# ECR 리포지토리 생성
echo -e "${YELLOW}[2/4] ECR 리포지토리 생성...${NC}"
for REPO in it-helpdesk-api agentcore-backend; do
    if aws ecr describe-repositories --repository-names $REPO --region $REGION 2>/dev/null; then
        echo -e "${GREEN}  ✓ $REPO 이미 존재${NC}"
    else
        aws ecr create-repository \
            --repository-name $REPO \
            --image-scanning-configuration scanOnPush=true \
            --region $REGION
        echo -e "${GREEN}  ✓ $REPO 생성 완료${NC}"
    fi
done
echo ""

# Docker 빌드 & 푸시
echo -e "${YELLOW}[3/4] it-helpdesk-api 빌드 & 푸시...${NC}"
docker build -t it-helpdesk-api ./it-helpdesk-api
docker tag it-helpdesk-api:latest "${ECR_BASE}/it-helpdesk-api:latest"
docker push "${ECR_BASE}/it-helpdesk-api:latest"
echo -e "${GREEN}  ✓ 완료${NC}"
echo ""

echo -e "${YELLOW}[4/4] agentcore-backend 빌드 & 푸시...${NC}"
docker build -t agentcore-backend ./agentcore-backend
docker tag agentcore-backend:latest "${ECR_BASE}/agentcore-backend:latest"
docker push "${ECR_BASE}/agentcore-backend:latest"
echo -e "${GREEN}  ✓ 완료${NC}"
echo ""

echo "=========================================="
echo -e "${GREEN}  ECR 준비 완료!${NC}"
echo "=========================================="
echo ""
echo "이미지 URI:"
echo "  Helpdesk:  ${ECR_BASE}/it-helpdesk-api:latest"
echo "  AgentCore: ${ECR_BASE}/agentcore-backend:latest"
echo ""
echo "이제 ./deploy-master.sh 실행 시 위 URI를 입력하면 한 번에 끝납니다."
