#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "AgentCore Backend - AWS 인프라 배포"
echo "=========================================="
echo ""

# 1. AWS 계정 확인
echo -e "${YELLOW}1. AWS 계정 확인 중...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}❌ AWS CLI가 설정되지 않았습니다.${NC}"
    exit 1
fi
REGION=$(aws configure get region || echo "us-east-1")
echo -e "${GREEN}✓ AWS 계정: $ACCOUNT_ID${NC}"
echo -e "${GREEN}✓ 리전: $REGION${NC}"
echo ""

STACK_NAME="agentcore-infra-stack"

# 2. VPC 및 Subnet
echo -e "${YELLOW}2. VPC 정보 가져오는 중...${NC}"
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")

if [ -z "$DEFAULT_VPC" ] || [ "$DEFAULT_VPC" == "None" ]; then
    read -p "VPC ID: " VPC_ID
else
    echo -e "${GREEN}✓ 기본 VPC: $DEFAULT_VPC${NC}"
    read -p "이 VPC를 사용하시겠습니까? (y/n) [y]: " USE_DEFAULT
    USE_DEFAULT=${USE_DEFAULT:-y}
    if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
        VPC_ID=$DEFAULT_VPC
    else
        read -p "VPC ID: " VPC_ID
    fi
fi

echo ""
echo -e "${YELLOW}Public Subnet 찾는 중...${NC}"
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[?MapPublicIpOnLaunch==\`true\`].[SubnetId,AvailabilityZone]" \
    --output text)

if [ -z "$SUBNETS" ]; then
    echo -e "${RED}❌ Public Subnet을 찾을 수 없습니다.${NC}"
    exit 1
fi

echo "$SUBNETS" | nl
SUBNET_ARRAY=($(echo "$SUBNETS" | awk '{print $1}'))
if [ ${#SUBNET_ARRAY[@]} -lt 2 ]; then
    echo -e "${RED}❌ 최소 2개의 Public Subnet이 필요합니다.${NC}"
    exit 1
fi
SUBNET1=${SUBNET_ARRAY[0]}
SUBNET2=${SUBNET_ARRAY[1]}
echo -e "${GREEN}✓ Subnet 1: $SUBNET1${NC}"
echo -e "${GREEN}✓ Subnet 2: $SUBNET2${NC}"
echo ""

# 3. 기존 스택 확인
echo -e "${YELLOW}3. 기존 스택 확인 중...${NC}"
STACK_EXISTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME 2>/dev/null || echo "")
if [ ! -z "$STACK_EXISTS" ]; then
    echo -e "${YELLOW}⚠️  스택 '$STACK_NAME'이(가) 이미 존재합니다.${NC}"
    read -p "스택을 업데이트하시겠습니까? (y/n) [n]: " UPDATE_STACK
    UPDATE_STACK=${UPDATE_STACK:-n}
    if [[ ! "$UPDATE_STACK" =~ ^[Yy]$ ]]; then
        exit 0
    fi
    ACTION="update"
else
    ACTION="create"
fi
echo ""

# 4. Container Image
echo -e "${YELLOW}4. Container Image 설정${NC}"
read -p "Container Image URI [선택]: " CONTAINER_IMAGE
CONTAINER_IMAGE=${CONTAINER_IMAGE:-""}
echo ""

# 5. 에이전트 환경변수
echo -e "${YELLOW}5. 에이전트 환경변수 설정${NC}"
read -p "Bedrock Model ID [us.anthropic.claude-sonnet-4-5-20250929-v1:0]: " BEDROCK_MODEL_ID
BEDROCK_MODEL_ID=${BEDROCK_MODEL_ID:-"us.anthropic.claude-sonnet-4-5-20250929-v1:0"}
read -p "AgentCore Gateway MCP URL [선택]: " GATEWAY_MCP_URL
GATEWAY_MCP_URL=${GATEWAY_MCP_URL:-""}
read -p "Helpdesk API URL [선택]: " HELPDESK_API_URL
HELPDESK_API_URL=${HELPDESK_API_URL:-""}
read -p "ECS Task 개수 [1]: " DESIRED_COUNT
DESIRED_COUNT=${DESIRED_COUNT:-1}
echo ""

# 파라미터 구성
PARAMETERS="ParameterKey=VpcId,ParameterValue=$VPC_ID"
PARAMETERS="$PARAMETERS ParameterKey=PublicSubnet1,ParameterValue=$SUBNET1"
PARAMETERS="$PARAMETERS ParameterKey=PublicSubnet2,ParameterValue=$SUBNET2"
PARAMETERS="$PARAMETERS ParameterKey=DesiredCount,ParameterValue=$DESIRED_COUNT"
PARAMETERS="$PARAMETERS ParameterKey=BedrockModelId,ParameterValue=$BEDROCK_MODEL_ID"
if [ ! -z "$CONTAINER_IMAGE" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=ContainerImage,ParameterValue=$CONTAINER_IMAGE"
fi
if [ ! -z "$GATEWAY_MCP_URL" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=GatewayMcpUrl,ParameterValue=$GATEWAY_MCP_URL"
fi
if [ ! -z "$HELPDESK_API_URL" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=HelpdeskApiUrl,ParameterValue=$HELPDESK_API_URL"
fi

# 배포 확인
echo "=========================================="
echo "배포 설정 확인"
echo "=========================================="
echo "Stack Name:    $STACK_NAME"
echo "VPC ID:        $VPC_ID"
echo "Subnet 1:      $SUBNET1"
echo "Subnet 2:      $SUBNET2"
echo "Model:         $BEDROCK_MODEL_ID"
echo "Gateway URL:   ${GATEWAY_MCP_URL:-'(미설정)'}"
echo "Helpdesk URL:  ${HELPDESK_API_URL:-'(미설정)'}"
echo "Container:     ${CONTAINER_IMAGE:-'(나중에 설정)'}"
echo "=========================================="
echo ""

read -p "계속 진행하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    exit 0
fi

echo ""
echo -e "${YELLOW}6. CloudFormation 스택 ${ACTION} 중...${NC}"

if [ "$ACTION" == "create" ]; then
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://cloudformation-infra.yaml \
        --parameters $PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION

    echo -e "${GREEN}✓ 스택 생성 요청 완료 (5-10분 소요)${NC}"
    read -p "완료까지 대기하시겠습니까? (y/n) [y]: " WAIT
    WAIT=${WAIT:-y}
    if [[ "$WAIT" =~ ^[Yy]$ ]]; then
        echo "대기 중..."
        aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
        echo -e "${GREEN}✓ 스택 생성 완료!${NC}"
    fi
else
    aws cloudformation update-stack \
        --stack-name $STACK_NAME \
        --template-body file://cloudformation-infra.yaml \
        --parameters $PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION
    echo -e "${GREEN}✓ 스택 업데이트 요청 완료${NC}"
fi

echo ""
# KB 문서 S3 업로드
KB_BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='KBDocsBucketName'].OutputValue" --output text 2>/dev/null || echo "")
if [ ! -z "$KB_BUCKET" ] && [ "$KB_BUCKET" != "None" ]; then
    echo -e "${YELLOW}7. KB 문서를 S3에 업로드 중...${NC}"
    if [ -d "kb_docs" ]; then
        aws s3 sync kb_docs/ s3://$KB_BUCKET/kb_docs/ --region $REGION
        echo -e "${GREEN}✓ kb_docs/ → s3://$KB_BUCKET/kb_docs/ 업로드 완료${NC}"
    fi
    echo ""
fi

echo "=========================================="
echo -e "${GREEN}인프라 배포 완료!${NC}"
echo "=========================================="

echo ""
echo "스택 Outputs:"
aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs" --output table --region $REGION 2>/dev/null || true

echo ""
echo "다음 단계:"
if [ -z "$CONTAINER_IMAGE" ]; then
    echo "1. Docker 이미지 빌드 & ECR 푸시:"
    echo "   ECR_URI=\$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query \"Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue\" --output text)"
    echo "   aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin \$ECR_URI"
    echo "   docker build -t agentcore-backend ."
    echo "   docker tag agentcore-backend:latest \$ECR_URI:latest"
    echo "   docker push \$ECR_URI:latest"
    echo ""
    echo "2. 스택 업데이트 (ContainerImage 추가):"
    echo "   ./deploy-infra.sh"
fi
echo ""
echo "Datadog 연동:"
echo "  ./deploy-datadog.sh"
echo ""
echo "스택 삭제:"
echo "  aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION"
