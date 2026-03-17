1. base.sh  -> 기본세팅 및 도커 설치를 한다.
2. Dokerfile -> 이미지를 다운받아서 설치 및 진행한다.
3. Jenkins 관리 - Credentials
     docker_password > 도커허브 로그인 패스워드
     k8s_config > k8s 인증서 
4. Jenkinsfile -> 파이프라인 잰킨스 파일



# ======== 이전 도커설정 복원 하려면 =====
# 컨테이너에서 설정 tar 생성 (workspace, logs 등 불필요한 것 제외)
docker exec jenkins tar czf /tmp/jenkins_config.tar.gz \
  -C /var/jenkins_home \
  --exclude='workspace' \
  --exclude='caches' \
  --exclude='logs' \
  --exclude='.cache' \
  --exclude='war' \
  .

# 호스트로 복사
docker cp jenkins:/tmp/jenkins_config.tar.gz ./jenkins_config.tar.gz



# 이후에 도커파일이 해당 라인 추가

# 이전 Jenkins 설정 복원
COPY jenkins_config.tar.gz /tmp/jenkins_config.tar.gz
RUN tar xzf /tmp/jenkins_config.tar.gz -C /var/jenkins_home \
    && rm /tmp/jenkins_config.tar.gz \
    && chown -R jenkins:jenkins /var/jenkins_home
