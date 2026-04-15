#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}  Knowledge Base 문서 동기화${NC}"
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

echo -e "${GREEN}✓ 선택된 스택: $STACK_NAME${NC}"
echo ""

BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='KBDocsBucketName'].OutputValue" \
    --output text --region $REGION)

KB_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='KnowledgeBaseId'].OutputValue" \
    --output text --region $REGION)

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
    echo -e "${RED}❌ KBDocsBucketName 출력값을 찾을 수 없습니다.${NC}"
    exit 1
fi

if [ -z "$KB_ID" ] || [ "$KB_ID" = "None" ]; then
    echo -e "${RED}❌ KnowledgeBaseId 출력값을 찾을 수 없습니다.${NC}"
    exit 1
fi

echo -e "  S3 버킷:        ${BLUE}$BUCKET_NAME${NC}"
echo -e "  Knowledge Base:  ${BLUE}$KB_ID${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KB_DOCS_DIR="$SCRIPT_DIR/kb_docs"

if [ ! -d "$KB_DOCS_DIR" ]; then
    echo -e "${RED}❌ kb_docs/ 폴더를 찾을 수 없습니다: $KB_DOCS_DIR${NC}"
    exit 1
fi

FILE_COUNT=$(find "$KB_DOCS_DIR" -type f | wc -l | tr -d ' ')
echo -e "${YELLOW}S3에 업로드할 파일: ${FILE_COUNT}개${NC}"
echo ""

echo "=========================================="
echo "  스택:           $STACK_NAME"
echo "  S3 대상:        s3://$BUCKET_NAME/kb_docs/"
echo "  Knowledge Base: $KB_ID"
echo "  로컬 파일:      $KB_DOCS_DIR/ (${FILE_COUNT}개)"
echo "=========================================="
echo ""
read -p "동기화를 시작하시겠습니까? (y/n) [y]: " CONFIRM
CONFIRM=${CONFIRM:-y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "취소합니다."
    exit 0
fi

echo ""
echo -e "${YELLOW}[1/3] S3에 문서 업로드 중...${NC}"
aws s3 sync "$KB_DOCS_DIR/" "s3://$BUCKET_NAME/kb_docs/" --region $REGION --delete
echo -e "${GREEN}✓ S3 업로드 완료${NC}"

echo ""
echo -e "${YELLOW}[2/3] Data Source ID 조회 중...${NC}"
DS_ID=$(aws bedrock-agent list-data-sources \
    --knowledge-base-id "$KB_ID" \
    --query "dataSourceSummaries[0].dataSourceId" \
    --output text --region $REGION)

if [ -z "$DS_ID" ] || [ "$DS_ID" = "None" ]; then
    echo -e "${RED}❌ Data Source를 찾을 수 없습니다.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Data Source: $DS_ID${NC}"

echo ""
echo -e "${YELLOW}[3/3] Knowledge Base 인덱싱 시작...${NC}"
INGESTION=$(aws bedrock-agent start-ingestion-job \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS_ID" \
    --region $REGION \
    --output json)

JOB_ID=$(echo "$INGESTION" | python3 -c "import sys,json; print(json.load(sys.stdin)['ingestionJob']['ingestionJobId'])")
echo -e "${GREEN}✓ Ingestion Job 시작: $JOB_ID${NC}"

echo ""
echo -e "${YELLOW}인덱싱 완료 대기 중...${NC}"
while true; do
    STATUS=$(aws bedrock-agent get-ingestion-job \
        --knowledge-base-id "$KB_ID" \
        --data-source-id "$DS_ID" \
        --ingestion-job-id "$JOB_ID" \
        --query "ingestionJob.status" \
        --output text --region $REGION)

    case "$STATUS" in
        COMPLETE)
            echo -e "${GREEN}✓ 인덱싱 완료!${NC}"
            break
            ;;
        FAILED)
            echo -e "${RED}❌ 인덱싱 실패${NC}"
            aws bedrock-agent get-ingestion-job \
                --knowledge-base-id "$KB_ID" \
                --data-source-id "$DS_ID" \
                --ingestion-job-id "$JOB_ID" \
                --region $REGION
            exit 1
            ;;
        *)
            echo -e "  상태: $STATUS ..."
            sleep 5
            ;;
    esac
done

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  Knowledge Base 동기화 완료!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "  S3:  s3://$BUCKET_NAME/kb_docs/"
echo -e "  KB:  $KB_ID"
echo ""
