# 02. 사전 준비 및 Vagrant 가이드

## 사전 설치 (Windows PC)

### 필수 소프트웨어

| 소프트웨어 | 다운로드 URL | 비고 |
|-----------|------------|------|
| VirtualBox | https://www.virtualbox.org/wiki/Downloads | "Windows hosts" 선택 |
| Vagrant | https://developer.hashicorp.com/vagrant/install | Windows AMD64 |

### Vagrant 플러그인 설치

설치 후 CMD 또는 PowerShell에서 실행:
```
vagrant plugin install vagrant-vbguest
```

### PC 최소 사양

- RAM: 32GB 이상 권장 (VM 3대 × 8GB = 24GB + 호스트 OS)
- Disk: SSD 여유 공간 200GB 이상
- CPU: 8코어 이상 권장

### Vagrant Box 미리 다운로드 (선택)

```
vagrant box add generic/rocky9
```

> `generic/rocky9`는 128GB 동적 할당 LVM 디스크를 사용합니다.
> 실제로는 사용량만큼만 호스트 디스크를 차지하므로 걱정할 필요 없습니다.

---

## Vagrantfile 설명

### Vagrantfile에만 가능한 설정 (VM 생성 시점)

아래 설정들은 VirtualBox 레벨에서 VM을 만들 때만 적용 가능하므로 Vagrantfile에 남겨두었습니다.
OS 부팅 후에는 변경할 수 없거나 매우 번거롭습니다.

| 설정 | 설명 | 값 |
|------|------|-----|
| `config.vm.box` | OS 이미지 | `generic/rocky9` |
| `private_network` | VirtualBox Host-Only NIC + IP | 192.168.56.30/31/32 |
| `forwarded_port` | SSH 포트포워딩 | 22 → 2222 (자동 조정) |
| `vb.memory` | VM 메모리 | 8192 (8GB) |
| `vb.cpus` | CPU 코어 수 | Master 4, Worker 2 |
| `--nested-hw-virt on` | 중첩 가상화 | - |

### 쉘 스크립트로 옮긴 설정 (OS 부팅 후 가능)

아래 설정들은 VM 안에서 자유롭게 변경 가능하므로 `k8s-common.sh`로 분리했습니다.

- hostname 설정 (`hostnamectl`)
- /etc/hosts 파일
- 타임존, NTP
- 방화벽, Swap, SELinux
- containerd, kubeadm 설치

---

## VM 생성 및 관리

### 파일 배치

```
C:\k8s-lab\
├── Vagrantfile
├── k8s-common.sh
├── k8s-master.sh
├── k8s-master-apps.sh
├── k8s-worker.sh
└── (문서들)
```

### VM 생성

```
cd C:\k8s-lab
vagrant up
```

처음 실행 시 Rocky 9 이미지 다운로드 포함 10~20분 소요.
3대 VM이 순차적으로 생성됩니다.

### 개별 VM만 생성

```
vagrant up master-node
vagrant up worker-node1
vagrant up worker-node2
```

### VM 접속

```
vagrant ssh master-node
vagrant ssh worker-node1
vagrant ssh worker-node2
```

### VM 관리 명령어

```bash
vagrant halt              # 3대 전부 종료
vagrant halt master-node  # 특정 VM만 종료
vagrant up                # 3대 전부 시작
vagrant reload            # 3대 재시작 (Vagrantfile 변경 적용)
vagrant status            # 3대 상태 확인
vagrant destroy -f        # 3대 전부 삭제 (데이터 손실!)
```

---

## 스크립트를 VM에 넣는 방법

### 방법 1 — Vagrant 공유 폴더 (추천)

Vagrantfile에서 `disabled: true`를 삭제하면 호스트의 `C:\k8s-lab\` 폴더가 VM 안의 `/vagrant`에 자동 마운트됩니다.

Vagrantfile 수정:
```ruby
# 변경 전
config.vm.synced_folder "./", "/vagrant", disabled: true

# 변경 후
config.vm.synced_folder "./", "/vagrant"
```

수정 후:
```
vagrant reload
vagrant ssh master-node
ls /vagrant/  # k8s-common.sh, k8s-master.sh 등이 보임
```

### 방법 2 — 직접 붙여넣기

```
vagrant ssh master-node
vi k8s-common.sh
# i 눌러서 편집 모드 → 스크립트 내용 붙여넣기 → Esc → :wq 저장
```

### 방법 3 — scp 전송

```
# 포트/키 정보 확인
vagrant ssh-config master-node

# scp로 전송 (출력된 포트/키 정보 사용)
scp -P 2222 -i .vagrant/machines/master-node/virtualbox/private_key \
  k8s-common.sh vagrant@127.0.0.1:/home/vagrant/
```

---

## 네트워크 구성

```
Windows Host (192.168.56.1)
    │
    ├── VirtualBox Host-Only Network (192.168.56.0/24)
    │       │
    │       ├── k8s-master  (192.168.56.30)
    │       ├── k8s-worker1 (192.168.56.31)
    │       ├── k8s-worker2 (192.168.56.32)
    │       │
    │       └── MetalLB Pool (192.168.56.200~220)
    │               │
    │               └── Envoy Gateway External IP
    │
    └── NAT (인터넷 접속용, 각 VM에 자동 할당)
```

- VM 간 통신: `192.168.56.x` (Host-Only Network)
- VM → 인터넷: NAT (패키지 다운로드 등)
- Windows → VM 서비스: MetalLB IP + 도메인 (HTTPRoute)

### Windows hosts 파일 설정 (선택)

`C:\Windows\System32\drivers\etc\hosts` 파일에 추가하면 도메인으로 접속 가능:
```
192.168.56.200  my-app.local
192.168.56.200  grafana.local
192.168.56.200  argocd.local
192.168.56.200  dashboard.local
```

---

## 트러블슈팅

### vagrant up 실패 — VT-x 오류

BIOS에서 Intel VT-x 또는 AMD-V 가상화를 활성화해야 합니다.
BIOS 진입 → Advanced → CPU Configuration → Virtualization Technology → Enabled

### vagrant up 실패 — Hyper-V 충돌

Windows에서 Hyper-V가 활성화되어 있으면 VirtualBox와 충돌합니다.
```
# 관리자 PowerShell
bcdedit /set hypervisorlaunchtype off
# 재부팅 필요
```

### SSH 접속 안 됨

```
vagrant ssh-config master-node
# IdentityFile 경로와 Port 확인 후 직접 ssh
ssh -p 2222 -i <IdentityFile 경로> vagrant@127.0.0.1
```

### VM 디스크 부족

`generic/rocky9`는 128GB 동적 디스크(LVM)를 사용하므로 일반적으로 부족하지 않습니다.
만약 부족하다면 `vagrant destroy -f && vagrant up`으로 재생성하거나,
VM 내부에서 `df -h`로 사용량을 확인하고 불필요한 이미지/로그를 정리하세요.
