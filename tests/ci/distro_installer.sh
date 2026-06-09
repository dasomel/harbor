#!/bin/bash
set -x

set -e

# Build prepare base image locally for linux/amd64; the upstream Docker Hub image
# goharbor/harbor-prepare-base:dev is sometimes pushed as ARM64-only, which causes
# "exec format error" on AMD64 GitHub-hosted runners.
sudo docker build --platform linux/amd64 --no-cache \
    -f make/photon/prepare/Dockerfile.base \
    -t goharbor/harbor-prepare-base:dev .
sudo make package_online GOBUILDTAGS="include_oss include_gcs" VERSIONTAG=dev-gitaction PKGVERSIONTAG=dev-gitaction UIVERSIONTAG=dev-gitaction GOBUILDIMAGE=golang:1.25.7 COMPILETAG=compile_golangimage TRIVYFLAG=true EXPORTERFLAG=true HTTPPROXY= PULL_BASE_FROM_DOCKERHUB=false
sudo make package_offline GOBUILDTAGS="include_oss include_gcs" VERSIONTAG=dev-gitaction PKGVERSIONTAG=dev-gitaction UIVERSIONTAG=dev-gitaction GOBUILDIMAGE=golang:1.25.7 COMPILETAG=compile_golangimage TRIVYFLAG=true EXPORTERFLAG=true HTTPPROXY= PULL_BASE_FROM_DOCKERHUB=false
