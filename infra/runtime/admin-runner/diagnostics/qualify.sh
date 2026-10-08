#!/bin/bash
# This runs only inside the explicitly Docker-bound Linux qualifier.
set -euo pipefail
test ! -e /usr/lib/sysstat/sadc
test ! -e /run/emisar-admin-runner/diagnostics
install -d -m 0700 /run/emisar-admin-runner/diagnostics
# Docker extraction belongs to the host CI UID. Match production root ownership
# without granting this isolated container CAP_CHOWN.
cp -a --no-preserve=ownership /qualification/bundle/. /run/emisar-admin-runner/diagnostics/
bundle=/run/emisar-admin-runner/diagnostics
test -z "$(find "$bundle" \( ! -uid 0 -o ! -gid 0 \) -print)"
bash /qualification/verify-diagnostics.sh "$bundle" "$1" amd64
for executable in "$bundle"/libexec/*; do
  [ "$(basename "$executable")" = ntpq ] && continue
  "$bundle/lib/loader" --library-path "$bundle/lib" --list "$executable"
done
export PYTHONHOME="$bundle/python"
export PYTHONPATH="$bundle/python/lib/python3/dist-packages"
"$bundle/lib/loader" --library-path "$bundle/lib" "$bundle/libexec/python3" -c \
  'import ntp.packet, ntp.control, ntp.ntpc; print(ntp.ntpc.statustoa(0, 0))'
"$bundle/bin/ntpq" --version
"$bundle/bin/chronyc" -v
"$bundle/bin/iostat" -V
"$bundle/bin/sar" -u 1 1
"$bundle/bin/free" -b
"$bundle/bin/vmstat" 1 2
"$bundle/cli-plugins/docker-compose" version
"$bundle/cli-plugins/docker-compose" docker-cli-plugin-metadata
# Only native diagnostics may be exported; system control stays on COS.
for protected in docker cloud-init curl gcloud elixir erl epmd systemctl journalctl; do
  test ! -e "$bundle/bin/$protected"
done
test -z "$(find "$bundle" -type f -perm /6000 -print)"
