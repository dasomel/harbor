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
