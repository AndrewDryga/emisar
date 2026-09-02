#!/bin/sh
# Size of each Symbolicator cache, largest first, plus the filesystem the cache
# root sits on. Symbolicator's caches are what fills a symbolication host's
# disk, and they grow at very different rates — one oversized cache is the
# answer far more often than the total is.
set -eu

cache_dir="${SYMBOLICATOR_CACHE_DIR:-}"
config="${SYMBOLICATOR_CONFIG:-/etc/symbolicator/config.yml}"

# Resolution order: the explicit variable, then the configuration the service
# itself reads, then the packaged default. Reading cache_dir from the config
# keeps this honest on a host that moved its caches off the root filesystem.
if [ -z "$cache_dir" ] && [ -f "$config" ]; then
  cache_dir=$(sed -n 's/^[[:space:]]*cache_dir:[[:space:]]*"\{0,1\}\([^"#]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    "$config" | head -1 | tr -d "'" | sed 's/[[:space:]]*$//')
fi
[ -n "$cache_dir" ] || cache_dir=/data

if [ ! -d "$cache_dir" ]; then
  printf 'cache directory %s does not exist\n' "$cache_dir" >&2
  exit 1
fi
if [ ! -r "$cache_dir" ] || [ ! -x "$cache_dir" ]; then
  printf 'cache directory %s is not readable\n' "$cache_dir" >&2
  exit 1
fi

printf 'cache root: %s\n\n' "$cache_dir"

# du reports each cache, sort orders them by the bytes that matter. Guard the
# listing rather than piping a failure into sort, so an unreadable cache root
# fails loudly instead of printing an empty report that reads as "nothing here".
set -- "$cache_dir"/*
if [ "$1" = "$cache_dir/*" ] && [ ! -e "$1" ]; then
  printf 'no caches present yet\n'
elif ! usage=$(du -sk "$@"); then
  printf 'could not measure every cache under %s\n' "$cache_dir" >&2
  exit 1
else
  printf '%s\n' "$usage" | sort -rn | awk '{
    kb = $1
    unit = "KiB"
    if (kb >= 1048576) { kb = kb / 1048576; unit = "GiB" }
    else if (kb >= 1024) { kb = kb / 1024; unit = "MiB" }
    printf "%10.1f %-4s %s\n", kb, unit, $2
  }'
fi

printf '\nfilesystem:\n'
df -h "$cache_dir"
