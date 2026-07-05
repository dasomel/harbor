# Upstream GA Tag → ARM64 Image Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every upstream `goharbor/harbor` GA release tag `>= v2.15.0` gets automatically mirrored into this fork, triggers a clean-tagged multi-arch (amd64+arm64) image build on `ghcr.io/dasomel/goharbor`, and gets a corresponding GitHub Release in this fork's repo.

**Architecture:** A new daily workflow (`sync-release-tags.yml`) diffs upstream GA tags against this fork's tags, pushes any missing ones (as bookkeeping markers), and then **explicitly invokes** `build-package.yml` via `gh workflow run --ref main -f release_tag=<tag>`. `build-package.yml`'s version-tag computation is fixed so both a direct tag push AND a `release_tag`-carrying `workflow_dispatch` produce a clean image tag (`v2.15.1`, no build suffix) instead of the current always-on `-build.N` suffix. A new job in `build-package.yml` creates a GitHub Release mirroring upstream's release notes once the multi-arch images finish building. The tag-diffing and version-tag logic are extracted into small, pure, unit-tested bash scripts so this can be verified without spending CI minutes.

**Tech Stack:** GitHub Actions (bash `run:` steps), `gh` CLI, `docker buildx`/`docker/build-push-action`, plain bash for the two new utility scripts (no new dependencies).

## Design Revision (post Task 1-5 whole-branch review)

The original design (Tasks 1-5) assumed that pushing an upstream tag object to `origin` would trigger `build-package.yml` via its `on: push: tags: 'v*'` trigger. **This is false and was caught by the final whole-branch review, independently confirmed against the real upstream repo:** GitHub Actions evaluates which workflows a `push` event triggers, and with what trigger conditions, using the workflow file **as it exists in the pushed ref's own tree** — not the version on this fork's `main` branch. Since a synced tag (e.g. `v2.15.1`) points at an *upstream* commit, and upstream's own `.github/workflows/build-package.yml` at that commit only triggers `on: push: branches: [main, release-*]` (no `tags:` key at all — confirmed via `git show v2.15.1:.github/workflows/build-package.yml`), pushing that tag to `origin` triggers **nothing**.

**Fix:** stop relying on the tag push itself to trigger the build. `sync-release-tags.yml` still pushes the tag (useful as a human-readable marker and for the idempotency/diffing check), but immediately follows it with an explicit `gh workflow run build-package.yml --ref main -f release_tag=<tag>` call. Because this is invoked with `--ref main`, GitHub Actions uses **this fork's own, current** `build-package.yml` — the one with the fixed version-tag logic, the multi-arch build, and the release job — regardless of what the pushed tag's tree contains. `build-package.yml` gains a new `release_tag` `workflow_dispatch` input: when set, every job's source checkout is pinned to that tag (so the actual Harbor source built is upstream's exact release content), while the workflow *definition* itself still comes from `main`.

This also removes the original PAT requirement for the *push* to matter (a plain `GITHUB_TOKEN` push is fine now, since we no longer depend on it cascading into anything) — but `sync-release-tags.yml` now needs `actions: write` permission so `gh workflow run` can invoke `build-package.yml`.

## Global Constraints

- Version floor: only GA tags matching `^v[0-9]+\.[0-9]+\.[0-9]+$` (no `-rc`/`-build`/etc suffix) at or above `v2.15.0` are in scope. No upper bound.
- Tag-triggered and `release_tag`-driven image builds must use the clean tag name (e.g. `v2.15.1`) as the final image tag, with no `-build.N` suffix. Plain main-branch/`workflow_dispatch`-without-`release_tag` triggers keep the existing `<VERSION>-build.<run_number>` scheme.
- `sync-release-tags.yml` must have `permissions: actions: write` (in addition to `contents: write`) so it can call `gh workflow run build-package.yml`. The `secrets.PAT_TOKEN || secrets.GITHUB_TOKEN` fallback pattern (matching `sync-upstream.yml`'s existing convention) is kept for the tag push itself, but a PAT is no longer strictly required for the feature to work end-to-end — the default `GITHUB_TOKEN` with `actions: write` is sufficient for both the push and the `gh workflow run` call.
- Every `actions/checkout` step in `build-package.yml` that checks out the Harbor source to build (as opposed to just reading this repo's own CI scripts) must honor `ref: ${{ inputs.release_tag || github.ref }}`, so a `release_tag`-driven run builds the exact upstream release source, not whatever is on `main`.
- New tag-diffing and version-tag logic must be pure (no network calls, no `git` invocations inside the functions) so they can be unit tested with plain fixture data.
- GitHub Release creation happens when `github.ref_type == 'tag'` OR `inputs.release_tag != ''`, and must be idempotent (skip if a release for that tag already exists). The tag name used throughout that job must come from `inputs.release_tag || github.ref_name`, passed via an `env:` var (never interpolated directly into a `run:` script body via `${{ }}`) — this applies to the release-notes body (already fixed in Task 5) and to the tag name itself (a gap Task 5 left open, since git tag names can contain shell metacharacters and are pushed by anyone with tag-push rights).
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

### Task 6: `release_tag` workflow_dispatch input in `build-package.yml`

**Files:**
- Modify: `.github/workflows/build-package.yml` (trigger block, `BUILD_PACKAGE` job's second checkout and "Prepare version info" step, every other job's source checkout, `create-github-release` job's gate and tag handling)

**Interfaces:**
- Consumes: `compute_version_tag` (Task 1), the existing `create-github-release` job (Task 5)
- Produces: a `release_tag` `workflow_dispatch` input that Task 7's `sync-release-tags.yml` invokes via `gh workflow run`.

- [ ] **Step 1: Add the `release_tag` input to the trigger block**

Replace:
```yaml
on:
  push:
    tags:
      - 'v*'  # v2.15.0, v2.16.0 등 버전 태그에만 반응
  workflow_dispatch:
```
with:
```yaml
on:
  push:
    tags:
      - 'v*'  # v2.15.0, v2.16.0 등 버전 태그에만 반응
  workflow_dispatch:
    inputs:
      release_tag:
        description: "업스트림 GA 릴리즈 태그를 이 fork의 CI로 빌드할 때 지정 (예: v2.15.1). 비워두면 기존 workflow_dispatch 동작(build.N 태깅) 그대로."
        required: false
        type: string
        default: ""
```

- [ ] **Step 2: Pin the `BUILD_PACKAGE` job's source checkout to `release_tag` when provided**

Find the second checkout in the `BUILD_PACKAGE` job (the one with `path: src/github.com/goharbor/harbor`):
```yaml
      - uses: actions/checkout@v6
        with:
          path: src/github.com/goharbor/harbor
```
Replace with:
```yaml
      - uses: actions/checkout@v6
        with:
          path: src/github.com/goharbor/harbor
          ref: ${{ inputs.release_tag || github.ref }}
```
(The *first* checkout in this job — the one with no `path:`, used to read `./VERSION` and `tools/release/compute_version_tag.sh` — stays untouched; it must keep resolving to `main` so this fork's own CI scripts are present, which is exactly what happens by default when the run is dispatched with `--ref main`.)

- [ ] **Step 3: Update "Prepare version info" to honor `release_tag`**

Replace the step body (as it stands after Task 2's edit):
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
with:
```yaml
      - name: Prepare version info
        id: version
        run: |
          source tools/release/compute_version_tag.sh

          target_release_version=$(cat ./VERSION)
          target_branch="$(echo ${GITHUB_REF#refs/heads/})"
          release_tag="${{ inputs.release_tag }}"

          if [ -n "$release_tag" ]; then
            ref_type_for_tag="tag"
            ref_name_for_tag="$release_tag"
          else
            ref_type_for_tag="${{ github.ref_type }}"
            ref_name_for_tag="${{ github.ref_name }}"
          fi

          Harbor_Package_Version=$(compute_version_tag "$ref_type_for_tag" "$ref_name_for_tag" "$target_release_version" "$GITHUB_RUN_NUMBER")

          if [ -n "$release_tag" ] || [[ $target_branch == "main" ]]; then
            Harbor_Assets_Version=$Harbor_Package_Version
          else
            Harbor_Assets_Version=$target_release_version
          fi

          echo "tag=${Harbor_Package_Version}" >> $GITHUB_OUTPUT
          echo "assets_version=${Harbor_Assets_Version}" >> $GITHUB_OUTPUT
          echo "HARBOR_VERSION=${Harbor_Assets_Version}" >> $GITHUB_ENV
```

- [ ] **Step 4: Pin every other job's source checkout to `release_tag` when provided**

In each of these jobs — `build-base-images`, `compile-binaries`, `compile-registry`, `compile-trivy-adapter`, `compile-exporter`, `build-final-images` — find the `Checkout repository` step:
```yaml
      - name: Checkout repository
        uses: actions/checkout@v4
```
and replace with:
```yaml
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          ref: ${{ inputs.release_tag || github.ref }}
```
Do this in all six jobs listed above (grep for `uses: actions/checkout@v4` to find every occurrence in this file — there should be exactly six, one per job). Do not touch the `BUILD_PACKAGE` job's checkouts again here (already handled in Steps 1-3) or the `create-github-release` job's checkout (handled separately in Step 5 — it doesn't build source, so it doesn't need this).

- [ ] **Step 5: Update the `create-github-release` job's gate and tag handling**

Replace:
```yaml
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
with:
```yaml
  create-github-release:
    runs-on: ubuntu-latest
    needs:
      - BUILD_PACKAGE
      - build-final-images
    if: github.ref_type == 'tag' || inputs.release_tag != ''
    permissions:
      contents: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Fetch upstream release notes
        id: upstream_notes
        env:
          TAG_NAME: ${{ inputs.release_tag || github.ref_name }}
        run: |
          set -euo pipefail
          tag="$TAG_NAME"
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
          TAG_NAME: ${{ inputs.release_tag || github.ref_name }}
        run: |
          set -euo pipefail
          tag="$TAG_NAME"
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
(This also fixes a gap the Task 5 review flagged: `github.ref_name`/the tag name is now passed via the `TAG_NAME` env var instead of being interpolated directly into the script bodies via `${{ }}`, consistent with how `RELEASE_NOTES` was already handled.)

- [ ] **Step 6: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 7: Verify all six non-`BUILD_PACKAGE`/non-`create-github-release` checkouts were updated**

Run: `grep -B2 "uses: actions/checkout@v4" .github/workflows/build-package.yml | grep -c "ref: \${{ inputs.release_tag || github.ref }}"`
Expected: `6` (one per job: `build-base-images`, `compile-binaries`, `compile-registry`, `compile-trivy-adapter`, `compile-exporter`, `build-final-images`). If it's `7`, the `create-github-release` job's checkout was mistakenly also given the `ref:` override — remove it there, since that job never builds source and doesn't need it.

- [ ] **Step 8: Hand-simulate both the plain-tag-push path and the new `release_tag` path**

Run:
```bash
source tools/release/compute_version_tag.sh
# Simulates a direct tag push (unchanged behavior):
echo "$(compute_version_tag tag v2.15.1 v2.16.0 99)"      # expect: v2.15.1
# Simulates the release_tag-driven path (release_tag set, ref_type/ref_name overridden to tag/v2.15.1 before calling compute_version_tag — this is exactly what Step 3's new branch does):
echo "$(compute_version_tag tag v2.15.1 v2.16.0 150)"     # expect: v2.15.1
# Simulates a plain workflow_dispatch with no release_tag on main (unchanged behavior):
echo "$(compute_version_tag branch main v2.16.0 150)"     # expect: v2.16.0-build.150
```
Expected output:
```
v2.15.1
v2.15.1
v2.16.0-build.150
```

- [ ] **Step 9: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): support release_tag workflow_dispatch input so sync-triggered builds use fork's own workflow

The sync-release-tags workflow cannot rely on pushing an upstream tag to
trigger build-package.yml's on:push:tags — GitHub Actions evaluates that
trigger using the pushed ref's own tree, which for an upstream tag is
upstream's original build-package.yml (no tags trigger at all). Instead,
sync-release-tags.yml now explicitly invokes this workflow via
workflow_dispatch with a release_tag input, pinning every source checkout
to that tag while still running this fork's own (main-branch) workflow
definition."
```

---

### Task 7: Explicit `gh workflow run` invocation in `sync-release-tags.yml`

**Files:**
- Modify: `.github/workflows/sync-release-tags.yml` (permissions block, the push loop)

**Interfaces:**
- Consumes: the `release_tag` input added to `build-package.yml` in Task 6.
- Produces: nothing new consumed elsewhere — this is the last piece of the trigger chain.

- [ ] **Step 1: Add `actions: write` permission**

Replace:
```yaml
    permissions:
      contents: write
```
with:
```yaml
    permissions:
      contents: write
      actions: write
```

- [ ] **Step 2: Invoke `build-package.yml` explicitly after each successful tag push**

Find the push loop (inside the "Sync missing upstream GA tags" step):
```bash
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
Replace with:
```bash
          failed=0
          while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            echo "Fetching and pushing ${tag}..."
            if git fetch upstream "refs/tags/${tag}:refs/tags/${tag}" \
               && git push origin "refs/tags/${tag}:refs/tags/${tag}"; then
              echo "- pushed: ${tag}" >> "$GITHUB_STEP_SUMMARY"
              echo "Triggering build-package.yml for ${tag}..."
              if gh workflow run build-package.yml --repo "${{ github.repository }}" --ref main -f release_tag="${tag}"; then
                echo "  - triggered build-package.yml (release_tag=${tag})" >> "$GITHUB_STEP_SUMMARY"
              else
                echo "  - FAILED to trigger build-package.yml for ${tag}" >> "$GITHUB_STEP_SUMMARY"
                failed=1
              fi
            else
              echo "- FAILED: ${tag}" >> "$GITHUB_STEP_SUMMARY"
              failed=1
            fi
          done <<< "$missing"

          exit $failed
```
(`gh` is already authenticated for this step via the existing `GH_TOKEN` env var on the "Sync missing upstream GA tags" step — no new env var needed. `gh workflow run` needs `actions: write`, added in Step 1.)

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-release-tags.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/sync-release-tags.yml
git commit -m "fix(ci): explicitly trigger build-package.yml via workflow_dispatch instead of relying on tag push"
```

---

### Task 8: End-to-end verification (live GitHub Actions)

**Files:** none (operational verification only)

**Interfaces:** none — this task exercises Tasks 1-7 together against the real GitHub repo.

- [ ] **Step 1: Push the branch's commits to `origin/main`**

This branch's work needs to land on `main` before the daily `schedule` trigger (or a manual `workflow_dispatch`) can exercise it end-to-end. Follow the project's normal merge process for this (e.g. `superpowers:finishing-a-development-branch`) rather than force-pushing directly.

- [ ] **Step 2: Run a dry-run sync**

```bash
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=true
```

- [ ] **Step 3: Confirm the dry-run summary lists the expected missing tags**

Run: `gh run view --repo dasomel/harbor --workflow sync-release-tags.yml --log | grep -A5 "Missing GA tags"`
Expected: output includes `v2.15.1` and `v2.15.2` (and by now, possibly newer GA tags too, since upstream releases continuously).

- [ ] **Step 4: Run for real**

```bash
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=false
```

- [ ] **Step 5: Confirm `build-package.yml` was explicitly triggered per tag, not via a tag-push event**

Run: `gh run list --repo dasomel/harbor --workflow build-package.yml --limit 5 --json event,displayTitle,status`
Expected: new runs with `"event": "workflow_dispatch"` (not `"push"`), one per newly-synced tag.

- [ ] **Step 6: After a build completes, confirm the multi-arch image and the clean tag**

Run: `docker buildx imagetools inspect ghcr.io/dasomel/goharbor/harbor-core:v2.15.1`
Expected: a manifest list containing both `linux/amd64` and `linux/arm64` platforms (no `-build.N` suffix in the tag).

- [ ] **Step 7: Confirm the GitHub Release was created**

Run: `gh release view v2.15.1 --repo dasomel/harbor`

---

### Task 9: Key idempotency off Release existence, not tag-in-origin (self-healing retry)

**Files:**
- Modify: `.github/workflows/sync-release-tags.yml` (the "Sync missing upstream GA tags" step's data-gathering lines)

**Interfaces:**
- Consumes: `filter_ga_tags_min_version`, `diff_missing_tags` from Task 3 — unchanged signatures, just fed a different "already have" data source.

**Why:** the round-2 whole-branch review found that once the tag push and the actual build were decoupled (Task 6-7's fix), keying "is this tag missing?" off "does the tag exist in `origin`" creates a silent stuck state: the tag gets pushed BEFORE the build runs, so if `gh workflow run` fails, or the dispatched `build-package.yml` run later fails for any reason (transient runner issue, one failing matrix component, etc.), the tag is already in `origin` — so the next day's sync sees it as "not missing" and never retries, and no GitHub Release or images are ever produced for that version, with no visible signal. Keying idempotency off **"does a GitHub Release already exist for this tag"** instead makes the loop self-healing: a failed build leaves no Release, so the tag is still treated as missing and retried on the next scheduled run (re-pushing an identical tag is a harmless no-op; re-running `gh workflow run` is exactly the retry we want).

- [ ] **Step 1: Replace the "already have" data source**

Replace:
```bash
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
```
with:
```bash
          tmp_dir=$(mktemp -d)
          git ls-remote --tags upstream | awk '{print $2}' | sed 's#refs/tags/##; s/\^{}//' | sort -u > "$tmp_dir/upstream_raw.txt"
          gh release list --repo "${{ github.repository }}" --limit 1000 --json tagName -q '.[].tagName' | sort -u > "$tmp_dir/released_raw.txt"

          filter_ga_tags_min_version "$MIN_GA_VERSION" < "$tmp_dir/upstream_raw.txt" > "$tmp_dir/upstream_ga.txt"
          filter_ga_tags_min_version "$MIN_GA_VERSION" < "$tmp_dir/released_raw.txt" > "$tmp_dir/released_ga.txt"

          missing=$(diff_missing_tags "$tmp_dir/upstream_ga.txt" "$tmp_dir/released_ga.txt")

          {
            echo "## Sync Release Tags"
            echo
            if [ -z "$missing" ]; then
              echo "No GA tags (>= ${MIN_GA_VERSION}) without a completed Release. Nothing to do."
            else
              echo "GA tags (>= ${MIN_GA_VERSION}) without a completed Release (will be (re-)triggered):"
              echo '```'
              echo "$missing"
              echo '```'
            fi
          } >> "$GITHUB_STEP_SUMMARY"
```

Do not change anything below this (the `DRY_RUN` check, or the push/trigger loop) — the loop still needs to push the tag (idempotent no-op if it's already there from a previous failed attempt) before calling `gh workflow run`, since `build-package.yml`'s checkout steps resolve `ref: inputs.release_tag` against `origin`, which requires the tag to actually exist there.

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-release-tags.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm the re-run behavior with the real repo (read-only — this just lists current releases, no writes)**

Run:
```bash
gh release list --repo dasomel/harbor --limit 1000 --json tagName -q '.[].tagName' | sort -u
```
Expected: prints whatever GitHub Releases currently exist on the fork (very likely empty right now, since none have been created yet) — confirms the command itself is valid and reachable with the current `gh` auth, independent of the workflow.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/sync-release-tags.yml
git commit -m "fix(ci): key tag-sync idempotency off Release existence, not tag-in-origin

Pushing the tag and running the build are now decoupled (a prior fix made
sync-release-tags.yml explicitly invoke build-package.yml via
workflow_dispatch rather than relying on the push itself to trigger it).
Checking 'does this tag exist in origin' to decide what's missing meant a
failed build left a permanently-stuck, silently-unretried tag: the tag was
already pushed, so the next day's sync saw nothing to do. Keying off
'does a GitHub Release exist for this tag' instead makes a failed run
self-healing — it gets retried on the next scheduled sync."
```

---

### Task 10: Fix `filter_ga_tags_min_version` aborting the workflow when its input has zero matches

**Files:**
- Modify: `tools/release/sync_release_tags.sh` (the `filter_ga_tags_min_version` function)
- Modify: `tools/release/sync_release_tags.test.sh` (add a regression test that exercises the bug's actual failure mode)

**Interfaces:** unchanged — same function signature/behavior contract (stdin in, filtered+sorted tags out), just no longer aborts the calling script when it legitimately produces zero output.

**Why:** live end-to-end testing against the real repo (Task 8) found that `sync-release-tags.yml`'s first real dry-run failed immediately, with zero output, before printing anything. Root cause: `filter_ga_tags_min_version` pipes through `grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'`, and `grep` exits with status `1` when it matches **zero** lines — this is standard, correct `grep` behavior, not an error. Under `set -euo pipefail`, that `1` becomes the whole pipeline's exit status (pipefail takes the rightmost non-zero), which then aborts the entire script via `set -e`. This function is called directly (not wrapped in `$(...)` command substitution) at `.github/workflows/sync-release-tags.yml`'s line computing `released_ga.txt` from `released_raw.txt` — and `released_raw.txt` is empty right now because this fork has zero GitHub Releases yet (a brand new, never-yet-successful sync), which is exactly the state that hits this bug. It will keep happening any time zero already-released GA tags exist, not just on the very first run.

The existing unit test (`sync_release_tags.test.sh`) already covers "returns nothing when all tags are below the floor" but calls the function via `actual_empty=$(printf ... | filter_ga_tags_min_version ...)` — a **variable assignment**. Bash's `set -e` has a specific, easy-to-miss exemption: a failing command substitution on the right-hand side of a plain assignment does *not* trigger `-e` (only the assignment's own — always-successful — exit status is checked). That exemption is exactly why this bug passed unit testing, task review, and two whole-branch reviews undetected: every test and every reviewer's mental trace used the assignment form, which structurally cannot observe this class of bug. The new regression test below calls the function directly (matching how the real workflow calls it) specifically so this can't recur silently.

**Correction (post-implementation):** the test input below uses `printf ''` (genuinely empty stdin). An earlier draft of this step used `printf 'v2.14.0\nv2.14.5\n'` instead — that input does NOT reproduce the bug, since both strings match the GA regex and `grep` exits 0 for them; they only get filtered out afterward by the version-floor comparison inside the `while read` loop (which always exits 0 regardless of whether it echoes anything). Only genuinely zero grep matches exercise the actual failure mode. The implementer caught and fixed this during Task 10; the snippet below reflects the corrected version.

- [ ] **Step 1: Write the failing regression test**

Add to `tools/release/sync_release_tags.test.sh`, in the `filter_ga_tags_min_version` section (after the existing `actual_empty` assertion):

```bash
# Regression: a DIRECT call (not wrapped in `x=$(...)`) must not abort the
# calling script under `set -e` when the input has zero GA matches — this
# is exactly how sync-release-tags.yml invokes it, unlike the assignment
# form above (which bash's set -e semantics exempt from failure detection
# and so cannot catch this class of bug).
direct_call_output_file=$(mktemp)
if (set -euo pipefail; printf '' | filter_ga_tags_min_version "v2.15.0" > "$direct_call_output_file"); then
  direct_call_exit=0
else
  direct_call_exit=$?
fi
assert_eq "direct call (no assignment) exits 0 even when nothing matches" "0" "$direct_call_exit"
assert_eq "direct call produces empty output when nothing matches" "" "$(cat "$direct_call_output_file")"
rm -f "$direct_call_output_file"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tools/release/sync_release_tags.test.sh`
Expected: FAIL — `direct call (no assignment) exits 0 even when nothing matches (expected '0', got '1')` (the subshell aborts via `set -e` before writing to `direct_call_output_file`, so `direct_call_exit` is `1`)

- [ ] **Step 3: Fix `filter_ga_tags_min_version`**

Replace:
```bash
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
```
with:
```bash
filter_ga_tags_min_version() {
  local min_version="$1"
  { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
    | while IFS= read -r tag; do
        if [ "$(printf '%s\n%s\n' "$min_version" "$tag" | sort -V | head -n1)" = "$min_version" ]; then
          echo "$tag"
        fi
      done \
    | sort -V
}
```
(The `|| true` absorbs `grep`'s "zero matches" exit status of `1` right where it happens, so it can never become the pipeline's overall exit status under `pipefail`. A genuine `grep` usage error, distinct from "no matches", is not a case this function needs to distinguish — the function's whole contract is "filter and possibly find nothing.")

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tools/release/sync_release_tags.test.sh`
Expected: all assertions PASS (existing 4 plus the 2 new ones), exit code 0.

- [ ] **Step 5: Re-verify against real, empty input exactly as the workflow uses it**

Run:
```bash
source tools/release/sync_release_tags.sh
(set -euo pipefail; printf '' | filter_ga_tags_min_version "v2.15.0"); echo "exit: $?"
```
Expected: `exit: 0` (empty output, printed nothing, but the subshell did not abort)

- [ ] **Step 6: Commit**

```bash
git add tools/release/sync_release_tags.sh tools/release/sync_release_tags.test.sh
git commit -m "fix(ci): stop grep's zero-matches exit status from aborting filter_ga_tags_min_version

grep exits 1 when it matches nothing — correct grep behavior, but fatal
under this repo's set -euo pipefail workflows when the function is called
directly (not wrapped in an assignment, which set -e otherwise exempts
from failure detection). This is exactly what happened on the first live
run of sync-release-tags.yml: this fork has zero GitHub Releases yet, so
released_raw.txt was empty, grep matched nothing, and the whole step
aborted before printing anything."
```
Expected: a release titled `v2.15.1 (linux/amd64, linux/arm64)` with body text mentioning it was mirrored from `goharbor/harbor`.
