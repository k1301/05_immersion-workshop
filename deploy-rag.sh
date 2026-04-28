#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STACK_NAME="${STACK_NAME:-agentcore-workshop-stack}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TEMPLATE_FILE="${TEMPLATE_FILE:-agentcore-master-stack.yaml}"
PUBLIC_ECR_ALIAS="${PUBLIC_ECR_ALIAS:-j7s8j5m6}"
AGENTCORE_IMAGE="${AGENTCORE_IMAGE:-public.ecr.aws/${PUBLIC_ECR_ALIAS}/agentcore-backend/rag:latest}"

get_stack_output() {
    local output_key="$1"

    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --output text \
        --no-cli-pager
}

print_rag_outputs() {
    local workshop_app_url helpdesk_url kb_id

    workshop_app_url=$(get_stack_output "WorkshopAppUrl")
    helpdesk_url=$(get_stack_output "HelpdeskUrl")
    kb_id=$(get_stack_output "KnowledgeBaseId")

    echo
    echo "=================================================="
    echo " Step 2 Outputs"
    echo "=================================================="
    echo "Workshop App URL      : $workshop_app_url"
    echo "Helpdesk API URL      : $helpdesk_url"
    echo "Knowledge Base ID     : $kb_id"
    echo "=================================================="
}

if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" --no-cli-pager >/dev/null 2>&1; then
    echo "Stack '$STACK_NAME' does not exist. Create it first."
    exit 1
fi

echo "Deploying RAG step"
echo "Stack: $STACK_NAME"
echo "Region: $REGION"
echo "Backend image: $AGENTCORE_IMAGE"

aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --template-body "file://${SCRIPT_DIR}/${TEMPLATE_FILE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=HelpdeskContainerImage,UsePreviousValue=true \
        ParameterKey=AgentcoreContainerImage,ParameterValue="${AGENTCORE_IMAGE}" \
        ParameterKey=GatewayMcpUrl,UsePreviousValue=true \
    --region "$REGION" \
    --no-cli-pager

aws cloudformation wait stack-update-complete \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --no-cli-pager

echo
echo "RAG step deployed successfully."
print_rag_outputs
