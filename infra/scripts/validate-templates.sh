#!/usr/bin/env bash
set -euo pipefail

infra_dir=$(cd "$(dirname "$0")/.." && pwd)
render_dir="${infra_dir}/tests/render"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
proxy_image='gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c'
livebook_image='ghcr.io/livebook-dev/livebook:0.19.8@sha256:38eed8467d3df794dd36cbe722768e46d709b02e00368e0a06aa7508220a8763'

grep -Fqx "  cloud_sql_proxy_image = \"$proxy_image\"" "${infra_dir}/compute.tf"
proxy_version=$(docker run --rm --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges "$proxy_image" --version)
grep -Fq 'cloud-sql-proxy version 2.23.0+container' <<<"$proxy_version"

sed -nE 's/^[[:space:]]*livebook_image[[:space:]]*=[[:space:]]*//p' \
  "${infra_dir}/livebook.tf" | grep -Fqx "\"$livebook_image\""
livebook_version=$(docker run --rm --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --entrypoint /app/bin/livebook \
  "$livebook_image" version)
grep -Fq 'livebook 0.19.8' <<<"$livebook_version"

terraform -chdir="$render_dir" init -backend=false -input=false >/dev/null
terraform -chdir="$render_dir" apply -auto-approve -input=false \
  -state="$tmp/render.tfstate" >/dev/null

rendered="$tmp/cloud-init.yaml"
terraform -chdir="$render_dir" output -state="$tmp/render.tfstate" \
  -raw cloud_init >"$rendered"
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)' "$rendered"
cloud-init schema --config-file "$rendered"

livebook_rendered="$tmp/livebook-cloud-init.yaml"
terraform -chdir="$render_dir" output -state="$tmp/render.tfstate" \
  -raw livebook_cloud_init >"$livebook_rendered"
ruby -ryaml -e 'YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)' "$livebook_rendered"
cloud-init schema --config-file "$livebook_rendered"

grep -Fq "ensure_image \"$proxy_image\"" "$rendered"
grep -Fq -- "--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges $proxy_image --private-ip --auto-iam-authn" "$rendered"
grep -Fq 'Wants=emisar-cloud-sql-proxy.service' "$rendered"
grep -Fq '/var/lib/emisar-admin-runner/install.sh' "$rendered"
grep -Fq 'runner=/run/emisar-admin-runner/bin/emisar' "$rendered"
grep -Fq 'BIN_DIR=/run/emisar-admin-runner/bin' "$rendered"
grep -Fq '/bin/bash /var/lib/emisar-admin-runner/install.sh' "$rendered"
grep -Fq -- '--version "0.14.0"' "$rendered"
grep -Fq -- '--no-service' "$rendered"
grep -Fq 'emisar version 0.14.0' "$rendered"
grep -Fq 'docker exec emisar /app/bin/emisar pid' "$rendered"
grep -Fq 'exec "$runner" connect --config /var/lib/emisar-admin-runner/config.yaml' "$rendered"
grep -Fq 'Requires=emisar.service' "$rendered"
grep -Fq 'PartOf=emisar.service' "$rendered"
grep -Fq 'group: emisar-admin' "$rendered"
grep -Fq 'max_risk: critical' "$rendered"
grep -Fq '/var/lib/emisar-admin-runner/packs/emisar-admin/pack.yaml' "$rendered"
if [ "$(wc -c < "$rendered")" -gt 262144 ]; then
  echo "rendered cloud-init exceeds Compute Engine's per-value metadata limit" >&2
  exit 1
fi
if grep -Eq '^[[:space:]]+(Requires|BindsTo|PartOf|Requisite|PropagatesStopTo)=.*emisar-cloud-sql-proxy' "$rendered"; then
  echo "portal service must not restart with the Cloud SQL Auth Proxy" >&2
  exit 1
fi

mock_bin="$tmp/mock-bin"
mkdir "$mock_bin"
printf '%s\n' \
  '#!/bin/sh' \
  '[ "$1" = exec ] || exit 2' \
  'shift' \
  'while [ "${1-}" = --env ]; do export "$2"; shift 2; done' \
  '[ "$1" = emisar ] && [ "$2" = /app/bin/emisar ] && [ "$3" = rpc ]' \
  '[ "$EMISAR_ADMIN_ACTION_ID" = emisar.admin.account.show ]' \
  '[ "$EMISAR_ADMIN_ARG_COUNT" = 1 ]' \
  '[ "$EMISAR_ADMIN_ARG_1" = "account=demo=west" ]' \
  'case "$4" in *"Emisar.Admin.execute(action_id, args)"*) ;; *) exit 3 ;; esac' \
  'if [ "${MOCK_RPC_ERROR:-0}" = 1 ]; then' \
  '  printf "__EMISAR_ADMIN_ERROR__{\"ok\":false,\"error\":\"not_found\"}\\n"' \
  'else' \
  '  printf "__EMISAR_ADMIN_OK__{\"ok\":true,\"result\":{\"release\":\"test\"}}\\n"' \
  'fi' >"$mock_bin/docker"
chmod 0755 "$mock_bin/docker"

rpc_output=$(PATH="$mock_bin:$PATH" \
  /bin/sh "${infra_dir}/packs/emisar-admin/scripts/callback.sh" \
    emisar.admin.account.show 'account=demo=west')
[ "$rpc_output" = '{"ok":true,"result":{"release":"test"}}' ]

if PATH="$mock_bin:$PATH" MOCK_RPC_ERROR=1 \
  /bin/sh "${infra_dir}/packs/emisar-admin/scripts/callback.sh" \
    emisar.admin.account.show 'account=demo=west' \
  >"$tmp/rpc-error.out" 2>"$tmp/rpc-error.err"; then
  echo "admin RPC domain errors must fail the action" >&2
  exit 1
fi
grep -Fq '"error":"not_found"' "$tmp/rpc-error.err"

ruby -ryaml -rbase64 -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  document.fetch("write_files").each do |entry|
    next unless entry.fetch("path").end_with?(".sh")
    name = entry.fetch("path").delete_prefix("/").tr("/", "-")
    destination = File.join(ARGV.fetch(1), name)
    content = entry["encoding"] == "b64" ? Base64.strict_decode64(entry.fetch("content")) : entry.fetch("content")
    File.write(destination, content)
  end
' "$rendered" "$tmp"

livebook_scripts="$tmp/livebook-scripts"
mkdir "$livebook_scripts"
ruby -ryaml -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  document.fetch("write_files").each do |entry|
    next unless entry.fetch("permissions") == "0755"
    destination = File.join(ARGV.fetch(1), File.basename(entry.fetch("path")))
    File.write(destination, entry.fetch("content"))
  end
' "$livebook_rendered" "$livebook_scripts"

livebook_notebooks="$tmp/livebook-notebooks"
mkdir "$livebook_notebooks"
ruby -ryaml -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
  document.fetch("write_files").each do |entry|
    next unless entry.fetch("path").end_with?(".livemd")
    destination = File.join(ARGV.fetch(1), File.basename(entry.fetch("path")))
    File.write(destination, entry.fetch("content"))
  end
' "$livebook_rendered" "$livebook_notebooks"

for notebook in "${infra_dir}"/livebook/notebooks/*.livemd; do
  cmp "$notebook" "$livebook_notebooks/$(basename "$notebook")"
done

rendered_notebook_count=$(find "$livebook_notebooks" -type f -name '*.livemd' | wc -l | tr -d ' ')
source_notebook_count=$(find "${infra_dir}/livebook/notebooks" -type f -name '*.livemd' | wc -l | tr -d ' ')
[ "$rendered_notebook_count" = "$source_notebook_count" ]

docker run --rm --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /data:rw,nosuid,nodev,size=64m \
  --mount type=bind,src="$livebook_notebooks",dst=/notebooks,readonly \
  --entrypoint /app/bin/livebook "$livebook_image" eval '
    files = Path.wildcard("/notebooks/*.livemd")
    files == [] && raise "no Livebook notebooks rendered"

    Enum.each(files, fn file ->
      {notebook, %{warnings: warnings}} =
        file |> File.read!() |> Livebook.LiveMarkdown.notebook_from_livemd()

      warnings != [] && raise "#{Path.basename(file)}: #{inspect(warnings)}"

      notebook
      |> Livebook.Notebook.Export.Elixir.notebook_to_elixir()
      |> Code.string_to_quoted!()
    end)
  '

grep -Fq "ensure_image \"$livebook_image\"" "$livebook_rendered"
grep -Fq "ensure_image \"$proxy_image\"" "$livebook_rendered"
grep -Fq 'LIVEBOOK_IDENTITY_PROVIDER=google_iap:' "$livebook_rendered"
grep -Fq 'LIVEBOOK_TOKEN_ENABLED=false' "$livebook_rendered"
grep -Fq 'LIVEBOOK_NODE=livebook@' "$livebook_rendered"
grep -Fq 'PGOPTIONS=-c default_transaction_read_only=on' "$livebook_rendered"
grep -Fq 'install -d -o 1000 -g 1000 -m 0750 "$mountpoint/.livebook"' "$livebook_rendered"
grep -Fq 'if [ ! -e "$destination" ]; then' "$livebook_rendered"
grep -Fq '/data/notebooks/Emisar Product Analytics' "${infra_dir}/README.md"
grep -Fq 'product_analytics.exs' "$livebook_rendered"
grep -Fq -- '--user 1000:1000 --read-only --cap-drop=ALL --security-opt=no-new-privileges' "$livebook_rendered"
grep -Fq -- '--tmpfs /app/tmp:rw,nosuid,nodev,size=64m' "$livebook_rendered"
grep -Fq -- '--tmpfs /home/livebook:rw,exec,nosuid,nodev,size=512m' "$livebook_rendered"
grep -Fq -- "--network host --read-only --cap-drop=ALL --security-opt=no-new-privileges $proxy_image --private-ip --auto-iam-authn" "$livebook_rendered"
grep -Fq '/public/health' "${infra_dir}/lb.tf"
grep -Fq 'System.cmd("/bin/bash", ["/opt/emisar/list-portal-nodes"])' "${infra_dir}/README.md"
if grep -Fq 'LIVEBOOK_PASSWORD' "$livebook_rendered"; then
  echo "IAP-only Livebook must not configure a second password login" >&2
  exit 1
fi
if grep -Fq 'LIVEBOOK_CLUSTER=' "$livebook_rendered"; then
  echo "Livebook must not auto-join the production portal cluster" >&2
  exit 1
fi

livebook_home_probe=$(docker run --rm --read-only --user 1000:1000 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /home/livebook:rw,exec,nosuid,nodev,size=512m \
  --entrypoint /bin/sh "$livebook_image" -c '
    probe=/home/livebook/mix-install-exec-probe
    printf "#!/bin/sh\nprintf livebook-home-exec-ok\n" > "$probe"
    chmod 0700 "$probe"
    exec "$probe"
  ')
[ "$livebook_home_probe" = 'livebook-home-exec-ok' ]

for script in \
  "$tmp"/*.sh \
  "$livebook_scripts"/* \
  "${infra_dir}/scripts/database" \
  "${infra_dir}/scripts/portal"; do
  bash -n "$script"
  shellcheck "$script"
done

mta_policy="${infra_dir}/templates/mta-sts.txt"
grep -qx 'version: STSv1' "$mta_policy"
grep -qx 'mode: testing' "$mta_policy"
grep -qx 'mx: aspmx.l.google.com' "$mta_policy"
grep -qx 'mx: \*.aspmx.l.google.com' "$mta_policy"
grep -Eq '^max_age: [1-9][0-9]*$' "$mta_policy"
