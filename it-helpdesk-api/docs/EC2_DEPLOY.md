# EC2 배포 가이드

## 1단계: EC2 인스턴스 생성

### AWS Console에서:
1. EC2 Console → "Launch Instance"
2. 설정:
   - **Name**: `it-helpdesk-api`
   - **AMI**: Amazon Linux 2023
   - **Instance type**: `t2.micro`
   - **Key pair**: 생성 또는 선택 (다운로드!)
   - **Security Group**:
     - SSH (22) - My IP
     - Custom TCP (8000) - 0.0.0.0/0
3. Launch Instance

## 2단계: 파일 업로드

### 로컬에서 실행:

```bash
# EC2 퍼블릭 IP 확인 (AWS Console에서)
export EC2_IP="YOUR_EC2_PUBLIC_IP"

# 파일 압축
cd ~/it-helpdesk-api
tar -czf api.tar.gz main.py models.py requirements.txt deploy.sh helpdesk-api.service

# EC2로 업로드
scp -i ~/.ssh/your-key.pem api.tar.gz ec2-user@$EC2_IP:~
```

## 3단계: EC2에서 설치

### EC2에 SSH 접속:

```bash
ssh -i ~/.ssh/your-key.pem ec2-user@$EC2_IP
```

### 설치 및 실행:

```bash
# 압축 해제
tar -xzf api.tar.gz
mkdir -p it-helpdesk-api
mv main.py models.py requirements.txt it-helpdesk-api/
cd it-helpdesk-api

# 배포 스크립트 실행
bash ../deploy.sh

# 가상환경 활성화
source venv/bin/activate

# 수동 테스트
uvicorn main:app --host 0.0.0.0 --port 8000
```

### 브라우저에서 확인:
```
http://YOUR_EC2_PUBLIC_IP:8000/docs
```

## 4단계: Systemd 서비스로 등록 (자동 시작)

```bash
# 서비스 파일 복사
sudo cp ../helpdesk-api.service /etc/systemd/system/

# Ubuntu를 사용하는 경우 User를 ubuntu로 변경
sudo sed -i 's/ec2-user/ubuntu/g' /etc/systemd/system/helpdesk-api.service

# 서비스 시작
sudo systemctl daemon-reload
sudo systemctl enable helpdesk-api
sudo systemctl start helpdesk-api

# 상태 확인
sudo systemctl status helpdesk-api
```

## 5단계: 테스트

```bash
# EC2 내부에서
curl http://localhost:8000/tickets | jq

# 로컬에서
curl http://YOUR_EC2_PUBLIC_IP:8000/tickets | jq
```

## 6단계: OpenAPI 스펙 업데이트

로컬에서 `openapi.json` 파일의 서버 URL을 업데이트:

```json
{
  "servers": [
    {
      "url": "http://YOUR_EC2_PUBLIC_IP:8000",
      "description": "EC2 Production Server"
    }
  ]
}
```

## 트러블슈팅

### 포트 8000이 막혀있는 경우:
```bash
# 보안 그룹 확인 (AWS Console)
# 또는 방화벽 확인
sudo firewall-cmd --list-all  # Amazon Linux
sudo ufw status                # Ubuntu
```

### 로그 확인:
```bash
# Systemd 서비스 로그
sudo journalctl -u helpdesk-api -f

# 또는 수동 실행으로 디버깅
cd ~/it-helpdesk-api
source venv/bin/activate
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### 서비스 재시작:
```bash
sudo systemctl restart helpdesk-api
```

## HTTPS 설정 (선택사항)

나중에 HTTPS가 필요하면:
1. 도메인 설정
2. Nginx 리버스 프록시 설치
3. Let's Encrypt SSL 인증서 발급

```bash
sudo yum install -y nginx certbot python3-certbot-nginx
# 또는
sudo apt install -y nginx certbot python3-certbot-nginx
```
