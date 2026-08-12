#!/bin/bash
set -euo pipefail

install -d -m 0700 /run/emisar-admin-runner

for attempt in $(seq 1 60); do
  if docker exec emisar /app/bin/emisar pid >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" = 60 ]; then
    echo "local emisar release did not become available" >&2
    exit 1
  fi
  sleep 2
done

token_response=$(curl --fail --silent --show-error --retry 5 --retry-delay 2 \
  --retry-connrefused --connect-timeout 5 --max-time 30 \
  -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)
TOKEN=$(printf '%s' "$token_response" | grep -oE '"access_token": ?"[^"]+"' | cut -d'"' -f4 || true)
[ -n "$TOKEN" ] || { echo "no metadata access token" >&2; exit 1; }

fetch_secret() {
  local secret=$1
  local version=$2
  local label=$3
  local body status data decoded

  body=$(mktemp /run/emisar-admin-runner/secret.XXXXXX)
  if ! status=$(printf 'Authorization: Bearer %s\n' "$TOKEN" | \
    curl --silent --show-error --retry 5 --retry-delay 2 \
      --retry-connrefused --connect-timeout 5 --max-time 30 \
      -H @- -o "$body" -w '%%{http_code}' \
      "https://secretmanager.googleapis.com/v1/projects/${project_id}/secrets/$${secret}/versions/$${version}:access"); then
    rm -f "$body"
    echo "Secret Manager $label request failed" >&2
    return 1
  fi
  if [ "$status" != 200 ]; then
    rm -f "$body"
    echo "Secret Manager returned HTTP $status for $label" >&2
    return 1
  fi
  data=$(grep -oE '"data": ?"[^"]+"' "$body" | cut -d'"' -f4 || true)
  rm -f "$body"
  [ -n "$data" ] || { echo "Secret Manager returned no $label" >&2; return 1; }
  decoded=$(printf '%s' "$data" | base64 -d) || {
    echo "Secret Manager returned invalid $label data" >&2
    return 1
  }
  printf '%s' "$decoded"
}

EMISAR_ENROLLMENT_KEY=$(fetch_secret \
  emisar-admin-runner-enrollment-key \
  "${enrollment_secret_version}" \
  enrollment-key)
printf '%s' "$EMISAR_ENROLLMENT_KEY" | grep -Eq '^emkey-enroll-[A-Za-z0-9_-]{16,}$' || {
  echo "Secret Manager returned an invalid enrollment key" >&2
  exit 1
}
export EMISAR_ENROLLMENT_KEY

TFE_TOKEN=$(fetch_secret \
  emisar-admin-runner-tfe-token \
  "${tfe_secret_version}" \
  HCP-token)
[ "$${#TFE_TOKEN}" -ge 16 ] || {
  echo "Secret Manager returned an invalid HCP token" >&2
  exit 1
}
export TFE_TOKEN

SENTRY_AUTH_TOKEN=$(fetch_secret \
  emisar-admin-runner-sentry-token \
  "${sentry_secret_version}" \
  Sentry-token)
[ "$${#SENTRY_AUTH_TOKEN}" -ge 32 ] || {
  echo "Secret Manager returned an invalid Sentry token" >&2
  exit 1
}
export SENTRY_AUTH_TOKEN
# The organization's own URL, which serves the same /api/0 the pack's default
# sentry.io host does. Naming it explicitly keeps the reads on this org's
# region rather than depending on a redirect.
export SENTRY_URL=https://emisar.sentry.io

runner=/run/emisar-admin-runner/bin/emisar
expected_version="emisar version ${runner_version}"
# Seed from the checksum-verified release so first boot does not depend on the
# registry; the exact-version/hash loop below owns the final installed bytes.
bundled_packs='linux-core debugging systemd-deep cloud-init docker firewall nic time-sync elixir-beam'
runner_bin_dir=$(dirname "$runner")
install -d -m 0755 "$runner_bin_dir"
install -m 0755 /var/lib/emisar-admin-runner/gcloud.sh "$runner_bin_dir/gcloud"
export PATH="$runner_bin_dir:$PATH"
command -v curl >/dev/null
command -v jq >/dev/null
gcloud version >/dev/null
installed_version=$($runner --version 2>/dev/null || true)
if [ "$installed_version" != "$expected_version" ]; then
  case "$(uname -m)" in
    x86_64|amd64) runner_arch=amd64 ;;
    aarch64|arm64) runner_arch=arm64 ;;
    *) echo "unsupported runner architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  release_tag="runner-v${runner_version}"
  release_name="emisar-${runner_version}-linux-$${runner_arch}"
  tarball="$${release_name}.tar.gz"
  release_base="https://github.com/andrewdryga/emisar/releases/download/$${release_tag}"
  bundle_dir=$(mktemp -d /run/emisar-admin-runner/release.XXXXXX)
  trap 'rm -rf "$bundle_dir"' EXIT

  curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --retry-connrefused --connect-timeout 5 --max-time 30 \
    "$${release_base}/$${tarball}" -o "$${bundle_dir}/$${tarball}"
  curl --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --retry-connrefused --connect-timeout 5 --max-time 30 \
    "$${release_base}/SHA256SUMS" -o "$${bundle_dir}/SHA256SUMS"

  expected_hash=$(awk -v artifact="$tarball" '$2 == artifact {print $1}' \
    "$${bundle_dir}/SHA256SUMS")
  printf '%s' "$expected_hash" | grep -Eq '^[a-f0-9]{64}$' || {
    echo "release checksums do not contain exactly one valid hash for $${tarball}" >&2
    exit 1
  }
  actual_hash=$(sha256sum "$${bundle_dir}/$${tarball}" | cut -d' ' -f1)
  [ "$actual_hash" = "$expected_hash" ] || {
    echo "release checksum mismatch for $${tarball}" >&2
    exit 1
  }

  tar -C "$bundle_dir" -xzf "$${bundle_dir}/$${tarball}"
  install -d -m 0755 "$(dirname "$runner")"
  install -m 0755 "$${bundle_dir}/$${release_name}/emisar" "$${runner}.new"
  [ "$("$${runner}.new" --version)" = "$expected_version" ]
  mv "$${runner}.new" "$runner"

  for pack in $bundled_packs; do
    bundle_pack="$${bundle_dir}/$${release_name}/packs/$${pack}"
    if [ -f "$${bundle_pack}/pack.yaml" ]; then
      "$runner" pack install "$bundle_pack" \
        --dest /var/lib/emisar-admin-runner/packs \
        --force
    fi
  done

  rm -rf "$bundle_dir"
  trap - EXIT
fi

[ "$($runner --version)" = "$expected_version" ]
test -f /var/lib/emisar-admin-runner/packs/emisar-admin/pack.yaml
test -r /var/lib/emisar-admin-runner/packs/emisar-admin/scripts/callback.sh
# A missing pack is installed by the pinned loop below, which passes --hash: a
# pack with no directory validates to an empty hash, which never matches the
# expected one. The install-by-bare-name that used to sit here added nothing
# except a window where registry bytes nobody had verified were on the disk of a
# runner admitted at max_risk: critical.
while IFS='|' read -r pack_ref expected_hash; do
  pack_id=$${pack_ref%%=*}
  installed_hash=$("$runner" pack validate \
    "/var/lib/emisar-admin-runner/packs/$${pack_id}" 2>/dev/null | \
    awk '$1 == "hash:" {print $2}' || true)
  if [ "$installed_hash" != "$expected_hash" ]; then
    "$runner" pack install "$pack_ref" \
      --hash "$expected_hash" \
      --dest /var/lib/emisar-admin-runner/packs \
      --force
  fi
done <<'PACKS'
${pinned_packs}
PACKS
"$runner" pack list --packs-dir /var/lib/emisar-admin-runner/packs >/dev/null

exec "$runner" connect --config /var/lib/emisar-admin-runner/config.yaml
