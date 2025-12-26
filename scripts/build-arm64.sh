#!/bin/bash
#
# Harbor ARM64 이미지 로컬 빌드 스크립트
# 
# 사용법:
#   ./scripts/build-arm64.sh              # 전체 빌드
#   ./scripts/build-arm64.sh core         # 특정 컴포넌트만 빌드
#   ./scripts/build-arm64.sh --push       # 빌드 후 레지스트리에 푸시
#
# 환경변수:
#   REGISTRY          - 컨테이너 레지스트리 (기본값: ghcr.io)
#   IMAGE_NAMESPACE   - 이미지 네임스페이스 (기본값: 현재 git 사용자/harbor)
#   VERSION_TAG       - 버전 태그 (기본값: VERSION 파일 + -arm64)
#

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 프로젝트 루트로 이동
cd "$(dirname "$0")/.."
PROJECT_ROOT=$(pwd)

# 환경 변수 설정
REGISTRY=${REGISTRY:-"ghcr.io"}
VERSION=$(cat VERSION | tr -d '\n')
VERSION_TAG=${VERSION_TAG:-"${VERSION}-arm64"}
IMAGE_NAMESPACE=${IMAGE_NAMESPACE:-"$(git config user.name | tr '[:upper:]' '[:lower:]' | tr ' ' '-')/harbor"}

# 컴포넌트 목록
ALL_COMPONENTS=(
    "core"
    "db"
    "exporter"
    "jobservice"
    "log"
    "nginx"
    "portal"
    "prepare"
    "redis"
    "registry"
    "registryctl"
    "trivy-adapter"
)

# Go 버전
GO_VERSION="1.24.6"
TRIVY_VERSION="v0.65.0"
TRIVY_ADAPTER_VERSION="v0.34.0-rc.1"

# 플래그 파싱
PUSH_IMAGES=false
BUILD_COMPONENTS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --push)
            PUSH_IMAGES=true
            shift
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --tag)
            VERSION_TAG="$2"
            shift 2
            ;;
        --namespace)
            IMAGE_NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [COMPONENT...]"
            echo ""
            echo "Options:"
            echo "  --push              Push images to registry after build"
            echo "  --registry VALUE    Container registry (default: ghcr.io)"
            echo "  --tag VALUE         Version tag (default: VERSION-arm64)"
            echo "  --namespace VALUE   Image namespace (default: auto-detected)"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Components:"
            printf '  %s\n' "${ALL_COMPONENTS[@]}"
            exit 0
            ;;
        *)
            BUILD_COMPONENTS+=("$1")
            shift
            ;;
    esac
done

# 빌드할 컴포넌트가 지정되지 않으면 전체 빌드
if [[ ${#BUILD_COMPONENTS[@]} -eq 0 ]]; then
    BUILD_COMPONENTS=("${ALL_COMPONENTS[@]}")
fi

# 빌드 정보 출력
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Harbor ARM64 Multi-Architecture Build               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_info "Registry:       ${REGISTRY}"
log_info "Namespace:      ${IMAGE_NAMESPACE}"
log_info "Version Tag:    ${VERSION_TAG}"
log_info "Push Images:    ${PUSH_IMAGES}"
log_info "Components:     ${BUILD_COMPONENTS[*]}"
echo ""

# Docker Buildx 확인
check_buildx() {
    log_info "Checking Docker Buildx..."
    if ! docker buildx version > /dev/null 2>&1; then
        log_error "Docker Buildx is not available. Please install it first."
        exit 1
    fi
    
    # Multi-platform 빌더 생성/사용
    if ! docker buildx inspect harbor-multiarch > /dev/null 2>&1; then
        log_info "Creating multi-platform builder..."
        docker buildx create --name harbor-multiarch --driver docker-container --use
    else
        docker buildx use harbor-multiarch
    fi
    
    # ARM64 에뮬레이션 확인
    if ! docker run --rm --privileged multiarch/qemu-user-static --reset -p yes > /dev/null 2>&1; then
        log_warn "QEMU setup might have issues. Trying to continue..."
    fi
    
    log_success "Docker Buildx ready"
}

# Go 바이너리 컴파일
compile_binary() {
    local component=$1
    local binary_name=$2
    local source_path=$3
    
    log_info "Compiling ${component} binary..."
    
    mkdir -p "make/photon/${component}/binary/amd64"
    mkdir -p "make/photon/${component}/binary/arm64"
    
    GITCOMMIT=$(git rev-parse --short=8 HEAD)
    LDFLAGS="-w -s"
    
    if [[ "${component}" == "core" ]]; then
        LDFLAGS="${LDFLAGS} -X github.com/goharbor/harbor/src/pkg/version.GitCommit=${GITCOMMIT} -X github.com/goharbor/harbor/src/pkg/version.ReleaseVersion=${VERSION}"
    fi
    
    # AMD64 빌드
    log_info "  Building for amd64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "${LDFLAGS}" \
        -o "make/photon/${component}/binary/amd64/${binary_name}" \
        "./${source_path}"
    
    # ARM64 빌드
    log_info "  Building for arm64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "${LDFLAGS}" \
        -o "make/photon/${component}/binary/arm64/${binary_name}" \
        "./${source_path}"
    
    log_success "  ${component} binary compiled"
}

# Registry 바이너리 컴파일
compile_registry() {
    log_info "Compiling registry binary..."
    
    local temp_dir=$(mktemp -d)
    git clone -b release/2.8 https://github.com/goharbor/distribution.git "${temp_dir}"
    
    mkdir -p "make/photon/registry/binary/amd64"
    mkdir -p "make/photon/registry/binary/arm64"
    
    cd "${temp_dir}"
    
    # AMD64 빌드
    log_info "  Building for amd64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -o "${PROJECT_ROOT}/make/photon/registry/binary/amd64/registry" \
        ./cmd/registry
    
    # ARM64 빌드
    log_info "  Building for arm64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
        -o "${PROJECT_ROOT}/make/photon/registry/binary/arm64/registry" \
        ./cmd/registry
    
    cd "${PROJECT_ROOT}"
    rm -rf "${temp_dir}"
    
    log_success "  registry binary compiled"
}

# Trivy Adapter 컴파일
compile_trivy_adapter() {
    log_info "Compiling trivy-adapter binary..."
    
    local temp_dir=$(mktemp -d)
    git clone https://github.com/goharbor/harbor-scanner-trivy.git "${temp_dir}"
    cd "${temp_dir}" && git checkout "${TRIVY_ADAPTER_VERSION}" && cd -
    
    mkdir -p "make/photon/trivy-adapter/binary/amd64"
    mkdir -p "make/photon/trivy-adapter/binary/arm64"
    
    cd "${temp_dir}"
    
    # AMD64 빌드
    log_info "  Building for amd64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on go build \
        -o "${PROJECT_ROOT}/make/photon/trivy-adapter/binary/amd64/scanner-trivy" \
        cmd/scanner-trivy/main.go
    
    # ARM64 빌드
    log_info "  Building for arm64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GO111MODULE=on go build \
        -o "${PROJECT_ROOT}/make/photon/trivy-adapter/binary/arm64/scanner-trivy" \
        cmd/scanner-trivy/main.go
    
    cd "${PROJECT_ROOT}"
    rm -rf "${temp_dir}"
    
    # Trivy 바이너리 다운로드
    log_info "  Downloading trivy binary..."
    TRIVY_VERSION_NUM=$(echo "${TRIVY_VERSION}" | sed 's/^v//')
    
    curl -sL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_VERSION_NUM}_Linux-64bit.tar.gz" \
        | tar xz -C "make/photon/trivy-adapter/binary/amd64/"
    
    curl -sL "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_VERSION_NUM}_Linux-ARM64.tar.gz" \
        | tar xz -C "make/photon/trivy-adapter/binary/arm64/"
    
    log_success "  trivy-adapter compiled"
}

# Base 이미지 빌드
build_base_image() {
    local component=$1
    local image_name="${REGISTRY}/${IMAGE_NAMESPACE}/harbor-${component}-base:${VERSION_TAG}"
    
    log_info "Building base image for ${component}..."
    
    local push_flag=""
    if [[ "${PUSH_IMAGES}" == "true" ]]; then
        push_flag="--push"
    else
        push_flag="--load"
    fi
    
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        -f "make/photon/${component}/Dockerfile.base" \
        -t "${image_name}" \
        ${push_flag} \
        .
    
    log_success "  Base image built: ${image_name}"
}

# 최종 이미지 빌드
build_final_image() {
    local component=$1
    local image_name="${REGISTRY}/${IMAGE_NAMESPACE}/harbor-${component}:${VERSION_TAG}"
    
    log_info "Building final image for ${component}..."
    
    # Dockerfile 선택
    local dockerfile="make/photon/${component}/Dockerfile"
    if [[ -f "make/photon/${component}/Dockerfile.multiarch" ]]; then
        dockerfile="make/photon/${component}/Dockerfile.multiarch"
    fi
    
    local push_flag=""
    if [[ "${PUSH_IMAGES}" == "true" ]]; then
        push_flag="--push"
    else
        push_flag="--load"
    fi
    
    # versions 파일 생성
    cat > make/photon/prepare/versions << EOF
VERSION_TAG: ${VERSION}
REGISTRY_VERSION: v2.8.3-patch-redis
TRIVY_VERSION: ${TRIVY_VERSION}
TRIVY_ADAPTER_VERSION: ${TRIVY_ADAPTER_VERSION}
EOF
    
    docker buildx build \
        --platform linux/amd64,linux/arm64 \
        --build-arg harbor_base_image_version="${VERSION_TAG}" \
        --build-arg harbor_base_namespace="${REGISTRY}/${IMAGE_NAMESPACE}" \
        --build-arg TARGETARCH=arm64 \
        -f "${dockerfile}" \
        -t "${image_name}" \
        ${push_flag} \
        .
    
    log_success "  Final image built: ${image_name}"
}

# 메인 빌드 프로세스
main() {
    # Buildx 확인
    check_buildx
    
    # 바이너리 컴파일
    for component in "${BUILD_COMPONENTS[@]}"; do
        case ${component} in
            core)
                compile_binary "core" "harbor_core" "src/core"
                ;;
            jobservice)
                compile_binary "jobservice" "harbor_jobservice" "src/jobservice"
                ;;
            registryctl)
                compile_binary "registryctl" "harbor_registryctl" "src/registryctl"
                ;;
            registry)
                compile_registry
                ;;
            trivy-adapter)
                compile_trivy_adapter
                ;;
        esac
    done
    
    # Base 이미지 빌드
    echo ""
    log_info "Building base images..."
    for component in "${BUILD_COMPONENTS[@]}"; do
        build_base_image "${component}"
    done
    
    # 최종 이미지 빌드
    echo ""
    log_info "Building final images..."
    for component in "${BUILD_COMPONENTS[@]}"; do
        build_final_image "${component}"
    done
    
    # 완료
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Build Complete! 🎉                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_info "Images built:"
    for component in "${BUILD_COMPONENTS[@]}"; do
        echo "  - ${REGISTRY}/${IMAGE_NAMESPACE}/harbor-${component}:${VERSION_TAG}"
    done
    echo ""
    
    if [[ "${PUSH_IMAGES}" == "true" ]]; then
        log_success "Images pushed to ${REGISTRY}"
    else
        log_info "To push images, run with --push flag"
    fi
}

# 실행
main
