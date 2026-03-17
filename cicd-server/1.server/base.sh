## ============= 기본설정 START ==============

echo '======== [1] Rocky Linux 기본 설정 ========'
echo '======== [1-1] 패키지 업데이트 ========'
# 강의와 동일한 실습 환경을 유지하기 위해 Linux Update 주석 처리
# yum -y update

# 초기 root 비밀번호 변경을 원하시면 아래 주석을 풀고 [새로운비밀번호]에 비번을 입력해주세요
echo "root:1234" | chpasswd

echo '======== [1-2] 타임존 설정 및 동기화========'
timedatectl set-timezone Asia/Seoul
timedatectl set-ntp true

echo '======== [1-3] Disk 확장 설정 ========'
yum install -y cloud-utils-growpart
growpart /dev/sda 4
xfs_growfs /dev/sda4

echo '======== [1-4] 방화벽 해제 ========'
systemctl stop firewalld && systemctl disable firewalld


echo '======== [3] 도커 설치 ========'
# https://download.docker.com/linux/centos/8/x86_64/stable/Packages/ 저장소 경로
yum install -y yum-utils
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce-3:23.0.6-1.el8 docker-ce-cli-1:23.0.6-1.el8 containerd.io-1.6.21-3.1.el8
systemctl daemon-reload
systemctl enable --now docker



## ============= 기본설정 END ==============

# 도커 이미지 빌드
docker build -t jenkins .

# 도커 이미지 띄우기
#docker run -d -p 8080:8080 -p 50000:50000 -v /var/run/docker.sock:/var/run/docker.sock --name jenkins 0fb 
docker run -d --name jenkins \
  -p 8080:8080 \
  -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  my-jenkins:1.0


# 도커 권한 주기
chmod 666 /var/run/docker.sock
usermod -aG docker jenkins


