# 05. hostPath 경로 이전 가이드 (`/root` → `/home`)

## 개요

업로드 파일 저장 경로를 `/root/insideHomepage/upload/{dev,prod}/file` 에서
`/home/insideHomepage/upload/{dev,prod}/file` 로 이전하는 절차입니다.

| 환경 | 컨테이너 내부 | 기존 호스트 경로 | 신규 호스트 경로 |
|------|--------------|----------------|----------------|
| dev  | `/app/upload/file` | `/root/insideHomepage/upload/dev/file`  | `/home/insideHomepage/upload/dev/file`  |
| prod | `/app/upload/file` | `/root/insideHomepage/upload/prod/file` | `/home/insideHomepage/upload/prod/file` |

> ⚠️ k8s PV 의 `hostPath.path` 는 **immutable** 필드입니다.
> values 만 수정하고 Argo sync 를 돌리면 실패하므로, **PV/PVC 삭제 → 재생성** 이 필요합니다.
> PV/PVC 오브젝트만 삭제하는 것이며, 호스트의 실제 파일은 삭제되지 않습니다.

---

## 사전 준비 — 다운타임 공지

- PV 재생성 중 파드는 Pending 상태가 되어 파일 업/다운로드가 중단됩니다.
- dev 먼저 진행하여 검증 후 prod 를 진행하는 것을 권장합니다.

---

## 사전 준비 — 오브젝트 이름 조회

본 가이드의 명령어에서 사용하는 플레이스홀더입니다. 작업 전에 모두 확인해두세요.

| 플레이스홀더          | 설명                           | 조회 명령                                                  |
| --------------- | ---------------------------- | ------------------------------------------------------ |
| `<namespace>`   | insideinfo-api 가 배포된 네임스페이스  | `kubectl get ns \| grep -i inside`                     |
| `<pv-name>`     | 업로드용 PV 오브젝트 이름              | `kubectl get pv \| grep insideinfo`                    |
| `<pvc-name>`    | 업로드용 PVC 오브젝트 이름             | `kubectl get pvc -A \| grep insideinfo`                |
| `<deploy-name>` | insideinfo-api Deployment 이름 | `kubectl -n <namespace> get deploy \| grep insideinfo` |
| `<노드-hostname>` | PV 가 바라보는 워커 노드 hostname     | `kubectl get nodes -o wide`                            |

```bash
# namespace 단독 조회
kubectl get ns | grep -i <project-name> # inside

# PVC + namespace 한 번에 (NAMESPACE / NAME 컬럼 확인)
kubectl get pvc -A | grep <project-name>  # insideinfo

# PV 이름 조회
kubectl get pv | grep <project-name>  # insideinfo

# PV 로부터 <namespace>/<pvc-name> 역조회
kubectl get pv <pv-name> \
  -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}'

# Deployment 이름 조회
kubectl -n <namespace> get deploy | grep insideinfo

# 노드 hostname (values 의 persistence.nodeNames 와 동일해야 함)
kubectl get nodes -o wide

# (참고) ArgoCD 로 관리 중이면 destination namespace 확인
argocd app list | grep insideinfo
argocd app get <app-name> | grep -i namespace
```

> 이 프로젝트 기준 기본값(values 파일 정의):
> - dev  : `pv=insideinfo-api-dev-upload-pv`, `pvc=insideinfo-api-dev-upload-pvc`
> - prod : `pv=insideinfo-api-prod-upload-pv`, `pvc=insideinfo-api-prod-upload-pvc`
> - node : `hompage-prod`
>
> 실제 클러스터에서 달라졌을 수 있으니 위 명령으로 확인하세요.

---

## 1단계 — 호스트 데이터 이전

PV 가 바라보는 노드(`hompage-prod`)에서 실행합니다.

```bash
# 노드 접속
ssh <노드-hostname>

# 신규 디렉터리 생성
mkdir -p /home/insideHomepage/upload/dev/file
mkdir -p /home/insideHomepage/upload/prod/file

# 데이터 복사 (원본은 롤백 대비 보존)
rsync -av /root/insideHomepage/upload/dev/file/  /home/insideHomepage/upload/dev/file/
rsync -av /root/insideHomepage/upload/prod/file/ /home/insideHomepage/upload/prod/file/

# 권한 확인 (기존과 동일하게 맞춤)
ls -la /home/insideHomepage/upload/dev/file
ls -la /home/insideHomepage/upload/prod/file
```

> `/home` 파티션 용량이 충분한지 사전 확인: `df -h /home`

---

## 2단계 — Helm values 수정

`insideinfo-gitops` 저장소에서 아래 두 파일을 수정합니다.

**dev**: `apps/insideinfo-api/helm/values/dev/inside-api-values.yaml`
```yaml
persistence:
  enabled: true
  hostPath: /home/insideHomepage/upload/dev/file   # ← 변경
  storageSize: 10Gi
  pvName: insideinfo-api-dev-upload-pv
  pvcName: insideinfo-api-dev-upload-pvc
```

**prod**: `apps/insideinfo-api/helm/values/prod/inside-api-values.yaml`
```yaml
persistence:
  enabled: true
  hostPath: /home/insideHomepage/upload/prod/file  # ← 변경
  storageSize: 10Gi
  pvName: insideinfo-api-prod-upload-pv
  pvcName: insideinfo-api-prod-upload-pvc
```

아직 **커밋/푸시하지 않고** 로컬에만 둡니다. (3단계에서 기존 PV/PVC 를 먼저 정리해야 함)

---

## 3단계 — ArgoCD 자동 sync 비활성화 (필수 선행)

⚠️ **PVC/PV 삭제나 Deployment 스케일 다운을 하기 전에 반드시 Auto-Sync 를 꺼야 합니다.**
자동 sync 가 켜진 상태에서 리소스를 삭제하면 Argo 가 즉시 되돌려 놓아서 작업이 진행되지 않습니다.

**ArgoCD UI 방식 (권장)**

1. 해당 Application 선택 → **App Details** → **SYNC POLICY**
2. **ENABLE AUTO-SYNC** 체크 해제 → `NONE` 표시 확인
3. PRUNE RESOURCES / SELF HEAL 체크는 그대로 둬도 무방 (자동 sync 꺼진 동안엔 동작 안 함)

**kubectl 방식 (argocd CLI 가 없을 때)**

```bash
# Argo Application 이름 확인 (보통 argocd 네임스페이스)
kubectl -n argocd get applications | grep insideinfo

# 자동 sync 끄기
kubectl -n argocd patch application <app-name> \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 확인 — automated 필드가 사라져야 함
kubectl -n argocd get application <app-name> \
  -o jsonpath='{.spec.syncPolicy}{"\n"}'
```

---

## 4단계 — 기존 PV/PVC 삭제 (dev 먼저)

> `<namespace>` / `<pvc-name>` / `<pv-name>` / `<deploy-name>` 는
> 상단 **사전 준비 — 오브젝트 이름 조회** 에서 확인한 값으로 치환해서 실행합니다.

```bash
# 현재 상태 확인
kubectl -n <namespace> get pvc <pvc-name>
kubectl get pv <pv-name>

# PVC 를 사용하는 파드 스케일 다운 (pvc-protection finalizer 해제용)
kubectl -n <namespace> scale deploy <deploy-name> --replicas=0

# 파드가 사라졌는지 확인
kubectl -n <namespace> get pod | grep <deploy-name>

# PVC → PV 순으로 삭제
kubectl -n <namespace> delete pvc <pvc-name>
kubectl delete pv <pv-name>
```

> PVC 가 `Terminating` 에서 멈추면: 파드가 아직 마운트 중인 것. 스케일 다운이
> 실제로 적용됐는지(Argo 가 되돌리지 않는지) 확인 후 아래 finalizer 제거:
> ```bash
> kubectl -n <namespace> patch pvc <pvc-name> \
>   -p '{"metadata":{"finalizers":null}}'
> kubectl patch pv <pv-name> -p '{"metadata":{"finalizers":null}}'
> ```

---

## 5단계 — values 커밋 & Argo sync 재활성화

```bash
cd insideinfo-gitops
git add apps/insideinfo-api/helm/values/dev/inside-api-values.yaml
git commit -m "chore(api): move dev upload hostPath /root → /home"
git push
```

그다음 ArgoCD UI 에서:

1. **SYNC POLICY → ENABLE AUTO-SYNC** 다시 체크 (원복)
2. 상단 **SYNC** 버튼 → **SYNCHRONIZE** 수동 트리거
3. 리소스 트리에서 PV/PVC 가 `/home/...` 경로로 재생성되고 Deployment 가
   `replicas=1` 로 복구되어 Pod Running 되는지 확인

kubectl 방식으로 Auto-Sync 되돌리기:
```bash
kubectl -n argocd patch application <app-name> --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## 6단계 — 검증

```bash
# 파드 Running 확인
kubectl -n <namespace> get pod -l app=<deploy-name>

# 마운트 경로 내용 확인 (이전한 파일이 보여야 함)
kubectl -n <namespace> exec deploy/<deploy-name> -- ls /app/upload/file | head

# 신규 업로드 테스트 후 호스트에서 확인
ls -lt /home/insideHomepage/upload/dev/file | head
```

업로드/다운로드/썸네일이 정상 동작하는지 관리자 화면에서 확인합니다.

---

## 7단계 — prod 동일 진행

dev 에서 검증이 끝난 후 3~6단계를 **prod 값**(prod 용 Application, `insideinfo-api-prod-upload-pv/pvc`, prod values 파일) 으로 반복합니다.

---

## 8단계 — 원본 정리 (롤백 대기기간 이후)

이상 없음이 확인되면 (권장: 최소 1~2일 운영 후) 기존 경로를 정리합니다.

```bash
# 혹시 모를 상황 대비 아카이브
tar -czf /home/insideHomepage/upload-backup-$(date +%Y%m%d).tar.gz \
    -C /root/insideHomepage upload

# 정리
rm -rf /root/insideHomepage/upload
```

---

## 롤백 절차

신규 경로 전환 후 문제가 발생하면:

1. values 파일의 `hostPath` 를 `/root/...` 로 되돌리고 커밋/푸시
2. 신규로 만들어진 `/home` 기반 PV/PVC 삭제
3. Argo sync → 기존 `/root` 기반 PV/PVC 재생성
4. 파드 Running 확인

`/root` 원본을 8단계 전까지 보존하므로 데이터 손실 없이 롤백 가능합니다.

---

## 참고 — 코드 내 주석 (선택)

실제 동작엔 영향 없지만 문서 싱크를 위해 업데이트 권장:

- `insideinfo-api/src/main/java/kr/co/insideinfo/config/UploadProperties.java:11-12`
  주석의 `/root/insideHomepage/...` → `/home/insideHomepage/...`

---

## 체크리스트

- [ ] `/home` 파티션 용량 확인 (`df -h /home`)
- [ ] `rsync` 로 dev/prod 데이터 이전 완료
- [ ] 권한/소유자 동일 확인
- [ ] values (dev) 수정 (로컬)
- [ ] **ArgoCD Auto-Sync 비활성화 (dev)**
- [ ] Deployment 스케일 다운 + 기존 PV/PVC (dev) 삭제
- [ ] values (dev) 커밋/푸시 → Auto-Sync 재활성화 + Sync (dev)
- [ ] dev 업/다운로드 동작 검증
- [ ] values (prod) 수정 (로컬)
- [ ] **ArgoCD Auto-Sync 비활성화 (prod)**
- [ ] Deployment 스케일 다운 + 기존 PV/PVC (prod) 삭제
- [ ] values (prod) 커밋/푸시 → Auto-Sync 재활성화 + Sync (prod)
- [ ] prod 업/다운로드 동작 검증
- [ ] UploadProperties.java 주석 업데이트
- [ ] 1~2일 운영 후 `/root/insideHomepage/upload` 정리
