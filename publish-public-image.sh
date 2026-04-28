#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./publish-public-image.sh [chatbot|rag|gateway|helpdesk|all]

Examples:
  ./publish-public-image.sh rag
  ./publish-public-image.sh helpdesk
  ./publish-public-image.sh all

Environment overrides:
  AWS_REGION         AWS region for ECR Public login (default: us-east-1)
  PUBLIC_ECR_ALIAS   Public ECR registry alias (default: j7s8j5m6)
EOF
}

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PUBLIC_ECR_ALIAS="${PUBLIC_ECR_ALIAS:-j7s8j5m6}"
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    usage
    exit 1
fi

case "$TARGET" in
    chatbot|rag|gateway|helpdesk|all) ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unsupported target: $TARGET"
        usage
        exit 1
        ;;
esac

publish_agentcore_image() {
    local step="$1"
    local app_file image_name local_tag remote_tag

    case "$step" in
        chatbot)
            app_file="chainlit_app_basic.py"
            image_name="basic"
            ;;
        rag)
            app_file="chainlit_app_rag.py"
            image_name="rag"
            ;;
        gateway)
            app_file="chainlit_app_gateway.py"
            image_name="gateway"
            ;;
        *)
            echo "Unsupported agentcore step: $step"
            exit 1
            ;;
    esac

    local_tag="agentcore-backend:${step}"
    remote_tag="public.ecr.aws/${PUBLIC_ECR_ALIAS}/agentcore-backend/${image_name}:latest"

    echo
    echo "Publishing agentcore step: $step"
    echo "Target image: $remote_tag"

    docker build --platform linux/amd64 \
        --build-arg CHAINLIT_APP_FILE="${app_file}" \
        -t "${local_tag}" ./agentcore-backend

    docker tag "${local_tag}" "${remote_tag}"
    docker push "${remote_tag}"
}

publish_helpdesk_image() {
    local local_tag remote_tag

    local_tag="it-helpdesk-api:latest"
    remote_tag="public.ecr.aws/${PUBLIC_ECR_ALIAS}/it-helpdesk-api:latest"

    echo
    echo "Publishing helpdesk image"
    echo "Target image: $remote_tag"

    docker build --platform linux/amd64 -t "${local_tag}" ./it-helpdesk-api
    docker tag "${local_tag}" "${remote_tag}"
    docker push "${remote_tag}"
}

echo "Logging in to public ECR"
aws ecr-public get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin public.ecr.aws

case "$TARGET" in
    chatbot|rag|gateway)
        publish_agentcore_image "$TARGET"
        ;;
    helpdesk)
        publish_helpdesk_image
        ;;
    all)
        publish_agentcore_image "chatbot"
        publish_agentcore_image "rag"
        publish_agentcore_image "gateway"
        publish_helpdesk_image
        ;;
esac

echo
echo "Public ECR publish completed."
