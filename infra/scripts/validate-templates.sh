#!/usr/bin/env bash
set -euo pipefail

infra_dir=$(cd "$(dirname "$0")/.." && pwd)
render_dir="${infra_dir}/tests/render"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
proxy_image='gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c'

grep -Fqx "  cloud_sql_proxy_image = \"$proxy_image\"" "${infra_dir}/compute.tf"
proxy_version=$(docker run --rm --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges "$proxy_image" --version)
grep -Fq 'cloud-sql-proxy version 2.23.0+container' <<<"$proxy_version"

terraform -chdir="$render_dir" init -backend=false -input=false >/dev/null
terraform -chdir="$render_dir" apply -auto-approve -input=false \
  -state="$tmp/render.tfstate" >/dev/null

rendered="$tmp/cloud-init.yaml"
terraform -chdir="$render_dir" output -state="$tmp/render.tfstate" \
  -raw cloud_init >"$rendered"
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)' "$rendered"
cloud-init schema --config-file "$rendered"

grep -Fq "ensure_image \"$proxy_image\"" "$rendered"
grep -Fq -- "--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges $proxy_image --private-ip --auto-iam-authn" "$rendered"
grep -Fq 'Wants=emisar-cloud-sql-proxy.service' "$rendered"
if grep -Eq '^[[:space:]]+(Requires|BindsTo|PartOf|Requisite|PropagatesStopTo)=.*emisar-cloud-sql-proxy' "$rendered"; then
  echo "portal service must not restart with the Cloud SQL Auth Proxy" >&2
  exit 1
fi
ruby -ryaml -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  document.fetch("write_files").each do |entry|
    next unless entry.fetch("path").end_with?(".sh")
    destination = File.join(ARGV.fetch(1), File.basename(entry.fetch("path")))
    File.write(destination, entry.fetch("content"))
  end
' "$rendered" "$tmp"

for script in "$tmp"/*.sh; do
  bash -n "$script"
  shellcheck "$script"
done

mta_policy="${infra_dir}/templates/mta-sts.txt"
grep -qx 'version: STSv1' "$mta_policy"
grep -qx 'mode: testing' "$mta_policy"
grep -qx 'mx: aspmx.l.google.com' "$mta_policy"
grep -qx 'mx: \*.aspmx.l.google.com' "$mta_policy"
grep -Eq '^max_age: [1-9][0-9]*$' "$mta_policy"
