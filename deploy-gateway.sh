#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  ./deploy-gateway.sh

Examples:
  ./deploy-gateway.sh

Environment overrides:
  STACK_NAME       CloudFormation stack name (default: agentcore-workshop-stack)
  AWS_REGION       AWS region (default: us-east-1)
  TEMPLATE_FILE    Template file name (default: agentcore-master-stack.yaml)
  PUBLIC_ECR_ALIAS Public ECR alias (default: j7s8j5m6)
  AGENTCORE_IMAGE  Full backend image URI override
  GATEWAY_MCP_URL  Gateway MCP URL override
  WORKSHOP_SCENARIO Scenario override (default: normal)
EOF
}

get_stack_output() {
    local output_key="$1"

    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --output text \
        --no-cli-pager
}

print_gateway_outputs() {
    local workshop_app_url helpdesk_url

    workshop_app_url=$(get_stack_output "WorkshopAppUrl")
    helpdesk_url=$(get_stack_output "HelpdeskUrl")

    echo
    echo "=================================================="
    echo " Step 3 Outputs"
    echo "=================================================="
    echo "Workshop App URL      : $workshop_app_url"
    echo "Helpdesk API URL      : $helpdesk_url"
    echo "Gateway MCP URL       : $GATEWAY_URL"
    echo "=================================================="
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "deploy-gateway.sh does not accept positional arguments."
    usage
    exit 1
fi

STACK_NAME="${STACK_NAME:-agentcore-workshop-stack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TEMPLATE_FILE="${TEMPLATE_FILE:-agentcore-master-stack.yaml}"
PUBLIC_ECR_ALIAS="${PUBLIC_ECR_ALIAS:-j7s8j5m6}"
AGENTCORE_IMAGE="${AGENTCORE_IMAGE:-public.ecr.aws/${PUBLIC_ECR_ALIAS}/agentcore-backend/gateway:latest}"
GATEWAY_URL="${GATEWAY_MCP_URL:-}"
WORKSHOP_SCENARIO="${WORKSHOP_SCENARIO:-normal}"
TEMP_TEMPLATE_FILE=""

cleanup() {
    if [ -n "$TEMP_TEMPLATE_FILE" ] && [ -f "$TEMP_TEMPLATE_FILE" ]; then
        rm -f "$TEMP_TEMPLATE_FILE"
    fi
}

prepare_template() {
    ACTIVE_TEMPLATE_FILE="${SCRIPT_DIR}/${TEMPLATE_FILE}"

    if [ "$WORKSHOP_SCENARIO" = "token_error" ]; then
        TEMP_TEMPLATE_FILE="$(mktemp "${TMPDIR:-/tmp}/agentcore-gateway-template.XXXXXX")"
        awk '
            /Name: WORKSHOP_SCENARIO/ {
                print
                getline
                sub(/\047normal\047/, "\047token_error\047")
                print
                next
            }
            /Name: BEDROCK_MAX_TOKENS/ {
                print
                getline
                sub(/\0474096\047/, "\04780\047")
                print
                next
            }
            { print }
        ' "$ACTIVE_TEMPLATE_FILE" > "$TEMP_TEMPLATE_FILE"
        ACTIVE_TEMPLATE_FILE="$TEMP_TEMPLATE_FILE"
    fi
}

trap cleanup EXIT

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    echo "Stack '$STACK_NAME' does not exist. Create it first."
    exit 1
fi

if [ -z "$GATEWAY_URL" ]; then
    read -r -p "Gateway MCP URL을 입력하세요: " GATEWAY_URL
fi

if [ -z "$GATEWAY_URL" ]; then
    echo "Gateway MCP URL이 비어 있습니다."
    exit 1
fi

prepare_template

echo "Deploying gateway step"
echo "Stack: $STACK_NAME"
echo "Region: $REGION"
echo "Backend image: $AGENTCORE_IMAGE"
echo "Gateway MCP URL: $GATEWAY_URL"

aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${ACTIVE_TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
        ParameterKey=AgentcoreContainerImage,ParameterValue="${AGENTCORE_IMAGE}" \
        ParameterKey=GatewayMcpUrl,ParameterValue="${GATEWAY_URL}" \
    --region "$REGION" \
    --no-cli-pager

echo
echo "CloudFormation 업데이트 진행 중입니다. 잠시만 기다리세요..."

aws cloudformation wait stack-update-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --no-cli-pager

echo
echo "Gateway step deployed successfully."
print_gateway_outputs
