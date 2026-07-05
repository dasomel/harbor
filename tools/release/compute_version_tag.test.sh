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
