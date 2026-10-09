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
# Prove the qualifier's own libc cannot hide an omitted private dependency.
# This is the extracted test copy only; restore it before positive qualification.
mv "$bundle/lib/libc.so.6" /run/diagnostics-removed-libc.so.6
trap 'mv /run/diagnostics-removed-libc.so.6 "$bundle/lib/libc.so.6"' EXIT
if bash /qualification/verify-linkage.sh "$bundle" "$bundle/libexec/python3"; then
  echo 'missing private libc passed through the qualifier distribution' >&2
  exit 1
fi
mv /run/diagnostics-removed-libc.so.6 "$bundle/lib/libc.so.6"
trap - EXIT
for executable in "$bundle"/libexec/*; do
  [ "$(basename "$executable")" = ntpq ] && continue
  bash /qualification/verify-linkage.sh "$bundle" "$executable"
done
while IFS= read -r -d '' extension; do
  bash /qualification/verify-linkage.sh "$bundle" "$extension"
done < <(find "$bundle/python" -type f -name '*.so*' -print0)
export PYTHONHOME="$bundle/python"
export PYTHONPATH="$bundle/python/lib/python3/dist-packages"
"$bundle/lib/loader" --library-path "$bundle/lib" "$bundle/libexec/python3" -B -P -S -c \
  'import importlib.util, ntp.packet, ntp.control, ntp.ntpc; print(ntp.ntpc.statustoa(0, 0)); assert all(importlib.util.find_spec(name) is None for name in ("sqlite3", "_sqlite3", "xml", "pyexpat", "_elementtree", "ssl", "_ssl", "tarfile"))'
"$bundle/bin/ntpq" --version
"$bundle/lib/loader" --library-path "$bundle/lib" "$bundle/libexec/python3" -B -P -S \
  /qualification/qualify-ntpq.py "$bundle/bin/ntpq"
"$bundle/bin/chronyc" -v
"$bundle/bin/iostat" -V
"$bundle/bin/sar" -u 1 1
"$bundle/bin/free" -b
"$bundle/bin/vmstat" 1 2
"$bundle/cli-plugins/docker-compose" version
test "$("$bundle/cli-plugins/docker-compose" version --short)" = 5.5.1
"$bundle/cli-plugins/docker-compose" docker-cli-plugin-metadata
# Exercise the real plugin's parser without a daemon or host configuration.
printf '%s\n' 'services:' '  probe:' '    image: example.invalid/qualification:fixed' | \
  "$bundle/cli-plugins/docker-compose" -p qualification -f - config --format json > /run/compose-config.json
"$bundle/bin/jq" -e '.services.probe.image == "example.invalid/qualification:fixed"' /run/compose-config.json
# Only native diagnostics may be exported; system control stays on COS.
for protected in docker cloud-init curl gcloud elixir erl epmd systemctl journalctl; do
  test ! -e "$bundle/bin/$protected"
done
test -z "$(find "$bundle" -type f -perm /6000 -print)"
# Imports must not generate unmanifested bytecode or alter any shipped bytes.
bash /qualification/verify-diagnostics.sh "$bundle" "$1" amd64
