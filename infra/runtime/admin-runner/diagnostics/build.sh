#!/bin/bash
set -euo pipefail
revision=$1
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
[ "$(dpkg --print-architecture)" = amd64 ]
bundle_root=/bundle
ownership_rows=/tmp/diagnostics-ownership.tsv
: > "$ownership_rows"
# shellcheck source=infra/runtime/admin-runner/diagnostics/inventory.sh
source /build/inventory.sh
install -d /bundle/{bin,libexec,lib,python/lib,cli-plugins}
cp /build/commands.txt /bundle/commands.txt
install -m 0755 /build/run-tool /bundle/run-tool
repository_identity=$'emisar\t'"$revision"$'\tall\temisar\t'"$revision"
diagnostics_record_origin /bundle/commands.txt repository /build/commands.txt "$repository_identity"
diagnostics_record_origin /bundle/run-tool repository /build/run-tool "$repository_identity"
deb=(/ntp-source/ntpsec_*.deb)
[ "${#deb[@]}" -eq 1 ]
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
ntp_identity=$(printf '%s\t%s\t%s\t%s\t%s' "$ntp_package" "$ntp_version" \
  "$(dpkg-deb -f "${deb[0]}" Architecture)" "$ntp_source_name" "$ntp_source_version")
sysstat_identity=$(diagnostics_package_identity sysstat)
sysstat_source=(/sysstat-source/sysstat-*/)
[ "${#sysstat_source[@]}" -eq 1 ]
while IFS= read -r command; do
  source=$(command -v "$command")
  case "$command" in
    sar|sadc|iostat) cmp "${sysstat_source[0]}$command" "$source" ;;
    ntpq) cmp /ntp-source/extracted/usr/bin/ntpq "$source" ;;
  esac
  install -m 0755 "$(readlink -f "$source")" "/bundle/libexec/$command"
  case "$command" in
    sar|sadc|iostat) diagnostics_record_origin "/bundle/libexec/$command" debian-source "${sysstat_source[0]}$command" "$sysstat_identity" ;;
    ntpq) diagnostics_record_origin /bundle/libexec/ntpq debian-extracted /ntp-source/extracted/usr/bin/ntpq "$ntp_identity" ;;
    *) diagnostics_record_debian "$source" "/bundle/libexec/$command" ;;
  esac
  ln -s ../run-tool "/bundle/bin/$command"
done < /build/commands.txt
install -m 0755 /python-source/private-python /bundle/libexec/python3
python_identity=$(diagnostics_package_identity python3.11-minimal)
diagnostics_record_origin /bundle/libexec/python3 debian-source /python-source/private-python "$python_identity"
for evidence in installed-identity.json private-identity.json private-build.txt; do
  cp "/python-source/$evidence" "/bundle/python-$evidence"
done
diagnostics_copy_python_tree /usr/lib/python3.11 /bundle/python/lib/python3.11
install -d /bundle/python/lib/python3
diagnostics_copy_python_tree /usr/lib/python3/dist-packages /bundle/python/lib/python3/dist-packages
# libntpc is dlopened by Python, so ldd on the interpreter cannot find it.
ntpc=$(find /usr/lib -path '*/ntp/libntpc.so' -print -quit)
[ -n "$ntpc" ]
ntpc_destination=/bundle/python/lib/python3/dist-packages/ntp/libntpc.so
if [ ! -f "$ntpc_destination" ]; then
  diagnostics_copy_debian "$ntpc" "$ntpc_destination"
else
  cmp "$ntpc" "$ntpc_destination"
fi
while IFS= read -r -d '' file; do
  while IFS= read -r library; do
    [ -f "$library" ] || continue
    target="/bundle/lib/$(basename "$library")"
    if [ -f "$target" ]; then
      cmp "$library" "$target"
    else
      diagnostics_copy_debian "$library" "$target"
    fi
  done < <(ldd "$file" 2>/dev/null | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' || true)
done < <(find /bundle/libexec /bundle/python -type f -print0)
loader=$(readlink -f /lib64/ld-linux-x86-64.so.2)
install -m 0755 "$loader" /bundle/lib/loader
diagnostics_record_debian "$loader" /bundle/lib/loader
# Rebuilt upstream source is not the official release asset. Keep its license,
# actual compiler/build information and measured binary identity together.
install -m 0755 /compose-source-build/docker-compose /bundle/cli-plugins/docker-compose
install -d /bundle/compose
cp /compose-source-build/build.txt /bundle/compose-build.txt
cp /compose-source-build/buildinfo.txt /bundle/compose-buildinfo.txt
compose_source=https://codeload.github.com/docker/compose/tar.gz/5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de
diagnostics_record_origin /bundle/cli-plugins/docker-compose github-source "$compose_source" \
  $'docker-compose\t5.5.1\tamd64\tdocker/compose\tv5.5.1'
for license in LICENSE NOTICE; do
  cp "/compose-source-build/$license" "/bundle/compose/$license"
  diagnostics_record_origin "/bundle/compose/$license" github-source "$compose_source" \
    $'docker-compose\t5.5.1\tamd64\tdocker/compose\tv5.5.1'
done
# The embedded Go runtime's notice comes from the pinned compiler image, not
# from the Compose source archive.
cp /compose-source-build/GO-LICENSE /bundle/compose/GO-LICENSE
diagnostics_record_origin /bundle/compose/GO-LICENSE compiler-image \
  golang:1.27.2-alpine3.24@sha256:85dc1069ac644ea3c527b177303a406eb3358192816cd7f9e5848eb658851673 \
  $'stdlib\tv1.27.2\tall\tgolang/go\tgo1.27.2'
# Retain all signed build dependencies honestly, separately from shipped bytes.
dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Version}\t${Architecture}\t${source:Package}\t${source:Version}\n' | \
  awk -F '\t' '$1 == "ii " {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' | sort > /bundle/debian-builder.tsv
printf '%s\n' "$ntp_identity" >> /bundle/debian-builder.tsv
sort -u "$ownership_rows" > /bundle/file-origins.tsv
awk -F '\t' '$2 ~ /^debian(-source|-extracted|-bytecode)?$/ {print $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8}' \
  /bundle/file-origins.tsv | sort -u > /bundle/debian-runtime.tsv
source_version=$(dpkg-parsechangelog -l /sysstat-source/sysstat-*/debian/changelog -S Version)
[ "$source_version" = "$(dpkg-query -W -f='${source:Version}' sysstat)" ]
source_dsc=(/sysstat-source/sysstat_*.dsc)
[ "${#source_dsc[@]}" -eq 1 ]
printf 'sysstat\t%s\tDebian-signed-source; dsc_sha256=%s; SA_LIB_DIR=/run/emisar-admin-runner/diagnostics/bin\n' \
  "$source_version" "$(sha256sum "${source_dsc[0]}" | cut -d' ' -f1)" > /bundle/source-builds.tsv
printf 'ntpsec\t%s\tDebian-signed-package; deb_sha256=%s\n' \
  "$ntp_source_version" "$(sha256sum "${deb[0]}" | cut -d' ' -f1)" >> /bundle/source-builds.tsv
python_dsc=(/python-source/python3.11_*.dsc)
[ "${#python_dsc[@]}" -eq 1 ]
printf 'python3.11\t%s\tDebian-signed-source; dsc_sha256=%s; private interpreter; pyexpat/_elementtree disabled\n' \
  "$(dpkg-query -W -f='${source:Version}' python3.11-minimal)" \
  "$(sha256sum "${python_dsc[0]}" | cut -d' ' -f1)" >> /bundle/source-builds.tsv
printf 'docker/compose\tv5.5.1\tcommit=5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de; pinned Go1.27.2; compose-build.txt/compose-buildinfo.txt\n' >> /bundle/source-builds.tsv
find /bundle -type f -exec chmod a-s,go-w {} +
cd /bundle
find . -type f ! -path ./SHA256SUMS ! -path ./manifest -print0 | sort -z | xargs -0 sha256sum > /tmp/bundle-SHA256SUMS
mv /tmp/bundle-SHA256SUMS SHA256SUMS
checksums_hash=$(sha256sum SHA256SUMS | cut -d' ' -f1)
printf '%s\n' 'schema=2' 'purpose=admin-diagnostics' 'os=linux' 'architecture=amd64' \
  "revision=$revision" "checksums_sha256=$checksums_hash" \
  'inventory_scope=measured shipped Debian closure; complete builder provenance retained' > manifest
