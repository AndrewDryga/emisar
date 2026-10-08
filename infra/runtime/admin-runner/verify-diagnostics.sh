#!/bin/bash
# Trusted host validator, not a script executed from the extracted artifact.
set -euo pipefail
bundle=$1 revision=$2 architecture=$3
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
[ "$architecture" = amd64 ]
cd "$bundle"
# Bootstrap validation uses COS primitives only, never host or extracted jq.
{
  read -r line; [ "$line" = schema=1 ]
  read -r line; [ "$line" = purpose=admin-diagnostics ]
  read -r line; [ "$line" = os=linux ]
  read -r line; [ "$line" = "architecture=$architecture" ]
  read -r line; [ "$line" = "revision=$revision" ]
  read -r line; [[ "$line" =~ ^checksums_sha256=([a-f0-9]{64})$ ]]
  expected=${BASH_REMATCH[1]}
  read -r line; [ "$line" = 'inventory_scope=conservative signed Debian builder inventory, including build-only packages' ]
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
actual_files=$(find . -type f ! -name SHA256SUMS ! -name manifest | sort)
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
test -s debian-inventory.tsv && test -s source-builds.tsv
