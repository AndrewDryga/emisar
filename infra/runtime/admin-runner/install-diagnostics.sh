#!/bin/bash
set -euo pipefail
image=$1
[[ "$image" =~ ^ghcr\.io/andrewdryga/emisar@sha256:[a-f0-9]{64}$ ]]
[ "$(id -u)" = 0 ]
[ "$(uname -m)" = x86_64 ]
root=/run/emisar-admin-runner
install -d -o root -g root -m 0700 "$root"
# A restart with the exact cached digest must not depend on registry uptime.
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker pull "$image" >/dev/null
fi
identity=$(docker inspect --format '{{.Os}}|{{.Architecture}}|{{index .Config.Labels "org.emisar.image-purpose"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")
IFS='|' read -r os architecture purpose revision <<< "$identity"
[ "$os" = linux ] && [ "$architecture" = amd64 ] && [ "$purpose" = admin-diagnostics ]
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
digests=$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image")
grep -Fxq "$image" <<< "$digests"
stage=$(mktemp -d "$root/diagnostics.XXXXXX")
cid=''
committed=false
cleanup() {
  [ -z "$cid" ] || docker rm "$cid" >/dev/null 2>&1 || true
  rm -f "$stage.link"
  rm -f "$stage.previous.link"
  if [ "$committed" = false ]; then rm -rf "$stage"; fi
}
trap cleanup EXIT
# The extraction container is never started and receives no mounts or socket.
cid=$(docker create --network none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges "$image")
docker cp "$cid:/bundle/." "$stage"
bash /var/lib/emisar-admin-runner/verify-diagnostics.sh "$stage" "$revision" amd64
chown -R root:root "$stage"
find "$stage" -type f -exec chmod a-s,go-w {} +
find "$stage" -type d -exec chmod go-w {} +
# Validate staged closure without letting sar's fixed path sample an old bundle.
"$stage/bin/ntpq" --version >/dev/null
"$stage/bin/iostat" -V >/dev/null
"$stage/bin/chronyc" -v >/dev/null
"$stage/cli-plugins/docker-compose" version >/dev/null
[ ! -e "$root/diagnostics" ] || [ -L "$root/diagnostics" ]
previous=$(readlink "$root/diagnostics" || true)
rollback=$(readlink "$root/diagnostics.previous" || true)
owned_generation() {
  local generation=$1
  [[ "$generation" =~ ^diagnostics\.[A-Za-z0-9]{6}$ ]] &&
    [ -d "$root/$generation" ] && [ ! -L "$root/$generation" ]
}
if [ -n "$previous" ]; then
  owned_generation "$previous"
  ln -s "$previous" "$stage.previous.link"
fi
install -d -o root -g root -m 0700 "$root/docker"
printf '{"cliPluginsExtraDirs":["%s/diagnostics/cli-plugins"]}\n' "$root" > "$stage/docker-config.json"
chmod 0600 "$stage/docker-config.json"
mv -f "$stage/docker-config.json" "$root/docker/config.json"
[ ! -e "$root/diagnostics" ] || [ -L "$root/diagnostics" ]
ln -s "$(basename "$stage")" "$stage.link"
if [ -n "$previous" ]; then
  mv -Tf "$stage.previous.link" "$root/diagnostics.previous"
fi
mv -Tf "$stage.link" "$root/diagnostics"
committed=true
# At most the active and one prior generation survive successful installation.
# Only a previously referenced, fully valid owned generation is removable.
if [ -n "$rollback" ] && [ "$rollback" != "$previous" ] && owned_generation "$rollback"; then
  old_revision=$(sed -n 's/^revision=\([a-f0-9]\{40\}\)$/\1/p' "$root/$rollback/manifest")
  if bash /var/lib/emisar-admin-runner/verify-diagnostics.sh "$root/$rollback" "$old_revision" amd64; then
    rm -rf "${root:?}/${rollback:?}"
  else
    echo 'retaining invalid prior diagnostics generation for inspection' >&2
  fi
fi
