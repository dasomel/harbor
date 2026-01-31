# Fork 변경사항

이 문서는 [goharbor/harbor](https://github.com/goharbor/harbor)에서 fork한 후 추가된 변경사항을 기록합니다.

> upstream의 변경사항은 자동으로 sync되며, 이 문서에는 fork에서 직접 수정한 내용만 포함됩니다.

---

## 2026-01-31

### Fixed
- workflow_dispatch 이벤트에서 get-changed-files 스킵 처리 (`f585d00`)
- multiarch Dockerfile에서 install_cert.sh 누락 및 경로 일관성 수정 (`29dd609`)

## 2026-01-22

### Added
- release 태그에서만 빌드 트리거되도록 설정 (`bd61099`)

### Fixed
- workflow 파일 업데이트를 위한 PAT 명시적 사용 (`24d7c53`)

## 2026-01-14

### Fixed
- sync-upstream에서 fork 전용 파일 머지 충돌 자동 해결 (`b6ddd68`)

## 2026-01-05

### Fixed
- CI에서 base image 이름이 Dockerfile과 일치하도록 수정 (`a1cab47`)

### Changed
- 공식 helm chart와 일치하도록 이미지 네이밍 컨벤션 변경, photon suffix 추가 (`1aab24a`)

## 2026-01-04

### Fixed
- self-hosted runner 부재로 인한 CONFORMANCE_TEST 스케줄 실행 비활성화 (`027c506`)

## 2026-01-01

### Added
- upstream 자동 sync workflow 추가 (`590df18`)
- multi-arch 빌드 + SBOM, provenance, Cosign 서명 지원 (`1eb86d4`)

### Changed
- README에 multi-arch, sync, security 정보 추가 (`b341236`)

### Removed
- 중복된 build-arm64.yml workflow 삭제 (`551a8ab`)

## 2025-12-29

### Fixed
- multi-arch 이미지 보존을 위해 latest 태그 push 제거 (`aa9b3f8`)
- clean multi-arch 빌드를 위해 cache 및 provenance 비활성화 (`7031782`)

## 2025-12-28

### Added
- build-arm64.yml을 multi-arch 빌드로 전환, paths 필터 제거, 버전 포맷 통일 (`850d91f`)

### Fixed
- go.mod를 1.24.6으로 복원, workflow에서 Go 1.24 사용 (`e94afe8`)
- Go 버전 1.23.2로 다운그레이드, 버전 태그 통일 (`f277aa3`)
- 이미지 경로를 ghcr.io/dasomel/goharbor/로 통일 (`ebf46b9`)
- 패키지 정리, Helm 호환 이미지 이름 사용, version + latest 태그 추가 (`1ecb2a4`)
- push 후 패키지 자동 공개 설정 단계 추가 (`2557d4a`)

### Docs
- 버전 태그 예시 수정 (v2.15.0-build.10) (`d0538e1`)

## 2025-12-27

### Added
- ARM64 multi-architecture 빌드 지원 (`14b49b7`)

### Fixed
- fork 정보 및 사용 가능한 이미지 정보를 README에 추가 (`c4a7e5c`)
- packages write 권한 추가, ghcr.io 이미지 push 수정, Docker Hub 의존성 제거 (`09d0e67`)
- ghcr.io로 이미지 push 변경 (`fdedcca`)
- YAML 문법 오류 해결, GitHub Artifacts로 전환 (`46fa93f`)
- CI 및 build-package workflow에서 ubuntu-latest runner 사용 (`4a1c0b0`)
- portal 이미지 빌드에 누락된 NODE build arg 추가 (`5921c88`)
- 의존성 문제 해결을 위해 registry 컴파일에 Docker 사용 (`2d4fe4b`)
- Go 버전 1.24.6으로 업데이트, 모든 컴파일 단계에 GOFLAGS 추가 (`9b86f5b`)
- ARM64 빌드를 위해 quay.io/goswagger/swagger 이미지 사용 (`a21326c`)
- Harbor 의존성을 위한 ARM64 빌드 workflow 수정 (`32e0f78`)

---

## 주요 기능 요약

### Multi-Architecture 빌드
- AMD64 + ARM64 지원
- SBOM 및 provenance 메타데이터 포함
- Cosign을 통한 이미지 서명

### CI/CD 개선
- GitHub Actions workflow 최적화
- ghcr.io 이미지 레지스트리 사용
- upstream 자동 sync

### 이미지 배포
- 이미지 위치: `ghcr.io/dasomel/goharbor/`
- Helm chart 호환 네이밍 컨벤션
