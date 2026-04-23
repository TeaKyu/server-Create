# dev/prod 환경 분리 가이드

01-배포-가이드.md 완료 상태에서 이미지 태그 기반으로 dev/prod 환경을 분리하는 가이드.

---

## 전제 조건

| 항목 | 상태 |
|------|------|
| 01-배포-가이드.md | 완료 (dev 환경 배포 정상 동작) |
| ArgoCD Application | `insideinfo-api-dev`, `insideinfo-web-dev` Running |
| gitops 레포 | `main` 브랜치에 push 완료 |
| Jenkins | Docker 이미지 빌드 → GitLab registry push 중 |

---

## 환경 분리 전략

**소스 레포 (api, web)**: `dev` / `main` 브랜치 분리
**gitops 레포**: `dev` / `main` 브랜치 분리, values 디렉토리로 환경 구분
**이미지 태그**: 환경 prefix + 날짜 기반 버전 태그 (`dev-yyyyMMdd-HHmm` / `prod-yyyyMMdd-HHmm`)
**자동 배포**: ArgoCD Image Updater 가 **dev/prod 양쪽 모두** 태그를 감지해 gitops values 를 갱신.
  - dev: Application 이 자동 Sync → 즉시 배포
  - prod: Application 은 수동 Sync → 담당자 승인 후 배포

> Image Updater 설정 상세: 04-이미지-자동배포-가이드.md

```
소스 레포 (insideinfo-api, insideinfo-web):
├── dev  브랜치 → Jenkins 빌드 → 이미지:dev-버전태그 push  → Image Updater 감지 → gitops dev  → 자동 Sync
└── main 브랜치 → Jenkins 빌드 → 이미지:prod-버전태그 push → Image Updater 감지 → gitops main → 수동 Sync

gitops 레포 (insideinfo-gitops):
├── dev  브랜치 → Image Updater 가 values/dev/*  자동 갱신
└── main 브랜치 → Image Updater 가 values/prod/* 자동 갱신 (Sync 만 수동)
```

| 항목 | dev | prod |
|------|-----|------|
| 소스 브랜치 | `dev` | `main` (MR 승인 후) |
| 이미지 태그 | `:dev-버전태그` (Image Updater 자동) | `:prod-버전태그` (Image Updater 자동) |
| gitops 브랜치 | `dev` (Image Updater 관리) | `main` (Image Updater 관리) |
| ArgoCD sync | 자동 (prune + selfHeal) | 수동 (ArgoCD UI / CLI) |
| 네임스페이스 | insideinfo | insideinfo |
| DB | 동일 (INSIDEDB) | 동일 (INSIDEDB) |

---

## Step 1: 소스 레포에 dev 브랜치 생성

GitLab UI 또는 로컬에서 `insideinfo-api`, `insideinfo-web` 레포에 `dev` 브랜치를 생성한다.

### 방법 1: GitLab UI

각 레포 페이지 → 브랜치 드롭다운 → `dev` 입력 → **Create branch: dev from main** 클릭

### 방법 2: 로컬

```bash
cd /path/to/insideinfo-api
git checkout main
git pull origin main
git checkout -b dev
git push origin dev
```

> **참고**: GitLab UI에서 브랜치를 만든 경우 로컬에서는 fetch만 하면 된다.
> ```bash
> git fetch origin
> git checkout dev
> ```

---

## Step 2: Jenkins Pipeline 설정

기존 Pipeline Job에 **BRANCH 파라미터**를 추가하여 dev/main 브랜치를 선택 빌드한다.

### 2-1. Pipeline Job 설정

1. Jenkins 대시보드 → 기존 Pipeline Job 클릭 → **Configure**
2. **이 빌드는 매개변수가 있습니다** 체크
3. **Choice Parameter** 추가:

| 항목 | 값 |
|------|-----|
| Name | `BRANCH` |
| Choices | `dev` (한 줄에 하나씩, dev가 첫 번째 = 기본값) |
|         | `main` |
| Description | `빌드할 브랜치를 선택하세요` |

4. Pipeline 스크립트를 아래 Step 3의 Jenkinsfile로 교체
5. **Save**

> **참고**: 파라미터 없이 빌드하면 첫 번째 항목인 `dev`가 기본 선택된다.

---

## Step 3: Jenkins Pipeline 스크립트

Jenkins Pipeline 스크립트에 Jenkinsfile 내용을 입력한다.
참고 파일: `insideinfo-deploy/Jenkinsfile-api`, `insideinfo-deploy/Jenkinsfile-web`

### 3-1. insideinfo-api Jenkinsfile

```groovy
pipeline {
    agent any
    tools {
        gradle 'gradle-8.14'
        jdk 'jdk-21'
    }
    parameters {
        // dev / main 둘 다 Image Updater 가 자동 감지 (dev-* / prod-* 태그로 구분)
        // dev  → gitops dev  브랜치 업데이트 → ArgoCD 자동 Sync
        // main → gitops main 브랜치 업데이트 → ArgoCD 수동 Sync
        choice(name: 'BRANCH', choices: ['dev', 'main'], description: '빌드할 브랜치를 선택하세요')
    }
    environment {
        REGISTRY_URL = "gitlab.insideinfo.co.kr:5005"
        IMAGE_PATH   = "ax-2/insideinfo-api"
        IMAGE_NAME   = "${REGISTRY_URL}/${IMAGE_PATH}/insideinfo-api"
        CHECKOUT_URL = "http://gitlab.insideinfo.co.kr/ax-2/insideinfo-api.git"
    }
    stages {
        stage('Source Build') {
            steps {
                sh "git config --global http.sslVerify false"
                git branch: "${params.BRANCH}",
                url: "${CHECKOUT_URL}", credentialsId: 'gitlab-backend'
                sh "chmod +x ./gradlew"
                sh "gradle clean build"
                sh "cp ./build/libs/*.jar ./"
                script {
                    // 브랜치별 prefix → Image Updater 의 allowTags regex 와 매칭
                    def envPrefix = params.BRANCH == 'main' ? 'prod' : 'dev'
                    env.VERSION = "${envPrefix}-" + new Date().format("yyyyMMdd-HHmm")
                }
            }
        }
        stage('Docker Image Build & Push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'gitlab-backend', passwordVariable: 'GIT_TOKEN', usernameVariable:
'GIT_USER')]){
                    script {
                        sh "echo \$GIT_TOKEN | docker login ${REGISTRY_URL} -u \$GIT_USER --password-stdin"

                        sh "docker build -t ${IMAGE_NAME}:${env.VERSION} ."
                        sh "docker push ${IMAGE_NAME}:${env.VERSION}"

                        // dev  → Image Updater 가 dev-* 태그 감지 → gitops dev  브랜치 업데이트 → ArgoCD 자동 Sync
                        // main → Image Updater 가 prod-* 태그 감지 → gitops main 브랜치 업데이트 → ArgoCD 수동 Sync
                    }
                }
            }
        }
    }
    post {
        always {
            script {
                // Docker 로그아웃
                sh "docker logout ${REGISTRY_URL} || true"

                // 방금 빌드한 이미지 삭제
                sh "docker rmi ${IMAGE_NAME}:${env.VERSION} || true"
                sh "docker image prune -f || true"

                // 워크스페이스에 복사한 jar 파일 삭제
                sh "rm -f *.jar"

                // 워크스페이스 전체 정리 (필요시 주석 해제)
                // cleanWs()
            }
        }
    }
}
```

### 3-2. insideinfo-web Jenkinsfile

```groovy
pipeline {
    agent any
    tools {
        nodejs 'nodejs-24'
    }
    parameters {
        choice(name: 'BRANCH', choices: ['dev', 'main'], description: '빌드할 브랜치를 선택하세요')
    }
    environment {
        REGISTRY_URL = "gitlab.insideinfo.co.kr:5005"
        IMAGE_PATH   = "ax-2/insideinfo-web"
        IMAGE_NAME   = "${REGISTRY_URL}/${IMAGE_PATH}/insideinfo-web"
        CHECKOUT_URL = "http://gitlab.insideinfo.co.kr/ax-2/insideinfo-web.git"
    }
    stages {
        stage('Source Build') {
            steps {
                sh "git config --global http.sslVerify false"
                git branch: "${params.BRANCH}",
                url: "${CHECKOUT_URL}", credentialsId: 'gitlab-frontend'
                script {
                    // 브랜치별 prefix → Image Updater 의 allowTags regex 와 매칭
                    def envPrefix = params.BRANCH == 'main' ? 'prod' : 'dev'
                    env.VERSION = "${envPrefix}-" + new Date().format("yyyyMMdd-HHmm")
                    // SSR 내부 API 호출 — main(prod) 빌드는 prod API, 그 외는 dev API (k8s 내부 DNS)
                    env.API_URL = params.BRANCH == 'main' ? 'http://insideinfo-api-prod:8080' : 'http://insideinfo-api-dev:8080'
                }
            }
        }
        stage('Docker Image Build & Push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'gitlab-frontend', passwordVariable: 'GIT_TOKEN', usernameVariable:
'GIT_USER')]){
                    script {
                        sh "echo \$GIT_TOKEN | docker login ${REGISTRY_URL} -u \$GIT_USER --password-stdin"

                        sh "docker build --build-arg NEXT_PUBLIC_API_URL=${env.API_URL} -t ${IMAGE_NAME}:${env.VERSION} ."
                        sh "docker push ${IMAGE_NAME}:${env.VERSION}"
                    }
                }
            }
        }
    }
    post {
        always {
            script {
                sh "docker logout ${REGISTRY_URL} || true"
                sh "docker rmi ${IMAGE_NAME}:${env.VERSION} || true"
                sh "docker image prune -f || true"
            }
        }
    }
}
```

### 3-3. api와 web 차이점

| 항목 | api | web |
|------|-----|-----|
| tools | gradle + jdk | nodejs |
| Source Build | `gradle clean build` | Docker 내에서 빌드 |
| IMAGE_PATH | `ax-2/insideinfo-api` | `ax-2/insideinfo-web` |
| build-arg | 없음 | `NEXT_PUBLIC_API_URL` 필요 |
| credentials | `gitlab-backend` | `gitlab-frontend` |

---

## Step 4: gitops values 파일 수정

gitops 레포는 `main` (prod values) / `dev` (dev values) 두 브랜치를 사용한다.
이미지 태그 초기값은 임의의 유효한 빌드 태그로 둔다 — 첫 Jenkins 빌드 이후 Image Updater 가 자동 갱신한다.

### 4-1. dev values 초기 태그

`apps/insideinfo-api/helm/values/dev/inside-api-values.yaml`:
```yaml
image:
  tag: "dev-20260415-1341"   # Image Updater 가 이후 최신 dev-* 태그로 자동 업데이트
```

`apps/insideinfo-web/helm/values/dev/inside-web-values.yaml`:
```yaml
image:
  tag: "dev-20260415-1341"   # Image Updater 가 이후 최신 dev-* 태그로 자동 업데이트
```

### 4-2. prod values 파일 생성

`apps/insideinfo-api/helm/values/prod/inside-api-values.yaml`:

```yaml
replicaCount: 1

image:
  repository: <GITLAB_REGISTRY>/ax-2/insideinfo-api/insideinfo-api
  pullPolicy: Always
  tag: "prod-20260415-1341"   # Image Updater 가 이후 최신 prod-* 태그로 자동 업데이트

fullnameOverride: insideinfo-api-prod

imagePullSecrets:
  - name: gitlab-registry-secret

serviceAccount:
  create: false
  automount: true
  annotations: {}
  name: ""

podAnnotations: {}
podLabels: {}
podSecurityContext: {}
securityContext: {}

service:
  type: ClusterIP
  port: 8080
  targetPort: 8080

httproute:
  enabled: true
  gatewayName: eg
  gatewayNamespace: default
  hostnames:
    - prod.insideinfo.api

resources:
  requests:
    memory: "512Mi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "2000m"

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 80

volumes:
  - name: secret-config
    secret:
      secretName: insideinfo-api-prod-config

volumeMounts:
  - name: secret-config
    mountPath: /app/config

nodeSelector: {}
tolerations: []
affinity: {}

configmap:
  data:
    properties:
      SPRING_PROFILES_ACTIVE: "prod"
      TZ: "Asia/Seoul"

secret:
  data:
    config:
      application-secret.yml: |
        spring:
          datasource:
            url: jdbc:mysql://<DB_IP>:<DB_PORT>/INSIDEDB?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8
            username: INSIDE
            password: 1qaz@WSX3edc
```

`apps/insideinfo-web/helm/values/prod/inside-web-values.yaml`:

```yaml
replicaCount: 1

image:
  repository: <GITLAB_REGISTRY>/ax-2/insideinfo-web/insideinfo-web
  pullPolicy: Always
  tag: "prod-20260415-1341"   # Image Updater 가 이후 최신 prod-* 태그로 자동 업데이트

fullnameOverride: insideinfo-web-prod

imagePullSecrets:
  - name: gitlab-registry-secret

serviceAccount:
  create: false
  automount: true
  annotations: {}
  name: ""

podAnnotations: {}
podLabels: {}
podSecurityContext: {}
securityContext: {}

service:
  type: ClusterIP
  port: 3000
  targetPort: 3000

httproute:
  enabled: true
  gatewayName: eg
  gatewayNamespace: default
  hostnames:
    - prod.insideinfo

resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "500m"

autoscaling:
  enabled: false
  minReplicas: 1
  maxReplicas: 4
  targetCPUUtilizationPercentage: 80

volumes: []
volumeMounts: []

nodeSelector: {}
tolerations: []
affinity: {}

configmap:
  data:
    properties:
      NEXT_PUBLIC_API_URL: "http://insideinfo-api-prod:8080"
      PORT: "3000"
```

> **주의**: `NEXT_PUBLIC_API_URL`이 `insideinfo-api-prod`를 가리켜야 한다. dev와 다름.

---

## Step 5: prod ArgoCD Application 매니페스트 생성

### 5-1. API prod Application

`apps/insideinfo-api/argocd/application-prod.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: insideinfo-api-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <GITOPS_REPO_URL>
    targetRevision: main             # gitops main 브랜치
    path: apps/insideinfo-api/helm
    helm:
      valueFiles:
        - values/prod/inside-api-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: insideinfo
  syncPolicy:                        # 자동 sync 없음 = 수동
    syncOptions:
      - CreateNamespace=true
```

### 5-2. Web prod Application

`apps/insideinfo-web/argocd/application-prod.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: insideinfo-web-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <GITOPS_REPO_URL>
    targetRevision: main             # gitops main 브랜치
    path: apps/insideinfo-web/helm
    helm:
      valueFiles:
        - values/prod/inside-web-values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: insideinfo
  syncPolicy:                        # 자동 sync 없음 = 수동
    syncOptions:
      - CreateNamespace=true
```

### 5-3. dev Application 확인

`application-dev.yaml`의 `targetRevision`은 `dev` 브랜치를 바라본다.
Image Updater가 dev 브랜치의 values 파일을 자동 업데이트하고, ArgoCD가 자동 sync한다.

```yaml
# application-dev.yaml
spec:
  source:
    targetRevision: dev              # gitops dev 브랜치 (Image Updater가 관리)
    helm:
      valueFiles:
        - values/dev/inside-*-values.yaml
  syncPolicy:
    automated:                       # 자동 sync
      prune: true
      selfHeal: true
```

> **참고**: Image Updater 설정은 04-이미지-자동배포-가이드.md를 참고한다.

---

## Step 6: gitops 레포 push & ArgoCD 등록

```bash
cd /path/to/insideinfo-gitops

git add .
git commit -m "feat: dev/prod 환경 분리 (이미지 태그 기반)"
git -c http.sslVerify=false push origin main
```

서버에서:

```bash
cd /path/to/insideinfo-gitops
git -c http.sslVerify=false pull origin main

# prod app 신규 등록
kubectl apply -f apps/insideinfo-api/argocd/application-prod.yaml
kubectl apply -f apps/insideinfo-web/argocd/application-prod.yaml
```

확인:

```bash
kubectl get application -n argocd
```

기대 결과:

```
NAME                    SYNC STATUS   HEALTH STATUS
insideinfo-api-dev      Synced        Healthy
insideinfo-web-dev      Synced        Healthy
insideinfo-api-prod     OutOfSync     Missing        ← 수동 sync 대기
insideinfo-web-prod     OutOfSync     Missing        ← 수동 sync 대기
```

---

## Step 7: prod 첫 배포 (수동 Sync)

### 방법 1: ArgoCD Web UI

1. `http://argocd.local:30080` 접속
2. `insideinfo-api-prod` 클릭 → **SYNC** 버튼 클릭
3. `insideinfo-web-prod` 클릭 → **SYNC** 버튼 클릭

### 방법 2: CLI

```bash
argocd login argocd.local:30080 --username admin --password admin --insecure

argocd app sync insideinfo-api-prod
argocd app sync insideinfo-web-prod
```

---

## Step 8: 배포 확인

### 8-1. 파드 상태

```bash
kubectl get pods -n insideinfo
```

기대 결과:

```
NAME                                    READY   STATUS
insideinfo-api-dev-xxxxxxxxxx-xxxxx     1/1     Running
insideinfo-web-dev-xxxxxxxxxx-xxxxx     1/1     Running
insideinfo-api-prod-xxxxxxxxxx-xxxxx    1/1     Running
insideinfo-web-prod-xxxxxxxxxx-xxxxx    1/1     Running
```

### 8-2. 서비스 & HTTPRoute

```bash
kubectl get svc -n insideinfo
kubectl get httproute -n insideinfo
```

기대 결과:

| 서비스                 | 포트   | 호스트                       |
| ------------------- | ---- | ------------------------- |
| insideinfo-api-dev  | 8080 | dev.insideinfo.api      |
| insideinfo-web-dev  | 3000 | dev.insideinfo          |
| insideinfo-api-prod | 8080 | prod.insideinfo.api |
| insideinfo-web-prod | 3000 | prod.insideinfo     |

### 8-3. 이미지 태그 확인

```bash
# dev 파드 이미지 확인 → :dev 태그
kubectl get pods -n insideinfo -l app.kubernetes.io/name=insideinfo-api -o jsonpath='{.items[*].spec.containers[*].image}'

# prod 파드 이미지 확인 → :latest 태그
kubectl get pods -n insideinfo -l app.kubernetes.io/name=insideinfo-api -o jsonpath='{.items[*].spec.containers[*].image}'
```

### 8-4. 접속 테스트

`/etc/hosts`에 추가:

```
<K3S_NODE_IP>  prod.insideinfo.api prod.insideinfo   # 192.168.70.142
```

```bash
# dev 환경
curl http://dev.insideinfo.api:30080/actuator/health
curl -I http://dev.insideinfo:30080

# prod 환경
curl http://prod.insideinfo.api:30080/actuator/health
curl -I http://prod.insideinfo:30080
```

---

## 운영 워크플로우

### dev 배포 (자동)

```
Jenkins에서 BRANCH=dev 선택 → 빌드
  → Docker 이미지 빌드 → :dev-버전태그 push
  → ArgoCD Image Updater 가 dev-* 태그 감지 (2분 간격 폴링)
  → gitops dev 브랜치 values/dev/*-values.yaml 의 image.tag 자동 업데이트 (git commit & push)
  → ArgoCD dev Application 자동 Sync → 배포
```

### prod 배포 (수동 Sync)

```
dev에서 검증 완료
  → Jenkins에서 BRANCH=main 선택 → 빌드
  → Docker 이미지 빌드 → :prod-버전태그 push
  → ArgoCD Image Updater 가 prod-* 태그 감지 (2분 간격 폴링)
  → gitops main 브랜치 values/prod/*-values.yaml 의 image.tag 자동 업데이트 (git commit & push)
  → ArgoCD prod Application 이 OutOfSync 상태 → 담당자가 수동 Sync → 배포
```

또는 CLI:

```bash
argocd app sync insideinfo-api-prod
argocd app sync insideinfo-web-prod
```

> Image Updater 설정 상세: 04-이미지-자동배포-가이드.md

### 롤백

prod에서 문제 발생 시:

```bash
# ArgoCD에서 이전 버전으로 롤백
argocd app history insideinfo-api-prod
argocd app rollback insideinfo-api-prod <REVISION>

# 또는 이미지 태그를 특정 버전으로 변경
# values/prod/inside-api-values.yaml 에서:
#   tag: "latest" → "20260413-1430"
# gitops main에 push 후 수동 sync
```

---

## 이미지 관리 요약

```
같은 이미지 레포지토리, 환경 prefix + 날짜 버전 태그로 구분:

<GITLAB_REGISTRY>/ax-2/insideinfo-api/insideinfo-api:dev-20260414-1534   ← dev  (Image Updater → dev  브랜치 values 갱신 → 자동 Sync)
<GITLAB_REGISTRY>/ax-2/insideinfo-api/insideinfo-api:prod-20260414-1700  ← prod (Image Updater → main 브랜치 values 갱신 → 수동 Sync)
```

| 소스 브랜치 | Jenkins 트리거 | 이미지 태그 | Image Updater 감지 | ArgoCD |
|-------------|---------------|-------------|---------------------|--------|
| `dev` (파라미터 선택) | 수동 실행 | `:dev-버전태그` | values/dev 자동 갱신 | 자동 Sync |
| `main` (파라미터 선택) | 수동 실행 | `:prod-버전태그` | values/prod 자동 갱신 | 수동 Sync |

---

## 트러블슈팅

### prod Application이 OutOfSync 상태로 유지됨

정상이다. `automated` 없이 `syncOptions`만 설정했으므로 수동 Sync 전까지 OutOfSync 상태.

### dev와 prod 파드 동작이 다름

ConfigMap이 다르다. 확인:

```bash
kubectl get configmap insideinfo-web-dev -n insideinfo -o yaml
kubectl get configmap insideinfo-web-prod -n insideinfo -o yaml
```

`NEXT_PUBLIC_API_URL` 값이 각각 `-dev`, `-prod`를 가리키는지 확인.

### prod Sync 시 Secret 에러

`insideinfo-api-prod-config` Secret은 Helm 차트에서 자동 생성된다.
기존 `insideinfo-api-dev-config`과 이름이 다르므로 별도 관리됨.

### Jenkins SSL 인증서 오류

`server verification failed: certificate signer not trusted` 에러 발생 시:

```bash
# Jenkins 컨테이너에서 실행
docker exec jenkins git config --global http.sslVerify false
```

또는 Jenkins 관리 > System > Global properties > Environment variables 에 `GIT_SSL_NO_VERIFY=true` 추가.

### Image Updater로 dev 자동 배포가 안 됨

04-이미지-자동배포-가이드.md의 트러블슈팅 섹션을 참고한다.

---

## 최종 구조

### 소스 레포 (insideinfo-api, insideinfo-web)

```
insideinfo-api/
├── src/
├── build.gradle
├── Dockerfile
└── ...

브랜치:
├── dev   → Jenkins 파라미터 선택 빌드 → :버전태그
└── main  → Jenkins 파라미터 선택 빌드 → :버전태그
```

### gitops 레포 (insideinfo-gitops)

```
insideinfo-gitops/
├── dev  브랜치 (Image Updater 가 dev-*  태그 감지 후 자동 commit)
│   └── values/dev/  → image.tag 자동 업데이트
├── main 브랜치 (Image Updater 가 prod-* 태그 감지 후 자동 commit)
│   └── values/prod/ → image.tag 자동 업데이트 (Sync 만 수동)
│
├── apps/insideinfo-api/
│   ├── argocd/
│   │   ├── application-dev.yaml      ← dev  브랜치, 자동 Sync
│   │   ├── application-prod.yaml     ← main 브랜치, 수동 Sync
│   │   ├── image-updater-dev.yaml    ← Image Updater CR (dev-*  태그 감지 → values/dev)
│   │   └── image-updater-prod.yaml   ← Image Updater CR (prod-* 태그 감지 → values/prod)
│   └── helm/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── templates/
│       └── values/
│           ├── dev/inside-api-values.yaml
│           └── prod/inside-api-values.yaml
├── apps/insideinfo-web/
│   ├── argocd/
│   │   ├── application-dev.yaml      ← dev  브랜치, 자동 Sync
│   │   ├── application-prod.yaml     ← main 브랜치, 수동 Sync
│   │   ├── image-updater-dev.yaml    ← Image Updater CR (dev-*  태그 감지 → values/dev)
│   │   └── image-updater-prod.yaml   ← Image Updater CR (prod-* 태그 감지 → values/prod)
│   └── helm/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── templates/
│       └── values/
│           ├── dev/inside-web-values.yaml
│           └── prod/inside-web-values.yaml
```

### 전체 아키텍처

```
[dev 배포 — 전 과정 자동]

Jenkins (BRANCH=dev 선택)
  → Docker 이미지:dev-버전태그 push → GitLab Registry
                                         │
                                         ▼
                         ArgoCD Image Updater (dev-* regex, 2분 폴링)
                                         │
                                         ▼
                         gitops dev 브랜치 values/dev/* image.tag 자동 커밋
                                         │
                                         ▼
                         ArgoCD insideinfo-*-dev Application (자동 Sync)
                                         │
                                         ▼
                         insideinfo-*-dev (k8s)

[prod 배포 — Sync 만 수동]

Jenkins (BRANCH=main 선택)
  → Docker 이미지:prod-버전태그 push → GitLab Registry
                                         │
                                         ▼
                         ArgoCD Image Updater (prod-* regex, 2분 폴링)
                                         │
                                         ▼
                         gitops main 브랜치 values/prod/* image.tag 자동 커밋
                                         │
                                         ▼
                         ArgoCD insideinfo-*-prod Application (OutOfSync)
                                         │
                                         ▼  ← 담당자가 ArgoCD UI / CLI 로 수동 Sync
                         insideinfo-*-prod (k8s)
```

```
브라우저
  │
  ▼
Envoy Gateway (NodePort 30080)
  │
  ├─ Host: dev.insideinfo          → insideinfo-web-dev:3000
  ├─ Host: dev.insideinfo.api      → insideinfo-api-dev:8080
  ├─ Host: prod.insideinfo         → insideinfo-web-prod:3000
  └─ Host: prod.insideinfo.api     → insideinfo-api-prod:8080
                                           │
                                           ▼
                                      MySQL (INSIDEDB) ← 동일 DB
```

---

## 외부 IP 확보 후 도메인 변경

외부 IP가 확보되면 prod의 hostname을 실제 도메인으로 변경한다.

`values/prod/inside-api-values.yaml`:
```yaml
httproute:
  hostnames:
    - api.insideinfo.co.kr       # 실제 운영 도메인
```

`values/prod/inside-web-values.yaml`:
```yaml
httproute:
  hostnames:
    - insideinfo.co.kr           # 실제 운영 도메인
```

gitops main에 push 후 ArgoCD에서 수동 Sync.

---

## 설정값 참조

01-배포-가이드.md의 설정값 표를 참고한다. 추가 변수:

| 변수 | 설명 | 현재 값 |
|------|------|---------|
| `prod.insideinfo.api` | prod API 내부 테스트 도메인 | 외부 IP 확보 후 실제 도메인으로 변경 |
| `prod.insideinfo` | prod Web 내부 테스트 도메인 | 외부 IP 확보 후 실제 도메인으로 변경 |
