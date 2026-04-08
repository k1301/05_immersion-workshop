# ECS 배포 가이드

AWS ECS (Elastic Container Service)에 IT Helpdesk API를 배포하는 가이드입니다.

## 전제조건

- AWS CLI 설치 및 설정
- Docker 설치
- AWS 계정 및 적절한 권한 (ECS, ECR, IAM)

## 배포 아키텍처

```
GitHub Repository
      ↓
   Docker Build
      ↓
   Amazon ECR (Container Registry)
      ↓
   ECS Fargate Task
      ↓
   Application Load Balancer (선택사항)
      ↓
   Public Access
```

---

## 1단계: ECR Repository 생성

### AWS Console에서:
1. ECR Console → "Create repository"
2. Repository name: `it-helpdesk-api`
3. "Create repository"

### AWS CLI로:
```bash
aws ecr create-repository --repository-name it-helpdesk-api --region us-east-1
```

**Repository URI 저장:**
```
123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api
```

---

## 2단계: Docker 이미지 빌드 및 푸시

### 로컬에서:

```bash
# 프로젝트 디렉토리로 이동
cd ~/it-helpdesk-api

# ECR 로그인
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789012.dkr.ecr.us-east-1.amazonaws.com

# Docker 이미지 빌드
docker build -t it-helpdesk-api .

# 이미지 태그
docker tag it-helpdesk-api:latest \
  123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api:latest

# ECR에 푸시
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api:latest
```

**로컬 테스트:**
```bash
# Docker Compose로 테스트
docker-compose up

# 또는 직접 실행
docker run -p 8000:8000 it-helpdesk-api

# 브라우저에서 확인
open http://localhost:8000/docs
```

---

## 3단계: ECS Cluster 생성

### AWS Console에서:
1. ECS Console → "Clusters" → "Create cluster"
2. Cluster name: `helpdesk-cluster`
3. Infrastructure: **AWS Fargate (serverless)**
4. "Create"

### AWS CLI로:
```bash
aws ecs create-cluster --cluster-name helpdesk-cluster --region us-east-1
```

---

## 4단계: Task Definition 생성

### task-definition.json 파일 생성:

```json
{
  "family": "it-helpdesk-api",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::123456789012:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "helpdesk-api",
      "image": "123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "PYTHONUNBUFFERED",
          "value": "1"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/it-helpdesk-api",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8000/ || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 10
      }
    }
  ]
}
```

### CloudWatch Logs Group 생성:
```bash
aws logs create-log-group --log-group-name /ecs/it-helpdesk-api --region us-east-1
```

### Task Definition 등록:
```bash
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json \
  --region us-east-1
```

---

## 5단계: Security Group 설정

### Security Group 생성:
```bash
# VPC ID 확인
aws ec2 describe-vpcs

# Security Group 생성
aws ec2 create-security-group \
  --group-name helpdesk-api-sg \
  --description "Security group for IT Helpdesk API" \
  --vpc-id vpc-xxxxx

# 인바운드 규칙 추가 (포트 8000)
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxx \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0
```

---

## 6단계: ECS Service 생성

### AWS Console에서:
1. ECS Cluster → "Services" → "Create"
2. Launch type: **Fargate**
3. Task Definition: `it-helpdesk-api:1`
4. Service name: `helpdesk-api-service`
5. Number of tasks: `1`
6. Networking:
   - VPC: 기본 VPC 선택
   - Subnets: Public subnet 선택
   - Security group: 위에서 생성한 것 선택
   - **Auto-assign public IP: ENABLED**
7. "Create"

### AWS CLI로:
```bash
aws ecs create-service \
  --cluster helpdesk-cluster \
  --service-name helpdesk-api-service \
  --task-definition it-helpdesk-api:1 \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx],securityGroups=[sg-xxxxx],assignPublicIp=ENABLED}" \
  --region us-east-1
```

---

## 7단계: 퍼블릭 IP 확인 및 테스트

### Task의 퍼블릭 IP 확인:
```bash
# Task ARN 확인
aws ecs list-tasks --cluster helpdesk-cluster --service-name helpdesk-api-service

# Task 상세 정보
aws ecs describe-tasks --cluster helpdesk-cluster --tasks <task-arn>
```

**또는 AWS Console에서:**
1. ECS Cluster → Tasks → Task 클릭
2. "Network" 섹션에서 Public IP 확인

### 테스트:
```bash
# API 테스트
curl http://PUBLIC_IP:8000/

# Swagger UI
open http://PUBLIC_IP:8000/docs
```

---

## 8단계 (선택): Application Load Balancer 추가

프로덕션 환경에서는 ALB를 사용하는 것이 권장됩니다.

### ALB 생성:
1. EC2 Console → Load Balancers → "Create"
2. Type: **Application Load Balancer**
3. Name: `helpdesk-api-alb`
4. Scheme: **internet-facing**
5. Listeners: HTTP (80)
6. Target Group 생성:
   - Target type: **IP**
   - Protocol: HTTP
   - Port: 8000
   - Health check path: `/`

### ECS Service에 ALB 연결:
Service 업데이트 시 Load Balancer 설정 추가

---

## 9단계: 업데이트 배포

코드 변경 후 새 버전 배포:

```bash
# 1. 새 이미지 빌드 및 푸시
docker build -t it-helpdesk-api .
docker tag it-helpdesk-api:latest \
  123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api:v2
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/it-helpdesk-api:v2

# 2. Task Definition 업데이트 (이미지 버전 변경)
# task-definition.json에서 image 태그를 :v2로 변경

# 3. 새 Task Definition 등록
aws ecs register-task-definition \
  --cli-input-json file://task-definition.json

# 4. Service 업데이트
aws ecs update-service \
  --cluster helpdesk-cluster \
  --service helpdesk-api-service \
  --task-definition it-helpdesk-api:2 \
  --force-new-deployment
```

---

## 비용 최적화

### Fargate Spot 사용 (개발/테스트 환경):
```json
{
  "capacityProviderStrategy": [
    {
      "capacityProvider": "FARGATE_SPOT",
      "weight": 1
    }
  ]
}
```

### Task 크기 조정:
- 개발: CPU 256, Memory 512MB
- 프로덕션: CPU 512, Memory 1024MB

---

## 트러블슈팅

### Task가 시작되지 않는 경우:
```bash
# Task 이벤트 확인
aws ecs describe-tasks --cluster helpdesk-cluster --tasks <task-arn>

# CloudWatch Logs 확인
aws logs tail /ecs/it-helpdesk-api --follow
```

### 네트워크 연결 문제:
- Security Group의 인바운드 규칙 확인
- Public IP가 할당되었는지 확인
- Subnet이 Public인지 확인 (Internet Gateway 연결)

### 이미지 Pull 실패:
- ECR 권한 확인 (ecsTaskExecutionRole)
- 이미지 URI가 정확한지 확인

---

## 자동화 (CI/CD)

GitHub Actions 예시:

```yaml
name: Deploy to ECS

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      
      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v1
      
      - name: Build and push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          ECR_REPOSITORY: it-helpdesk-api
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
      
      - name: Deploy to ECS
        run: |
          aws ecs update-service \
            --cluster helpdesk-cluster \
            --service helpdesk-api-service \
            --force-new-deployment
```

---

## 참고 자료

- [AWS ECS Documentation](https://docs.aws.amazon.com/ecs/)
- [AWS Fargate Pricing](https://aws.amazon.com/fargate/pricing/)
- [ECS Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/)
