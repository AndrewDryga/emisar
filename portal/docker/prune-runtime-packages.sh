#!/bin/sh
set -eu

# Runtime updates replace the image, never run apt inside it. The portal starts
# directly as nobody and never uses PAM, login, or account-management utilities.
# GnuTLS belongs only to apt's HTTPS transport here.
set -- apt libgnutls30 login util-linux libpam0g libpam-modules libpam-modules-bin libpam-runtime
plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
apt-get -s purge "$@" > "$plan"
removals=$(awk '$1 == "Purg" || $1 == "Remv" {print $2}' "$plan" | sort)
expected=$(printf '%s\n' adduser apt libgnutls30 libpam-modules libpam-modules-bin libpam-runtime libpam0g login passwd util-linux | sort)
test "$removals" = "$expected" || {
  echo 'runtime package removal would affect an unreviewed dependency' >&2
  exit 1
}
# Debian marks some removed utilities Essential. Only the exact ten-package
# removal checked above is allowed; no autoremove or forced dependency break.
apt-get purge -y --allow-remove-essential "$@"
test -z "$(dpkg --audit)"
for package in base-passwd coreutils dash dpkg libstdc++6 libsctp1 openssl libtinfo6 locales ca-certificates netcat-openbsd; do
  test "$(dpkg-query -W -f='${Status}' "$package")" = 'install ok installed'
done
test "$(id -u nobody)" = 65534
