#!/usr/bin/env bash
# Smoke-test an official runner container image — the same checks gate a
# CI build of the Dockerfile and the published release image (which the
# release workflow runs against the pushed digest, per platform):
#
#   runner/release/verify-image.sh IMAGE VERSION [PLATFORM]
#
# IMAGE is a local tag or a pushed ref (name@sha256:...); VERSION is the
# exact version `emisar --version` must report; PLATFORM selects an arch
# from a multi-arch ref (e.g. linux/arm64, running under qemu on amd64).
set -euo pipefail

image=${1:?usage: verify-image.sh IMAGE VERSION [PLATFORM]}
version=${2:?usage: verify-image.sh IMAGE VERSION [PLATFORM]}
platform=${3:-}

release_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

run() {
  if [ -n "$platform" ]; then
    docker run --rm --platform "$platform" "$@"
  else
    docker run --rm "$@"
  fi
}

fail() {
  echo "verify-image: $1" >&2
  exit 1
}

echo "== verifying ${image}${platform:+ (${platform})}"

# Non-root by default, at the pinned uid the docs cite.
uid=$(run "$image" id -u)
test "$uid" = 65532 || fail "container user is uid ${uid}, want 65532"

# The binary is the release build it claims to be.
got=$(run "$image" emisar --version)
test "$got" = "emisar version ${version}" || fail "'${got}' != 'emisar version ${version}'"

# The baked packs load and are exactly the curated set — nothing dropped,
# nothing smuggled in.
expected=$(grep -Ev '^[[:space:]]*(#|$)' "${release_dir}/container-packs.txt" | sort | paste -sd, -)
actual=$(run "$image" emisar pack list --json | jq -r '.[].id' | sort | paste -sd, -)
test "$actual" = "$expected" || fail "baked packs '${actual}' != expected '${expected}'"

# doctor proves the default config is usable end to end: config loads and
# validates, the enrollment credential is read from the documented env var,
# pack dirs and packs load, every action's executable resolves on PATH, and
# the baked control-plane URL answers over TLS. Missing action tools only
# WARN in doctor, so require the zero-warning summary line, not just exit 0.
doctor=$(run -e EMISAR_ENROLLMENT_KEY=emkey-smoke-canary "$image" emisar doctor) \
  || { printf '%s\n' "$doctor"; fail "emisar doctor failed"; }
printf '%s\n' "$doctor"
grep -q "All checks passed" <<<"$doctor" || fail "emisar doctor reported warnings"

# Runner state persists under /var/lib/emisar and the runtime user owns it.
run "$image" sh -c 'touch /var/lib/emisar/.smoke' || fail "/var/lib/emisar is not writable"

# Pack bytes stay immutable to the runtime user.
test "$(run "$image" stat -c '%U:%G:%a' /opt/emisar/packs)" = "root:root:755" \
  || fail "/opt/emisar/packs ownership drifted"
run "$image" sh -c '! touch /opt/emisar/packs/.smoke 2>/dev/null' \
  || fail "/opt/emisar/packs is writable by the runtime user"

echo "verify-image: ${image}${platform:+ (${platform})} ok"
