#!/bin/sh
set -eu

installed=$(dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\n')
if printf '%s\n' "$installed" | awk -F '\t' '$2 == "ii " && ($1 == "apt" || $1 == "libgnutls30") {found=1} END {exit !found}'; then
  echo 'unused apt/GnuTLS is still installed in the runtime image' >&2
  exit 1
fi
test -z "$(find /app /usr/lib -name '*gnutls*' -print)"
test -s /etc/ssl/certs/ca-certificates.crt
files=$(mktemp)
trap 'rm -f "$files"' EXIT
find /app -type f -print > "$files"
count=0
while IFS= read -r file; do
  magic=$(od -An -tx1 -N4 "$file" | tr -d '[:space:]')
  [ "$magic" = 7f454c46 ] || continue
  if linkage=$(ldd "$file" 2>&1); then
    case "$linkage" in
      *'not found'*|*gnutls*) echo 'release ELF has missing or unexpected GnuTLS linkage' >&2; exit 1 ;;
    esac
  else
    case "$linkage" in
      *'not a dynamic executable'*|*'statically linked'*) ;;
      *) echo 'release ELF linkage could not be inspected' >&2; exit 1 ;;
    esac
  fi
  count=$((count + 1))
done < "$files"
test "$count" -gt 0
printf 'runtime package/CA and native dependency closure verified: %s ELF files\n' "$count"
