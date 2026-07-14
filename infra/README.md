# infra - emisar on Google Cloud

This directory is the production Terraform configuration for the emisar control
plane. HCP Terraform workspace `Dryga/emisar` owns state and applies. GitHub CD
uploads reviewed configurations and creates saved plans; it never applies them.

See [`.github/DEPLOYMENT.md`](../.github/DEPLOYMENT.md) for the public delivery,
rollout, and rollback contract.

```text
Cloud DNS (DNSSEC) -> global IPv4/IPv6 HTTPS load balancer
                         |-> regional MIG of private COS instances
                         |      |-> Secret Manager
                         |      |-> Cloud SQL PostgreSQL over private IP
                         |      `-> Cloud Logging and Monitoring
                         `-> public-read, versioned pack registry in GCS

Private instances -> Cloud NAT for controlled egress
Operators -> IAP + OS Login for SSH
Better Stack -> external probes, on-call escalation, public status page
```

## Production controls

| Area | Configuration |
|---|---|
| Compute | Regional managed instance group, Shielded VM, no external VM IPs, zero-unavailable rolling updates |
| Database | Cloud SQL PostgreSQL 18, private IP, IAM database authentication through a local proxy, PITR, automated backups, deletion protection |
| Network | Dedicated VPC, flow logs, Cloud NAT, load-balancer-only application ingress, IAP-only SSH |
| TLS | Certificate Manager DNS authorization, managed certificates, restricted TLS 1.2+ policy |
| Secrets | Explicit Secret Manager versions fingerprint the VM template; VM access is per-secret and read-only |
| Supply chain | Production runs an immutable GHCR digest built and tested by CI; pack artifacts are versioned in GCS |
| DNS | Authoritative Cloud DNS zone with DNSSEC signing and the complete web and email record set |
| Monitoring | Google Cloud alerts plus independent Better Stack probes, escalation, and status page |

Environment sizing and contacts are HCP Terraform workspace variables. Do not
commit production scale, spend, contact addresses, or secrets.

## Delivery

Every main-branch delivery reuses the exact CI workflow that tested the commit.
For portal changes, CD publishes that tested image to GHCR by immutable digest.
For portal or infrastructure changes, CD then:

1. Verifies the commit is still current `main`.
2. Uploads `infra/` as a provisional HCP Terraform configuration.
3. Creates a saved plan with the tested image digest.
4. Stops and links the complete plan in the GitHub job summary.

Review every resource action and the run's commit before selecting **Confirm &
Apply** in HCP Terraform. Workspace auto-apply must remain disabled. A replaced
or stale saved plan is discarded instead of applying against changed state.

Normal image rollouts create one replacement VM whose `/healthz` remains false
until the release has reached PostgreSQL once, wait for that gate, and only then
drain an old VM. The load balancer independently requires `/readyz` continuously.
Old and new application versions overlap, so schema
changes use expand/contract sequencing. Rollback is another reviewed plan that
sets `container_image` to a previously published digest. During the IAM cutover,
a pre-cutover image rollback must atomically set `database_auth_mode=password`
and retain `database_password_rollback_enabled=true` in that same plan: those
images do not understand the passwordless database runtime configuration. The
Cloud SQL Auth Proxy is a separately pinned infrastructure container, so changing
the portal image never changes or removes it.

## Runtime shape

Cloud-init fetches exact Secret Manager versions, assigns the
instance's internal IP to `NODE_IP`, runs Ecto migrations under their advisory
lock, and starts the already-cached immutable container digest. In IAM mode a
separately pinned loopback Cloud SQL Auth Proxy container obtains short-lived
database credentials from the VM identity; the application assumes the non-login
`emisar_owner` role. The portal image contains only the application release.
`Emisar.Cluster.GCE` discovers running peers by
the `cluster_name` label through the Compute API. Erlang distribution is limited
to tagged application instances on TCP 4369 and 9100-9105.

The load balancer uses DB-independent `/healthz` for auto-healing and DB-aware
`/readyz` for traffic eligibility. Backend HTTP accepts only Google proxy and
health-check source ranges. Public traffic terminates TLS at the load balancer.

## Secrets

Externally issued credentials are sensitive HCP Terraform workspace variables.
`SECRET_KEY_BASE` and `RELEASE_COOKIE` are separate values with independent
generations. Production
database access uses IAM; the password secret exists only during cutover as a
tested rollback path. Adding a secret requires:

1. A sensitive variable in `variables.tf` when the value is externally issued.
2. A Terraform-managed secret container and an `app_secrets` entry in `secrets.tf`.
3. An `optional_secret_values` entry when the application can boot without it.
4. The minimum per-secret IAM binding for the instance service account.

Never place values in git, defaults, command history, or `.tfvars` files.

Changing a workspace value alone is intentionally not a rotation: write-only
values cannot produce a useful diff at a stable version. Rotate one credential
by incrementing only its entry in `local.secret_generations`. The resulting
exact version is part of cloud-init, so the instance template rolls and no VM
ever follows the mutable `latest` alias.

The first cookie cutover is special: leave `release_cookie_ready=false`. First
prove every serving VM is healthy and uses one instance template, then read the
numeric `emisar-secret-key-base` version embedded in that template's rendered
startup script. Never use `latest`: an out-of-band newer version is not
necessarily the value running VMs use. This command intentionally fails until
the new exact-version template has fully rolled out.

```sh
instances=$(gcloud compute instance-groups managed list-instances emisar \
  --project emisar --region us-central1 --format=json)
jq -e 'length > 0 and all(.[];
  .instanceStatus == "RUNNING" and .currentAction == "NONE" and
  all(.instanceHealth[]?; .detailedHealthState == "HEALTHY"))' <<<"$instances"
templates=$(jq -r '.[].version.instanceTemplate | split("/")[-1]' \
  <<<"$instances" | sort -u)
[ "$(printf '%s\n' "$templates" | sed '/^$/d' | wc -l | tr -d ' ')" = 1 ]
template=$templates
secret_version=$(gcloud compute instance-templates describe "$template" \
  --project emisar --format=json |
  jq -r '.properties.metadata.items[] | select(.key == "user-data") | .value' |
  sed -n 's/.*fetch_secret "emisar-secret-key-base" "\([0-9][0-9]*\)" "SECRET_KEY_BASE".*/\1/p')
[ -n "$secret_version" ]
umask 077
gcloud secrets versions access "$secret_version" --project emisar \
  --secret emisar-secret-key-base |
  { IFS= read -r value; printf 'emisar-release-cookie:%s' "$value" | openssl dgst -sha256 -r | cut -d' ' -f1; } \
  > /tmp/emisar-release-cookie
```

Store that file's value as sensitive ephemeral `release_cookie_value`, securely
delete the local file, then set
`release_cookie_ready=true`. Old and new nodes use identical cookies, so this is
a normal zero-unavailable rollout. Rotate signing and cookie values separately
in later maintenance windows: first prove no migration/long-running job is in
flight; increment only the affected generation; retain the preceding Secret
Manager version; watch ready backends and cluster-failure alerts until every VM
uses the same template; verify a single cluster and user/session behavior. A
failed cookie rotation is recovered by writing the preceding value at a new
generation and rolling forward, never by following `latest` or decrementing a
write-only generation.

## Database IAM and pgAudit cutover

The cutover is deliberately reversible and fits one short maintenance window:

1. Apply with `database_auth_mode=password`, `pgaudit_log=none`, and password
   rollback enabled. Enabling the Cloud SQL pgAudit flag restarts the zonal
   instance; wait for `/readyz` and record the interruption.
2. Run `scripts/prepare-database-iam.sql` through the existing database user.
   It installs pgAudit, creates `emisar_owner`, and reassigns database, schema,
   relation, sequence, type, and function ownership.
3. Confirm `local.cloud_sql_proxy_image` is the reviewed official version-and-digest
   pin. Set `database_owner_role_ready=true` and roll the candidate portal image
   while still in password mode. Start a temporary proxy from the pinned sidecar
   image on one serving VM; this uses the production VM identity, not the
   operator's IAM principal:

   ```sh
   instance_url=$(gcloud compute instance-groups managed list-instances emisar \
     --project emisar --region us-central1 --format=json | jq -er '.[0].instance')
   vm=${instance_url##*/}
   zone=$(printf '%s' "$instance_url" | awk -F/ '{print $(NF-2)}')
   connection_name=$(gcloud sql instances describe emisar --project emisar \
     --format='value(connectionName)')
   proxy_image='gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.23.0@sha256:54e23cad9aeeedbf88ab75f993146631b878035f702b31c51885a932e0c7286c'
   gcloud compute ssh "$vm" --project emisar --zone "$zone" --tunnel-through-iap \
     --command="sudo docker rm -f emisar-iam-verify 2>/dev/null || true; sudo docker run -d --rm --name emisar-iam-verify --network host '$proxy_image' --private-ip --auto-iam-authn --address 127.0.0.1 --port 55432 '$connection_name'"
   gcloud compute ssh "$vm" --project emisar --zone "$zone" --tunnel-through-iap \
     -- -N -L 55432:127.0.0.1:55432
   gcloud compute ssh "$vm" --project emisar --zone "$zone" --tunnel-through-iap \
     --command='sudo docker rm -f emisar-iam-verify'
   ```

   While that tunnel remains open, run from a second terminal. When the verifier
   returns, stop the tunnel with Ctrl-C; the next command in the first terminal
   removes the temporary proxy:

   ```sh
   psql -h 127.0.0.1 -p 55432 -U emisar-vm@emisar.iam -d emisar \
     -v expected_session_user=emisar-vm@emisar.iam \
     -f infra/scripts/verify-database-iam.sql
   ```

   The verifier refuses the password rollback principal and proves migration
   ownership. Then set `database_auth_mode=iam` and roll one VM at a time. Prove
   boot, migration, reconnect, cluster formation, readiness, and both rollback
   cases before proceeding: an IAM-runtime-capable image changes only
   `container_image`; a pre-IAM-runtime image changes `container_image` and
   `database_auth_mode=password` atomically while rollback resources still exist.
4. Set `pgaudit_log=role,ddl`. Confirm `AUDIT:` entries for role/DDL activity and
   confirm normal `SELECT`, `INSERT`, `UPDATE`, and `DELETE` traffic is absent.
   `pgaudit.log_parameter` remains off. Revert to `none` immediately if volume
   is not as expected.
5. After the rollback period, set `database_password_rollback_enabled=false`.
   That removes the built-in password user and DATABASE_URL version from new
   runtime configuration. The database URL version is deleted deliberately;
   its container, access logs, and the independent 400-day audit evidence remain.

## Terraform authority

The single HCP Terraform workspace owns the complete production stack,
including IAM, WIF, secret containers, and workload resources. Its HCP token
and apply identity are production-admin credentials. Organization policies
start in dry-run and are enforced only after Policy Simulator and clean plans.

## DNS and DNSSEC

`dns.tf` is the complete authoritative zone. Add durable records there before
expecting them to resolve publicly. Cloud DNS supplies the apex NS and SOA
records itself.

DNSSEC is complete: Cloud DNS signs the zone and the registrar publishes the
current key-signing DS, so validating resolvers authenticate the chain from
`.dev` to `emisar.dev`. Verify the live chain with:

```sh
dig +short DS emisar.dev
dig @1.1.1.1 +dnssec emisar.dev A
dig @8.8.8.8 +dnssec emisar.dev A
```

Every registrar DS must appear in `terraform output -json dnssec_ds_record`; both resolver
responses must contain the `ad` flag. A future DNSSEC key rotation follows the
same parent/child ordering discipline: publish the replacement DS only after the
new child key is active, and remove the old DS only after resolver convergence.

## Pack registry

`registry.emisar.dev` terminates at the shared load balancer and routes directly
to one public-read GCS bucket. The publisher can create, but cannot replace or
delete, objects under `v1/packs/`, `v1/catalog/`, and `v1/schemas/`. It can
replace or delete only `catalog.json` and `suggest.json`; GCS requires delete
permission to replace an object. A repeated immutable publication fetches the
existing object and verifies its bytes before treating the collision as
idempotent. Bucket versioning retains previous pointer generations.

```sh
curl -fsS https://registry.emisar.dev/v1/catalog.json | jq '.schema_version'
gcloud storage ls -a gs://$(terraform output -raw pack_registry_bucket)/v1/catalog.json
```

Pack publication has a separate GitHub environment approval and is serialized
so an active publication cannot be canceled halfway through.

## Recovery drills

Run `drills/cleanup-recovery-drills.sh` before and after every exercise; after
client loss an operator must run its 12-hour janitor mode to find abandoned
labeled/prefixed resources. It is intentionally supervised rather than backed by
a persistent cross-service delete identity. `drills/run-pitr-iam.sh` is dry-run by default. With `--apply` it clones a recent
PITR point into a uniquely named scratch instance, creates a temporary scoped IAM
principal and private probe VM, proves restored data through `emisar_owner`, and
uses the independent janitor on exit, and fails a successful drill if cleanup or
final inventory verification fails. It never patches, stops, or routes traffic
to production. Evidence manifests live under the git-ignored `.agent/drills/`;
record actual RPO/RTO and retain the empty-inventory result.

## Outputs

Useful non-secret outputs:

```sh
terraform output url
terraform output lb_ipv4
terraform output lb_ipv6
terraform output nameservers
terraform output status_page_url
terraform output pack_registry_base_url
```

## Validation

Run from this directory:

```sh
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
tflint
scripts/validate-templates.sh
```

These checks are credential-free. A live plan or apply is a separate,
credentials-gated production action performed through HCP Terraform.
