#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "Datadog LLM Observability 연동"
echo "=========================================="
echo ""

REGION=$(aws configure get region || echo "us-east-1")
INFRA_STACK="agentcore-infra-stack"
DD_STACK="agentcore-datadog-stack"

# 1. infra 스택 확인
echo -e "${YELLOW}1. 인프라 스택 확인 중...${NC}"
INFRA_EXISTS=$(aws cloudformation describe-stacks --stack-name $INFRA_STACK 2>/dev/null || echo "")
if [ -z "$INFRA_EXISTS" ]; then
    echo -e "${RED}❌ 인프라 스택 '$INFRA_STACK'이(가) 없습니다. 먼저 deploy-infra.sh를 실행하세요.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 인프라 스택 확인 완료${NC}"

# infra 스택에서 값 가져오기
ECR_URI=$(aws cloudformation describe-stacks --stack-name $INFRA_STACK --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" --output text)
echo -e "${GREEN}✓ ECR URI: $ECR_URI${NC}"
echo ""

# 2. Datadog 설정
echo -e "${YELLOW}2. Datadog 설정${NC}"
read -p "Datadog API Key (필수): " DD_API_KEY
if [ -z "$DD_API_KEY" ]; then
    echo -e "${RED}❌ Datadog API Key는 필수입니다.${NC}"
    exit 1
fi
read -p "Datadog Site [datadoghq.com]: " DD_SITE
DD_SITE=${DD_SITE:-"datadoghq.com"}
read -p "ML App 이름 [agentcore-backend]: " DD_ML_APP
DD_ML_APP=${DD_ML_APP:-"agentcore-backend"}
echo ""

# 3. 에이전트 설정 (infra와 동일하게)
echo -e "${YELLOW}3. 에이전트 설정${NC}"
read -p "Container Image URI [$ECR_URI:latest]: " CONTAINER_IMAGE
CONTAINER_IMAGE=${CONTAINER_IMAGE:-"$ECR_URI:latest"}
read -p "Bedrock Model ID [us.anthropic.claude-sonnet-4-5-20250929-v1:0]: " BEDROCK_MODEL_ID
BEDROCK_MODEL_ID=${BEDROCK_MODEL_ID:-"us.anthropic.claude-sonnet-4-5-20250929-v1:0"}
read -p "AgentCore Gateway MCP URL [선택]: " GATEWAY_MCP_URL
GATEWAY_MCP_URL=${GATEWAY_MCP_URL:-""}
read -p "Helpdesk API URL [선택]: " HELPDESK_API_URL
HELPDESK_API_URL=${HELPDESK_API_URL:-""}
echo ""

# 파라미터
PARAMETERS="ParameterKey=InfraStackName,ParameterValue=$INFRA_STACK"
PARAMETERS="$PARAMETERS ParameterKey=ContainerImage,ParameterValue=$CONTAINER_IMAGE"
PARAMETERS="$PARAMETERS ParameterKey=BedrockModelId,ParameterValue=$BEDROCK_MODEL_ID"
PARAMETERS="$PARAMETERS ParameterKey=DatadogApiKey,ParameterValue=$DD_API_KEY"
PARAMETERS="$PARAMETERS ParameterKey=DatadogSite,ParameterValue=$DD_SITE"
PARAMETERS="$PARAMETERS ParameterKey=DatadogMlApp,ParameterValue=$DD_ML_APP"
if [ ! -z "$GATEWAY_MCP_URL" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=GatewayMcpUrl,ParameterValue=$GATEWAY_MCP_URL"
fi
if [ ! -z "$HELPDESK_API_URL" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=HelpdeskApiUrl,ParameterValue=$HELPDESK_API_URL"
fi

echo "=========================================="
echo "Datadog 설정 확인"
echo "=========================================="
echo "DD Site:       $DD_SITE"
echo "DD ML App:     $DD_ML_APP"
echo "Container:     $CONTAINER_IMAGE"
echo "Model:         $BEDROCK_MODEL_ID"
echo "=========================================="
echo ""

read -p "계속 진행하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    exit 0
fi

# 4. Datadog 스택 배포
echo ""
echo -e "${YELLOW}4. Datadog 스택 배포 중...${NC}"

DD_EXISTS=$(aws cloudformation describe-stacks --stack-name $DD_STACK 2>/dev/null || echo "")
if [ -z "$DD_EXISTS" ]; then
    aws cloudformation create-stack \
        --stack-name $DD_STACK \
        --template-body file://cloudformation-datadog.yaml \
        --parameters $PARAMETERS \
        --region $REGION
    echo "대기 중..."
    aws cloudformation wait stack-create-complete --stack-name $DD_STACK --region $REGION
else
    aws cloudformation update-stack \
        --stack-name $DD_STACK \
        --template-body file://cloudformation-datadog.yaml \
        --parameters $PARAMETERS \
        --region $REGION
    echo "대기 중..."
    aws cloudformation wait stack-update-complete --stack-name $DD_STACK --region $REGION
fi
echo -e "${GREEN}✓ Datadog 스택 배포 완료${NC}"

# 5. ECS Service 업데이트
echo ""
echo -e "${YELLOW}5. ECS Service를 Datadog Task Definition으로 업데이트 중...${NC}"
aws ecs update-service \
    --cluster agent-backend-cluster \
    --service agent-backend-service \
    --task-definition agentcore-backend-datadog \
    --force-new-deployment \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ ECS Service 업데이트 완료 (새 태스크 배포 중...)${NC}"

echo ""
echo "=========================================="
echo -e "${GREEN}Datadog LLM Observability 연동 완료!${NC}"
echo "=========================================="
echo ""
echo "확인 방법:"
echo "  1. Datadog → LLM Observability → Traces 에서 트레이스 확인"
echo "  2. ML App: $DD_ML_APP"
echo "  3. Service: agentcore-backend"
echo ""
echo "스택 삭제 (Datadog 연동 해제):"
echo "  aws cloudformation delete-stack --stack-name $DD_STACK --region $REGION"
