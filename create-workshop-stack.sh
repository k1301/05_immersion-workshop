#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  ./create-workshop-stack.sh

Examples:
  ./create-workshop-stack.sh

Environment overrides:
  STACK_NAME      CloudFormation stack name (default: agentcore-workshop-stack)
  AWS_REGION      AWS region (default: us-east-1)
  TEMPLATE_FILE   Template file name (default: agentcore-master-stack.yaml)
  IMAGE_BASE      Public ECR base URI (default: public.ecr.aws/j7s8j5m6/agentcore-backend)
  HELPDESK_IMAGE  Helpdesk API image URI
  AGENTCORE_IMAGE Full backend image URI override
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

print_stack_outputs() {
    local helpdesk_url gateway_secret_arn gateway_secret_name workshop_app_url kb_docs_bucket kb_id

    helpdesk_url=$(get_stack_output "HelpdeskUrl")
    gateway_secret_arn=$(get_stack_output "GatewayApiKeySecretArn")
    gateway_secret_name=$(get_stack_output "GatewayApiKeySecretName")
    workshop_app_url=$(get_stack_output "WorkshopAppUrl")
    kb_docs_bucket=$(get_stack_output "KBDocsBucketName")
    kb_id=$(get_stack_output "KnowledgeBaseId")

    echo
    echo "=================================================="
    echo " Workshop Outputs"
    echo "=================================================="
    echo "HelpdeskUrl            : $helpdesk_url"
    echo "GatewayApiKeySecretArn : $gateway_secret_arn"
    echo "GatewayApiKeySecretName: $gateway_secret_name"
    echo "WorkshopAppUrl         : $workshop_app_url"
    echo "KBDocsBucketName       : $kb_docs_bucket"
    echo "KnowledgeBaseId        : $kb_id"
    echo "=================================================="
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "create-workshop-stack.sh does not accept step arguments."
    usage
    exit 1
fi

STACK_NAME="${STACK_NAME:-agentcore-workshop-stack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TEMPLATE_FILE="${TEMPLATE_FILE:-agentcore-master-stack.yaml}"
HELPDESK_IMAGE="${HELPDESK_IMAGE:-public.ecr.aws/j7s8j5m6/it-helpdesk-api:latest}"
IMAGE_BASE="${IMAGE_BASE:-public.ecr.aws/j7s8j5m6/agentcore-backend}"
AGENTCORE_IMAGE="${AGENTCORE_IMAGE:-${IMAGE_BASE}/basic:latest}"
GATEWAY_URL="${GATEWAY_MCP_URL:-}"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    echo "Stack '$STACK_NAME' already exists. Use ./deploy-rag.sh or ./deploy-gateway.sh to switch steps."
    exit 1
fi

echo "Creating stack: $STACK_NAME"
echo "Region: $REGION"
echo "Template: $TEMPLATE_FILE"
echo "Backend image: $AGENTCORE_IMAGE"
echo "Helpdesk image: $HELPDESK_IMAGE"

PARAMETERS=(
    "ParameterKey=HelpdeskContainerImage,ParameterValue=${HELPDESK_IMAGE}"
    "ParameterKey=AgentcoreContainerImage,ParameterValue=${AGENTCORE_IMAGE}"
    "ParameterKey=GatewayMcpUrl,ParameterValue=${GATEWAY_URL}"
)

aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${SCRIPT_DIR}/${TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters "${PARAMETERS[@]}" \
    --region "$REGION" \
    --no-cli-pager

aws cloudformation wait stack-create-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --no-cli-pager

echo
echo "Stack created successfully."
print_stack_outputs
