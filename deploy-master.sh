#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  전체 인프라 원클릭 배포${NC}"
echo -e "${BLUE}  VPC → ECR → Docker Build/Push → ECS 서비스${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# ============================================================
# 1. AWS 계정 확인
# ============================================================
echo -e "${YELLOW}[1/7] AWS 계정 확인 중...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}❌ AWS CLI가 설정되지 않았습니다. 'aws configure'를 먼저 실행하세요.${NC}"
    exit 1
fi
REGION=$(aws configure get region || echo "us-east-1")
echo -e "${GREEN}✓ 계정: $ACCOUNT_ID / 리전: $REGION${NC}"
echo ""

MASTER_STACK_NAME="agentcore-master-stack"
TEMPLATE_BUCKET="agentcore-cfn-templates-${ACCOUNT_ID}-${REGION}"

# ============================================================
# 2. 파라미터 입력
# ============================================================
echo -e "${YELLOW}[2/7] 파라미터 설정${NC}"

read -p "환경 이름 [agentcore]: " ENV_NAME
ENV_NAME=${ENV_NAME:-agentcore}

read -p "Bedrock Model ID [리전에 맞게 자동 설정, Enter 건너뛰기]: " MODEL_ID
MODEL_ID=${MODEL_ID:-""}

read -p "AgentCore Gateway MCP URL [선택, Enter 건너뛰기]: " GATEWAY_URL
GATEWAY_URL=${GATEWAY_URL:-""}

read -p "Helpdesk API URL [선택, Enter 건너뛰기]: " HELPDESK_URL
HELPDESK_URL=${HELPDESK_URL:-""}

echo ""
echo "=========================================="
echo "  환경: $ENV_NAME"
echo "  모델: $MODEL_ID"
echo "  Gateway MCP: ${GATEWAY_URL:-'(미설정)'}"
echo "  Helpdesk URL: ${HELPDESK_URL:-'(미설정)'}"
echo "=========================================="
echo ""
read -p "배포를 시작하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "취소합니다."
    exit 0
fi
echo ""

# ============================================================
# 3. S3 버킷 + 자식 템플릿 업로드
# ============================================================
echo -e "${YELLOW}[3/7] 템플릿 S3 업로드 중...${NC}"

if ! aws s3 ls "s3://${TEMPLATE_BUCKET}" 2>/dev/null; then
    if [ "$REGION" == "us-east-1" ]; then
        aws s3 mb "s3://${TEMPLATE_BUCKET}" --region "$REGION"
    else
        aws s3api create-bucket \
            --bucket "${TEMPLATE_BUCKET}" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION"
    fi
fi

aws s3 cp it-helpdesk-api/cloudformation.yaml "s3://${TEMPLATE_BUCKET}/nested/it-helpdesk-api.yaml" --quiet
aws s3 cp agentcore-backend/cloudformation-infra.yaml "s3://${TEMPLATE_BUCKET}/nested/agentcore-backend.yaml" --quiet
echo -e "${GREEN}✓ 템플릿 업로드 완료${NC}"
echo ""

# ============================================================
# 4. 1차 배포: VPC + ECR + ALB 등 (컨테이너 이미지 없이)
# ============================================================
echo -e "${YELLOW}[4/7] 1차 배포: 인프라 생성 중 (VPC, ECR, ALB, KB...)${NC}"
echo "  ECS 서비스는 이미지 빌드 후 2차에서 생성됩니다."
echo ""

STACK_EXISTS=$(aws cloudformation describe-stacks --stack-name $MASTER_STACK_NAME 2>/dev/null || echo "")

if [ ! -z "$STACK_EXISTS" ]; then
    STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $MASTER_STACK_NAME \
        --query "Stacks[0].StackStatus" --output text 2>/dev/null)
    echo -e "${YELLOW}⚠️  기존 스택 발견 (상태: $STACK_STATUS)${NC}"

    if [[ "$STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
        echo "롤백된 스택을 삭제하고 다시 생성합니다..."
        aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION
        aws cloudformation wait stack-delete-complete --stack-name $MASTER_STACK_NAME --region $REGION
        STACK_EXISTS=""
    fi
fi

COMMON_PARAMS="\
    ParameterKey=EnvironmentName,ParameterValue=$ENV_NAME \
    ParameterKey=TemplateBucketName,ParameterValue=$TEMPLATE_BUCKET \
    ParameterKey=BedrockModelId,ParameterValue=$MODEL_ID \
    ParameterKey=GatewayMcpUrl,ParameterValue=$GATEWAY_URL \
    ParameterKey=HelpdeskApiUrl,ParameterValue=$HELPDESK_URL"

if [ -z "$STACK_EXISTS" ]; then
    aws cloudformation create-stack \
        --stack-name $MASTER_STACK_NAME \
        --template-body file://master-stack.yaml \
        --parameters $COMMON_PARAMS \
            ParameterKey=HelpdeskContainerImage,ParameterValue="" \
            ParameterKey=AgentcoreContainerImage,ParameterValue="" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION

    echo "스택 생성 대기 중... (약 10분)"
    aws cloudformation wait stack-create-complete \
        --stack-name $MASTER_STACK_NAME --region $REGION
else
    aws cloudformation update-stack \
        --stack-name $MASTER_STACK_NAME \
        --template-body file://master-stack.yaml \
        --parameters $COMMON_PARAMS \
            ParameterKey=HelpdeskContainerImage,ParameterValue="" \
            ParameterKey=AgentcoreContainerImage,ParameterValue="" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION 2>/dev/null || echo "(변경사항 없음, 계속 진행)"

    echo "스택 업데이트 대기 중..."
    aws cloudformation wait stack-update-complete \
        --stack-name $MASTER_STACK_NAME --region $REGION 2>/dev/null || true
fi

echo -e "${GREEN}✓ 1차 인프라 생성 완료${NC}"
echo ""

# ============================================================
# 5. ECR URI 가져오기 + Docker 이미지 빌드 & 푸시
# ============================================================
echo -e "${YELLOW}[5/7] Docker 이미지 빌드 & ECR 푸시 중...${NC}"

# 자식 스택 ID 조회
HELPDESK_STACK_ID=$(aws cloudformation list-stack-resources \
    --stack-name $MASTER_STACK_NAME \
    --query "StackResourceSummaries[?LogicalResourceId=='HelpdeskStack'].PhysicalResourceId" \
    --output text)

AGENTCORE_STACK_ID=$(aws cloudformation list-stack-resources \
    --stack-name $MASTER_STACK_NAME \
    --query "StackResourceSummaries[?LogicalResourceId=='AgentcoreStack'].PhysicalResourceId" \
    --output text)

# ECR URI 조회
HELPDESK_ECR=$(aws cloudformation describe-stacks \
    --stack-name "$HELPDESK_STACK_ID" \
    --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" \
    --output text)

AGENTCORE_ECR=$(aws cloudformation describe-stacks \
    --stack-name "$AGENTCORE_STACK_ID" \
    --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" \
    --output text)

echo "  Helpdesk ECR:  $HELPDESK_ECR"
echo "  AgentCore ECR: $AGENTCORE_ECR"
echo ""

# ECR 로그인
aws ecr get-login-password --region $REGION | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
echo ""

# Helpdesk API 빌드 & 푸시
echo -e "${YELLOW}  → it-helpdesk-api 빌드 중...${NC}"
docker buildx build --platform linux/amd64 -t it-helpdesk-api ./it-helpdesk-api
docker tag it-helpdesk-api:latest "${HELPDESK_ECR}:latest"
docker push "${HELPDESK_ECR}:latest"
echo -e "${GREEN}  ✓ it-helpdesk-api 푸시 완료${NC}"
echo ""

# AgentCore Backend 빌드 & 푸시
echo -e "${YELLOW}  → agentcore-backend 빌드 중...${NC}"
docker buildx build --platform linux/amd64 -t agentcore-backend ./agentcore-backend
docker tag agentcore-backend:latest "${AGENTCORE_ECR}:latest"
docker push "${AGENTCORE_ECR}:latest"
echo -e "${GREEN}  ✓ agentcore-backend 푸시 완료${NC}"
echo ""

# ============================================================
# 6. 2차 배포: 컨테이너 이미지 추가 → ECS 서비스 생성
# ============================================================
echo -e "${YELLOW}[6/7] 2차 배포: ECS 서비스 생성 중...${NC}"

aws cloudformation update-stack \
    --stack-name $MASTER_STACK_NAME \
    --template-body file://master-stack.yaml \
    --parameters $COMMON_PARAMS \
        ParameterKey=HelpdeskContainerImage,ParameterValue="${HELPDESK_ECR}:latest" \
        ParameterKey=AgentcoreContainerImage,ParameterValue="${AGENTCORE_ECR}:latest" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $REGION

echo "ECS 서비스 생성 대기 중... (약 5분)"
aws cloudformation wait stack-update-complete \
    --stack-name $MASTER_STACK_NAME --region $REGION

echo -e "${GREEN}✓ ECS 서비스 생성 완료${NC}"
echo ""

# ============================================================
# 7. KB 문서 업로드 + 결과 출력
# ============================================================
echo -e "${YELLOW}[7/7] KB 문서 업로드 & 결과 확인${NC}"

KB_BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$AGENTCORE_STACK_ID" \
    --query "Stacks[0].Outputs[?OutputKey=='KBDocsBucketName'].OutputValue" \
    --output text 2>/dev/null || echo "")

if [ ! -z "$KB_BUCKET_NAME" ] && [ "$KB_BUCKET_NAME" != "None" ] && [ -d "agentcore-backend/kb_docs" ]; then
    aws s3 sync agentcore-backend/kb_docs/ "s3://${KB_BUCKET_NAME}/kb_docs/" --region $REGION
    echo -e "${GREEN}✓ KB 문서 업로드 완료${NC}"

    # KB 데이터 소스 동기화
    KB_ID=$(aws cloudformation describe-stacks \
        --stack-name "$AGENTCORE_STACK_ID" \
        --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" \
        --output text 2>/dev/null || echo "")
    if [ ! -z "$KB_ID" ] && [ "$KB_ID" != "None" ]; then
        DS_ID=$(aws bedrock-agent list-data-sources \
            --knowledge-base-id "$KB_ID" \
            --query "dataSourceSummaries[0].dataSourceId" \
            --output text --region $REGION 2>/dev/null || echo "")
        if [ ! -z "$DS_ID" ] && [ "$DS_ID" != "None" ]; then
            aws bedrock-agent start-ingestion-job \
                --knowledge-base-id "$KB_ID" \
                --data-source-id "$DS_ID" \
                --region $REGION > /dev/null 2>&1
            echo -e "${GREEN}✓ KB 데이터 소스 동기화 시작${NC}"
        fi
    fi
fi
echo ""

# 최종 결과
echo -e "${BLUE}================================================${NC}"
echo -e "${GREEN}  전체 인프라 배포 완료!${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
aws cloudformation describe-stacks \
    --stack-name $MASTER_STACK_NAME \
    --query "Stacks[0].Outputs" \
    --output table \
    --region $REGION 2>/dev/null || true

echo ""
echo "삭제하려면:"
echo "  aws cloudformation delete-stack --stack-name $MASTER_STACK_NAME --region $REGION"
echo "  aws s3 rb s3://${TEMPLATE_BUCKET} --force"
