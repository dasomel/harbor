# Fork Changes

This document records changes made after forking from [goharbor/harbor](https://github.com/goharbor/harbor).

> Upstream changes are synced automatically. This document only includes fork-specific modifications.

---

## 2026-01-31

### Fixed
- Skip get-changed-files for workflow_dispatch events (`f585d00`)
- Add missing install_cert.sh and fix path consistency in multiarch Dockerfiles (`29dd609`)

## 2026-01-22

### Added
- Trigger builds only on release tags (`bd61099`)

### Fixed
- Use PAT explicitly for git push to allow workflow file updates (`24d7c53`)

## 2026-01-14

### Fixed
- Auto-resolve merge conflicts for fork-specific files in sync-upstream (`b6ddd68`)

## 2026-01-05

### Fixed
- Fix base image naming in CI to match Dockerfile expectations (`a1cab47`)

### Changed
- Update image naming convention to match official helm chart and add photon suffix (`1aab24a`)

## 2026-01-04

### Fixed
- Disable CONFORMANCE_TEST scheduled runs due to missing self-hosted runner (`027c506`)

## 2026-01-01

### Added
- Add upstream sync workflow (`590df18`)
- Multi-arch build with SBOM, provenance, and Cosign signing (`1eb86d4`)

### Changed
- Update README with multi-arch, sync, and security details (`b341236`)

### Removed
- Remove duplicate build-arm64.yml workflow (`551a8ab`)

## 2025-12-29

### Fixed
- Remove latest tag push from build-package to preserve multi-arch images (`aa9b3f8`)
- Disable cache and provenance for clean multi-arch build (`7031782`)

## 2025-12-28

### Added
- Convert build-arm64.yml to multi-arch build, remove paths filter, unify version format (`850d91f`)

### Fixed
- Revert go.mod to 1.24.6, update workflows to use Go 1.24 (`e94afe8`)
- Downgrade Go version to 1.23.2, unify version tags (`f277aa3`)
- Unify image path to ghcr.io/dasomel/goharbor/ (`ebf46b9`)
- Clean up packages, use Helm-compatible image names, add version + latest tags (`1ecb2a4`)
- Add step to automatically set packages to public after push (`2557d4a`)

### Docs
- Fix example version tag to v2.15.0-build.10 (`d0538e1`)

## 2025-12-27

### Added
- Add ARM64 multi-architecture build support (`14b49b7`)

### Fixed
- Add fork information and available images to README (`c4a7e5c`)
- Add packages write permission, fix ghcr.io image push, remove Docker Hub dependency (`09d0e67`)
- Push images to ghcr.io instead of Docker Hub (`fdedcca`)
- Resolve YAML syntax error and switch to GitHub Artifacts (`46fa93f`)
- Use ubuntu-latest runner for CI and build-package workflows (`4a1c0b0`)
- Add missing NODE build arg for portal image build (`5921c88`)
- Use Docker for registry compilation to resolve dependency issues (`2d4fe4b`)
- Update Go version to 1.24.6 and add GOFLAGS to all compile steps (`9b86f5b`)
- Fix ARM64 build by using quay.io/goswagger/swagger image (`a21326c`)
- Fix ARM64 build workflow for Harbor dependencies (`32e0f78`)

---

## Summary

### Multi-Architecture Build
- AMD64 + ARM64 support
- SBOM and provenance metadata included
- Image signing with Cosign

### CI/CD Improvements
- GitHub Actions workflow optimization
- Using ghcr.io image registry
- Automatic upstream sync

### Image Distribution
- Image location: `ghcr.io/dasomel/goharbor/`
- Helm chart compatible naming convention
