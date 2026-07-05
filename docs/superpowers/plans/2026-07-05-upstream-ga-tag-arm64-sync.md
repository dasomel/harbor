# Upstream GA Tag → ARM64 Image Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every upstream `goharbor/harbor` GA release tag `>= v2.15.0` gets automatically mirrored into this fork, triggers a clean-tagged multi-arch (amd64+arm64) image build on `ghcr.io/dasomel/goharbor`, and gets a corresponding GitHub Release in this fork's repo.

**Architecture:** A new daily workflow (`sync-release-tags.yml`) diffs upstream GA tags against this fork's tags and pushes any missing ones using a PAT (required so the push cascades into `build-package.yml`, which a default `GITHUB_TOKEN` push cannot do). `build-package.yml`'s version-tag computation is fixed so a tag-push trigger produces a clean image tag (`v2.15.1`, no build suffix) instead of the current always-on `-build.N` suffix. A new job in `build-package.yml` creates a GitHub Release mirroring upstream's release notes once the multi-arch images finish building. The tag-diffing and version-tag logic are extracted into small, pure, unit-tested bash scripts so this can be verified without spending CI minutes.

**Tech Stack:** GitHub Actions (bash `run:` steps), `gh` CLI, `docker buildx`/`docker/build-push-action`, plain bash for the two new utility scripts (no new dependencies).

## Global Constraints

- Version floor: only GA tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$` (no `-rc`/`-build`/etc suffix) at or above `v2.15.0` are in scope. No upper bound.
- Tag-triggered image builds must use the clean tag name (e.g. `v2.15.1`) as the final image tag, with no `-build.N` suffix. Non-tag triggers (main branch push, `workflow_dispatch`) keep the existing `<VERSION>-build.<run_number>` scheme.
- The tag-sync push MUST use `secrets.PAT_TOKEN` (falling back to `secrets.GITHUB_TOKEN` only if PAT_TOKEN is unset, matching the existing pattern in `sync-upstream.yml`). A push made with the default `GITHUB_TOKEN` does not trigger other workflows on this repo — if `PAT_TOKEN` isn't configured as a repo secret, tag pushes will create the git tag but `build-package.yml` will silently never fire. Note this in the PR/handoff.
- New tag-diffing and version-tag logic must be pure (no network calls, no `git` invocations inside the functions) so they can be unit tested with plain fixture data.
- GitHub Release creation only happens when `github.ref_type == 'tag'`, and must be idempotent (skip if a release for that tag already exists).
- Do not touch `publish_release.yml`, package/installer build steps, or anything below `v2.15.0`.

---

### Task 1: `compute_version_tag` utility + tests

**Files:**
- Create: `tools/release/compute_version_tag.sh`
- Create: `tools/release/compute_version_tag.test.sh`

**Interfaces:**
- Produces: shell function `compute_version_tag(ref_type, ref_name, version_file_content, run_number)` → prints the resulting image version tag to stdout. Consumed by Task 2.

- [ ] **Step 1: Write the failing test**

Create `tools/release/compute_version_tag.test.sh`:

```bash
#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/compute_version_tag.sh"

fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

assert_eq "tag push uses the clean tag name, no suffix" \
  "v2.15.1" \
  "$(compute_version_tag tag v2.15.1 v2.16.0 42)"

assert_eq "main branch push uses the build-numbered scheme" \
  "v2.16.0-build.42" \
  "$(compute_version_tag branch main v2.16.0 42)"

assert_eq "workflow_dispatch on a non-main branch also uses the build-numbered scheme" \
  "v2.15.0-build.7" \
  "$(compute_version_tag branch release-2.15.0 v2.15.0 7)"

exit $fail
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/release/compute_version_tag.test.sh`
Expected: FAIL — `compute_version_tag.sh: No such file or directory` (script doesn't exist yet)

- [ ] **Step 3: Write minimal implementation**

Create `tools/release/compute_version_tag.sh`:

```bash
#!/bin/bash
# Computes the container image version tag used by build-package.yml.
#
# Usage: source this file, then call:
#   compute_version_tag <ref_type> <ref_name> <version_file_content> <run_number>
#
# - ref_type: GitHub Actions' `github.ref_type`, either "tag" or "branch"
# - ref_name: GitHub Actions' `github.ref_name` (e.g. "v2.15.1" for a tag push,
#             "main" for a branch push)
# - version_file_content: contents of the repo's VERSION file (e.g. "v2.16.0")
# - run_number: GitHub Actions' `github.run_number`
#
# When triggered by a GA version tag push, the output is the tag itself with
# no suffix (e.g. "v2.15.1") so the resulting image tag matches upstream/Helm
# chart appVersion exactly. Otherwise (main branch push, workflow_dispatch),
# the existing build-numbered scheme is preserved (e.g. "v2.16.0-build.42").
compute_version_tag() {
  local ref_type="$1"
  local ref_name="$2"
  local version_file_content="$3"
  local run_number="$4"

  if [ "$ref_type" = "tag" ]; then
    echo "$ref_name"
  else
    echo "${version_file_content}-build.${run_number}"
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  compute_version_tag "$1" "$2" "$3" "$4"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tools/release/compute_version_tag.test.sh`
Expected:
```
PASS: tag push uses the clean tag name, no suffix
PASS: main branch push uses the build-numbered scheme
PASS: workflow_dispatch on a non-main branch also uses the build-numbered scheme
```
(exit code 0)

- [ ] **Step 5: Commit**

```bash
git add tools/release/compute_version_tag.sh tools/release/compute_version_tag.test.sh
git commit -m "feat(ci): add compute_version_tag helper for clean release-tag image tagging"
```

---

### Task 2: Wire `compute_version_tag` into `build-package.yml`

**Files:**
- Modify: `.github/workflows/build-package.yml:61-76` (the `Prepare version info` step inside the `BUILD_PACKAGE` job)

**Interfaces:**
- Consumes: `compute_version_tag` from Task 1 (`tools/release/compute_version_tag.sh`)
- Produces: unchanged output names (`steps.version.outputs.tag`, `steps.version.outputs.assets_version`) — same contract every downstream job already relies on, only the *value* changes for tag-triggered runs.

- [ ] **Step 1: Replace the step body**

Replace the existing step (lines 61-76):

```yaml
      - name: Prepare version info
        id: version
        run: |
          target_release_version=$(cat ./VERSION)
          Harbor_Package_Version=$target_release_version-'build.'$GITHUB_RUN_NUMBER
          target_branch="$(echo ${GITHUB_REF#refs/heads/})"
          
          if [[ $target_branch == "main" ]]; then
            Harbor_Assets_Version=$Harbor_Package_Version
          else
            Harbor_Assets_Version=$target_release_version
          fi
          
          echo "tag=${Harbor_Package_Version}" >> $GITHUB_OUTPUT
          echo "assets_version=${Harbor_Assets_Version}" >> $GITHUB_OUTPUT
          echo "HARBOR_VERSION=${Harbor_Assets_Version}" >> $GITHUB_ENV
```

with:

```yaml
      - name: Prepare version info
        id: version
        run: |
          source tools/release/compute_version_tag.sh

          target_release_version=$(cat ./VERSION)
          target_branch="$(echo ${GITHUB_REF#refs/heads/})"
          Harbor_Package_Version=$(compute_version_tag "${{ github.ref_type }}" "${{ github.ref_name }}" "$target_release_version" "$GITHUB_RUN_NUMBER")

          if [[ $target_branch == "main" ]]; then
            Harbor_Assets_Version=$Harbor_Package_Version
          else
            Harbor_Assets_Version=$target_release_version
          fi

          echo "tag=${Harbor_Package_Version}" >> $GITHUB_OUTPUT
          echo "assets_version=${Harbor_Assets_Version}" >> $GITHUB_OUTPUT
          echo "HARBOR_VERSION=${Harbor_Assets_Version}" >> $GITHUB_ENV
```

(This step runs with the default working directory, which is the first `actions/checkout@v6` at repo root — same place `tools/release/compute_version_tag.sh` and `./VERSION` live, so no `cd` is needed. Confirm this by checking that the two checkout steps preceding it are still: a root checkout, then a second checkout with `path: src/github.com/goharbor/harbor` — the version step reads `./VERSION` from the root checkout today, unchanged by this edit.)

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the new call sites by hand-simulating both branches**

Run:
```bash
source tools/release/compute_version_tag.sh
echo "$(compute_version_tag tag v2.15.1 v2.16.0 99)"      # expect: v2.15.1
echo "$(compute_version_tag branch main v2.16.0 99)"      # expect: v2.16.0-build.99
```
Expected output:
```
v2.15.1
v2.16.0-build.99
```
This confirms the exact two code paths `build-package.yml` will exercise, using the already-unit-tested function from Task 1 — no live GitHub Actions run needed to validate the logic itself (Task 6 covers the live end-to-end check).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): use clean tag name for release-tag-triggered image builds"
```

---

### Task 3: `sync_release_tags` utilities + tests

**Files:**
- Create: `tools/release/sync_release_tags.sh`
- Create: `tools/release/sync_release_tags.test.sh`

**Interfaces:**
- Produces: shell functions
  - `filter_ga_tags_min_version(min_version)` — reads newline-delimited tags from stdin, writes matching GA tags (sorted ascending) to stdout.
  - `diff_missing_tags(upstream_tags_file, origin_tags_file)` — writes tags present in `upstream_tags_file` but absent from `origin_tags_file` to stdout.
  Both consumed by Task 4.

- [ ] **Step 1: Write the failing test**

Create `tools/release/sync_release_tags.test.sh`:

```bash
#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/sync_release_tags.sh"

fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=1
  else
    echo "PASS: $desc"
  fi
}

# --- filter_ga_tags_min_version ---

input_tags=$'v2.14.0\nv2.15.0\nv2.15.0-rc1\nv2.15.1\nv2.15.1-build.12\nv2.15.2\nv2.16.0\nv3.0.0'
actual=$(printf '%s\n' "$input_tags" | filter_ga_tags_min_version "v2.15.0")
expected=$'v2.15.0\nv2.15.1\nv2.15.2\nv2.16.0\nv3.0.0'
assert_eq "filters out pre-v2.15.0, rc, and build-suffixed tags" "$expected" "$actual"

actual_empty=$(printf 'v2.14.0\nv2.14.5\n' | filter_ga_tags_min_version "v2.15.0")
assert_eq "returns nothing when all tags are below the floor" "" "$actual_empty"

# --- diff_missing_tags ---

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

printf 'v2.15.0\nv2.15.1\nv2.15.2\nv2.16.0\n' > "$tmp_dir/upstream.txt"
printf 'v2.15.0\nv2.16.0\n' > "$tmp_dir/origin.txt"

actual_missing=$(diff_missing_tags "$tmp_dir/upstream.txt" "$tmp_dir/origin.txt")
expected_missing=$'v2.15.1\nv2.15.2'
assert_eq "reports tags present upstream but missing from origin" "$expected_missing" "$actual_missing"

actual_none_missing=$(diff_missing_tags "$tmp_dir/origin.txt" "$tmp_dir/origin.txt")
assert_eq "reports nothing when lists are identical" "" "$actual_none_missing"

exit $fail
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/release/sync_release_tags.test.sh`
Expected: FAIL — `sync_release_tags.sh: No such file or directory`

- [ ] **Step 3: Write minimal implementation**

Create `tools/release/sync_release_tags.sh`:

```bash
#!/bin/bash
# Helper functions for syncing upstream GA release tags into this fork.
# All functions operate on plain newline-delimited tag lists (no network
# calls) so they can be unit tested in isolation. The calling workflow is
# responsible for producing those lists via `git ls-remote --tags`.

# filter_ga_tags_min_version <min_version>
# Reads tags (one per line) from stdin, outputs only strict GA tags
# (vX.Y.Z, no -rc/-build/etc suffix) at or above <min_version>, sorted
# ascending by version.
filter_ga_tags_min_version() {
  local min_version="$1"
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | while IFS= read -r tag; do
        if [ "$(printf '%s\n%s\n' "$min_version" "$tag" | sort -V | head -n1)" = "$min_version" ]; then
          echo "$tag"
        fi
      done \
    | sort -V
}

# diff_missing_tags <upstream_tags_file> <origin_tags_file>
# Prints tags present in <upstream_tags_file> but absent from
# <origin_tags_file>.
diff_missing_tags() {
  local upstream_file="$1"
  local origin_file="$2"
  comm -23 \
    <(sort "$upstream_file") \
    <(sort "$origin_file")
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "$1" in
    filter_ga_tags_min_version) shift; filter_ga_tags_min_version "$@" ;;
    diff_missing_tags) shift; diff_missing_tags "$@" ;;
    *) echo "usage: $0 {filter_ga_tags_min_version <min_version> | diff_missing_tags <upstream_file> <origin_file>}" >&2; exit 1 ;;
  esac
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tools/release/sync_release_tags.test.sh`
Expected:
```
PASS: filters out pre-v2.15.0, rc, and build-suffixed tags
PASS: returns nothing when all tags are below the floor
PASS: reports tags present upstream but missing from origin
PASS: reports nothing when lists are identical
```
(exit code 0)

- [ ] **Step 5: Commit**

```bash
git add tools/release/sync_release_tags.sh tools/release/sync_release_tags.test.sh
git commit -m "feat(ci): add sync_release_tags helpers for GA-tag filtering and diffing"
```

---

### Task 4: New workflow `sync-release-tags.yml`

**Files:**
- Create: `.github/workflows/sync-release-tags.yml`

**Interfaces:**
- Consumes: `filter_ga_tags_min_version`, `diff_missing_tags` from Task 3 (`tools/release/sync_release_tags.sh`)
- Produces: pushes missing GA tags (`>= v2.15.0`) to `origin`, which triggers `build-package.yml` (`on: push: tags: 'v*'`).

- [ ] **Step 1: Create the workflow file**

Create `.github/workflows/sync-release-tags.yml`:

```yaml
name: "Sync Release Tags"

on:
  schedule:
    - cron: '30 0 * * *' # 매일 00:30 UTC, sync-upstream.yml(00:00) 직후 실행
  workflow_dispatch:
    inputs:
      dry_run:
        description: "true면 반영 대상 태그만 로그로 출력하고 실제 push는 하지 않음"
        type: boolean
        default: true

jobs:
  sync-release-tags:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    env:
      MIN_GA_VERSION: v2.15.0
      DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && github.event.inputs.dry_run || 'false' }}
    steps:
      - name: Checkout target branch
        uses: actions/checkout@v4
        with:
          ref: main
          fetch-depth: 0
          token: ${{ secrets.PAT_TOKEN || secrets.GITHUB_TOKEN }}

      - name: Sync missing upstream GA tags
        env:
          GH_TOKEN: ${{ secrets.PAT_TOKEN || secrets.GITHUB_TOKEN }}
        run: |
          set -euo pipefail
          source tools/release/sync_release_tags.sh

          git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${{ github.repository }}.git"

          if git remote | grep -q '^upstream$'; then
            git remote set-url upstream https://github.com/goharbor/harbor.git
          else
            git remote add upstream https://github.com/goharbor/harbor.git
          fi

          tmp_dir=$(mktemp -d)
          git ls-remote --tags upstream | awk '{print $2}' | sed 's#refs/tags/##; s/\^{}//' | sort -u > "$tmp_dir/upstream_raw.txt"
          git ls-remote --tags origin   | awk '{print $2}' | sed 's#refs/tags/##; s/\^{}//' | sort -u > "$tmp_dir/origin_raw.txt"

          filter_ga_tags_min_version "$MIN_GA_VERSION" < "$tmp_dir/upstream_raw.txt" > "$tmp_dir/upstream_ga.txt"
          filter_ga_tags_min_version "$MIN_GA_VERSION" < "$tmp_dir/origin_raw.txt"   > "$tmp_dir/origin_ga.txt"

          missing=$(diff_missing_tags "$tmp_dir/upstream_ga.txt" "$tmp_dir/origin_ga.txt")

          {
            echo "## Sync Release Tags"
            echo
            if [ -z "$missing" ]; then
              echo "No missing GA tags (>= ${MIN_GA_VERSION}). Nothing to do."
            else
              echo "Missing GA tags (>= ${MIN_GA_VERSION}):"
              echo '```'
              echo "$missing"
              echo '```'
            fi
          } >> "$GITHUB_STEP_SUMMARY"

          if [ -z "$missing" ]; then
            exit 0
          fi

          if [ "$DRY_RUN" = "true" ]; then
            echo "dry_run=true, skipping push." >> "$GITHUB_STEP_SUMMARY"
            exit 0
          fi

          failed=0
          while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            echo "Fetching and pushing ${tag}..."
            if git fetch upstream "refs/tags/${tag}:refs/tags/${tag}" \
               && git push origin "refs/tags/${tag}:refs/tags/${tag}"; then
              echo "- pushed: ${tag}" >> "$GITHUB_STEP_SUMMARY"
            else
              echo "- FAILED: ${tag}" >> "$GITHUB_STEP_SUMMARY"
              failed=1
            fi
          done <<< "$missing"

          exit $failed
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-release-tags.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Dry-run the diffing logic locally against real remotes (no push)**

Run:
```bash
source tools/release/sync_release_tags.sh
tmp_dir=$(mktemp -d)
git ls-remote --tags https://github.com/goharbor/harbor.git | awk '{print $2}' | sed 's#refs/tags/##; s/\^{}//' | sort -u > "$tmp_dir/upstream_raw.txt"
git ls-remote --tags origin | awk '{print $2}' | sed 's#refs/tags/##; s/\^{}//' | sort -u > "$tmp_dir/origin_raw.txt"
filter_ga_tags_min_version v2.15.0 < "$tmp_dir/upstream_raw.txt" > "$tmp_dir/upstream_ga.txt"
filter_ga_tags_min_version v2.15.0 < "$tmp_dir/origin_raw.txt" > "$tmp_dir/origin_ga.txt"
diff_missing_tags "$tmp_dir/upstream_ga.txt" "$tmp_dir/origin_ga.txt"
```
Expected: a list including at least `v2.15.1` and `v2.15.2` (confirmed missing from `origin` earlier in this conversation). This proves the exact shell pipeline the workflow uses works against the real repos before it's ever run in CI.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/sync-release-tags.yml
git commit -m "feat(ci): add daily sync-release-tags workflow to mirror upstream GA tags"
```

---

### Task 5: GitHub Release creation job in `build-package.yml`

**Files:**
- Modify: `.github/workflows/build-package.yml` (append a new job after the `summary` job, i.e. after the current last line)

**Interfaces:**
- Consumes: `needs.BUILD_PACKAGE.outputs.version_tag` is NOT needed here — this job uses `github.ref_name` directly (only runs when `github.ref_type == 'tag'`, so `ref_name` is already the clean tag, e.g. `v2.15.1`).
- Depends on: `BUILD_PACKAGE`, `build-final-images` jobs (must wait for images to actually be built before announcing a release).

- [ ] **Step 1: Append the new job**

Add to the end of `.github/workflows/build-package.yml`:

```yaml

  # ========================================
  # 9단계: GitHub Release 생성 (태그 트리거 시에만)
  # ========================================
  create-github-release:
    runs-on: ubuntu-latest
    needs:
      - BUILD_PACKAGE
      - build-final-images
    if: github.ref_type == 'tag'
    permissions:
      contents: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Fetch upstream release notes
        id: upstream_notes
        run: |
          set -euo pipefail
          tag="${{ github.ref_name }}"
          notes=$(curl -s \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/goharbor/harbor/releases/tags/${tag}" \
            | jq -r '.body // "(upstream release notes unavailable)"')
          {
            echo "notes<<NOTES_EOF"
            echo "$notes"
            echo ""
            echo "---"
            echo "Mirrored from [goharbor/harbor ${tag}](https://github.com/goharbor/harbor/releases/tag/${tag}), rebuilt here with added \`linux/arm64\` images."
            echo "NOTES_EOF"
          } >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          RELEASE_NOTES: ${{ steps.upstream_notes.outputs.notes }}
        run: |
          set -euo pipefail
          tag="${{ github.ref_name }}"
          if gh release view "$tag" --repo "${{ github.repository }}" >/dev/null 2>&1; then
            echo "Release $tag already exists, skipping."
            exit 0
          fi
          printf '%s\n' "$RELEASE_NOTES" > /tmp/release_notes.md
          gh release create "$tag" \
            --repo "${{ github.repository }}" \
            --title "${tag} (linux/amd64, linux/arm64)" \
            --notes-file /tmp/release_notes.md
```

(Passing the fetched notes via an `env:` var rather than interpolating `${{ steps.upstream_notes.outputs.notes }}` directly into the script body avoids GitHub Actions' literal-substitution-before-execution turning arbitrary characters in the upstream release notes — backticks, `$(...)`, quotes — into executable shell syntax.)

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the idempotency guard against a real tag**

Run:
```bash
gh release view v2.15.0 --repo dasomel/harbor >/dev/null 2>&1 && echo "exists" || echo "does not exist"
```
Expected: `does not exist` (confirms the `gh release view` idempotency check used above is the correct command and exits non-zero when no release exists yet, exactly as the job's `if` branch relies on).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "feat(ci): create a GitHub Release mirroring upstream notes on tag-triggered builds"
```

---

### Task 6: End-to-end verification (live GitHub Actions)

**Files:** none (operational verification only)

**Interfaces:** none — this task exercises Tasks 1-5 together against the real GitHub repo.

- [ ] **Step 1: Confirm `PAT_TOKEN` secret exists**

Run: `gh secret list --repo dasomel/harbor`
Expected: `PAT_TOKEN` is listed. If it is missing, tag pushes from Task 4's workflow will create tags but will NOT trigger `build-package.yml` (GitHub Actions does not cascade-trigger workflows from a push authenticated with the default `GITHUB_TOKEN`) — stop and get a PAT configured before proceeding.

- [ ] **Step 2: Push the two new workflow files and run a dry-run sync**

```bash
git push origin main
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=true
```

- [ ] **Step 3: Confirm the dry-run summary lists the expected missing tags**

Run: `gh run view --repo dasomel/harbor --workflow sync-release-tags.yml --log | grep -A5 "Missing GA tags"`
Expected: output includes `v2.15.1` and `v2.15.2`.

- [ ] **Step 4: Run for real**

```bash
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=false
```

- [ ] **Step 5: Confirm `build-package.yml` was triggered per pushed tag**

Run: `gh run list --repo dasomel/harbor --workflow build-package.yml --limit 5`
Expected: new runs with `event: push` and the ref matching each newly pushed tag (e.g. `v2.15.1`, `v2.15.2`).

- [ ] **Step 6: After a build completes, confirm the multi-arch image and the clean tag**

Run: `docker buildx imagetools inspect ghcr.io/dasomel/goharbor/harbor-core:v2.15.1`
Expected: a manifest list containing both `linux/amd64` and `linux/arm64` platforms (no `-build.N` suffix in the tag).

- [ ] **Step 7: Confirm the GitHub Release was created**

Run: `gh release view v2.15.1 --repo dasomel/harbor`
Expected: a release titled `v2.15.1 (linux/amd64, linux/arm64)` with body text mentioning it was mirrored from `goharbor/harbor`.
