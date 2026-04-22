#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGION="$(aws configure get region 2>/dev/null || true)"
REGION="${REGION:-us-east-1}"
WORKSHOP_STACK="${WORKSHOP_STACK:-agentcore-workshop-stack}"
DD_STACK="${DD_STACK:-agentcore-datadog-stack}"
DD_TASK_FAMILY="agentcore-backend-datadog"

echo "=========================================="
echo "Datadog LLM Observability 연동"
echo "=========================================="
echo ""

get_stack_parameter() {
  local stack_name="$1"
  local key="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query "Stacks[0].Parameters[?ParameterKey=='${key}'].ParameterValue | [0]" \
    --output text \
    --region "$REGION" 2>/dev/null || true
}

get_stack_output() {
  local stack_name="$1"
  local key="$2"
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text \
    --region "$REGION" 2>/dev/null || true
}

get_resource_physical_id() {
  local stack_name="$1"
  local logical_id="$2"
  aws cloudformation list-stack-resources \
    --stack-name "$stack_name" \
    --query "StackResourceSummaries[?LogicalResourceId=='${logical_id}'].PhysicalResourceId | [0]" \
    --output text \
    --region "$REGION" 2>/dev/null || true
}

normalize_text() {
  local value="${1:-}"
  if [ "$value" = "None" ] || [ "$value" = "null" ] || [ "$value" = "NoneType" ]; then
    echo ""
  else
    echo "$value"
  fi
}

echo -e "${YELLOW}1. 워크샵 스택 확인 중...${NC}"
STACK_JSON="$(aws cloudformation describe-stacks --stack-name "$WORKSHOP_STACK" --region "$REGION" 2>/dev/null || true)"
if [ -z "$STACK_JSON" ]; then
  echo -e "${RED}❌ 워크샵 스택 '$WORKSHOP_STACK'이(가) 없습니다.${NC}"
  echo "   WORKSHOP_STACK 환경변수를 설정하거나 agentcore-workshop-stack 을 먼저 배포하세요."
  exit 1
fi
echo -e "${GREEN}✓ 워크샵 스택 확인 완료: $WORKSHOP_STACK${NC}"
echo ""

echo -e "${YELLOW}2. Datadog 설정${NC}"
read -r -p "Datadog API Key (필수): " DD_API_KEY
if [ -z "$DD_API_KEY" ]; then
  echo -e "${RED}❌ Datadog API Key는 필수입니다.${NC}"
  exit 1
fi
read -r -p "Datadog Site [datadoghq.com]: " DD_SITE
DD_SITE="${DD_SITE:-datadoghq.com}"
read -r -p "ML App 이름 [agentcore-backend]: " DD_ML_APP
DD_ML_APP="${DD_ML_APP:-agentcore-backend}"
echo ""

echo -e "${YELLOW}3. 기존 워크샵 스택에서 설정 가져오는 중...${NC}"

CONTAINER_IMAGE="$(normalize_text "$(get_stack_parameter "$WORKSHOP_STACK" "AgentcoreContainerImage")")"
if [ -z "$CONTAINER_IMAGE" ]; then
  CONTAINER_IMAGE="public.ecr.aws/j7s8j5m6/agentcore-backend:latest"
fi

GATEWAY_MCP_URL="$(normalize_text "$(get_stack_parameter "$WORKSHOP_STACK" "GatewayMcpUrl")")"
HELPDESK_API_URL="$(normalize_text "$(get_stack_output "$WORKSHOP_STACK" "HelpdeskUrl")")"
KB_ID="$(normalize_text "$(get_stack_output "$WORKSHOP_STACK" "KnowledgeBaseId")")"
BEDROCK_MODEL_ID=""

ECS_EXEC_ROLE_NAME="$(normalize_text "$(get_resource_physical_id "$WORKSHOP_STACK" "ECSExecutionRole")")"
ECS_TASK_ROLE_NAME="$(normalize_text "$(get_resource_physical_id "$WORKSHOP_STACK" "ECSTaskRole")")"
LOG_GROUP="$(normalize_text "$(get_resource_physical_id "$WORKSHOP_STACK" "AgentcoreLogGroup")")"
ECS_CLUSTER="$(normalize_text "$(get_resource_physical_id "$WORKSHOP_STACK" "ECSCluster")")"
ECS_SERVICE="$(normalize_text "$(get_resource_physical_id "$WORKSHOP_STACK" "AgentcoreService")")"

if [ -z "$ECS_EXEC_ROLE_NAME" ] || [ -z "$ECS_TASK_ROLE_NAME" ] || [ -z "$KB_ID" ] || [ -z "$LOG_GROUP" ] || [ -z "$ECS_CLUSTER" ] || [ -z "$ECS_SERVICE" ]; then
  echo -e "${RED}❌ 현재 스택에서 Datadog 연동에 필요한 리소스 값을 충분히 찾지 못했습니다.${NC}"
  echo "   확인 항목:"
  echo "   - ECSExecutionRole: ${ECS_EXEC_ROLE_NAME:-'(없음)'}"
  echo "   - ECSTaskRole:      ${ECS_TASK_ROLE_NAME:-'(없음)'}"
  echo "   - KnowledgeBaseId:  ${KB_ID:-'(없음)'}"
  echo "   - AgentcoreLogGroup:${LOG_GROUP:-'(없음)'}"
  echo "   - ECSCluster:       ${ECS_CLUSTER:-'(없음)'}"
  echo "   - AgentcoreService: ${ECS_SERVICE:-'(없음)'}"
  exit 1
fi

ECS_EXEC_ROLE="$(aws iam get-role --role-name "$ECS_EXEC_ROLE_NAME" --query 'Role.Arn' --output text --region "$REGION")"
ECS_TASK_ROLE="$(aws iam get-role --role-name "$ECS_TASK_ROLE_NAME" --query 'Role.Arn' --output text --region "$REGION")"

echo -e "${GREEN}✓ Container:    $CONTAINER_IMAGE${NC}"
echo -e "${GREEN}✓ Model:        ${BEDROCK_MODEL_ID:-'(자동 설정)'}${NC}"
echo -e "${GREEN}✓ Gateway URL:  ${GATEWAY_MCP_URL:-'(미설정)'}${NC}"
echo -e "${GREEN}✓ Helpdesk URL: ${HELPDESK_API_URL:-'(미설정)'}${NC}"
echo -e "${GREEN}✓ KB ID:        $KB_ID${NC}"
echo -e "${GREEN}✓ ECS Cluster:  $ECS_CLUSTER${NC}"
echo -e "${GREEN}✓ ECS Service:  $ECS_SERVICE${NC}"
echo ""

PARAMETERS=(
  "ParameterKey=InfraStackName,ParameterValue=${WORKSHOP_STACK}"
  "ParameterKey=ContainerImage,ParameterValue=${CONTAINER_IMAGE}"
  "ParameterKey=BedrockModelId,ParameterValue=${BEDROCK_MODEL_ID}"
  "ParameterKey=GatewayMcpUrl,ParameterValue=${GATEWAY_MCP_URL}"
  "ParameterKey=HelpdeskApiUrl,ParameterValue=${HELPDESK_API_URL}"
  "ParameterKey=ECSTaskExecutionRoleArn,ParameterValue=${ECS_EXEC_ROLE}"
  "ParameterKey=ECSTaskRoleArn,ParameterValue=${ECS_TASK_ROLE}"
  "ParameterKey=KnowledgeBaseId,ParameterValue=${KB_ID}"
  "ParameterKey=LogGroupName,ParameterValue=${LOG_GROUP}"
  "ParameterKey=DatadogApiKey,ParameterValue=${DD_API_KEY}"
  "ParameterKey=DatadogSite,ParameterValue=${DD_SITE}"
  "ParameterKey=DatadogMlApp,ParameterValue=${DD_ML_APP}"
)

echo "=========================================="
echo "Datadog 설정 확인"
echo "=========================================="
echo "Region:        $REGION"
echo "WorkshopStack: $WORKSHOP_STACK"
echo "DD Stack:      $DD_STACK"
echo "DD Site:       $DD_SITE"
echo "DD ML App:     $DD_ML_APP"
echo "Container:     $CONTAINER_IMAGE"
echo "Model:         ${BEDROCK_MODEL_ID:-'(자동 설정)'}"
echo "=========================================="
echo ""

read -r -p "계속 진행하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  exit 0
fi

echo ""
echo -e "${YELLOW}4. Datadog 스택 배포 중...${NC}"
DD_EXISTS="$(aws cloudformation describe-stacks --stack-name "$DD_STACK" --region "$REGION" 2>/dev/null || true)"
if [ -z "$DD_EXISTS" ]; then
  aws cloudformation create-stack \
    --stack-name "$DD_STACK" \
    --template-body "file://${SCRIPT_DIR}/cloudformation-datadog.yaml" \
    --parameters "${PARAMETERS[@]}" \
    --region "$REGION"
  echo "대기 중..."
  aws cloudformation wait stack-create-complete --stack-name "$DD_STACK" --region "$REGION"
else
  set +e
  UPDATE_OUTPUT="$(aws cloudformation update-stack \
    --stack-name "$DD_STACK" \
    --template-body "file://${SCRIPT_DIR}/cloudformation-datadog.yaml" \
    --parameters "${PARAMETERS[@]}" \
    --region "$REGION" 2>&1)"
  UPDATE_STATUS=$?
  set -e
  if [ $UPDATE_STATUS -ne 0 ]; then
    if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
      echo -e "${YELLOW}ℹ️ Datadog 스택 변경사항이 없습니다.${NC}"
    else
      echo "$UPDATE_OUTPUT"
      exit $UPDATE_STATUS
    fi
  else
    echo "대기 중..."
    aws cloudformation wait stack-update-complete --stack-name "$DD_STACK" --region "$REGION"
  fi
fi
echo -e "${GREEN}✓ Datadog 스택 배포 완료${NC}"

echo ""
echo -e "${YELLOW}5. ECS Service를 Datadog Task Definition으로 업데이트 중...${NC}"
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$DD_TASK_FAMILY" \
  --force-new-deployment \
  --region "$REGION" > /dev/null
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
