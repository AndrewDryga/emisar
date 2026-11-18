#!/bin/sh
set -eu

# Build the signed upstream source with the pinned compiler and the x/net
# security update. The compiler alone does not patch Compose's separately
# linked networking dependency.
source_commit=5bceecf985347fcf6dd23029ce440b502a0d4301
source_url=https://codeload.github.com/docker/compose/tar.gz/$source_commit
source_sha256=f21c00230b32c4b01dcf516e37a195f166798443eaadfbdd635d86079f16fcb9
compiler_image=golang:1.27.3-alpine3.24@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18
test "$(go env GOVERSION)" = go1.27.3
mkdir /compose /compose-src
wget -O /compose-source.tar.gz "$source_url"
printf '%s  %s\n' "$source_sha256" /compose-source.tar.gz | sha256sum -c -
tar -xzf /compose-source.tar.gz -C /compose-src --strip-components=1
cd /compose-src
printf '%s  %s\n' \
  add1d3fc58082dc40ea0ebcc3d2c80b1f4bf99a5452aab2026e8997b511cfb09 go.mod \
  742b5078110f95e2a78eb36cc17c13b340111297d574f140e7134c341bf0e3b2 go.sum | sha256sum -c -
export GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64
go get golang.org/x/net@v0.62.0
printf '%s  %s\n' \
  3f1cbe9c14f71355628c968b58f064d0ff81201b8637ca0389c9c7f746244b74 go.mod \
  3b18e947c444627b533d810db6fd0cf1a9d153c3e36a43bf15bb6169d9cf9a2b go.sum | sha256sum -c -
go build -mod=readonly -trimpath -tags=e2e \
  -ldflags='-w -X github.com/docker/compose/v5/internal.Version=v5.7.0' \
  -o /compose/docker-compose ./cmd
# The download cache is only an optimization, never source-integrity evidence.
go mod verify
# The build must not rewrite the reviewed, hash-bound derived module inputs.
printf '%s  %s\n' \
  3f1cbe9c14f71355628c968b58f064d0ff81201b8637ca0389c9c7f746244b74 go.mod \
  3b18e947c444627b533d810db6fd0cf1a9d153c3e36a43bf15bb6169d9cf9a2b go.sum | sha256sum -c -
cp LICENSE NOTICE /compose/
cp /usr/local/go/LICENSE /compose/GO-LICENSE
go version -m /compose/docker-compose > /compose/buildinfo.txt
{
  printf 'source_url=%s\nsource_sha256=%s\nsource_commit=%s\n' "$source_url" "$source_sha256" "$source_commit"
  printf 'toolchain_image=%s\ntoolchain_version=go1.27.3\n' "$compiler_image"
  printf '%s\n' \
    'go_mod_sha256=add1d3fc58082dc40ea0ebcc3d2c80b1f4bf99a5452aab2026e8997b511cfb09' \
    'go_sum_sha256=742b5078110f95e2a78eb36cc17c13b340111297d574f140e7134c341bf0e3b2' \
    'module_update=go get golang.org/x/net@v0.62.0' \
    'module_update_advisories=CVE-2026-78661 / GO-2026-6860' \
    'derived_go_mod_sha256=3f1cbe9c14f71355628c968b58f064d0ff81201b8637ca0389c9c7f746244b74' \
    'derived_go_sum_sha256=3b18e947c444627b533d810db6fd0cf1a9d153c3e36a43bf15bb6169d9cf9a2b' \
    'build_flags=GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -mod=readonly -trimpath -tags=e2e -ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.7.0'
  printf 'binary_sha256=%s\n' "$(sha256sum /compose/docker-compose | cut -d' ' -f1)"
  printf 'build_info_sha256=%s\n' "$(sha256sum /compose/buildinfo.txt | cut -d' ' -f1)"
} > /compose/build.txt
