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
