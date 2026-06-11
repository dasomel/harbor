#!/bin/bash
set -x

set -e

# Build base images locally for linux/amd64; upstream Docker Hub images
# are sometimes pushed as ARM64-only, causing "exec format error" on AMD64 runners.
for component in core db exporter jobservice log nginx portal prepare redis registry registryctl trivy-adapter; do
    if [ -f "make/photon/${component}/Dockerfile.base" ]; then
        sudo docker build --platform linux/amd64 --no-cache \
            -f make/photon/${component}/Dockerfile.base \
            -t goharbor/harbor-${component}-base:dev .
    fi
done
sudo make package_online GOBUILDTAGS="include_oss include_gcs" VERSIONTAG=dev-gitaction PKGVERSIONTAG=dev-gitaction UIVERSIONTAG=dev-gitaction GOBUILDIMAGE=golang:1.25.7 COMPILETAG=compile_golangimage TRIVYFLAG=true EXPORTERFLAG=true HTTPPROXY= PULL_BASE_FROM_DOCKERHUB=false
sudo make package_offline GOBUILDTAGS="include_oss include_gcs" VERSIONTAG=dev-gitaction PKGVERSIONTAG=dev-gitaction UIVERSIONTAG=dev-gitaction GOBUILDIMAGE=golang:1.25.7 COMPILETAG=compile_golangimage TRIVYFLAG=true EXPORTERFLAG=true HTTPPROXY= PULL_BASE_FROM_DOCKERHUB=false
