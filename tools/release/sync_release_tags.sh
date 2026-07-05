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
  { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } \
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
