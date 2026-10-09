#!/bin/sh
set -eu

# Runtime updates replace the image, never run apt inside it. GnuTLS belongs
# only to apt's HTTPS transport here; do not suppress or leave its unused bytes.
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
apt-get -s purge apt libgnutls30 > "$plan"
removals=$(awk '$1 == "Purg" || $1 == "Remv" {print $2}' "$plan" | sort)
test "$removals" = "$(printf 'apt\nlibgnutls30')" || {
  echo 'runtime package removal would affect an unreviewed dependency' >&2
  exit 1
}
# Debian marks apt essential. Only the exact two-package removal checked above
# is allowed; no autoremove, forced dependency break or manual library deletion.
apt-get purge -y --allow-remove-essential apt libgnutls30
test -z "$(dpkg --audit)"
for package in libstdc++6 libsctp1 openssl libtinfo6 locales ca-certificates netcat-openbsd; do
  test "$(dpkg-query -W -f='${Status}' "$package")" = 'install ok installed'
done
