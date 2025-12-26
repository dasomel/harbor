# Harbor ARM64 빌드 가이드

이 문서는 Harbor를 ARM64 (Apple Silicon, AWS Graviton 등) 아키텍처용으로 빌드하는 방법을 설명합니다.

## 개요

Harbor 공식 릴리즈는 현재 x86_64(amd64) 아키텍처만 지원합니다. 이 빌드 시스템을 사용하면 ARM64 이미지를 직접 빌드하고 배포할 수 있습니다.

## 지원 아키텍처

- `linux/amd64` (x86_64)
- `linux/arm64` (ARM64, aarch64)

## 빌드 방법

### 방법 1: GitHub Actions (권장)

#### 자동 빌드
`main` 또는 `release-*` 브랜치에 푸시하면 자동으로 ARM64 이미지가 빌드됩니다.

#### 수동 빌드
1. GitHub 저장소의 **Actions** 탭으로 이동
2. **Build ARM64 Images** 워크플로우 선택
3. **Run workflow** 클릭
4. 옵션 설정:
   - `version_tag`: 이미지 태그 (예: `v2.15.0-arm64`)
   - `push_images`: 이미지를 레지스트리에 푸시할지 여부

### 방법 2: 로컬 빌드

#### 사전 요구사항

1. **Docker Desktop** (BuildX 포함) 또는 Docker + BuildX 플러그인
2. **Go 1.24+**
3. **Git**
4. ARM64 에뮬레이션을 위한 **QEMU** (amd64 시스템에서 빌드하는 경우)

```bash
# QEMU 설정 (Linux에서)
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

#### 빌드 실행

```bash
# 전체 빌드
./scripts/build-arm64.sh

# 특정 컴포넌트만 빌드
./scripts/build-arm64.sh core registry

# 빌드 후 레지스트리에 푸시
./scripts/build-arm64.sh --push

# 커스텀 레지스트리 사용
./scripts/build-arm64.sh --registry docker.io --namespace myuser/harbor --push
```

#### 옵션

| 옵션 | 설명 | 기본값 |
|------|------|--------|
| `--push` | 빌드 후 레지스트리에 푸시 | false |
| `--registry` | 컨테이너 레지스트리 | ghcr.io |
| `--namespace` | 이미지 네임스페이스 | 자동 감지 |
| `--tag` | 버전 태그 | VERSION-arm64 |

## 빌드되는 컴포넌트

| 컴포넌트 | 이미지 이름 | 설명 |
|----------|-------------|------|
| core | harbor-core | Harbor 코어 서비스 |
| db | harbor-db | PostgreSQL 데이터베이스 |
| exporter | harbor-exporter | Prometheus 메트릭 익스포터 |
| jobservice | harbor-jobservice | 비동기 작업 서비스 |
| log | harbor-log | 로그 수집기 |
| nginx | nginx-photon | Nginx 프록시 |
| portal | harbor-portal | 웹 UI |
| prepare | prepare | 설정 준비 도구 |
| redis | redis-photon | Redis 캐시 |
| registry | registry-photon | Docker Registry |
| registryctl | harbor-registryctl | Registry 컨트롤러 |
| trivy-adapter | trivy-adapter-photon | 취약점 스캐너 |

## GitHub Container Registry에서 이미지 사용

```bash
# 로그인 (Personal Access Token 필요)
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# 이미지 풀
docker pull ghcr.io/YOUR_USERNAME/harbor/harbor-core:v2.15.0-arm64

# ARM64 시스템에서 실행
docker run --platform linux/arm64 ghcr.io/YOUR_USERNAME/harbor/harbor-core:v2.15.0-arm64
```

## Harbor 설치 (ARM64)

### helm 차트 사용

```bash
# values.yaml 수정
cat > arm64-values.yaml << EOF
# Harbor ARM64 이미지 설정
core:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/harbor-core
    tag: v2.15.0-arm64

portal:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/harbor-portal
    tag: v2.15.0-arm64

jobservice:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/harbor-jobservice
    tag: v2.15.0-arm64

registry:
  registry:
    image:
      repository: ghcr.io/YOUR_USERNAME/harbor/registry-photon
      tag: v2.15.0-arm64
  controller:
    image:
      repository: ghcr.io/YOUR_USERNAME/harbor/harbor-registryctl
      tag: v2.15.0-arm64

database:
  internal:
    image:
      repository: ghcr.io/YOUR_USERNAME/harbor/harbor-db
      tag: v2.15.0-arm64

redis:
  internal:
    image:
      repository: ghcr.io/YOUR_USERNAME/harbor/redis-photon
      tag: v2.15.0-arm64

trivy:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/trivy-adapter-photon
    tag: v2.15.0-arm64

nginx:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/nginx-photon
    tag: v2.15.0-arm64

exporter:
  image:
    repository: ghcr.io/YOUR_USERNAME/harbor/harbor-exporter
    tag: v2.15.0-arm64
EOF

# Harbor 설치
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor -f arm64-values.yaml
```

## 트러블슈팅

### QEMU 에뮬레이션 오류

```bash
# QEMU 재설정
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

# BuildX 빌더 재생성
docker buildx rm harbor-multiarch
docker buildx create --name harbor-multiarch --driver docker-container --use
```

### 빌드 시간이 너무 오래 걸릴 때

QEMU 에뮬레이션은 네이티브 빌드보다 5-10배 느릴 수 있습니다.

**권장사항:**
- ARM64 네이티브 호스트에서 빌드 (Apple Silicon Mac, AWS Graviton 등)
- GitHub Actions의 ARM64 러너 사용 (self-hosted)

### 메모리 부족 오류

```bash
# Docker 데스크탑 메모리 증가 (최소 8GB 권장)
# 또는 swap 증가

# 빌드 병렬도 제한
DOCKER_BUILDKIT_PARALLEL=2 ./scripts/build-arm64.sh
```

## 기여

ARM64 빌드 관련 이슈나 개선 사항은 GitHub 이슈로 등록해 주세요.

## 라이선스

Apache License 2.0 - Harbor 프로젝트와 동일합니다.
