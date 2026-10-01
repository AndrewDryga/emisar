#!/bin/bash
set -euo pipefail
image=$1
case "$image" in
  *@sha256:*) ;;
  *) echo 'admin diagnostics image must have an immutable digest' >&2; exit 1 ;;
esac
# Installation runs before connect and installs only boot-recreatable files. The
# immutable image is copied, never started or given host mounts or privileges.
root=/run/emisar-admin-runner
if [[ ! "$image" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/-]*:[a-zA-Z0-9._-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo 'invalid admin diagnostics image identity' >&2
  exit 1
fi
stage=$(mktemp -d "$root/diagnostics.XXXXXX")
container=
cleanup() {
  [ -z "$container" ] || docker rm "$container" >/dev/null
  rm -rf "$stage"
}
trap cleanup EXIT
if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker pull "$image" >/dev/null
fi
container=$(docker create "$image")
docker cp "$container:/bundle/." "$stage/"
# Verify the extracted command set before exposing any executable on PATH.
while IFS= read -r command; do
  case "$command" in
    bash|chronyc|curl|dmidecode|ethtool|findmnt|free|iostat|jq|last|lscpu|lvs|mdadm|ntpq|ping|ps|pvs|sar|sadc|slabtop|smartctl|ss|sysctl|uptime|vgs|vmstat) ;;
    *) echo 'unexpected admin diagnostics command' >&2; exit 1 ;;
  esac
  test -x "$stage/libexec/$command"
  test "$(readlink "$stage/bin/$command")" = ../run-tool
done < "$stage/commands.txt"
test -x "$stage/lib/loader"
test -x "$stage/run-tool"
test -x "$stage/cli-plugins/docker-compose"
# Validate executable architecture and the relocated dependency closure before
# replacing a previously working installation. No diagnostic mutations occur.
"$stage/bin/iostat" -V >/dev/null
"$stage/bin/sadc" -V >/dev/null
"$stage/bin/ntpq" --version >/dev/null
"$stage/cli-plugins/docker-compose" version >/dev/null
chmod -R go-w "$stage"
rm -rf "$root/diagnostics"
mv "$stage" "$root/diagnostics"
install -d -m 0700 "$root/docker"
# This config only selects a CLI plugin; it contains no registry credentials.
printf '{"cliPluginsExtraDirs":["%s/diagnostics/cli-plugins"]}\n' "$root" > "$root/docker/config.json"
