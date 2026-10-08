#!/bin/bash
set -euo pipefail
revision=$1
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
[ "$(dpkg --print-architecture)" = amd64 ]
install -d /bundle/{bin,libexec,lib,python/lib,cli-plugins}
cp /build/commands.txt /bundle/commands.txt
install -m 0755 /build/run-tool /bundle/run-tool
while IFS= read -r command; do
  source=$(command -v "$command")
  install -m 0755 "$(readlink -f "$source")" "/bundle/libexec/$command"
  ln -s ../run-tool "/bundle/bin/$command"
done < /build/commands.txt
install -m 0755 "$(readlink -f "$(command -v python3)")" /bundle/libexec/python3
cp -aL /usr/lib/python3.11 /bundle/python/lib/
install -d /bundle/python/lib/python3
cp -aL /usr/lib/python3/dist-packages /bundle/python/lib/python3/
# libntpc is dlopened by Python, so ldd on the interpreter cannot find it.
ntpc=$(find /usr/lib -path '*/ntp/libntpc.so' -print -quit)
[ -n "$ntpc" ]
cp -L "$ntpc" /bundle/python/lib/python3/dist-packages/ntp/libntpc.so
while IFS= read -r -d '' file; do
  while IFS= read -r library; do
    [ -f "$library" ] || continue
    target="/bundle/lib/$(basename "$library")"
    if [ -f "$target" ]; then
      cmp "$library" "$target"
    else
      cp -L "$library" "$target"
    fi
  done < <(ldd "$file" 2>/dev/null | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' || true)
done < <(find /bundle/libexec /bundle/python -type f -print0)
install -m 0755 "$(readlink -f /lib64/ld-linux-x86-64.so.2)" /bundle/lib/loader
# Exact upstream v5.5.1 asset; not a mutable release download at boot.
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64 \
  -o /bundle/cli-plugins/docker-compose
printf '%s  %s\n' db1889184726840f75c4f9c001048430d4f25b3be3cb084d3ddd762bc0aed576 \
  /bundle/cli-plugins/docker-compose | sha256sum --check --status
chmod 0755 /bundle/cli-plugins/docker-compose
# Conservative builder inventory deliberately includes build-only components.
# Scan this signed Debian inventory before stripping the final image; do not
# pretend an empty scratch-image OS scan covers the shipped ELF/Python closure.
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' | sort > /bundle/debian-inventory.tsv
deb=(/ntp-source/ntpsec_*.deb)
ntp_package=$(dpkg-deb -f "${deb[0]}" Package)
ntp_version=$(dpkg-deb -f "${deb[0]}" Version)
ntp_source=$(dpkg-deb -f "${deb[0]}" Source)
ntp_source_name=$ntp_package
ntp_source_version=$ntp_version
if [ -n "$ntp_source" ]; then
  [[ "$ntp_source" =~ ^([a-z0-9+.-]+)(\ \(([^()]+)\))?$ ]]
  ntp_source_name=${BASH_REMATCH[1]}
  if [ -n "${BASH_REMATCH[3]}" ]; then ntp_source_version=${BASH_REMATCH[3]}; fi
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$ntp_package" "$ntp_version" \
  "$(dpkg-deb -f "${deb[0]}" Architecture)" "$ntp_source_name" "$ntp_source_version" >> /bundle/debian-inventory.tsv
source_version=$(dpkg-parsechangelog -l /sysstat-source/sysstat-*/debian/changelog -S Version)
[ "$source_version" = "$(dpkg-query -W -f='${source:Version}' sysstat)" ]
printf 'sysstat\t%s\tDebian-signed-source; SA_LIB_DIR=/run/emisar-admin-runner/diagnostics/bin\n' \
  "$source_version" > /bundle/source-builds.tsv
find /bundle -type f -exec chmod a-s,go-w {} +
cd /bundle
find . -type f ! -name SHA256SUMS ! -name manifest -print0 | sort -z | xargs -0 sha256sum > /tmp/bundle-SHA256SUMS
mv /tmp/bundle-SHA256SUMS SHA256SUMS
checksums_hash=$(sha256sum SHA256SUMS | cut -d' ' -f1)
printf '%s\n' 'schema=1' 'purpose=admin-diagnostics' 'os=linux' 'architecture=amd64' \
  "revision=$revision" "checksums_sha256=$checksums_hash" \
  'inventory_scope=conservative signed Debian builder inventory, including build-only packages' > manifest
