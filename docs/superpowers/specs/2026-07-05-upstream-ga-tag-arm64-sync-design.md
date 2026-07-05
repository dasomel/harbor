# 업스트림 GA 태그 자동 반영 + ARM64 이미지 정합성 확보

- Date: 2026-07-05
- Status: Approved

## Background

이 fork(`dasomel/harbor`)의 목적은 공식 Harbor 프로젝트가 릴리즈 태그에 대해 amd64 이미지만 배포하는 것과 달리, 동일한 버전에 대해 amd64+arm64 멀티아치 이미지를 `ghcr.io/dasomel/goharbor`에 제공하는 것이다.

조사 결과 다음 문제가 확인되었다.

1. `.github/workflows/sync-upstream.yml`은 upstream의 `main` 브랜치만 병합할 뿐, **태그는 전혀 동기화하지 않는다**. 따라서 `build-package.yml`(트리거: `on: push: tags: 'v*'`)이 업스트림 GA 릴리즈(v2.15.1, v2.15.2 등)에 대해 한 번도 실행되지 않았다. 실제로 `ghcr.io/dasomel/goharbor/harbor-core`에는 `v2.15.0-build.26~32`와 `latest`만 존재하고 `v2.15.1`, `v2.15.2` 태그는 amd64/arm64 모두 없다.
2. 설령 태그가 push되어 빌드가 트리거되더라도, `build-package.yml`의 "Prepare version info" 스텝은 `target_branch="$(echo ${GITHUB_REF#refs/heads/})"`로 브랜치명을 추출하는데, 태그 push 시 `GITHUB_REF`는 `refs/tags/v2.15.1` 형태라 접두사 치환이 되지 않는다. 결과적으로 브랜치 판별 조건과 무관하게 최종 이미지 태그(`version_tag` 출력)는 항상 `$target_release_version-build.$GITHUB_RUN_NUMBER` 형식으로 고정된다. 이는 Helm 차트가 `appVersion`으로 찾는 정확한 태그(`v2.15.1`)와 일치하지 않는다.

참고: 공식 `goharbor/harbor-core:v2.15.1`, `v2.15.0`, `v2.15.2` 이미지는 모두 단일 manifest(amd64)이며, `dev` 태그만 amd64+arm64 manifest list다. 즉 GA 릴리즈에 대한 arm64 부재는 공식 프로젝트의 정책적 특성이며, 이 fork가 그 위에 arm64를 추가로 빌드/제공하는 것이 프로젝트의 존재 이유다.

## Scope

- 대상 버전: **v2.15.0 이상 GA 태그** (`^v[0-9]+\.[0-9]+\.[0-9]+$` 정규식에 매칭, `-rc`/`-build` 등 접미사가 붙은 프리릴리즈/빌드 태그는 제외). 상한 없음 — v2.16.x, v2.17.x 등 이후 버전도 계속 자동 포함.
- 백필과 향후 자동화를 별도 절차로 나누지 않는다. "없는 태그를 찾아 push하는" 단일 메커니즘이 최초 실행 시 현재 누락분(v2.15.1, v2.15.2 등)도 자연스럽게 채우고, 이후 새 릴리즈도 같은 방식으로 채운다.
- 설치 패키지(offline/online installer)나 헬름 차트 자체의 버전업은 이번 스코프에 포함하지 않는다. 오직 "업스트림 GA 태그 → fork 태그 반영 → 멀티아치 이미지 빌드"만 다룬다.

## Design

### 1. 신규 워크플로우: `.github/workflows/sync-release-tags.yml`

**트리거**
- `schedule`: 매일 1회, `sync-upstream.yml`(`0 0 * * *`) 직후인 `30 0 * * *` (UTC)
- `workflow_dispatch`: 입력값 `dry_run` (boolean, default `true`)

**동작 순서**
1. 저장소 체크아웃 (`fetch-depth: 0`, `PAT_TOKEN` 사용 — 태그 push 권한 필요)
2. `upstream` remote 등록/갱신 (`https://github.com/goharbor/harbor.git`), `git fetch upstream --tags`
3. upstream 태그 중 GA 패턴(`^v[0-9]+\.[0-9]+\.[0-9]+$`)만 추출
4. `sort -V` 기준으로 `v2.15.0` 이상만 필터링
5. `git ls-remote --tags origin`으로 fork(origin)에 이미 존재하는 태그 목록을 구해 **차집합**(upstream에는 있지만 origin에는 없는 태그) 계산
6. `dry_run=true`: 차집합 목록을 `$GITHUB_STEP_SUMMARY`에 출력하고 종료 (push 안 함)
7. `dry_run=false`: 차집합의 각 태그를 upstream이 가리키는 커밋 그대로 origin에 `git push origin refs/tags/<tag>` — 태그 하나 실패해도 나머지는 계속 진행(개별 try/continue)
8. 새로 push된 태그 목록을 요약으로 출력

각 태그 push는 기존 `build-package.yml`의 `on: push: tags: 'v*'` 트리거를 그대로 발동시켜 별도 연동 코드 없이 빌드가 시작된다.

### 2. `build-package.yml` "Prepare version info" 스텝 수정

기존:
```bash
target_release_version=$(cat ./VERSION)
Harbor_Package_Version=$target_release_version-'build.'$GITHUB_RUN_NUMBER
target_branch="$(echo ${GITHUB_REF#refs/heads/})"
...
echo "tag=${Harbor_Package_Version}" >> $GITHUB_OUTPUT
```

수정:
- `github.ref_type == 'tag'`인 경우 (즉 이 워크플로우가 버전 태그 push로 트리거된 경우): `Harbor_Package_Version=${{ github.ref_name }}` — 접미사 없이 태그명 그대로 사용
- 그 외(main 브랜치 push, workflow_dispatch)는 기존 `$target_release_version-build.$GITHUB_RUN_NUMBER` 방식 유지
- `tag` 출력(`version_tag`)이 이 값을 그대로 반영하므로, base 이미지/최종 이미지 태그 로직(`build-base-images`, `build-final-images` job)은 수정 불필요 — 출력값만 고치면 전체에 전파됨
- `assets_version` 로직은 변경 없음 (이미 비-main 브랜치에서는 접미사 없는 `target_release_version`을 쓰고 있어 문제 없음)

### 데이터 흐름

```
upstream에 새 GA 태그 등장 (예: v2.15.3)
  → (매일 00:30 UTC) sync-release-tags.yml이 origin에 없는 태그로 감지
  → git push origin v2.15.3
  → build-package.yml 트리거 (on: push: tags: v*)
  → version_tag = "v2.15.3" (접미사 없음)
  → amd64+arm64 멀티아치 빌드 → ghcr.io/dasomel/goharbor/harbor-core:v2.15.3 (멀티아치)
```

### 에러 처리

- 개별 태그 push 실패(권한/네트워크 등) 시 해당 태그만 로그로 남기고 나머지 태그는 계속 처리 — 워크플로우 전체를 중단하지 않는다.
- 이미 origin에 존재하는 태그는 재push 시도하지 않는다 (중복 빌드 방지).
- `dry_run` 모드는 실제 태그 push 없이 차집합만 로그로 확인할 수 있게 하여, 최초 배포 시 의도치 않은 대량 빌드 트리거를 방지한다.

### 테스트/검증 계획

1. `sync-release-tags.yml`을 `workflow_dispatch`(`dry_run=true`)로 실행 → 요약에 `v2.15.1`, `v2.15.2` 등이 감지되는지 확인
2. `dry_run=false`로 실행 → `build-package.yml`이 각 태그에 대해 자동 트리거되는지 `gh run list`로 확인
3. 빌드 완료 후 `docker buildx imagetools inspect ghcr.io/dasomel/goharbor/harbor-core:v2.15.1`로 amd64+arm64 manifest list가 존재하는지 확인
4. `build-package.yml` 수정 후에도 기존 main 브랜치 push/workflow_dispatch 빌드가 기존 `build.N` 태깅 방식으로 정상 동작하는지 회귀 확인 (latest 태그 등)

### 3. `build-package.yml`에 GitHub Release 생성 잡 추가

현재 태그가 push되어 이미지가 빌드되어도 이 fork 저장소에는 **git 태그만 남고 GitHub Release가 생성되지 않는다** (`publish_release.yml`의 릴리즈 생성 로직은 `if: github.repository == 'goharbor/harbor'` 조건 때문에 fork에서 실행되지 않음). 태그 push로 빌드가 트리거될 때(`github.ref_type == 'tag'`), 이미지 빌드가 끝난 뒤 다음을 수행하는 잡을 추가한다.

1. upstream(`goharbor/harbor`)의 동일 태그 릴리즈 노트를 GitHub API로 조회
2. 이미 동일 태그의 Release가 존재하면 스킵 (멱등성)
3. 없으면 `gh release create <tag>`로 이 fork 저장소에 Release 생성 — 제목에 "linux/amd64, linux/arm64" 명시, 본문은 upstream 릴리즈 노트 + 원본 링크 + arm64 추가 빌드임을 알리는 안내 문구

이 잡은 `build-final-images`가 성공한 뒤 실행되며, 태그 트리거가 아닌 main 브랜치 push/workflow_dispatch에서는 실행되지 않는다.

## Out of Scope

- 과거(v2.13, v2.14 등 v2.15 미만) 버전의 소급 빌드
- rc/프리릴리즈 태그 반영
- 설치 패키지(installer tarball)나 helm chart 자체의 버전 정책 변경
- 이미 존재하는 `v2.15.0-build.*` 태그 정리/삭제
