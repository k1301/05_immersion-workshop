#!/bin/bash

set -e

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=========================================="
echo "IT Helpdesk API - CloudFormation 배포"
echo "=========================================="
echo ""

# AWS 계정 확인
echo -e "${YELLOW}1. AWS 계정 확인 중...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}❌ AWS CLI가 설정되지 않았습니다.${NC}"
    echo "aws configure를 실행하여 AWS 자격 증명을 설정하세요."
    exit 1
fi
REGION=$(aws configure get region || echo "us-east-1")
echo -e "${GREEN}✓ AWS 계정: $ACCOUNT_ID${NC}"
echo -e "${GREEN}✓ 리전: $REGION${NC}"
echo ""

# 스택 이름
STACK_NAME="helpdesk-api-stack"

# VPC 및 Subnet 선택
echo -e "${YELLOW}2. VPC 정보 가져오는 중...${NC}"

# 기본 VPC 찾기
DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")

if [ -z "$DEFAULT_VPC" ] || [ "$DEFAULT_VPC" == "None" ]; then
    echo -e "${YELLOW}기본 VPC를 찾을 수 없습니다. VPC를 직접 입력하세요:${NC}"
    read -p "VPC ID: " VPC_ID
else
    echo -e "${GREEN}✓ 기본 VPC 발견: $DEFAULT_VPC${NC}"
    read -p "이 VPC를 사용하시겠습니까? (y/n) [y]: " USE_DEFAULT
    USE_DEFAULT=${USE_DEFAULT:-y}

    if [[ "$USE_DEFAULT" =~ ^[Yy]$ ]]; then
        VPC_ID=$DEFAULT_VPC
    else
        read -p "VPC ID: " VPC_ID
    fi
fi

# Public Subnets 찾기
echo ""
echo -e "${YELLOW}Public Subnet 찾는 중...${NC}"
SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[?MapPublicIpOnLaunch==\`true\`].[SubnetId,AvailabilityZone]" \
    --output text)

if [ -z "$SUBNETS" ]; then
    echo -e "${RED}❌ Public Subnet을 찾을 수 없습니다.${NC}"
    echo "VPC에 Public Subnet이 있는지 확인하세요."
    exit 1
fi

echo -e "${GREEN}사용 가능한 Public Subnets:${NC}"
echo "$SUBNETS" | nl

SUBNET_ARRAY=($(echo "$SUBNETS" | awk '{print $1}'))

if [ ${#SUBNET_ARRAY[@]} -lt 2 ]; then
    echo -e "${RED}❌ 최소 2개의 Public Subnet이 필요합니다 (다른 AZ에).${NC}"
    exit 1
fi

SUBNET1=${SUBNET_ARRAY[0]}
SUBNET2=${SUBNET_ARRAY[1]}
echo -e "${GREEN}✓ Subnet 1: $SUBNET1${NC}"
echo -e "${GREEN}✓ Subnet 2: $SUBNET2${NC}"
echo ""

# 스택 존재 여부 확인
echo -e "${YELLOW}3. 기존 스택 확인 중...${NC}"
STACK_EXISTS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME 2>/dev/null || echo "")

if [ ! -z "$STACK_EXISTS" ]; then
    echo -e "${YELLOW}⚠️  스택 '$STACK_NAME'이(가) 이미 존재합니다.${NC}"
    read -p "스택을 업데이트하시겠습니까? (y/n) [n]: " UPDATE_STACK
    UPDATE_STACK=${UPDATE_STACK:-n}

    if [[ ! "$UPDATE_STACK" =~ ^[Yy]$ ]]; then
        echo "배포를 취소합니다."
        exit 0
    fi
    ACTION="update"
else
    ACTION="create"
fi
echo ""

# Container Image (선택사항)
echo -e "${YELLOW}4. Container Image 설정${NC}"
echo "ECR에 이미지를 푸시했다면 URI를 입력하세요."
echo "아직 없다면 Enter를 눌러 건너뛰세요 (나중에 업데이트 가능)."
echo ""
read -p "Container Image URI [선택]: " CONTAINER_IMAGE
CONTAINER_IMAGE=${CONTAINER_IMAGE:-""}
echo ""

# DesiredCount
read -p "ECS Task 개수 [1]: " DESIRED_COUNT
DESIRED_COUNT=${DESIRED_COUNT:-1}
echo ""

# 파라미터 구성
PARAMETERS="ParameterKey=VpcId,ParameterValue=$VPC_ID"
PARAMETERS="$PARAMETERS ParameterKey=PublicSubnet1,ParameterValue=$SUBNET1"
PARAMETERS="$PARAMETERS ParameterKey=PublicSubnet2,ParameterValue=$SUBNET2"
PARAMETERS="$PARAMETERS ParameterKey=DesiredCount,ParameterValue=$DESIRED_COUNT"

if [ ! -z "$CONTAINER_IMAGE" ]; then
    PARAMETERS="$PARAMETERS ParameterKey=ContainerImage,ParameterValue=$CONTAINER_IMAGE"
fi

# 배포 확인
echo "=========================================="
echo "배포 설정 확인"
echo "=========================================="
echo "Stack Name: $STACK_NAME"
echo "VPC ID: $VPC_ID"
echo "Subnet 1: $SUBNET1"
echo "Subnet 2: $SUBNET2"
echo "Desired Count: $DESIRED_COUNT"
if [ ! -z "$CONTAINER_IMAGE" ]; then
    echo "Container Image: $CONTAINER_IMAGE"
else
    echo "Container Image: (나중에 설정)"
fi
echo "=========================================="
echo ""

read -p "계속 진행하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "배포를 취소합니다."
    exit 0
fi

echo ""
echo -e "${YELLOW}5. CloudFormation 스택 ${ACTION} 중...${NC}"

if [ "$ACTION" == "create" ]; then
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://cloudformation.yaml \
        --parameters $PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION

    echo -e "${GREEN}✓ 스택 생성 요청 완료${NC}"
    echo ""
    echo "스택 생성 중... (5-10분 소요)"
    echo "진행 상황을 확인하려면:"
    echo "  aws cloudformation describe-stacks --stack-name $STACK_NAME"
    echo "  또는 AWS Console에서 CloudFormation 확인"
    echo ""

    read -p "스택 생성 완료까지 대기하시겠습니까? (y/n) [y]: " WAIT
    WAIT=${WAIT:-y}

    if [[ "$WAIT" =~ ^[Yy]$ ]]; then
        echo "대기 중..."
        aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
        echo -e "${GREEN}✓ 스택 생성 완료!${NC}"
    fi
else
    aws cloudformation update-stack \
        --stack-name $STACK_NAME \
        --template-body file://cloudformation.yaml \
        --parameters $PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION

    echo -e "${GREEN}✓ 스택 업데이트 요청 완료${NC}"
    echo ""
    echo "스택 업데이트 중... (5-10분 소요)"
fi

echo ""
echo "=========================================="
echo -e "${GREEN}배포 완료!${NC}"
echo "=========================================="
echo ""

# Outputs 가져오기
echo "스택 Outputs:"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --query "Stacks[0].Outputs" \
    --output table \
    --region $REGION 2>/dev/null || echo "아직 Outputs를 가져올 수 없습니다."

echo ""
echo "다음 단계:"
if [ -z "$CONTAINER_IMAGE" ]; then
    echo "1. Docker 이미지를 빌드하고 ECR에 푸시하세요:"
    echo "   ECR URI는 위의 ECRRepositoryUri를 확인하세요"
    echo ""
    echo "2. 스택을 업데이트하여 ECS 서비스를 생성하세요:"
    echo "   ./deploy-cloudformation.sh"
else
    echo "1. ALB URL에 접속하여 API를 테스트하세요"
    echo "2. Bedrock Agent Core Gateway에 ALB DNS를 연결하세요"
fi
echo ""
echo "스택 삭제 (필요시):"
echo "  aws cloudformation delete-stack --stack-name $STACK_NAME"
