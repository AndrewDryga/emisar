#!/bin/sh
set -eu

# The upstream release asset embeds an affected Go runtime. Preserve its exact
# signed source and build recipe, but compile with our patched, pinned image.
source_commit=5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de
source_url=https://codeload.github.com/docker/compose/tar.gz/$source_commit
source_sha256=c72877db37172d8ee55f565e4fed20067af89015e986b190768fd4ee621025f2
compiler_image=golang:1.27.2-alpine3.24@sha256:85dc1069ac644ea3c527b177303a406eb3358192816cd7f9e5848eb658851673
test "$(go env GOVERSION)" = go1.27.2
mkdir /compose /compose-src
wget -O /compose-source.tar.gz "$source_url"
printf '%s  %s\n' "$source_sha256" /compose-source.tar.gz | sha256sum -c -
tar -xzf /compose-source.tar.gz -C /compose-src --strip-components=1
cd /compose-src
printf '%s  %s\n' \
  cdf5424bec2a7c75fa955a56efc88fb1731db5cca019cf63d4a1980a218e0868 go.mod \
  8e96090883306abcd19ed57025a3e108b0b1cf6a6dff220c73d1aa77bb408a10 go.sum | sha256sum -c -
export GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64
go build -mod=readonly -trimpath -tags=e2e \
  -ldflags='-w -X github.com/docker/compose/v5/internal.Version=v5.5.1' \
  -o /compose/docker-compose ./cmd
# The download cache is only an optimization, never source-integrity evidence.
go mod verify
# Readonly module resolution must not rewrite the authenticated source inputs.
printf '%s  %s\n' \
  cdf5424bec2a7c75fa955a56efc88fb1731db5cca019cf63d4a1980a218e0868 go.mod \
  8e96090883306abcd19ed57025a3e108b0b1cf6a6dff220c73d1aa77bb408a10 go.sum | sha256sum -c -
cp LICENSE NOTICE /compose/
cp /usr/local/go/LICENSE /compose/GO-LICENSE
go version -m /compose/docker-compose > /compose/buildinfo.txt
{
  printf 'source_url=%s\nsource_sha256=%s\nsource_commit=%s\n' "$source_url" "$source_sha256" "$source_commit"
  printf 'toolchain_image=%s\ntoolchain_version=go1.27.2\n' "$compiler_image"
  printf '%s\n' \
    'go_mod_sha256=cdf5424bec2a7c75fa955a56efc88fb1731db5cca019cf63d4a1980a218e0868' \
    'go_sum_sha256=8e96090883306abcd19ed57025a3e108b0b1cf6a6dff220c73d1aa77bb408a10' \
    'build_flags=GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -mod=readonly -trimpath -tags=e2e -ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.5.1'
  printf 'binary_sha256=%s\n' "$(sha256sum /compose/docker-compose | cut -d' ' -f1)"
  printf 'build_info_sha256=%s\n' "$(sha256sum /compose/buildinfo.txt | cut -d' ' -f1)"
} > /compose/build.txt
