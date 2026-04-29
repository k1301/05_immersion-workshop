#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  ./enable-datadog.sh

Environment overrides:
  STACK_NAME       CloudFormation stack name (default: agentcore-workshop-stack)
  AWS_REGION       AWS region (default: us-east-1)
  TEMPLATE_FILE    Template file name (default: agentcore-master-stack.yaml)
  PUBLIC_ECR_ALIAS Public ECR alias (default: j7s8j5m6)
  AGENTCORE_IMAGE  Full backend image URI override
  GATEWAY_MCP_URL  Gateway MCP URL override
  DD_API_KEY       Datadog API key override
  DD_SITE          Datadog site (default: datadoghq.com)
  DD_LLMOBS_ML_APP Datadog LLM Observability ML app (default: agentcore-workshop)
  DD_SERVICE       Datadog service name (default: agentcore-backend)
  DD_ENV           Datadog environment name (default: workshop)
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

load_env_file() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        return
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            ''|\#*) continue ;;
            WORKSHOP_STACK_NAME|BEDROCK_KB_ID|HELPDESK_API_URL|GATEWAY_MCP_URL|DD_API_KEY|DD_SITE|DD_LLMOBS_ML_APP|DD_SERVICE|DD_ENV)
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                if [ -z "${!key:-}" ]; then
                    export "$key=$value"
                fi
                ;;
        esac
    done < "$env_file"
}

get_stack_parameter() {
    local parameter_key="$1"

    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Parameters[?ParameterKey=='${parameter_key}'].ParameterValue | [0]" \
        --output text \
        --no-cli-pager 2>/dev/null || true
}

normalize_text() {
    local value="${1:-}"
    if [ "$value" = "None" ] || [ "$value" = "null" ] || [ "$value" = "NoneType" ]; then
        echo ""
    else
        echo "$value"
    fi
}

print_datadog_outputs() {
    local workshop_app_url helpdesk_url kb_id

    workshop_app_url=$(get_stack_output "WorkshopAppUrl")
    helpdesk_url=$(get_stack_output "HelpdeskUrl")
    kb_id=$(get_stack_output "KnowledgeBaseId")

    echo
    echo "=================================================="
    echo " Step 4 Outputs"
    echo "=================================================="
    echo "Workshop App URL      : $workshop_app_url"
    echo "Helpdesk API URL      : $helpdesk_url"
    echo "Knowledge Base ID     : $kb_id"
    echo "Gateway MCP URL       : $GATEWAY_URL"
    echo "Datadog Site          : $DD_SITE"
    echo "Datadog ML App        : $DD_ML_APP"
    echo "=================================================="
}

cleanup() {
    if [ -n "$TEMP_TEMPLATE_FILE" ] && [ -f "$TEMP_TEMPLATE_FILE" ]; then
        rm -f "$TEMP_TEMPLATE_FILE"
    fi
}

prepare_template() {
    ACTIVE_TEMPLATE_FILE="${SCRIPT_DIR}/${TEMPLATE_FILE}"
    TEMP_TEMPLATE_FILE="$(mktemp "${TMPDIR:-/tmp}/agentcore-datadog-template.XXXXXX")"

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
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "enable-datadog.sh does not accept positional arguments."
    usage
    exit 1
fi

load_env_file "${SCRIPT_DIR}/.env"
load_env_file "${SCRIPT_DIR}/agentcore-backend/.env"

STACK_NAME="${STACK_NAME:-${WORKSHOP_STACK_NAME:-agentcore-workshop-stack}}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TEMPLATE_FILE="${TEMPLATE_FILE:-agentcore-master-stack.yaml}"
PUBLIC_ECR_ALIAS="${PUBLIC_ECR_ALIAS:-j7s8j5m6}"
AGENTCORE_IMAGE="${AGENTCORE_IMAGE:-public.ecr.aws/${PUBLIC_ECR_ALIAS}/agentcore-backend/gateway:latest}"
GATEWAY_URL="${GATEWAY_MCP_URL:-}"
DD_API_KEY="${DD_API_KEY:-}"
DD_SITE="${DD_SITE:-datadoghq.com}"
DD_ML_APP="${DD_LLMOBS_ML_APP:-agentcore-workshop}"
DD_SERVICE="${DD_SERVICE:-agentcore-backend}"
DD_ENV="${DD_ENV:-workshop}"
TEMP_TEMPLATE_FILE=""

trap cleanup EXIT

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    echo "Stack '$STACK_NAME' does not exist. Create it first."
    exit 1
fi

if [ -z "$GATEWAY_URL" ]; then
    GATEWAY_URL="$(normalize_text "$(get_stack_parameter "GatewayMcpUrl")")"
fi

if [ -z "$GATEWAY_URL" ]; then
    read -r -p "Gateway MCP URL을 입력하세요: " GATEWAY_URL
fi

if [ -z "$GATEWAY_URL" ]; then
    echo "Gateway MCP URL이 비어 있습니다."
    exit 1
fi

if [ -z "$DD_API_KEY" ]; then
    read -r -s -p "Datadog API Key를 입력하세요: " DD_API_KEY
    echo
fi

if [ -z "$DD_API_KEY" ]; then
    echo "Datadog API Key가 비어 있습니다."
    exit 1
fi

prepare_template

echo "Enabling Datadog observability"
echo "Stack: $STACK_NAME"
echo "Region: $REGION"
echo "Backend image: $AGENTCORE_IMAGE"
echo "Gateway MCP URL: $GATEWAY_URL"
echo "Datadog Site: $DD_SITE"
echo "Datadog ML App: $DD_ML_APP"

set +e
UPDATE_OUTPUT="$(aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${ACTIVE_TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
        ParameterKey=AgentcoreContainerImage,ParameterValue="${AGENTCORE_IMAGE}" \
        ParameterKey=GatewayMcpUrl,ParameterValue="${GATEWAY_URL}" \
        ParameterKey=DatadogApiKey,ParameterValue="${DD_API_KEY}" \
        ParameterKey=DatadogSite,ParameterValue="${DD_SITE}" \
        ParameterKey=DatadogMlApp,ParameterValue="${DD_ML_APP}" \
        ParameterKey=DatadogService,ParameterValue="${DD_SERVICE}" \
        ParameterKey=DatadogEnv,ParameterValue="${DD_ENV}" \
    --region "$REGION" \
    --no-cli-pager 2>&1)"
UPDATE_STATUS=$?
set -e

if [ $UPDATE_STATUS -ne 0 ]; then
    if echo "$UPDATE_OUTPUT" | grep -q "No updates are to be performed"; then
        echo "No CloudFormation updates were needed."
    else
        echo "$UPDATE_OUTPUT"
        exit $UPDATE_STATUS
    fi
else
    echo "$UPDATE_OUTPUT"
    echo
    echo "CloudFormation 업데이트 진행 중입니다. 잠시만 기다리세요..."
    aws cloudformation wait stack-update-complete \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --no-cli-pager
fi

echo
echo "Datadog observability enabled successfully."
print_datadog_outputs
