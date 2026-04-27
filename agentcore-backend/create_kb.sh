#!/bin/bash
set -e

# Bedrock Knowledge Base 생성 스크립트 (S3 Vector Store)

REGION="us-east-1"
KB_NAME="agent-kb"
S3_BUCKET="agent-kb-docs-<YOUR_ACCOUNT_ID>"
S3_PREFIX="kb_docs/"
EMBEDDING_MODEL="amazon.titan-embed-text-v2:0"

echo "🚀 Bedrock Knowledge Base 생성 중..."
echo "   Vector Store: S3"
echo "   Bucket: ${S3_BUCKET}"
echo "   Region: ${REGION}"
echo ""

# IAM Role for Bedrock KB
ROLE_NAME="BedrockKBRole-${KB_NAME}"
echo "📋 Step 1: IAM Role 생성..."

# Trust policy
cat > /tmp/kb-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create IAM role
ROLE_ARN=$(aws iam create-role \
  --role-name ${ROLE_NAME} \
  --assume-role-policy-document file:///tmp/kb-trust-policy.json \
  --query 'Role.Arn' \
  --output text 2>/dev/null || aws iam get-role --role-name ${ROLE_NAME} --query 'Role.Arn' --output text)

echo "✅ Role ARN: ${ROLE_ARN}"

# Attach S3 policy
echo "📋 Step 2: S3 권한 추가..."
cat > /tmp/kb-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-name KBS3Access \
  --policy-document file:///tmp/kb-s3-policy.json

# Attach Bedrock policy
aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess

echo "✅ IAM 권한 설정 완료"
echo ""
echo "⏳ IAM Role 전파 대기 (10초)..."
sleep 10

# Create Knowledge Base with S3 storage
echo "📋 Step 3: Knowledge Base 생성..."

KB_CONFIG=$(cat <<EOF
{
  "name": "${KB_NAME}",
  "description": "Enterprise Agent Knowledge Base with S3 Vector Store",
  "roleArn": "${ROLE_ARN}",
  "knowledgeBaseConfiguration": {
    "type": "VECTOR",
    "vectorKnowledgeBaseConfiguration": {
      "embeddingModelArn": "arn:aws:bedrock:${REGION}::foundation-model/${EMBEDDING_MODEL}",
      "embeddingModelConfiguration": {
        "bedrockEmbeddingModelConfiguration": {
          "dimensions": 1024
        }
      }
    }
  },
  "storageConfiguration": {
    "type": "S3_VECTORS",
    "s3VectorsConfiguration": {
      "vectorBucketArn": "arn:aws:s3:::${S3_BUCKET}",
      "indexName": "enterprise-agent-vector-index"
    }
  }
}
EOF
)

KB_RESPONSE=$(aws bedrock-agent create-knowledge-base \
  --region ${REGION} \
  --cli-input-json "${KB_CONFIG}")

KB_ID=$(echo ${KB_RESPONSE} | jq -r '.knowledgeBase.knowledgeBaseId')
echo "✅ Knowledge Base 생성 완료!"
echo "   KB ID: ${KB_ID}"
echo ""

# Create Data Source
echo "📋 Step 4: Data Source 추가..."

DS_CONFIG=$(cat <<EOF
{
  "knowledgeBaseId": "${KB_ID}",
  "name": "company-docs",
  "description": "Company guideline documents",
  "dataSourceConfiguration": {
    "type": "S3",
    "s3Configuration": {
      "bucketArn": "arn:aws:s3:::${S3_BUCKET}",
      "inclusionPrefixes": ["${S3_PREFIX}"]
    }
  },
  "vectorIngestionConfiguration": {
    "chunkingConfiguration": {
      "chunkingStrategy": "FIXED_SIZE",
      "fixedSizeChunkingConfiguration": {
        "maxTokens": 300,
        "overlapPercentage": 20
      }
    }
  }
}
EOF
)

DS_RESPONSE=$(aws bedrock-agent create-data-source \
  --region ${REGION} \
  --cli-input-json "${DS_CONFIG}")

DS_ID=$(echo ${DS_RESPONSE} | jq -r '.dataSource.dataSourceId')
echo "✅ Data Source 생성 완료!"
echo "   Data Source ID: ${DS_ID}"
echo ""

# Start ingestion job
echo "📋 Step 5: 문서 인덱싱 시작..."

INGESTION_RESPONSE=$(aws bedrock-agent start-ingestion-job \
  --region ${REGION} \
  --knowledge-base-id ${KB_ID} \
  --data-source-id ${DS_ID})

INGESTION_JOB_ID=$(echo ${INGESTION_RESPONSE} | jq -r '.ingestionJob.ingestionJobId')
echo "✅ 인덱싱 작업 시작!"
echo "   Job ID: ${INGESTION_JOB_ID}"
echo ""

# Wait for ingestion to complete
echo "⏳ 인덱싱 완료 대기 중..."
while true; do
  STATUS=$(aws bedrock-agent get-ingestion-job \
    --region ${REGION} \
    --knowledge-base-id ${KB_ID} \
    --data-source-id ${DS_ID} \
    --ingestion-job-id ${INGESTION_JOB_ID} \
    --query 'ingestionJob.status' \
    --output text)

  echo "   상태: ${STATUS}"

  if [ "${STATUS}" == "COMPLETE" ]; then
    echo "✅ 인덱싱 완료!"
    break
  elif [ "${STATUS}" == "FAILED" ]; then
    echo "❌ 인덱싱 실패"
    exit 1
  fi

  sleep 10
done

echo ""
echo "🎉 Knowledge Base 생성 완료!"
echo ""
echo "📝 생성된 리소스:"
echo "   Knowledge Base ID: ${KB_ID}"
echo "   Data Source ID: ${DS_ID}"
echo "   Role ARN: ${ROLE_ARN}"
echo ""
echo "🔗 .env에 추가할 설정:"
echo "BEDROCK_KB_ID=${KB_ID}"
echo ""

# Save KB ID to config
echo "" >> /Users/park/enterprise-agent-backend/.env
echo "# Bedrock Knowledge Base" >> /Users/park/enterprise-agent-backend/.env
echo "BEDROCK_KB_ID=${KB_ID}" >> /Users/park/enterprise-agent-backend/.env

echo "✅ .env 파일 업데이트 완료"
