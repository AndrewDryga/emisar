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
                         |      |-> host-supervised private emisar admin runner
                         |      `-> Cloud Logging and Monitoring
                         |-> optional private Livebook instance through IAP
                         |      |-> persistent notebook disk
                         |      |-> Cloud SQL IAM proxy
                         |      `-> explicit portal-node distribution
                         `-> public-read, versioned pack registry in GCS

Private instances -> Cloud NAT for controlled egress
Operators -> IAP + OS Login for SSH
Better Stack -> external probes, on-call escalation (severe GCP alarms page in), status page
```

## Production controls

| Area | Configuration |
|---|---|
| Compute | Regional managed instance group plus a host-supervised private admin runner per portal VM, optional single-node Livebook workbench, Shielded VMs, no external VM IPs, zero-unavailable portal rolling updates |
| Database | Cloud SQL PostgreSQL 18, private IP, IAM database authentication through a local proxy, PITR, automated backups, deletion protection |
| Network | Dedicated VPC, flow logs, Cloud NAT, load-balancer-only application ingress, IAP-only SSH |
| TLS | Certificate Manager DNS authorization, managed certificates, restricted TLS 1.2+ policy |
| Secrets | Explicit Secret Manager versions fingerprint the VM template; VM access is per-secret and read-only |
| Supply chain | Production runs an immutable portal GHCR digest built and tested by CI; COS installs a pinned immutable runner release with checksum verification, private packs are rendered by Terraform, and public pack artifacts are versioned in GCS |
| DNS | Authoritative Cloud DNS zone with DNSSEC signing and the complete web and email record set |
| Monitoring | Google Cloud alerts to email and Slack, with severe silent-failure alarms paging the Better Stack on-call; independent Better Stack probes, escalation, and status page |

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

Normal image rollouts may create one replacement VM per zone while retaining
every old serving VM. Each replacement's `/healthz` remains false until the
release has reached PostgreSQL once; only then can an old VM drain. The load
balancer independently requires `/readyz` continuously. Old and new application
versions overlap, so schema changes use expand/contract sequencing. Rollback is
another reviewed plan that sets `container_image` to a previously published
IAM-capable digest. Images from before the IAM database runtime are not rollback
candidates. The Cloud SQL Auth Proxy is a separately pinned infrastructure
container. The private admin runner is independently pinned in cloud-init and
continues to invoke the colocated portal release through its stable RPC boundary.

Readiness-contract replacements build a complete successor backend, wait for
every expected VM to pass `/readyz`, switch the URL map, and retain the previous
backend for five minutes while that change reaches every edge proxy. `getHealth`
alone is not sufficient: Google edge proxies can lag the control-plane URL-map
result. The regional MIG keeps the stable name `emisar`; changing its zone set
requires a separately reviewed staged migration, not an ordinary one-plan
replacement.

## Runtime shape

Cloud-init fetches exact Secret Manager versions, assigns the
instance's internal IP to `NODE_IP`, runs Ecto migrations under their advisory
lock, and starts the already-cached immutable container digest. A separately
pinned loopback Cloud SQL Auth Proxy container obtains short-lived
database credentials from the VM identity; the application assumes the non-login
`emisar_owner` role. Cloud-init installs the pinned runner release directly on
the COS host and writes the private packs from the reviewed Terraform module;
the portal container contains only the application release.
`Emisar.Cluster.GCE` discovers running peers by
the `cluster_name` label through the Compute API. Erlang distribution is limited
to tagged application instances plus explicit connections originating from the
Livebook tag on TCP 4369 and 9100-9105. Livebook has no `cluster_name` label, so
portal discovery never adds it automatically.

The load balancer uses DB-independent `/healthz` for auto-healing and DB-aware
`/readyz` for traffic eligibility. Backend HTTP accepts only Google proxy and
health-check source ranges. Public traffic terminates TLS at the load balancer.

## Private emisar administration

Every portal VM runs a dedicated `emisar-admin` runner directly under systemd.
Cloud-init uses the checked-in installer to fetch the pinned immutable runner
release, verify its published checksum, and install it under
`/run/emisar-admin-runner/bin`; COS mounts writable persistent paths `noexec`, so
config, identity, packs, and logs remain under `/var/lib/emisar-admin-runner`
while the boot-recreatable binary lives on executable tmpfs. Cloud-init also writes the unlisted
`infra/packs/emisar-admin` pack directly from the Terraform module. The runner advertises group
`emisar-admin` with `purpose=emisar-admin`; local admission accepts only
`emisar.admin.*` actions.

Set the reusable runner enrollment credential as the sensitive HCP
Terraform variable `emisar_runner_enrollment_key`. A regional MIG can create
several runners and replaces their boot disks during rollouts, so a single-use
key is insufficient. Issue the key in the management account with enough uses
for the fleet and rollout surge. Changing the variable automatically writes and
deploys a new exact Secret Manager version without storing the payload in state.

This is a fully trusted administration runner. It runs on the COS host and its
fixed script uses `docker exec emisar /app/bin/emisar rpc` to call the
colocated release, so compromising the runner is equivalent to compromising the
portal VM. The fixed pack passes its already-validated action arguments to one
private Elixir entrypoint; the normal action run remains the audit record.

After the first rollout, trust the exact `emisar-admin@0.1.0` hash advertised by
the new runners in the management account. Critical erasure actions remain
subject to the management account's normal policy and approval rules.

The pinned `runner-v0.14.0` release already exposes every contract this private
pack uses; the pack does not require a custom runner build.

## Portal VM operations

Use `scripts/portal` for IAP and OS Login access to the portal fleet. It limits
the picker to instances carrying the `cluster_name=emisar` label, supports fzf
multi-selection for read-only inspection and commands, and caches the selection
per shell session for repeated checks.

```sh
scripts/portal status
scripts/portal logs
scripts/portal --host emisar-example-a logs -f
scripts/portal version
scripts/portal remsh
scripts/portal cmd 'uptime && free -h'
scripts/portal --reuse-last-selection logs
scripts/portal --list-hosts
scripts/portal --host emisar-example-a --host emisar-example-b version
```

The helper uses the active gcloud project by default. Pass `--project`, or set
`EMISAR_GCP_PROJECT`, when the active configuration points elsewhere. `gcloud`
and, for interactive selection, `fzf` are required; the operator must have IAP
tunnel and OS Login access. `--list-hosts` prints one eligible VM name per line
for automation, and repeated `--host` options select exact VMs without fzf.

## Livebook admin workbench

The optional Livebook instance is a production admin/debug host. Enable it with
`livebook_enabled=true`, set its sizing as workspace variables, and set the
sensitive `livebook_iap_iam_user` to one lowercase Google Workspace user. The VM
has no public address. `https://livebook.<domain>` reaches a dedicated backend
through the shared HTTPS load balancer and grants only that principal the
resource-level IAP web-app role.

IAP uses Google's managed browser OAuth client; no OAuth client secret is
created or committed. Livebook receives
`LIVEBOOK_IDENTITY_PROVIDER=google_iap:<signed-jwt-audience>` and validates the
signed IAP assertion itself. `LIVEBOOK_TOKEN_ENABLED=false` and no
`LIVEBOOK_PASSWORD` is configured. Opening the URL therefore uses the current
Google/IAP browser identity automatically and never presents a second Livebook
login. Google's managed client is intentionally limited to users inside the
project's organization. The load balancer sends only Livebook's `/public/*`
health, tokenized input, and widget-asset routes to a separate non-IAP backend;
this is required because widgets load from `livebookusercontent.com` without an
operator IAP cookie. Every other route retains the IAP backend as its default.

Notebooks and Livebook configuration persist on the separately protected
`emisar-livebook-data` disk, mounted at `/data` in the container. Saved notebooks
live under `/data/notebooks`; Livebook configuration is
`/data/.livebook/livebook_config.v1.ets`. The VM boot disk and container are
disposable. Unsaved sessions are not a backup, and this stack does not create
automatic disk snapshots. Snapshot the data disk before high-risk notebook or
configuration changes.

The version-controlled product dashboard pack is seeded into
`/data/notebooks/Emisar Product Analytics` only when a file is missing. Reboots
and instance replacements therefore preserve operator edits, while Git remains
the recovery source for the canonical dashboards. Adding a new canonical file
seeds it on the next data-preparation run; changing an existing canonical file
does not overwrite the saved copy. The container runs as an unprivileged user
with a read-only root filesystem and an independently pinned image.
Mix and Hex build artifacts live in an executable, bounded
`/home/livebook` tmpfs because `Mix.install/1` runs downloaded build tools;
that dependency cache is intentionally discarded on service restart. Only
notebooks and Livebook configuration persist on `/data`.
`/public/health` and ephemeral widget assets remain available without IAP; every
operator route requires a valid IAP assertion.

The local Cloud SQL Auth Proxy logs in as the dedicated Livebook service account
and Cloud SQL assigns it `emisar_owner`. `DATABASE_URL` and standard `PG*`
variables are available inside notebooks; there is no database password.
Analysis connections must retain the read-only defaults exposed by the runtime:

```elixir
Mix.install([
  {:postgrex, "~> 0.22.0"},
  {:kino, "~> 0.19.0"},
  {:kino_vega_lite, "~> 0.1.13"}
])

Code.require_file("/opt/emisar/product_analytics.exs")
db = EmisarProductAnalytics.connect!()
```

This is an accidental-write guard, not a privilege boundary: the shared Erlang
cookie already makes the workbench fully trusted. Portal attachment is always
explicit. Discover current private node names from a notebook runtime, then
connect only to the node being debugged:

```elixir
{nodes, 0} = System.cmd("/bin/bash", ["/opt/emisar/list-portal-nodes"])
nodes
# => "emisar@10.x.x.x\n..."

Node.connect(:"emisar@10.x.x.x")
```

The Livebook node and its standalone notebook runtimes inherit the exact release
cookie, but no automatic cluster strategy is configured and no distribution
port is opened toward Livebook.

## Secrets

Externally issued credentials are sensitive HCP Terraform workspace variables.
`SECRET_KEY_BASE` and `RELEASE_COOKIE` are separate values with independent
generations. Production database access uses IAM and no DATABASE_URL secret
version exists. The protected empty container remains only to avoid destructive
removal and name reuse; retained access evidence lives in the locked logging
bucket. Adding a secret requires:

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
mig=$(terraform output -raw mig_name)
instances=$(gcloud compute instance-groups managed list-instances "$mig" \
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
delete the local file, and then choose the staged consumer. Enabling Livebook
while `release_cookie_ready=false` writes that exact value for Livebook without
changing the portal template; portal nodes continue deriving the same cookie.
Setting `release_cookie_ready=true` is the later, separately reviewed portal
rollout onto the already-matching secret. Old and new nodes therefore use
identical cookies throughout. Rotate signing and cookie values separately in
later maintenance windows: first prove no migration/long-running job is in
flight; increment only the affected generation; retain the preceding Secret
Manager version; watch ready backends and cluster-failure alerts until every VM
uses the same template; verify a single cluster and user/session behavior. A
failed cookie rotation is recovered by writing the preceding value at a new
generation and rolling forward, never by following `latest` or decrementing a
write-only generation.

## Database IAM and pgAudit

Production database access is IAM-only. The VM identity logs in through the
loopback Cloud SQL Auth Proxy, then assumes the non-login `emisar_owner` role for
migrations and application queries. `scripts/verify-database-iam.sql` proves the
login is not elevated, verifies application and pgAudit ownership, and performs
a reversible DDL probe.

Personal operator access is optional and attributable. Set the sensitive HCP
Terraform workspace variable `database_operator_iam_user` to one lowercase
Google user email. Terraform provisions that identity as a Cloud SQL IAM user,
grants connector login only on the `emisar` instance, grants the project-level
console discovery permissions Cloud SQL Studio requires, and assigns the
non-superuser `emisar_owner` database role. The database principal itself exists
only on `emisar`. Cloud SQL Studio is the browser-based path: select the `emisar`
database and IAM authentication in the instance's Studio view; there is no
database password.

For a local session from an operator workstation, authenticate both gcloud and
Application Default Credentials as that provisioned user, then run the database
helper:

```bash
gcloud auth application-default login
scripts/database                     # Postico 2
scripts/database --psql              # interactive psql
scripts/database --psql -- --command='select current_user;'
```

The helper selects a running portal VM, opens a local SOCKS5 route to it through
IAP and OS Login, and sends the local Cloud SQL Auth Proxy's private-IP traffic
through that route. The Auth Proxy still runs on the workstation under the
operator's ADC identity, so automatic IAM database authentication and pgAudit
attribution remain personal; the portal VM supplies network reachability only.
By default the helper opens Postico 2 and keeps the tunnel alive until Ctrl-C.
Use `--psql` for a terminal client, or `--proxy-only` to print local connection
settings for another client and keep the tunnel open. The database remains
private-only.

The built-in `emisar` principal remains because it owns pgAudit's protected
event triggers. Terraform gives it a generated apply-only password that is
never exposed as plaintext in Terraform state or Secret Manager; Cloud SQL keeps
only what it needs to verify logins. No DATABASE_URL version or VM secret access
remains.

Disaster recovery uses PITR, which preserves the roles, extensions, and
migrations. Run the verifier against the restored database before serving
traffic. The repository does not retain completed one-time database-bootstrap
or project-cleanup mutation scripts.

pgAudit records only `ROLE` and `DDL`. In Cloud Audit Logs these are Data Access
entries with `protoPayload.methodName=cloudsql.instances.query`; parameters are
disabled and normal `SELECT`, `INSERT`, `UPDATE`, and `DELETE` workload traffic
is excluded. The security evidence sink retains those entries for 400 days.

## Terraform authority

The single HCP Terraform workspace owns the complete project-scoped production
stack, including IAM, WIF, secret containers, and workload resources. Its HCP
token and apply identity are production-admin credentials. Organization Policy
administration is intentionally excluded: Google grants that authority above
the project, where it would also cover unrelated projects in the organization.

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
terraform output livebook_url
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
