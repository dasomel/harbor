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

---

### Task 11: Skip the legacy Docker-Hub "Build Base Image" step for `release_tag`-driven runs

**Files:**
- Modify: `.github/workflows/build-package.yml` (the `BUILD_PACKAGE` job's "Build Base Image" step's `if:` condition)

**Interfaces:** none — this only narrows an existing `if:` condition; no new inputs/outputs.

**Why:** the first live end-to-end run of the full chain (Task 8) found that all three `release_tag`-triggered `build-package.yml` runs failed within ~45 seconds, in the `BUILD_PACKAGE` job's "Build Base Image" step:

```
+ echo ''
+ docker login -u '' --password-stdin
username is empty
##[error]Process completed with exit code 1.
```

This step's `if:` condition includes `github.event_name == 'workflow_dispatch'` as one of its OR-ed triggers — a condition written for upstream's original workflow, back when this repo's own history shows it already failing the same way on a plain `workflow_dispatch` run months ago (`gh run list` shows a 45s `failure` on `2026-01-31`, pre-dating this feature entirely). The step tries to `docker login` and push `goharbor/photon:5.0` to Docker Hub using `secrets.DOCKER_HUB_USERNAME`/`DOCKER_HUB_PASSWORD` — secrets this fork does not have configured (confirmed via the login step's own literal empty-string interpolation in the log). This is a pre-existing, out-of-scope issue, unrelated to the ARM64 sync feature — but our new `release_tag` `workflow_dispatch` path (Task 6) now reliably triggers it every single time, which fully blocks the feature this plan exists to deliver. This fork's actual multi-arch base images are built separately by the `build-base-images` job (pushing to `ghcr.io/dasomel/goharbor/harbor-*-base`, nothing to do with Docker Hub or this step), so skipping this step for our path does not affect the real build.

The fix is scoped as narrowly as possible: only skip this step when the run was dispatched with a non-empty `release_tag`. A plain `workflow_dispatch` with no `release_tag` (e.g. an ordinary manual dev-build trigger) keeps its current (already broken, pre-existing, out-of-scope) behavior unchanged — fixing that generally is not this task's job.

- [ ] **Step 1: Narrow the `if:` condition**

Replace:
```yaml
      - name: Build Base Image
        if: |
          github.event_name == 'workflow_dispatch' ||
          contains(steps.changed-files.outputs.modified, 'Dockerfile.base') ||
          contains(steps.changed-files.outputs.modified, 'VERSION') ||
          contains(steps.changed-files.outputs.modified, '.buildbaselog') ||
          github.ref == 'refs/heads/main'
```
with:
```yaml
      - name: Build Base Image
        if: |
          (github.event_name == 'workflow_dispatch' && inputs.release_tag == '') ||
          contains(steps.changed-files.outputs.modified, 'Dockerfile.base') ||
          contains(steps.changed-files.outputs.modified, 'VERSION') ||
          contains(steps.changed-files.outputs.modified, '.buildbaselog') ||
          (github.ref == 'refs/heads/main' && inputs.release_tag == '')
```

**Correction (caught mid-implementation):** the fifth OR-term (`github.ref == 'refs/heads/main'`) must ALSO be gated with `&& inputs.release_tag == ''`. `sync-release-tags.yml` always dispatches with `--ref main`, so for our path `github.ref` is `refs/heads/main` regardless of `release_tag` — leaving that term ungated would make the step run anyway, defeating the whole fix. Both terms above need the same `&& inputs.release_tag == ''` guard.

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm the condition logic by hand-tracing both cases**

There is no local harness for evaluating GitHub Actions `if:` expressions, so trace through by hand and write the two cases into your report:
1. `release_tag` set to a non-empty tag (our path): `inputs.release_tag == ''` is `false` → the first OR-term is `false`. If none of the other OR-terms are true either (they check file-diff/ref conditions unrelated to this trigger), the whole condition is `false` → step is skipped. Confirm the other four OR-terms are indeed independent of `release_tag`/`event_name` (they check `steps.changed-files.outputs.modified` and `github.ref`) so they don't accidentally become true for this path.
2. Plain `workflow_dispatch` with no `release_tag` (existing behavior, e.g. dispatched via the GitHub UI with the input left blank, which defaults to `""` per Task 6's `default: ""`): `inputs.release_tag == ''` is `true` → first OR-term is `true` → step still runs, unchanged from today.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): skip legacy Docker-Hub base-image push for release_tag-driven builds

The 'Build Base Image' step tries to docker login + push goharbor/photon:5.0
to Docker Hub, which this fork has no credentials for. Its if: condition
already ran for any workflow_dispatch (a pre-existing, out-of-scope bug —
this repo's own run history shows it failing the same way months before
this feature existed), but our new release_tag workflow_dispatch path
(added to trigger builds for synced upstream tags) now hits it every time,
which blocked the entire ARM64 sync feature. This fork's real multi-arch
base images are built separately by the build-base-images job against
ghcr.io, so skipping this legacy step for release_tag runs doesn't affect
the actual build."
```

- [ ] **Step 5: Re-trigger a live build and confirm it gets past this step**

This is operational verification against the real repo, not a local test:
```bash
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=false
```
Wait for the triggered `build-package.yml` run(s) to reach the `build-base-images` / `compile-*` jobs (they'll take a while — this is a real multi-arch build). Confirm via:
```bash
gh run list --repo dasomel/harbor --workflow build-package.yml --limit 3 --json databaseId,status,conclusion
```
Expected: the run no longer fails within seconds — it should be `in_progress` for a meaningful duration (the real multi-arch build takes roughly an hour), not `completed`/`failure` almost immediately.

---

### Task 12: Dynamically discover buildable components instead of a hardcoded matrix (fixes redis→valkey break)

**Files:**
- Modify: `.github/workflows/build-package.yml` (add a new `discover-components` job; change `build-base-images` and `build-final-images`'s `strategy.matrix.component` to consume it; add a `valkey` case to both "Set component info" steps; add `valkey`/`valkey-photon` to the `summary` job's hardcoded component/package lists)

**Interfaces:**
- Produces: `needs.discover-components.outputs.components` — a JSON array string (e.g. `["core","db",...,"valkey"]`) consumed via `fromJson(...)` by `build-base-images` and `build-final-images`'s `strategy.matrix.component`.

**Why:** live end-to-end testing (Task 8) found that the real `v2.15.2` build failed with:
```
##[error]buildx failed with: ERROR: failed to build: resolve : lstat make/photon/redis: no such file or directory
```
Upstream Harbor renamed its cache backend from Redis to Valkey between `v2.15.1` and `v2.15.2` (`git log` shows commit `88ab66244 feat: replace redis with valkey as cache backend (#23157)`), renaming `make/photon/redis` → `make/photon/valkey`. Confirmed directly:
- `v2.15.0` and `v2.15.1` trees have `make/photon/redis` (no `valkey`).
- `v2.15.2` and this fork's current `main` both have `make/photon/valkey` (no `redis`).

`build-package.yml`'s `build-base-images`/`build-final-images` jobs hardcode `redis` in their `strategy.matrix.component` list — this was never updated when `main`'s own source renamed the directory, so **this is a pre-existing bug on `main` itself**, unrelated to the ARM64 sync feature, that this feature's `release_tag` mechanism now reliably exposes for every `v2.15.2+` build. A single static matrix cannot correctly build both `v2.15.0`/`v2.15.1` (need `redis`) and `v2.15.2`+ (need `valkey`) — the fix discovers the actual buildable component directories from whichever source tree is actually checked out (the `release_tag`, or `main` for ordinary builds), so it self-adapts to this rename (and any future one) automatically.

Confirmed naming convention for the new component (not guessed): `tests/docker-compose.test.yml:24` already references `goharbor/valkey-photon:__version__`, and `.github/workflows/nightly-trivy-scan.yml:17` already lists `valkey-photon` — both already use this name, only `build-package.yml` was missed. The base-image Dockerfile itself (`make/photon/valkey/Dockerfile`) does `FROM ${harbor_base_namespace}/harbor-valkey-base:...`, matching `build-base-images`' existing `harbor-${{ matrix.component }}-base` tag pattern automatically once `matrix.component` is `valkey`.

- [ ] **Step 1: Add the `discover-components` job**

Insert this new job into `.github/workflows/build-package.yml`, right after the `BUILD_PACKAGE` job's closing (i.e., immediately before the `# 2단계: Base 이미지 빌드` comment / `build-base-images:` job):

```yaml
  # ========================================
  # 1.5단계: 실제 체크아웃된 소스에서 빌드 가능한 컴포넌트 동적 탐지
  # ========================================
  discover-components:
    runs-on: ubuntu-latest
    outputs:
      components: ${{ steps.discover.outputs.components }}
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          ref: ${{ inputs.release_tag || github.ref }}

      - name: Discover buildable components
        id: discover
        run: |
          set -euo pipefail
          components=$(for d in make/photon/*/; do
            name=$(basename "$d")
            if [ -f "make/photon/${name}/Dockerfile.base" ]; then
              echo "$name"
            fi
          done | jq -R -s -c 'split("\n") | map(select(length > 0))')
          echo "Discovered components: ${components}"
          echo "components=${components}" >> "$GITHUB_OUTPUT"
```

(This checks out the same ref the rest of the pipeline builds from — `release_tag` when set, otherwise the triggering ref — and lists every `make/photon/<name>/` subdirectory that has a `Dockerfile.base`. This naturally excludes `make/photon/common/` and `make/photon/standalone-db-migrator/`, which have no `Dockerfile.base` and were never part of the build matrix.)

- [ ] **Step 2: Wire `build-base-images`' matrix to the discovered list**

Replace:
```yaml
  build-base-images:
    runs-on: ubuntu-latest
    needs: BUILD_PACKAGE
    strategy:
      fail-fast: false
      matrix:
        component:
          - core
          - db
          - exporter
          - jobservice
          - log
          - nginx
          - portal
          - prepare
          - redis
          - registry
          - registryctl
          - trivy-adapter
```
with:
```yaml
  build-base-images:
    runs-on: ubuntu-latest
    needs:
      - BUILD_PACKAGE
      - discover-components
    strategy:
      fail-fast: false
      matrix:
        component: ${{ fromJson(needs.discover-components.outputs.components) }}
```

- [ ] **Step 3: Wire `build-final-images`' matrix the same way**

Replace:
```yaml
  build-final-images:
    runs-on: ubuntu-latest
    needs:
      - BUILD_PACKAGE
      - build-base-images
      - compile-binaries
      - compile-registry
      - compile-trivy-adapter
      - compile-exporter

    strategy:
      fail-fast: false
      matrix:
        component:
          - core
          - db
          - exporter
          - jobservice
          - log
          - nginx
          - portal
          - prepare
          - redis
          - registry
          - registryctl
          - trivy-adapter
```
with:
```yaml
  build-final-images:
    runs-on: ubuntu-latest
    needs:
      - BUILD_PACKAGE
      - build-base-images
      - compile-binaries
      - compile-registry
      - compile-trivy-adapter
      - compile-exporter
      - discover-components

    strategy:
      fail-fast: false
      matrix:
        component: ${{ fromJson(needs.discover-components.outputs.components) }}
```

- [ ] **Step 4: Add a `valkey` case to both "Set component info" steps**

There are two identical `case "${{ matrix.component }}" in` blocks (one in `build-base-images`, one in `build-final-images`). In BOTH, add a `valkey)` branch immediately after the existing `redis)` branch — do not remove or change the `redis)` branch, since `v2.15.0`/`v2.15.1` still need it:

Find (appears twice):
```yaml
            redis) DESC="Harbor Redis"; NAME="redis-photon" ;;
```
and add immediately after each occurrence:
```yaml
            valkey) DESC="Harbor Valkey"; NAME="valkey-photon" ;;
```

- [ ] **Step 5: Add `valkey`/`valkey-photon` to the `summary` job's hardcoded lists (cosmetic, best-effort)**

These two lists are informational only (a step-summary table and a package-visibility loop) — they don't gate the actual build — but should mention both names since either one might have actually been built depending on which `release_tag` triggered the run.

Replace:
```yaml
          COMPONENTS="harbor-core harbor-db harbor-exporter harbor-jobservice harbor-log nginx-photon harbor-portal harbor-prepare redis-photon registry-photon harbor-registryctl trivy-adapter-photon"
```
with:
```yaml
          COMPONENTS="harbor-core harbor-db harbor-exporter harbor-jobservice harbor-log nginx-photon harbor-portal harbor-prepare redis-photon valkey-photon registry-photon harbor-registryctl trivy-adapter-photon"
```

Replace:
```yaml
          for comp in core db exporter jobservice log nginx portal prepare redis registry registryctl trivy-adapter; do
            case "${comp}" in
              nginx) NAME="nginx-photon" ;;
              registry) NAME="registry-photon" ;;
              redis) NAME="redis-photon" ;;
              trivy-adapter) NAME="trivy-adapter-photon" ;;
              prepare) NAME="harbor-prepare" ;;
              *) NAME="harbor-${comp}" ;;
            esac
            echo "| ${comp} | \`ghcr.io/dasomel/goharbor/${NAME}:${TAG}\` |" >> $GITHUB_STEP_SUMMARY
          done
```
with:
```yaml
          for comp in core db exporter jobservice log nginx portal prepare redis valkey registry registryctl trivy-adapter; do
            case "${comp}" in
              nginx) NAME="nginx-photon" ;;
              registry) NAME="registry-photon" ;;
              redis) NAME="redis-photon" ;;
              valkey) NAME="valkey-photon" ;;
              trivy-adapter) NAME="trivy-adapter-photon" ;;
              prepare) NAME="harbor-prepare" ;;
              *) NAME="harbor-${comp}" ;;
            esac
            echo "| ${comp} | \`ghcr.io/dasomel/goharbor/${NAME}:${TAG}\` |" >> $GITHUB_STEP_SUMMARY
          done
```

- [ ] **Step 6: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 7: Verify the discovery logic locally against both a `redis` tree and a `valkey` tree**

Run:
```bash
git show v2.15.1 --stat >/dev/null 2>&1  # sanity: tag exists locally
for tag in v2.15.1 v2.15.2; do
  echo "=== $tag ==="
  git ls-tree -d --name-only "$tag" make/photon/ | while read -r d; do
    name=$(basename "$d")
    if git cat-file -e "$tag:make/photon/${name}/Dockerfile.base" 2>/dev/null; then
      echo "$name"
    fi
  done | sort
done
```
Expected:
```
=== v2.15.1 ===
core
db
exporter
jobservice
log
nginx
portal
prepare
redis
registry
registryctl
trivy-adapter
=== v2.15.2 ===
core
db
exporter
jobservice
log
nginx
portal
prepare
registry
registryctl
trivy-adapter
valkey
```
(This uses `git ls-tree`/`git cat-file` instead of a real checkout, since it's simulating what the `discover-components` job's `ls`-based logic would find in each tree, without needing to actually check out each tag into the working directory.)

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): dynamically discover buildable components instead of a hardcoded matrix

Upstream renamed make/photon/redis to make/photon/valkey between v2.15.1
and v2.15.2 (#23157), but build-package.yml's matrix was never updated —
a pre-existing bug on main itself, since main's own source tree already
has valkey, not redis. A single static matrix can't build both v2.15.0/
v2.15.1 (redis) and v2.15.2+ (valkey) release_tag checkouts, so the
matrix is now discovered at runtime from whichever source tree is
actually checked out, self-adapting to this rename (and any future one)."
```

---

### Task 13: Cancel `publish_release.yml` runs triggered by our own tag sync

**Files:**
- Modify: `.github/workflows/sync-release-tags.yml` (the push loop, right after a successful `git push`)

**Interfaces:** none new — reads `${tag}` from the existing loop variable.

**Why:** this fork's `publish_release.yml` already has a guard (`if: github.repository == 'goharbor/harbor'`) on `main` — but pushing a tag that points at an **upstream** commit makes GitHub evaluate the `on: push: tags: 'v*.*.*'` trigger match using **that commit's own copy** of `publish_release.yml`, not `main`'s. Confirmed directly: `git show v2.15.2:.github/workflows/publish_release.yml` has no guard at all (upstream doesn't need one — it IS `goharbor/harbor`). So every tag this fork syncs unavoidably fires upstream's unguarded `publish_release.yml`, which fails loudly (this fork has none of the AWS/DockerHub secrets it needs) — this exact failure pattern is already visible in this fork's run history for tags pushed before this feature existed (`v2.13.5-rc1`, `v2.13.5-rc2`, `v2.14.3-rc1`), so it's a longstanding nuisance this task also incidentally cleans up. Editing `main`'s copy of the guard cannot fix this, since the trigger-match uses the pushed commit's own tree — the only reliable fix is to cancel the resulting run after the fact.

- [ ] **Step 1: Cancel the triggered `publish_release.yml` run right after pushing the tag**

Find (inside the push loop, right after the `- pushed: ${tag}` summary line):
```bash
            if git fetch upstream "refs/tags/${tag}:refs/tags/${tag}" \
               && git push origin "refs/tags/${tag}:refs/tags/${tag}"; then
              echo "- pushed: ${tag}" >> "$GITHUB_STEP_SUMMARY"
              echo "Triggering build-package.yml for ${tag}..."
```
Replace with:
```bash
            if git fetch upstream "refs/tags/${tag}:refs/tags/${tag}" \
               && git push origin "refs/tags/${tag}:refs/tags/${tag}"; then
              echo "- pushed: ${tag}" >> "$GITHUB_STEP_SUMMARY"

              # publish_release.yml's on:push:tags trigger is evaluated using
              # the pushed commit's OWN copy of that file — an upstream commit's
              # copy has no repository guard (upstream doesn't need one), so
              # this push unavoidably fires it. Cancel the resulting run rather
              # than let it fail loudly for secrets this fork doesn't have.
              for attempt in 1 2 3 4 5; do
                release_run_id=$(gh run list --repo "${{ github.repository }}" --workflow publish_release.yml \
                  --json databaseId,headBranch,createdAt \
                  --jq "[.[] | select(.headBranch == \"${tag}\")] | sort_by(.createdAt) | reverse | .[0].databaseId" 2>/dev/null || echo "")
                if [ -n "$release_run_id" ] && [ "$release_run_id" != "null" ]; then
                  echo "Cancelling triggered publish_release.yml run ${release_run_id} for ${tag}..."
                  gh run cancel "$release_run_id" --repo "${{ github.repository }}" || true
                  break
                fi
                sleep 3
              done

              echo "Triggering build-package.yml for ${tag}..."
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/sync-release-tags.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the lookup query against real, already-existing failed runs (read-only, no cancellation)**

Run:
```bash
gh run list --repo dasomel/harbor --workflow publish_release.yml --json databaseId,headBranch,createdAt \
  --jq '[.[] | select(.headBranch == "v2.15.2")] | sort_by(.createdAt) | reverse | .[0].databaseId'
```
Expected: prints the numeric run ID of the already-completed (failed) `publish_release.yml` run for `v2.15.2` (confirms the lookup query shape is correct against real data — this run already finished, so nothing will actually be cancelled by this read, it's the same query the loop uses).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/sync-release-tags.yml
git commit -m "fix(ci): cancel publish_release.yml runs our own tag sync unavoidably triggers

publish_release.yml's push:tags trigger match uses the pushed commit's own
file content, not main's — an upstream commit's copy has no repository
guard (upstream doesn't need one), so every synced tag fires it, and it
fails loudly for AWS/DockerHub secrets this fork doesn't have. Cancel the
resulting run instead of letting it fail noisily."
```

---

### Task 14: Let Go auto-select the toolchain version instead of hardcoding `golang:1.24`

**Files:**
- Modify: `.github/workflows/build-package.yml` (four `docker run ... golang:1.24 ...` blocks, in `compile-binaries` and `compile-registry` jobs)

**Interfaces:** none — purely additive `-e` flags on existing `docker run` invocations.

**Why:** live end-to-end testing (Task 8, re-run after Tasks 11/12) found `compile-binaries (core/jobservice/registryctl)` and `compile-registry` all failing with:
```
go: ../go.mod requires go >= 1.25.7 (running go 1.24.13; GOTOOLCHAIN=local)
```
Confirmed directly (`git show <tag>:src/go.mod`):
- `v2.15.0` requires `go 1.25.7`
- `v2.15.1` requires `go 1.25.9`
- `v2.15.2` requires `go 1.26.4`
- current `main` also requires `go 1.26.4`

`build-package.yml` hardcodes the `golang:1.24` Docker image for these compile steps — this is a pre-existing bug affecting `main`-branch builds too (main's own `go.mod` already needs 1.26.4), not specific to `release_tag` builds; our feature's dynamic checkouts across multiple historical `go.mod` requirements just makes a single hardcoded version even less viable (no one fixed version could satisfy `v2.15.0`'s 1.25.7 floor, `v2.15.2`'s 1.26.4 floor, and any future release's floor, simultaneously). Go has built-in support for exactly this: when `GOTOOLCHAIN=auto` (the modern Go default outside this container), `go build` automatically downloads and uses whichever newer toolchain the checked-out `go.mod` declares, with no hardcoded version needed anywhere — self-adapting the same way Task 12's dynamic component discovery does, just for the Go toolchain instead of the component matrix. The `golang:1.24` image apparently pins `GOTOOLCHAIN=local` by default (confirmed in the error's own `GOTOOLCHAIN=local` in the failing log line), so it needs to be explicitly overridden.

- [ ] **Step 1: Add `GOTOOLCHAIN=auto` to `compile-binaries`' AMD64 step**

Replace:
```yaml
          docker run --rm \
            -v $(pwd):/harbor \
            -w /harbor/src/${{ matrix.component }} \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=amd64 \
            -e GOFLAGS="-buildvcs=false" \
            golang:1.24 \
            go build -ldflags "${LDFLAGS}" -o /harbor/make/photon/${{ matrix.component }}/binary/amd64/${{ matrix.binary_name }} .
```
with:
```yaml
          docker run --rm \
            -v $(pwd):/harbor \
            -w /harbor/src/${{ matrix.component }} \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=amd64 \
            -e GOFLAGS="-buildvcs=false" \
            -e GOTOOLCHAIN=auto \
            golang:1.24 \
            go build -ldflags "${LDFLAGS}" -o /harbor/make/photon/${{ matrix.component }}/binary/amd64/${{ matrix.binary_name }} .
```

- [ ] **Step 2: Same for `compile-binaries`' ARM64 step**

Replace:
```yaml
          docker run --rm \
            -v $(pwd):/harbor \
            -w /harbor/src/${{ matrix.component }} \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=arm64 \
            -e GOFLAGS="-buildvcs=false" \
            golang:1.24 \
            go build -ldflags "${LDFLAGS}" -o /harbor/make/photon/${{ matrix.component }}/binary/arm64/${{ matrix.binary_name }} .
```
with:
```yaml
          docker run --rm \
            -v $(pwd):/harbor \
            -w /harbor/src/${{ matrix.component }} \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=arm64 \
            -e GOFLAGS="-buildvcs=false" \
            -e GOTOOLCHAIN=auto \
            golang:1.24 \
            go build -ldflags "${LDFLAGS}" -o /harbor/make/photon/${{ matrix.component }}/binary/arm64/${{ matrix.binary_name }} .
```

- [ ] **Step 3: Same for `compile-registry`'s AMD64 step**

Replace:
```yaml
          docker run --rm \
            -v /tmp/distribution:/go/src/github.com/docker/distribution \
            -w /go/src/github.com/docker/distribution \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=amd64 \
            -e GO111MODULE=auto \
            -e GOFLAGS="-buildvcs=false" \
            golang:1.24 \
            go build -tags "include_oss include_gcs" -o registry_amd64 ./cmd/registry
```
with:
```yaml
          docker run --rm \
            -v /tmp/distribution:/go/src/github.com/docker/distribution \
            -w /go/src/github.com/docker/distribution \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=amd64 \
            -e GO111MODULE=auto \
            -e GOFLAGS="-buildvcs=false" \
            -e GOTOOLCHAIN=auto \
            golang:1.24 \
            go build -tags "include_oss include_gcs" -o registry_amd64 ./cmd/registry
```

- [ ] **Step 4: Same for `compile-registry`'s ARM64 step**

Replace:
```yaml
          docker run --rm \
            -v /tmp/distribution:/go/src/github.com/docker/distribution \
            -w /go/src/github.com/docker/distribution \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=arm64 \
            -e GO111MODULE=auto \
            -e GOFLAGS="-buildvcs=false" \
            golang:1.24 \
            go build -tags "include_oss include_gcs" -o registry_arm64 ./cmd/registry
```
with:
```yaml
          docker run --rm \
            -v /tmp/distribution:/go/src/github.com/docker/distribution \
            -w /go/src/github.com/docker/distribution \
            -e CGO_ENABLED=0 \
            -e GOOS=linux \
            -e GOARCH=arm64 \
            -e GO111MODULE=auto \
            -e GOFLAGS="-buildvcs=false" \
            -e GOTOOLCHAIN=auto \
            golang:1.24 \
            go build -tags "include_oss include_gcs" -o registry_arm64 ./cmd/registry
```

- [ ] **Step 5: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 6: Verify exactly 4 occurrences were added**

Run: `grep -c 'GOTOOLCHAIN=auto' .github/workflows/build-package.yml`
Expected: `4`

- [ ] **Step 7: Sanity-check `GOTOOLCHAIN=auto` actually resolves the version mismatch (local Docker, read-only — doesn't touch the repo)**

Run:
```bash
docker run --rm -e GOTOOLCHAIN=auto -e GOFLAGS="-buildvcs=false" golang:1.24 sh -c 'mkdir -p /tmp/t && cd /tmp/t && printf "module t\ngo 1.25.7\n" > go.mod && printf "package main\nfunc main(){}\n" > main.go && go build -o /tmp/t/out . && echo BUILD_OK'
```
Expected: downloads the Go 1.25.7 toolchain automatically and prints `BUILD_OK` (confirms `GOTOOLCHAIN=auto` on this exact base image resolves a `go.mod` floor higher than the image's bundled Go version — the same shape of mismatch seen in the real failure, reproduced and fixed in isolation before touching the real workflow).

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): let Go auto-select its toolchain instead of hardcoding golang:1.24

v2.15.0/v2.15.1/v2.15.2 (and current main) all require a newer Go than
1.24 (1.25.7/1.25.9/1.26.4/1.26.4 respectively) per their own go.mod, but
compile-binaries/compile-registry hardcode the golang:1.24 image with
GOTOOLCHAIN=local, so every one of them fails immediately. GOTOOLCHAIN=auto
lets Go download and use whatever version go.mod actually declares, so
no single release's Go floor needs to be hardcoded or kept in sync here."
```

---

### Task 15: Fix the stale `trivy` release download (v0.65.0 no longer exists)

**Files:**
- Modify: `.github/workflows/build-package.yml` (two `TRIVY_VERSION: v0.65.0` lines)

**Interfaces:** none — a version-string constant used by `compile-trivy-adapter`'s download step and the `build-final-images` job's `versions` file generation.

**Why:** live end-to-end testing found `compile-trivy-adapter` failing:
```
gzip: stdin: not in gzip format
tar: Child returned status 1
```
The download URL is `https://github.com/aquasecurity/trivy/releases/download/v0.65.0/trivy_0.65.0_Linux-64bit.tar.gz`. Confirmed directly: `curl -s https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.65.0` returns `{"message": "Not Found", ...}` — this release no longer exists at all (the 9 bytes `curl` actually downloaded were GitHub's `Not Found` JSON error body, which `tar` then correctly refused to treat as a gzip stream). The current latest release is `v0.72.0`, confirmed to exist with the same `trivy_<version>_Linux-64bit.tar.gz` / `trivy_<version>_Linux-ARM64.tar.gz` asset naming pattern this workflow already expects — only the version number itself is stale, not the URL structure.

- [ ] **Step 1: Bump `TRIVY_VERSION` in both places**

There are two identical `TRIVY_VERSION: v0.65.0` lines (one in `compile-trivy-adapter`'s job-level `env:`, one in `build-final-images`'s job-level `env:`). Replace both occurrences:

Find (appears twice):
```yaml
      TRIVY_VERSION: v0.65.0
```
Replace both with:
```yaml
      TRIVY_VERSION: v0.72.0
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the new version's release assets actually exist (read-only network check)**

Run:
```bash
curl -s "https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.72.0" | python3 -c "
import json, sys
d = json.load(sys.stdin)
names = [a['name'] for a in d.get('assets', [])]
assert 'trivy_0.72.0_Linux-64bit.tar.gz' in names, 'AMD64 asset missing'
assert 'trivy_0.72.0_Linux-ARM64.tar.gz' in names, 'ARM64 asset missing'
print('OK: both AMD64 and ARM64 assets exist for v0.72.0')
"
```
Expected: `OK: both AMD64 and ARM64 assets exist for v0.72.0`

- [ ] **Step 4: Confirm exactly two occurrences were updated, none missed**

Run: `grep -n 'TRIVY_VERSION:' .github/workflows/build-package.yml`
Expected: two lines, both reading `TRIVY_VERSION: v0.72.0` (plus a third, unrelated line `TRIVY_VERSION: ${{ env.TRIVY_VERSION }}` used inside the `versions` file heredoc — that one's a reference, not a literal version, and should NOT have been changed).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): bump stale trivy release version — v0.65.0 no longer exists

compile-trivy-adapter's download of trivy_0.65.0_Linux-64bit.tar.gz was
failing with 'gzip: stdin: not in gzip format' — the v0.65.0 GitHub
release itself no longer exists (confirmed via the releases API), so
curl was silently downloading a 9-byte 'Not Found' error body instead.
v0.72.0 is the current latest release with the same asset naming
pattern this workflow already expects."
```

---

### Task 16: Fix stale swagger-codegen version (v0.31.0 → v0.33.1)

**Files:**
- Modify: `.github/workflows/build-package.yml` (the `SWAGGER_VERSION` variable and its one usage, in `compile-binaries`'s "Generate swagger APIs (for core)" step)

**Interfaces:** none — a version-string constant used only within this one step.

**Why:** live end-to-end testing found `compile-binaries (core, harbor_core)` failing on real releases with generated-code type errors, e.g.:
```
../server/v2.0/restapi/operations/harbor_api.go:92:65: cannot convert func(params artifact.CopyArtifactParams, principal *interface{}) middleware.Responder {…} (value of type func(...)) to type artifact.CopyArtifactHandlerFunc
```
`build-package.yml` hardcodes `SWAGGER_VERSION=v0.31.0` for the `quay.io/goswagger/swagger` codegen tool that regenerates `src/server/v2.0/...` from `api/v2.0/swagger.yaml`. Confirmed directly via each release's own `Makefile` (the authoritative source, unrelated to any workflow file): `v2.15.0`, `v2.15.1`, `v2.15.2`, and current `main` **all** specify `SWAGGER_VERSION=v0.33.1` — unlike the Go-toolchain issue (Task 14), this version is consistent across every relevant release, so a plain hardcoded bump (not dynamic detection) is the correct, sufficient fix. `v0.31.0` appears to have simply been wrong/stale in this workflow from the start, not a rename or version drift over time. Confirmed `quay.io/goswagger/swagger:v0.33.1` exists (amd64+arm64 manifest) before this task was written.

- [ ] **Step 1: Bump `SWAGGER_VERSION`**

Find (inside `compile-binaries`'s "Generate swagger APIs (for core)" step):
```yaml
          SWAGGER_VERSION=v0.31.0
```
Replace with:
```yaml
          SWAGGER_VERSION=v0.33.1
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm the new version's image actually exists (read-only, no side effects)**

Run: `docker manifest inspect quay.io/goswagger/swagger:v0.33.1 | head -5`
Expected: valid JSON manifest output (not a "manifest unknown" error), confirming the tag is pullable.

- [ ] **Step 4: Confirm exactly one occurrence was changed, and the templated usage line is untouched**

Run: `grep -n 'SWAGGER_VERSION' .github/workflows/build-package.yml`
Expected: two lines — `SWAGGER_VERSION=v0.33.1` (the literal, now updated) and `quay.io/goswagger/swagger:${SWAGGER_VERSION} \` (the reference, unchanged — it just interpolates whatever `SWAGGER_VERSION` is set to).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): bump stale swagger-codegen version to match what releases actually expect

compile-binaries (core) failed with generated-code type mismatches
(e.g. 'cannot convert func(..., principal *interface{}) ... to type
...HandlerFunc'). build-package.yml hardcoded SWAGGER_VERSION=v0.31.0,
but v2.15.0/v2.15.1/v2.15.2 and current main's own Makefiles all specify
v0.33.1 — a plain stale value, not a version that varies by release, so
a straight bump (not dynamic detection like the Go toolchain fix) is
the correct, sufficient fix here."
```

---

### Task 17: Run swagger codegen natively (via `go install`) instead of inside a Go-less Docker container

**Files:**
- Modify: `.github/workflows/build-package.yml` (`compile-binaries`'s "Generate swagger APIs (for core)" step)

**Interfaces:** none — this step's output (`src/server/v2.0/models`, `src/server/v2.0/restapi`) is consumed by the same job's subsequent compile step, unchanged in shape.

**Why:** live end-to-end testing (re-run after Task 16's `SWAGGER_VERSION` bump) found `compile-binaries (core)` now failing differently:
```
source formatting on generated source "definition" failed: err: go command required, not found: exec: "go": executable file not found in $PATH
```
`quay.io/goswagger/swagger:v0.33.1` (unlike whatever the stale `v0.31.0` tag needed, which never got this far before failing on the type-mismatch bug Task 16 fixed) shells out to `go` internally to format generated source, but this Docker image has no Go toolchain in it at all. Confirmed via a local reproduction: `go install github.com/go-swagger/go-swagger/cmd/swagger@v0.33.1` (run natively, not in that Docker image) installs and runs cleanly, reporting `version: v0.33.1`. This job already runs `actions/setup-go` earlier (with `GOTOOLCHAIN=auto` implicitly available, so `go install` self-resolves whatever Go version `go-swagger`'s own `go.mod` needs), so the simplest fix is to stop using the Docker image entirely and install/run `swagger` natively on the runner, where a working `go` is already on `PATH`.

- [ ] **Step 1: Replace the Docker-based invocation with a native `go install`**

Replace:
```yaml
      - name: Generate swagger APIs (for core)
        if: matrix.component == 'core'
        run: |
          SWAGGER_VERSION=v0.33.1
          rm -rf src/server/v2.0/models src/server/v2.0/restapi
          mkdir -p src/server/v2.0
          docker run --rm \
            -v $(pwd):/work \
            -w /work \
            -e GOFLAGS="-buildvcs=false" \
            quay.io/goswagger/swagger:${SWAGGER_VERSION} \
            generate server \
            --template-dir=tools/swagger/templates \
            --exclude-main \
            --additional-initialism=CVE \
            --additional-initialism=GC \
            --additional-initialism=OIDC \
            -f api/v2.0/swagger.yaml \
            -A harbor \
            --target src/server/v2.0
```
with:
```yaml
      - name: Generate swagger APIs (for core)
        if: matrix.component == 'core'
        env:
          GOFLAGS: "-buildvcs=false"
          GOTOOLCHAIN: auto
        run: |
          SWAGGER_VERSION=v0.33.1
          rm -rf src/server/v2.0/models src/server/v2.0/restapi
          mkdir -p src/server/v2.0
          go install github.com/go-swagger/go-swagger/cmd/swagger@${SWAGGER_VERSION}
          "$(go env GOPATH)/bin/swagger" generate server \
            --template-dir=tools/swagger/templates \
            --exclude-main \
            --additional-initialism=CVE \
            --additional-initialism=GC \
            --additional-initialism=OIDC \
            -f api/v2.0/swagger.yaml \
            -A harbor \
            --target src/server/v2.0
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Reproduce the native install locally, exactly as the step now does it**

Run:
```bash
docker run --rm golang:1.24 sh -c '
  export GOFLAGS="-buildvcs=false"
  export GOTOOLCHAIN=auto
  go install github.com/go-swagger/go-swagger/cmd/swagger@v0.33.1
  "$(go env GOPATH)/bin/swagger" version
'
```
Expected: prints `version: v0.33.1` (confirms the install + invocation shape works standalone, using the same env vars the real step now sets, before this touches the real workflow's behavior).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): run swagger codegen natively instead of inside a Go-less container

quay.io/goswagger/swagger:v0.33.1 shells out to 'go' internally to format
generated source, but that Docker image has no Go toolchain at all —
'go': executable file not found in \$PATH. This job already sets up Go
via actions/setup-go, so installing and running the swagger CLI natively
(go install .../swagger@v0.33.1) avoids needing a Go toolchain baked into
that container image."
```

---

### Task 18: Dynamically detect `Dockerfile.multiarch` instead of assuming it by component name

**Files:**
- Modify: `.github/workflows/build-package.yml` (`build-final-images` job: add a step, change the "Build and push final image" step's `file:` input)

**Interfaces:**
- Produces: `steps.dockerfile.outputs.path`, consumed by the same job's "Build and push final image" step (`file:` input).

**Why:** live end-to-end testing (after Task 17) got further than ever — `build-base-images`, `compile-binaries`, `compile-registry`, `compile-exporter`, `compile-trivy-adapter` all succeeded for `v2.15.2` — but `build-final-images` then failed for `core`, `registry`, `jobservice`, `portal`, `exporter`, `registryctl` with:
```
ERROR: failed to build: failed to solve: failed to read dockerfile: open Dockerfile.multiarch: no such file or directory
```
`build-package.yml` picks the Dockerfile via a hardcoded component-name list:
```yaml
file: ./make/photon/${{ matrix.component }}/Dockerfile${{ contains(fromJSON('["core", "jobservice", "registryctl", "registry", "trivy-adapter", "exporter"]'), matrix.component) && '.multiarch' || '' }}
```
Confirmed directly: `make/photon/core/` on current `main` has `Dockerfile`, `Dockerfile.base`, AND `Dockerfile.multiarch`, but the same directory in the `v2.15.2` tree has only `Dockerfile` and `Dockerfile.base` — `Dockerfile.multiarch` was added to these components sometime after `v2.15.2` was released. This is the exact same shape of problem Task 12 (redis/valkey) and Task 14 (Go toolchain) already fixed for other parts of the pipeline: a hardcoded assumption about `main`'s current file layout breaks when checking out an older `release_tag`'s tree. The fix follows the same self-adapting philosophy — check what's actually present in the checked-out source at runtime instead of assuming based on component name.

- [ ] **Step 1: Add a "Determine Dockerfile" step before "Build and push final image"**

Insert this new step immediately before the existing `- name: Build and push final image` step in the `build-final-images` job:

```yaml
      - name: Determine Dockerfile
        id: dockerfile
        run: |
          if [ -f "make/photon/${{ matrix.component }}/Dockerfile.multiarch" ]; then
            echo "path=make/photon/${{ matrix.component }}/Dockerfile.multiarch" >> "$GITHUB_OUTPUT"
          else
            echo "path=make/photon/${{ matrix.component }}/Dockerfile" >> "$GITHUB_OUTPUT"
          fi
```

- [ ] **Step 2: Consume the new output in "Build and push final image"**

Replace:
```yaml
          file: ./make/photon/${{ matrix.component }}/Dockerfile${{ contains(fromJSON('["core", "jobservice", "registryctl", "registry", "trivy-adapter", "exporter"]'), matrix.component) && '.multiarch' || '' }}
```
with:
```yaml
          file: ${{ steps.dockerfile.outputs.path }}
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify the detection logic against both a pre- and post-rename tree, without needing a real checkout**

Run:
```bash
for tag in v2.15.2 main; do
  echo "=== $tag ==="
  for comp in core jobservice registryctl registry trivy-adapter exporter nginx db prepare log portal; do
    if [ "$tag" = "main" ]; then
      f="make/photon/${comp}/Dockerfile.multiarch"
      [ -f "$f" ] && echo "$comp -> Dockerfile.multiarch" || echo "$comp -> Dockerfile"
    else
      if git cat-file -e "$tag:make/photon/${comp}/Dockerfile.multiarch" 2>/dev/null; then
        echo "$comp -> Dockerfile.multiarch"
      else
        echo "$comp -> Dockerfile"
      fi
    fi
  done
done
```
Expected: for `v2.15.2`, every component resolves to plain `Dockerfile` (none have `.multiarch` yet); for `main` (the working tree), `core`, `jobservice`, `registryctl`, `registry`, `trivy-adapter`, `exporter` resolve to `Dockerfile.multiarch` and the rest resolve to plain `Dockerfile` — matching the OLD hardcoded list exactly for `main`, and correctly diverging for `v2.15.2`. This confirms the new runtime-detection logic reproduces today's intended behavior on `main` while adapting correctly for older trees.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): detect Dockerfile.multiarch at runtime instead of assuming it by component name

build-final-images hardcoded which components use Dockerfile.multiarch
vs plain Dockerfile, based on main's current layout. v2.15.2's tree
(and presumably earlier releases) doesn't have Dockerfile.multiarch at
all for any component yet — it was added to main sometime after that
release. Checking for the file's actual presence in the checked-out
source, rather than assuming based on a hardcoded component list,
self-adapts the same way Task 12's component discovery and Task 14's
GOTOOLCHAIN=auto already do for other parts of this pipeline."
```

---

## Final State (verified live 2026-07-06 / 2026-07-07)

The full chain — sync → tag push → `workflow_dispatch` trigger → `BUILD_PACKAGE` → `discover-components` → `build-base-images` → `compile-*` → `build-final-images` → `create-github-release` — is **verified working end-to-end against the real repo**. Tasks 1-20 collectively took the pipeline from "no v2.15.x images at all" to full multi-arch releases:

| Release | Outcome |
|---|---|
| **v2.15.0** | ✅ **Complete** — all 12 components built amd64+arm64 (redis included), GitHub Release `v2.15.0 (linux/amd64, linux/arm64)` created |
| **v2.15.2** | ✅ **Complete** — all fixable components built amd64+arm64 (portal now passing via Task 20), `exporter` skipped by design, GitHub Release `v2.15.2 (linux/amd64, linux/arm64)` created |
| **v2.15.1** | ✅ **Complete** (after Task 21) — all 12 components build amd64+arm64 including `redis` (the `redis-photon` image contains valkey-in-redis-compat-mode, same as v2.15.0), GitHub Release `v2.15.1 (linux/amd64, linux/arm64)` created 2026-07-07. |

Multi-arch manifests confirmed via `docker buildx imagetools inspect` (both `linux/amd64` and `linux/arm64` present) for legacy-built images like `harbor-core:v2.15.0`, `registry-photon:v2.15.2`, `redis-photon:v2.15.0`.

### Remaining limitations (external or out-of-scope)

1. ~~**`redis` on `v2.15.1` fails with `redis package not found`.**~~ **FIXED by Task 21.** Root cause was NOT a removed package: `v2.15.1`'s redis Dockerfile.base uses `FROM goharbor/photon:5.0`, whose pinned snapshot repo has `valkey` (providing the `redis` capability) but no by-name `redis` package, and `tdnf install redis` doesn't fall back to the capability provider there. `v2.15.0` succeeded only because its Dockerfile.base uses `FROM photon:5.0` (official), which resolves redis→valkey. Task 21 remaps the redis base to official `photon:5.0` via buildx `--build-context`, making v2.15.1's redis build succeed on both arches without editing the upstream Dockerfile.

2. **`exporter` on pre-`Dockerfile.multiarch` releases cannot produce a real arm64 image at all.** Its plain `Dockerfile` is a multi-stage build that compiles the binary *inside* the image build with `ENV GOARCH=amd64` hardcoded (and requires a `build_image` build-arg this pipeline never provided). Producing arm64 would require modifying the upstream release's own source, violating this project's build-the-exact-upstream-source principle. Task 19 explicitly **skips** `exporter` in legacy mode rather than publishing a mislabeled amd64-only binary in an arm64 manifest slot. (`v2.15.2`+ ships a proper `Dockerfile.multiarch` for exporter, so this only affects pre-multiarch releases.)

(The portal Angular-build failure formerly listed here is **fixed** by Task 20 — it was a stale hardcoded `NODE` image, not an intrinsic limitation.)

---

### Task 19: Per-arch legacy builds + manifest merge for pre-`Dockerfile.multiarch` releases

**Files:**
- Modify: `.github/workflows/build-package.yml` (`build-final-images` job: extend the "Determine Dockerfile" step's outputs, add one conditional artifact-download step, gate the existing build/sign steps, add one new legacy-build step)

**Interfaces:**
- Produces: `steps.dockerfile.outputs.legacy` and `steps.dockerfile.outputs.skip` (in addition to the existing `path`), consumed by the same job's subsequent steps.

**Why:** live end-to-end testing after Task 18 confirmed the plain (pre-multiarch) Dockerfiles fail with e.g. `"/make/photon/core/harbor_core": not found`. The two Dockerfile generations use incompatible binary conventions, confirmed by direct comparison of `v2.15.2`'s trees against `main`:

| component | plain Dockerfile expects | our pipeline produces |
|---|---|---|
| core | `make/photon/core/harbor_core` | `make/photon/core/binary/{amd64,arm64}/harbor_core` |
| jobservice | `make/photon/jobservice/harbor_jobservice` | `.../binary/{arch}/harbor_jobservice` |
| registryctl | `make/photon/registryctl/harbor_registryctl` **AND** `make/photon/registry/binary/registry` | `.../binary/{arch}/harbor_registryctl` (registry binary is a separate artifact this matrix leg never downloads) |
| registry | `make/photon/registry/binary/registry` | `.../binary/{arch}/registry` |
| trivy-adapter | `make/photon/trivy-adapter/binary/{trivy,scanner-trivy}` | `.../binary/{arch}/{trivy,scanner-trivy}` |
| exporter | (self-builds in-image, `ENV GOARCH=amd64` hardcoded, needs `build_image` arg) | n/a — **unfixable without modifying upstream source; skipped** |

The plain Dockerfiles have no `TARGETARCH` concept, so a single `--platform linux/amd64,linux/arm64` build can never work with them. The fix builds **each architecture separately** — place that arch's binary at the legacy path, build and push a single-platform image tagged `<version>-<arch>` — then merges the two into one multi-arch manifest with `docker buildx imagetools create`, the same pattern upstream's own `publish_release.yml` uses (`tools/release/release_utils.sh`'s `publishImages` + the "Create multi-arch manifests" step). Components whose plain Dockerfile copies no compiled binary (`db`, `nginx`, `log`, `prepare`, `redis`, `valkey`, `portal`) already build fine multi-platform through the existing step and are untouched by this task.

- [ ] **Step 1: Extend the "Determine Dockerfile" step with `legacy` and `skip` outputs**

Replace:
```yaml
      - name: Determine Dockerfile
        id: dockerfile
        run: |
          if [ -f "make/photon/${{ matrix.component }}/Dockerfile.multiarch" ]; then
            echo "path=make/photon/${{ matrix.component }}/Dockerfile.multiarch" >> "$GITHUB_OUTPUT"
          else
            echo "path=make/photon/${{ matrix.component }}/Dockerfile" >> "$GITHUB_OUTPUT"
          fi
```
with:
```yaml
      - name: Determine Dockerfile
        id: dockerfile
        run: |
          if [ -f "make/photon/${{ matrix.component }}/Dockerfile.multiarch" ]; then
            echo "path=make/photon/${{ matrix.component }}/Dockerfile.multiarch" >> "$GITHUB_OUTPUT"
            echo "legacy=false" >> "$GITHUB_OUTPUT"
            echo "skip=false" >> "$GITHUB_OUTPUT"
          else
            echo "path=make/photon/${{ matrix.component }}/Dockerfile" >> "$GITHUB_OUTPUT"
            case "${{ matrix.component }}" in
              core|jobservice|registryctl|registry|trivy-adapter)
                # Pre-multiarch Dockerfile expecting externally-compiled binaries at
                # fixed single-arch paths — handled by the per-arch legacy build below.
                echo "legacy=true" >> "$GITHUB_OUTPUT"
                echo "skip=false" >> "$GITHUB_OUTPUT"
                ;;
              exporter)
                # Pre-multiarch exporter self-builds in-image with GOARCH=amd64
                # hardcoded and needs a build_image arg this pipeline doesn't
                # provide — a real arm64 image is impossible without modifying
                # upstream source. Skip rather than publish a broken image.
                echo "legacy=false" >> "$GITHUB_OUTPUT"
                echo "skip=true" >> "$GITHUB_OUTPUT"
                ;;
              *)
                # Plain Dockerfile with no compiled-binary COPY — multi-platform
                # build works as-is through the normal step.
                echo "legacy=false" >> "$GITHUB_OUTPUT"
                echo "skip=false" >> "$GITHUB_OUTPUT"
                ;;
            esac
          fi
```

- [ ] **Step 2: Add a conditional download of the registry binary for registryctl's legacy build**

Insert immediately after the "Determine Dockerfile" step (registryctl's plain Dockerfile also copies `make/photon/registry/binary/registry`, but this matrix leg only downloads `pkg-binary-registryctl`):
```yaml
      - name: Download registry binary for registryctl (legacy layout)
        if: matrix.component == 'registryctl' && steps.dockerfile.outputs.legacy == 'true'
        uses: actions/download-artifact@v4
        with:
          name: pkg-binary-registry
          path: make/photon/registry/binary/
```

- [ ] **Step 3: Gate the existing multiarch build step**

Change the existing step's header from:
```yaml
      - name: Build and push final image
        uses: docker/build-push-action@v6
```
to:
```yaml
      - name: Build and push final image
        if: steps.dockerfile.outputs.legacy != 'true' && steps.dockerfile.outputs.skip != 'true'
        uses: docker/build-push-action@v6
```
(everything under `with:` stays untouched).

- [ ] **Step 4: Add the legacy per-arch build step**

Insert immediately after the (now-gated) "Build and push final image" step:
```yaml
      - name: Build and push final image (legacy per-arch)
        if: steps.dockerfile.outputs.legacy == 'true'
        env:
          IMAGE: ghcr.io/dasomel/goharbor/${{ steps.info.outputs.image_name }}
          TAG: ${{ needs.BUILD_PACKAGE.outputs.version_tag }}
        run: |
          set -euo pipefail
          # Pre-multiarch Dockerfiles have no TARGETARCH concept: they COPY a
          # single binary from a fixed path. Build each architecture separately
          # (staging that arch's binary at the legacy path first), then merge
          # the per-arch images into one multi-arch manifest — the same pattern
          # upstream's publish_release.yml uses.
          for arch in amd64 arm64; do
            case "${{ matrix.component }}" in
              core)
                cp "make/photon/core/binary/${arch}/harbor_core" "make/photon/core/harbor_core"
                chmod +x "make/photon/core/harbor_core"
                ;;
              jobservice)
                cp "make/photon/jobservice/binary/${arch}/harbor_jobservice" "make/photon/jobservice/harbor_jobservice"
                chmod +x "make/photon/jobservice/harbor_jobservice"
                ;;
              registry)
                cp "make/photon/registry/binary/${arch}/registry" "make/photon/registry/binary/registry"
                chmod +x "make/photon/registry/binary/registry"
                ;;
              registryctl)
                cp "make/photon/registryctl/binary/${arch}/harbor_registryctl" "make/photon/registryctl/harbor_registryctl"
                cp "make/photon/registry/binary/${arch}/registry" "make/photon/registry/binary/registry"
                chmod +x "make/photon/registryctl/harbor_registryctl" "make/photon/registry/binary/registry"
                ;;
              trivy-adapter)
                cp "make/photon/trivy-adapter/binary/${arch}/trivy" "make/photon/trivy-adapter/binary/trivy"
                cp "make/photon/trivy-adapter/binary/${arch}/scanner-trivy" "make/photon/trivy-adapter/binary/scanner-trivy"
                chmod +x "make/photon/trivy-adapter/binary/trivy" "make/photon/trivy-adapter/binary/scanner-trivy"
                ;;
            esac
            docker buildx build \
              --platform "linux/${arch}" \
              -f "${{ steps.dockerfile.outputs.path }}" \
              --build-arg harbor_base_image_version="${TAG}" \
              --build-arg harbor_base_namespace=ghcr.io/dasomel/goharbor \
              --label "org.opencontainers.image.source=https://github.com/${{ github.repository }}" \
              --label "org.opencontainers.image.revision=${{ github.sha }}" \
              --label "org.opencontainers.image.version=${TAG}" \
              --provenance=false \
              -t "${IMAGE}:${TAG}-${arch}" \
              --push \
              .
          done
          docker buildx imagetools create -t "${IMAGE}:${TAG}" "${IMAGE}:${TAG}-amd64" "${IMAGE}:${TAG}-arm64"
          docker buildx imagetools create -t "${IMAGE}:latest" "${IMAGE}:${TAG}-amd64" "${IMAGE}:${TAG}-arm64"
```
(No `sbom:`/`provenance: true` equivalents here — those attestations are a docker/build-push-action nicety, and single-arch legacy builds keep the script simple; `--provenance=false` avoids the wrapper manifest that would complicate `imagetools create`.)

- [ ] **Step 5: Gate the cosign sign step on `skip`**

Change:
```yaml
      - name: Sign final image with Cosign
        env:
          COSIGN_EXPERIMENTAL: "true"
```
to:
```yaml
      - name: Sign final image with Cosign
        if: steps.dockerfile.outputs.skip != 'true'
        env:
          COSIGN_EXPERIMENTAL: "true"
```
(Signing works unchanged for legacy builds — the merged `${TAG}`/`latest` manifests exist by the time it runs. Only the exporter-skip case, where no image was pushed at all, must not attempt to sign.)

- [ ] **Step 6: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 7: Statically verify the gating logic and binary-path mapping**

Run:
```bash
# Exactly one legacy build step, gated on legacy==true:
grep -c "Build and push final image (legacy per-arch)" .github/workflows/build-package.yml   # expect 1
# The original build step is now gated:
grep -B1 "uses: docker/build-push-action@v6" .github/workflows/build-package.yml | grep -c "steps.dockerfile.outputs.legacy != 'true'"   # expect 1 in build-final-images (build-base-images' usage has no such gate — confirm it was NOT touched)
# Legacy-path staging targets match what each plain Dockerfile actually COPYs (against the real v2.15.2 tree):
for comp in core jobservice registryctl registry trivy-adapter; do
  echo "=== $comp ==="
  git show "v2.15.2:make/photon/${comp}/Dockerfile" | grep "^COPY" | grep -v "entrypoint\|install_cert\|start.sh\|views\|migrations\|icons\|versions\|redis.conf"
done
```
Expected for the last loop: each component's binary `COPY` lines reference exactly the destination paths the Step 4 `case` block stages (e.g. `./make/photon/core/harbor_core` for core, `./make/photon/registry/binary/registry` for registry AND registryctl, `./make/photon/trivy-adapter/binary/trivy` + `.../scanner-trivy` for trivy-adapter).

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): per-arch legacy builds for pre-Dockerfile.multiarch releases

Pre-multiarch plain Dockerfiles COPY a single externally-compiled binary
from a fixed path with no TARGETARCH concept, so one multi-platform build
can never satisfy them. For core/jobservice/registryctl/registry/
trivy-adapter, build each architecture separately (staging that arch's
binary at the legacy path first) and merge the results into one
multi-arch manifest via buildx imagetools create — the same pattern
upstream's publish_release.yml uses. exporter is skipped in legacy mode:
its plain Dockerfile self-builds in-image with GOARCH=amd64 hardcoded,
so a real arm64 image is impossible without modifying upstream source."
```

- [ ] **Step 9: Live end-to-end verification**

Push to `origin/main`, then re-run the sync:
```bash
git push origin main
gh workflow run sync-release-tags.yml --repo dasomel/harbor -f dry_run=false
```
Wait for the triggered `build-package.yml` runs. Expected outcomes:
- `v2.15.2` run: `build-final-images` succeeds for `core`, `jobservice`, `registryctl`, `registry`, `trivy-adapter` (in addition to the already-passing `valkey`/`db`/`nginx`/`log`); `exporter` is skipped (not failed); `portal` still fails (known limitation #2).
- Confirm a merged multi-arch manifest: `docker buildx imagetools inspect ghcr.io/dasomel/goharbor/harbor-core:v2.15.2` shows both `linux/amd64` and `linux/arm64`.
- `v2.15.0`/`v2.15.1` runs: same expectations for the fixable components (`build-base-images (redis)` still fails on those two — the Photon repo removed the `redis` package upstream; external, unfixable).

**Result (verified live 2026-07-06):** exactly as expected — `v2.15.2` succeeded for all five legacy components with correctly merged amd64+arm64 manifests (`harbor-core:v2.15.2`, `registry-photon:v2.15.2` inspected), `exporter` skipped cleanly (all build/sign steps `skipped`, job green), `portal` failed as predicted. This surfaced a consequence: portal's failure makes the `build-final-images` job fail overall, so `create-github-release` (which `needs:` it) is **skipped** — no Release is created, and Task 9's Release-existence idempotency will re-trigger the same tag every scheduled run, forever. Fixing portal (Task 20) resolves both.

---

### Task 20: Read the portal `NODE` build image from the release's own Makefile (fixes portal + unblocks Release creation)

**Files:**
- Modify: `.github/workflows/build-package.yml` (`build-final-images` job: extend the "Determine Dockerfile" step with a `node_image` output; use it in the existing build step's `build-args`)

**Interfaces:**
- Produces: `steps.dockerfile.outputs.node_image`, consumed by the same job's "Build and push final image" step.

**Why:** live verification of Task 19 confirmed `build-final-images (portal)` still fails with `ng build ... exit code: 3`. Root cause found — the exact same stale-hardcoded-version pattern as Task 16's swagger fix, but with a twist that mandates dynamic detection rather than a bump: the workflow passes `NODE=node:16.18.0` as a hardcoded build-arg, while each release's own `Makefile` (the authoritative source) specifies what Node the portal build actually needs, and **it genuinely varies by release**:
- `v2.15.0`, `v2.15.1`: `NODEBUILDIMAGE=node:16.18.0` (current hardcoded value is right for these)
- `v2.15.2`, current `main`: `NODEBUILDIMAGE=node:22.22.3` (Angular v21 toolchain — cannot build on Node 16, hence exit code 3)

A fixed bump to `node:22.22.3` would fix `v2.15.2` but break `v2.15.0`/`v2.15.1`'s portal. Reading `NODEBUILDIMAGE` from the checked-out source's own `Makefile` at runtime self-adapts per release — the same established pattern as Tasks 12/14/18. Beyond portal itself, this fix has a systemic payoff: with portal green, `build-final-images` succeeds overall, so `create-github-release` actually runs, the Release gets created, and Task 9's idempotency stops re-triggering the tag daily.

- [ ] **Step 1: Emit `node_image` from the "Determine Dockerfile" step**

At the top of the step's `run:` block (before the existing `if [ -f ... ]`), add:
```bash
          node_image=$(grep -E '^NODEBUILDIMAGE=' Makefile | head -n1 | cut -d= -f2 || true)
          echo "node_image=${node_image:-node:16.18.0}" >> "$GITHUB_OUTPUT"
```
(Fallback `node:16.18.0` — today's hardcoded value — covers any hypothetical release whose Makefile lacks the variable, preserving current behavior in that case rather than passing an empty build-arg. The `|| true` is load-bearing, not decorative: GitHub Actions' default shell is `bash -eo pipefail`, and a bare `var=$(pipeline)` assignment propagates the pipeline's exit status — so `grep` matching nothing would abort the whole step BEFORE the `${node_image:-...}` fallback ever runs, defeating exactly the case the fallback exists for. Empirically confirmed during review with `bash -e -o pipefail`: without `|| true`, neither subsequent line executes. Same bug class as Task 10's grep fix.)

- [ ] **Step 2: Use it in the existing build step's `build-args`**

Replace:
```yaml
            NODE=node:16.18.0
```
with:
```yaml
            NODE=${{ steps.dockerfile.outputs.node_image }}
```

- [ ] **Step 3: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 4: Verify the extraction logic against all relevant trees**

Run:
```bash
for ref in v2.15.0 v2.15.1 v2.15.2; do
  echo -n "$ref -> "
  git show "$ref:Makefile" | grep -E '^NODEBUILDIMAGE=' | head -n1 | cut -d= -f2
done
echo -n "main -> "
grep -E '^NODEBUILDIMAGE=' Makefile | head -n1 | cut -d= -f2
```
Expected:
```
v2.15.0 -> node:16.18.0
v2.15.1 -> node:16.18.0
v2.15.2 -> node:22.22.3
main -> node:22.22.3
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): read portal NODE build image from the release's own Makefile

build-final-images hardcoded NODE=node:16.18.0, but the required Node
genuinely varies by release (v2.15.0/v2.15.1 need node:16.18.0;
v2.15.2 and main need node:22.22.3 for the Angular v21 toolchain —
ng build exits 3 on Node 16). Reading NODEBUILDIMAGE from the checked-out
source's own Makefile self-adapts per release, same pattern as the
component-discovery/GOTOOLCHAIN/Dockerfile.multiarch fixes. With portal
green, build-final-images succeeds overall, so create-github-release
finally runs and the Release-existence idempotency stops re-triggering
completed tags daily."
```

- [ ] **Step 6: Live end-to-end verification**

Push and re-run the sync (`dry_run=false`). Expected for the `v2.15.2` run:
- `build-final-images (portal)`: **success** (first time ever)
- `build-final-images` overall: success → `create-github-release` runs → `gh release view v2.15.2 --repo dasomel/harbor` shows a Release titled `v2.15.2 (linux/amd64, linux/arm64)`
- Subsequent scheduled syncs no longer re-trigger `v2.15.2` (its Release now exists).

---

### Task 21: Build the `redis` base image from official `photon:5.0` (fixes v2.15.1 `redis package not found`)

**Files:**
- Modify: `.github/workflows/build-package.yml` (`build-base-images` job: add a conditional `build-contexts:` to the "Build and push base image" step)

**Interfaces:** none — a docker/build-push-action input, conditional on `matrix.component`.

**Why:** the redis failure (formerly "external, unfixable") was **root-caused and IS fixable.** `v2.15.1`'s `make/photon/redis/Dockerfile.base` does `FROM goharbor/photon:5.0` then `RUN tdnf install -y redis`. Confirmed directly:
- `v2.15.0`'s redis Dockerfile.base uses `FROM photon:5.0` (official) and **builds fine** — `tdnf install redis` on official `photon:5.0` resolves via capability match, installing `valkey 9.0.3` which provides `/usr/bin/redis-server` (VMware Photon renamed the package but kept the redis capability + a `redis-server` compat binary).
- `v2.15.1`'s redis Dockerfile.base uses `FROM goharbor/photon:5.0`, whose pinned `photon-snapshot` repo has `valkey` providing the `redis` *capability* but **no package named `redis`** — and `tdnf install redis` (by name) does not fall back to the capability-provider there, so it fails with `redis package not found`. (Tested directly: `docker run goharbor/photon:5.0 tdnf install -y redis` → `Error(1011): No matching packages`, while `docker run photon:5.0 tdnf install -y redis` → succeeds, installing valkey.)

So the failure is purely a base-image-metadata difference, not a genuinely-removed package. The fix: for the `redis` component only, remap the `goharbor/photon:5.0` base reference to the official `photon:5.0` (which handles the redis→valkey capability resolution) using buildx's `--build-context` — without editing the release's own Dockerfile.base. Verified locally: with that remap, `v2.15.1`'s redis Dockerfile.base builds cleanly for **both** `linux/amd64` and `linux/arm64`, and the resulting image has a working `redis-server` (valkey 9.0.3 in redis-compat mode). This is exactly what `v2.15.0`'s redis image already contains, so it's consistent and faithful to how the Photon ecosystem now ships "redis". The remap is scoped to `redis` alone (a `matrix.component == 'redis'` conditional), so every other component's base build is completely unaffected, and it's a harmless no-op for `v2.15.0`'s redis (whose Dockerfile.base doesn't reference `goharbor/photon:5.0` at all).

- [ ] **Step 1: Add the conditional `build-contexts:` input**

In the `build-base-images` job's "Build and push base image" step, add a `build-contexts:` line. Change:
```yaml
      - name: Build and push base image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ./make/photon/${{ matrix.component }}/Dockerfile.base
          platforms: linux/amd64,linux/arm64
          push: true
```
to:
```yaml
      - name: Build and push base image
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ./make/photon/${{ matrix.component }}/Dockerfile.base
          build-contexts: ${{ matrix.component == 'redis' && 'goharbor/photon:5.0=docker-image://photon:5.0' || '' }}
          platforms: linux/amd64,linux/arm64
          push: true
```
(An empty `build-contexts` value is a no-op — `docker/build-push-action` ignores it — so every non-redis component builds exactly as before. For `redis`, it rewrites `FROM goharbor/photon:5.0` to pull the official `photon:5.0` instead.)

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build-package.yml'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm scope — exactly one build-contexts line, only in build-base-images**

Run: `grep -n 'build-contexts:' .github/workflows/build-package.yml`
Expected: exactly one line, inside the `build-base-images` job's "Build and push base image" step (the `build-final-images` step must NOT gain one — it builds from per-component base images, not `goharbor/photon:5.0`).

- [ ] **Step 4: Reproduce the fix locally against v2.15.1's actual redis Dockerfile.base (both arches)**

Run:
```bash
tmp=$(mktemp -d)
git show v2.15.1:make/photon/redis/Dockerfile.base > "$tmp/Dockerfile.base"
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-context "goharbor/photon:5.0=docker-image://photon:5.0" \
  -f "$tmp/Dockerfile.base" \
  "$tmp"
echo "exit: $?"
```
Expected: `exit: 0` — the build completes for both platforms using the unmodified v2.15.1 Dockerfile.base, proving the `--build-context` remap (exactly what Step 1 wires into CI) makes `FROM goharbor/photon:5.0` + `tdnf install redis` succeed without editing the Dockerfile.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build-package.yml
git commit -m "fix(ci): build redis base from official photon:5.0 to resolve redis->valkey

v2.15.1's redis Dockerfile.base does FROM goharbor/photon:5.0 + tdnf
install -y redis, but that image's pinned photon-snapshot repo has no
package NAMED redis (only valkey, which provides the redis capability) —
and tdnf install-by-name doesn't fall back to the capability provider
there, so it fails with 'redis package not found'. The official photon:5.0
DOES resolve it (installs valkey 9.0.3, which ships a redis-server compat
binary) — which is exactly why v2.15.0's redis image (FROM photon:5.0)
already builds fine. Remap goharbor/photon:5.0 -> photon:5.0 for the redis
component only, via buildx --build-context, without editing the release's
own Dockerfile. Verified locally to build both amd64 and arm64."
```

- [ ] **Step 6: Live end-to-end verification**

Push and re-run the sync (`dry_run=false`). The idempotency check (Task 9) will re-trigger `v2.15.1` (it has no Release yet). Expected:
- `build-base-images (redis)` for the `v2.15.1` run: **success** (previously the only failing job).
- `v2.15.1`'s `build-final-images` completes for all components → `create-github-release` runs → `gh release view v2.15.1 --repo dasomel/harbor` shows `v2.15.1 (linux/amd64, linux/arm64)`.
- `docker buildx imagetools inspect ghcr.io/dasomel/goharbor/redis-photon:v2.15.1` shows both `linux/amd64` and `linux/arm64`.
