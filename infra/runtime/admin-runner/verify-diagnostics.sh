#!/bin/bash
# Trusted host validator, not a script executed from the extracted artifact.
set -euo pipefail
bundle=$1 revision=$2 architecture=$3
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
[ "$architecture" = amd64 ]
cd "$bundle"
# Bootstrap validation uses COS primitives only, never host or extracted jq.
{
  read -r line; [ "$line" = schema=2 ]
  read -r line; [ "$line" = purpose=admin-diagnostics ]
  read -r line; [ "$line" = os=linux ]
  read -r line; [ "$line" = "architecture=$architecture" ]
  read -r line; [ "$line" = "revision=$revision" ]
  read -r line; [[ "$line" =~ ^checksums_sha256=([a-f0-9]{64})$ ]]
  expected=${BASH_REMATCH[1]}
  read -r line; [ "$line" = 'inventory_scope=measured shipped Debian closure; complete builder provenance retained' ]
  if read -r line; then exit 1; fi
} < manifest
actual=$(sha256sum SHA256SUMS | cut -d' ' -f1)
[ "$actual" = "$expected" ]
# Never allow traversal, ambiguous filenames, special files or foreign links.
while IFS= read -r path; do
  [[ "$path" =~ ^\./[A-Za-z0-9_.+/-]+$ ]]
  [[ "$path" != *'/../'* && "$path" != *'/./'* ]]
done < <(find . -mindepth 1 -print)
[ -z "$(find . ! -type f ! -type d ! -type l -print)" ]
while read -r hash path; do
  [[ "$hash" =~ ^[a-f0-9]{64}$ && "$path" =~ ^\./[A-Za-z0-9_.+/-]+$ ]]
  [ -f "$path" ] && [ ! -L "$path" ]
  actual=$(sha256sum "$path" | cut -d' ' -f1)
  [ "$actual" = "$hash" ]
done < SHA256SUMS
actual_files=$(find . -type f ! -path ./SHA256SUMS ! -path ./manifest | sort)
listed_files=$(awk '{print $2}' SHA256SUMS | sort)
[ "$actual_files" = "$listed_files" ]
commands='chronyc dmidecode ethtool findmnt free iostat jq last lscpu lvs mdadm ntpq ping ps pvs sar sadc slabtop smartctl ss sysctl uptime vgs vmstat'
# This constant allowlist intentionally becomes one name per line.
# shellcheck disable=SC2086
[ "$(printf '%s\n' $commands)" = "$(< commands.txt)" ]
for command in $commands; do
  [ -x "libexec/$command" ]
  [ "$(readlink "bin/$command")" = ../run-tool ]
done
[ "$(find bin -mindepth 1 -maxdepth 1 | wc -l)" -eq 24 ]
# Build-time Python copies flatten distribution links. Only reviewed argv
# wrappers may be links, eliminating any dependency on host path resolution.
while IFS= read -r link; do
  case "$link" in
    ./bin/*) [ "$(readlink "$link")" = ../run-tool ] ;;
    *) echo 'unexpected bundle symlink' >&2; exit 1 ;;
  esac
done < <(find . -type l)
test -x run-tool && test -x lib/loader && test -x libexec/python3
test -x cli-plugins/docker-compose
test -s python/lib/python3/dist-packages/ntp/libntpc.so
test -s debian-runtime.tsv && test -s debian-builder.tsv && test -s file-origins.tsv && test -s source-builds.tsv
test -s python-installed-identity.json && test -s python-private-identity.json && test -s python-private-build.txt
test -s compose-build.txt && test -s compose-buildinfo.txt && test -s compose/LICENSE && test -s compose/NOTICE && test -s compose/GO-LICENSE
# These fixed source/compiler inputs and the measured output hashes are bound
# by the manifest. Never accept the old upstream binary under rebuilt provenance.
{
  read -r line; [ "$line" = source_url=https://codeload.github.com/docker/compose/tar.gz/5bceecf985347fcf6dd23029ce440b502a0d4301 ]
  read -r line; [ "$line" = source_sha256=f21c00230b32c4b01dcf516e37a195f166798443eaadfbdd635d86079f16fcb9 ]
  read -r line; [ "$line" = source_commit=5bceecf985347fcf6dd23029ce440b502a0d4301 ]
  read -r line; [ "$line" = toolchain_image=golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 ]
  read -r line; [ "$line" = toolchain_version=go1.27.4 ]
  read -r line; [ "$line" = go_mod_sha256=add1d3fc58082dc40ea0ebcc3d2c80b1f4bf99a5452aab2026e8997b511cfb09 ]
  read -r line; [ "$line" = go_sum_sha256=742b5078110f95e2a78eb36cc17c13b340111297d574f140e7134c341bf0e3b2 ]
  read -r line; [ "$line" = 'module_update=go get golang.org/x/net@v0.62.0' ]
  read -r line; [ "$line" = 'module_update_advisories=CVE-2026-78661 / GO-2026-6860' ]
  read -r line; [ "$line" = derived_go_mod_sha256=3f1cbe9c14f71355628c968b58f064d0ff81201b8637ca0389c9c7f746244b74 ]
  read -r line; [ "$line" = derived_go_sum_sha256=3b18e947c444627b533d810db6fd0cf1a9d153c3e36a43bf15bb6169d9cf9a2b ]
  read -r line; [ "$line" = 'build_flags=GOWORK=off GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 -mod=readonly -trimpath -tags=e2e -ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.7.0' ]
  read -r line; [ "$line" = "binary_sha256=$(sha256sum cli-plugins/docker-compose | cut -d' ' -f1)" ]
  read -r line; [ "$line" = "build_info_sha256=$(sha256sum compose-buildinfo.txt | cut -d' ' -f1)" ]
  if read -r line; then exit 1; fi
} < compose-build.txt
# Every payload file has one origin. Metadata is separately bound by SHA256SUMS;
# it is not executable runtime code and must not become a fake Debian component.
payload_files=$(find . -type f ! -path ./SHA256SUMS ! -path ./manifest ! -path ./debian-runtime.tsv \
  ! -path ./debian-builder.tsv ! -path ./file-origins.tsv ! -path ./source-builds.tsv \
  ! -path ./python-installed-identity.json ! -path ./python-private-identity.json ! -path ./python-private-build.txt \
  ! -path ./compose-build.txt ! -path ./compose-buildinfo.txt | sort)
origin_files=$(cut -f1 file-origins.tsv | sort)
[ "$payload_files" = "$origin_files" ]
awk -F '\t' -v revision="$revision" '
  NF != 8 || seen[$1]++ || $1 !~ /^\.\/[A-Za-z0-9_.+\/-]+$/ {exit 1}
  {for (i=1;i<=8;i++) if ($i == "") exit 1}
  $2 ~ /^debian(-source|-extracted|-bytecode)?$/ {
    if ($3 !~ /^\// || $4 !~ /^[a-z0-9][a-z0-9+.-]*$/ || ($6 != "amd64" && $6 != "all")) exit 1
    next
  }
  $2 == "repository" {
    if (($1 != "./run-tool" && $1 != "./commands.txt") || $4 != "emisar" || $5 != revision || $6 != "all" || $7 != "emisar" || $8 != revision) exit 1
    next
  }
  $2 == "github-source" {
    if (($1 != "./cli-plugins/docker-compose" && $1 != "./compose/LICENSE" && $1 != "./compose/NOTICE") || $3 != "https://codeload.github.com/docker/compose/tar.gz/5bceecf985347fcf6dd23029ce440b502a0d4301" || $4 != "docker-compose" || $5 != "5.7.0" || $6 != "amd64" || $7 != "docker/compose" || $8 != "v5.7.0") exit 1
    next
  }
  $2 == "compiler-image" {
    if ($1 != "./compose/GO-LICENSE" || $3 != "golang:1.27.4-alpine3.24@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280" || $4 != "stdlib" || $5 != "v1.27.4" || $6 != "all" || $7 != "golang/go" || $8 != "go1.27.4") exit 1
    next
  }
  {exit 1}
' file-origins.tsv
for inventory in debian-builder.tsv debian-runtime.tsv; do
  awk -F '\t' 'NF != 5 {exit 1} {for(i=1;i<=5;i++) if($i=="") exit 1}
    $1 !~ /^[a-z0-9][a-z0-9+.-]*$/ || ($3 != "amd64" && $3 != "all") {exit 1}' "$inventory"
done
derived_runtime=$(awk -F '\t' '$2 ~ /^debian(-source|-extracted|-bytecode)?$/ {print $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8}' file-origins.tsv | sort -u)
[ "$derived_runtime" = "$(sort -u debian-runtime.tsv)" ]
awk 'NR==FNR {builder[$0]=1;next} !($0 in builder) {exit 1}' debian-builder.tsv debian-runtime.tsv
