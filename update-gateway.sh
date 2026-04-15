#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  AgentCore Gateway MCP URL 업데이트${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}❌ AWS CLI가 설정되지 않았습니다.${NC}"
    exit 1
fi
REGION=$(aws configure get region || echo "us-east-1")

echo -e "${GREEN}✓ 계정: $ACCOUNT_ID / 리전: $REGION${NC}"
echo ""

echo -e "${YELLOW}활성 CloudFormation 스택 목록:${NC}"
STACKS=($(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[].StackName" \
    --output text --region $REGION))

if [ ${#STACKS[@]} -eq 0 ]; then
    echo -e "${RED}❌ 활성 스택이 없습니다.${NC}"
    exit 1
fi

for i in "${!STACKS[@]}"; do
    echo "  $((i+1))) ${STACKS[$i]}"
done
echo ""
read -p "스택 번호를 선택하세요 [1]: " STACK_IDX
STACK_IDX=${STACK_IDX:-1}
STACK_NAME="${STACKS[$((STACK_IDX-1))]}"

if [ -z "$STACK_NAME" ]; then
    echo -e "${RED}❌ 잘못된 선택입니다.${NC}"
    exit 1
fi

TEMPLATE_FILE="agentcore-master-stack.yaml"

echo -e "${GREEN}✓ 선택된 스택: $STACK_NAME${NC}"
echo ""

read -p "Gateway MCP URL을 입력하세요: " GATEWAY_URL
if [ -z "$GATEWAY_URL" ]; then
    echo -e "${RED}❌ Gateway MCP URL이 비어있습니다.${NC}"
    exit 1
fi

echo ""
echo "=========================================="
echo "  스택:        $STACK_NAME"
echo "  Gateway MCP URL: $GATEWAY_URL"
echo "  (나머지 파라미터는 기존값 유지)"
echo "=========================================="
echo ""
read -p "업데이트를 시작하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "취소합니다."
    exit 0
fi

echo ""
echo -e "${YELLOW}스택 업데이트 중...${NC}"

aws cloudformation update-stack \
    --stack-name $STACK_NAME \
    --template-body file://$TEMPLATE_FILE \
    --parameters \
        ParameterKey=GatewayMcpUrl,ParameterValue="$GATEWAY_URL" \
        ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
        ParameterKey=AgentcoreContainerImage,UsePreviousValue=true \
        ParameterKey=CodeServerVersion,UsePreviousValue=true \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $REGION

echo "ECS 서비스 재배포 대기 중... (약 3~5분)"
aws cloudformation wait stack-update-complete \
    --stack-name $STACK_NAME --region $REGION

echo ""
echo -e "${GREEN}✓ Gateway MCP URL 업데이트 완료!${NC}"
echo ""
echo -e "AgentCore에서 Gateway 연동을 테스트하세요:"
echo -e "  https://agentcore.${ACCOUNT_ID}.fitcloud.click"
