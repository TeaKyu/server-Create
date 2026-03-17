# 1. 공식 젠킨스 LTS 이미지 사용
FROM jenkins/jenkins:latest

# 2. 설치를 위해 일시적으로 root 권한 획득
USER root

# 3. 필수 패키지 설치 및 도구 설치
RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
# Infisical CLI 설치
# && curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | bash \
# && apt-get install -y infisical \
# Docker CLI 설치
 && mkdir -p /usr/share/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y docker-ce-cli \
# Node.js 20.x 설치 (프론트엔드 빌드용)
 && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y nodejs \
# kubectl 설치
 && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" \
 && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
# Helm 설치
# && curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
# 정리 작업
 && rm kubectl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# docker 그룹 생성 및 jenkins 유저 추가 (GID는 호스트의 docker GID와 맞출 것)
RUN groupadd -g 989 docker && usermod -aG docker jenkins

# 4. 보안을 위해 다시 jenkins 사용자로 전환
USER jenkins

# 5. (선택) 젠킨스 플러그인 자동 설치
# RUN jenkins-plugin-cli --plugins "blueocean docker-workflow kubernetes"
