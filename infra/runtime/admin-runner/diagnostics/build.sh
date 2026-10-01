#!/bin/bash
set -euo pipefail
install -d /bundle/{bin,libexec,lib,python/lib,cli-plugins}
cp /build/commands.txt /bundle/commands.txt
install -m 0755 /build/run-tool /bundle/run-tool
while IFS= read -r command; do
  case "$command" in
    sadc) source=/usr/lib/sysstat/sadc ;;
    *) source=$(command -v "$command") ;;
  esac
  install -m 0755 "$(readlink -f "$source")" "/bundle/libexec/$command"
  ln -s ../run-tool "/bundle/bin/$command"
done < /build/commands.txt
# ntpq is Python in NTPsec. Keep its interpreter and imports inside the bundle;
# no host Python package installation and no new time daemon are needed.
install -m 0755 "$(readlink -f "$(command -v python3)")" /bundle/libexec/python3
cp -a /usr/lib/python3.11 /bundle/python/lib/
install -d /bundle/python/lib/python3
cp -a /usr/lib/python3/dist-packages /bundle/python/lib/python3/
# ntpc.py checks beside itself before its distribution-specific absolute path.
# Include that dlopen dependency, which ldd on Python cannot discover.
ntpc=$(find /usr/lib -path '*/ntp/libntpc.so' -print -quit)
[ -n "$ntpc" ]
cp -L "$ntpc" /bundle/python/lib/python3/dist-packages/ntp/libntpc.so
# ldd recursively resolves the ELF dependency closure, including Python's native
# extensions. Flatten only these trusted package libraries, following symlinks.
while IFS= read -r -d '' file; do
  while IFS= read -r library; do
    [ -f "$library" ] && cp -L "$library" /bundle/lib/
  done < <(ldd "$file" 2>/dev/null | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' || true)
done < <(find /bundle/libexec /bundle/python -type f -print0)
case "$(dpkg --print-architecture)" in
  amd64)
    loader=/lib64/ld-linux-x86-64.so.2
    compose_arch=x86_64
    compose_hash=7af95166a730b87e172d4fc9aefea8725d3c6c7327d59149267b452114ddb7d4
    ;;
  arm64)
    loader=/lib/ld-linux-aarch64.so.1
    compose_arch=aarch64
    compose_hash=49082844b87f03cdcd5f5bbef1ba8c9c897b7a2dfb80cea18d61ec8ca6117e0c
    ;;
  *) echo 'unsupported diagnostics architecture' >&2; exit 1 ;;
esac
install -m 0755 "$(readlink -f "$loader")" /bundle/lib/loader
# These hashes were checked against the exact upstream v2.39.4 checksums.txt;
# downloading a checksum beside a binary at boot would not be an immutable pin.
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  "https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-$compose_arch" \
  -o /bundle/cli-plugins/docker-compose
printf '%s  %s\n' "$compose_hash" /bundle/cli-plugins/docker-compose | sha256sum --check --status
chmod 0755 /bundle/cli-plugins/docker-compose
# Strip privilege bits even if a distribution package installed one. The admin
# process already has its declared identity; helper elevation is forbidden.
find /bundle -type f -exec chmod a-s {} +
