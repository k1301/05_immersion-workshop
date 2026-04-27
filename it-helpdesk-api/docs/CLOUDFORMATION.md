# CloudFormation을 사용한 인프라 자동 배포

이 가이드는 AWS CloudFormation을 사용하여 **전체 인프라를 한 번에 자동으로 생성**하는 방법을 설명합니다.

## 🎯 생성되는 리소스

CloudFormation 스택이 다음 모든 리소스를 자동으로 생성합니다:

### 네트워킹
- ✅ **Application Load Balancer** (ALB) - 고정 DNS 제공
- ✅ **Target Group** - Health check 포함
- ✅ **Security Groups** - ALB용, ECS Task용

### 컨테이너 & 컴퓨팅
- ✅ **ECR Repository** - Docker 이미지 저장소
- ✅ **ECS Cluster** - Container Insights 활성화
- ✅ **ECS Task Definition** - Fargate 기반
- ✅ **ECS Service** - ALB 연결, Auto-scaling 준비

### 모니터링 & 보안
- ✅ **CloudWatch Logs** - 애플리케이션 로그
- ✅ **IAM Roles** - Task Execution, Task Role

---

## 🚀 빠른 시작 (자동 스크립트)

### 1단계: 스크립트 실행

```bash
cd ~/it-helpdesk-api
./deploy-cloudformation.sh
```

스크립트가 자동으로:
1. AWS 계정 확인
2. 기본 VPC 및 Subnet 찾기
3. 파라미터 입력 받기
4. CloudFormation 스택 생성
5. 완료 시 Outputs 표시

### 2단계: Docker 이미지 빌드 및 푸시

스택 생성 후 ECR URI를 사용하여:

```bash
# ECR 로그인
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  $(aws cloudformation describe-stacks \
    --stack-name helpdesk-api-stack \
    --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" \
    --output text)

# 이미지 빌드
docker build -t it-helpdesk-api .

# 이미지 태그
ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" \
  --output text)

docker tag it-helpdesk-api:latest $ECR_URI:latest

# ECR에 푸시
docker push $ECR_URI:latest
```

### 3단계: 스택 업데이트 (ECS Service 생성)

```bash
# 다시 스크립트 실행하고 Container Image URI 입력
./deploy-cloudformation.sh
```

---

## 📝 수동 배포 (AWS CLI)

### 1단계: VPC 및 Subnet 확인

```bash
# 기본 VPC 찾기
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true"

# Public Subnets 찾기 (최소 2개 필요)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-xxxxx" \
  --query "Subnets[?MapPublicIpOnLaunch==\`true\`].[SubnetId,AvailabilityZone]"
```

### 2단계: 스택 생성 (이미지 없이)

```bash
aws cloudformation create-stack \
  --stack-name helpdesk-api-stack \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxx \
    ParameterKey=PublicSubnet1,ParameterValue=subnet-xxxxx \
    ParameterKey=PublicSubnet2,ParameterValue=subnet-yyyyy \
    ParameterKey=DesiredCount,ParameterValue=1 \
  --capabilities CAPABILITY_NAMED_IAM

# 완료 대기
aws cloudformation wait stack-create-complete \
  --stack-name helpdesk-api-stack
```

### 3단계: Outputs 확인

```bash
aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs"
```

**중요한 Outputs:**
- `ECRRepositoryUri` - Docker 이미지 푸시할 URI
- `ALBDNSName` - Bedrock Gateway에 연결할 DNS
- `ALBURL` - API 테스트용 URL

### 4단계: Docker 이미지 푸시 (위와 동일)

### 5단계: 스택 업데이트 (ECS Service 생성)

```bash
# ECR URI 가져오기
ECR_URI=$(aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ECRRepositoryUri'].OutputValue" \
  --output text)

# 스택 업데이트
aws cloudformation update-stack \
  --stack-name helpdesk-api-stack \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=VpcId,UsePreviousValue=true \
    ParameterKey=PublicSubnet1,UsePreviousValue=true \
    ParameterKey=PublicSubnet2,UsePreviousValue=true \
    ParameterKey=ContainerImage,ParameterValue=$ECR_URI:latest \
    ParameterKey=DesiredCount,UsePreviousValue=true \
  --capabilities CAPABILITY_NAMED_IAM

# 완료 대기
aws cloudformation wait stack-update-complete \
  --stack-name helpdesk-api-stack
```

---

## 🧪 테스트

### API 테스트

```bash
# ALB URL 가져오기
ALB_URL=$(aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ALBURL'].OutputValue" \
  --output text)

# 티켓 목록 조회
curl $ALB_URL/tickets | jq

# Swagger UI
echo "Swagger UI: $ALB_URL/docs"
```

### Health Check 확인

```bash
# Target Group Health
aws elbv2 describe-target-health \
  --target-group-arn $(aws cloudformation describe-stacks \
    --stack-name helpdesk-api-stack \
    --query "Stacks[0].Outputs[?OutputKey=='TargetGroupArn'].OutputValue" \
    --output text)
```

---

## 🔗 Bedrock Agent Core Gateway 연결

### 1단계: ALB DNS 확인

```bash
aws cloudformation describe-stacks \
  --stack-name helpdesk-api-stack \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDNSName'].OutputValue" \
  --output text
```

**예시 출력:**
```
helpdesk-api-alb-1234567890.us-east-1.elb.amazonaws.com
```

### 2단계: OpenAPI 스펙 업데이트

`openapi.json` 파일의 서버 URL을 ALB DNS로 업데이트:

```json
{
  "servers": [
    {
      "url": "http://helpdesk-api-alb-1234567890.us-east-1.elb.amazonaws.com",
      "description": "Production ALB"
    }
  ]
}
```

### 3단계: Bedrock Console에서 Gateway 설정

1. AWS Console → Bedrock → Agent Core → Gateways
2. **Create Gateway**
3. Gateway 설정:
   - Name: `it-helpdesk-gateway`
   - OpenAPI Spec: `openapi.json` 업로드
   - API Endpoint: `http://ALB_DNS_NAME`
4. **Create**

### 4단계: Agent에서 Gateway 연결

LangGraph나 다른 Agent 프레임워크에서:
- Gateway Endpoint 사용
- MCP tool로 헬프데스크 API 호출

---

## 🔄 업데이트 및 관리

### 코드 업데이트 후 새 버전 배포

```bash
# 1. 새 이미지 빌드 및 푸시
docker build -t it-helpdesk-api .
docker tag it-helpdesk-api:latest $ECR_URI:v2
docker push $ECR_URI:v2

# 2. Task Definition 업데이트
# cloudformation.yaml의 ContainerImage 파라미터를 v2로 변경하거나

# 3. ECS Service 강제 재배포
aws ecs update-service \
  --cluster helpdesk-cluster \
  --service helpdesk-api-service \
  --force-new-deployment
```

### Task 개수 조정 (스케일링)

```bash
aws cloudformation update-stack \
  --stack-name helpdesk-api-stack \
  --template-body file://cloudformation.yaml \
  --parameters \
    ParameterKey=VpcId,UsePreviousValue=true \
    ParameterKey=PublicSubnet1,UsePreviousValue=true \
    ParameterKey=PublicSubnet2,UsePreviousValue=true \
    ParameterKey=ContainerImage,UsePreviousValue=true \
    ParameterKey=DesiredCount,ParameterValue=3 \
  --capabilities CAPABILITY_NAMED_IAM
```

### 로그 확인

```bash
# CloudWatch Logs
aws logs tail /ecs/it-helpdesk-api --follow

# 또는 AWS Console
echo "CloudWatch Logs: https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#logsV2:log-groups/log-group//ecs/it-helpdesk-api"
```

---

## 🗑️ 리소스 삭제

### 전체 스택 삭제

```bash
aws cloudformation delete-stack --stack-name helpdesk-api-stack

# 완료 대기
aws cloudformation wait stack-delete-complete \
  --stack-name helpdesk-api-stack
```

**주의:** 
- ECR Repository의 이미지는 자동 삭제되지 않을 수 있습니다
- 수동으로 이미지를 삭제하거나 Lifecycle Policy가 처리합니다

---

## 🔧 트러블슈팅

### 스택 생성 실패

```bash
# 스택 이벤트 확인
aws cloudformation describe-stack-events \
  --stack-name helpdesk-api-stack \
  --max-items 10

# 실패한 리소스 확인
aws cloudformation describe-stack-resources \
  --stack-name helpdesk-api-stack \
  --query "StackResources[?ResourceStatus=='CREATE_FAILED']"
```

**흔한 오류:**
1. **VPC/Subnet 없음** - 기본 VPC가 없거나 Public Subnet이 부족
2. **IAM 권한 부족** - CAPABILITY_NAMED_IAM 필요
3. **이미지 없음** - ContainerImage 파라미터 없이 ECS Service 생성 시도

### ECS Task 시작 실패

```bash
# Task 실패 이유 확인
aws ecs describe-tasks \
  --cluster helpdesk-cluster \
  --tasks $(aws ecs list-tasks \
    --cluster helpdesk-cluster \
    --service-name helpdesk-api-service \
    --query "taskArns[0]" --output text) \
  --query "tasks[0].stoppedReason"
```

### ALB Health Check 실패

```bash
# Security Group 확인
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=helpdesk-api-ecs-sg"

# ECS Task가 8000 포트를 listen하고 있는지 확인
# Task에 접속하여 curl http://localhost:8000/ 테스트
```

---

## 💰 비용 추정

### Fargate (1 Task, 0.25 vCPU, 0.5 GB 메모리)
- 시간당: ~$0.01
- 월간: ~$7.50

### Application Load Balancer
- 시간당: ~$0.0225
- 월간: ~$16.50

### CloudWatch Logs (7일 보관)
- 월간: ~$0.50 (1GB 기준)

**총 예상 비용:** ~$25/월 (1 Task 기준)

---

## 📚 참고 자료

- [AWS CloudFormation 문서](https://docs.aws.amazon.com/cloudformation/)
- [ECS Fargate 가격](https://aws.amazon.com/fargate/pricing/)
- [ALB 가격](https://aws.amazon.com/elasticloadbalancing/pricing/)
- [Bedrock Agent Core Gateway 문서](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway.html)
