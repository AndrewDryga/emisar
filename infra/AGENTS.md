# infra — agent manual

Terraform for running emisar on **Google Cloud** to a **SOC 2 Type II** posture
(compute + Cloud SQL + LB + DNS + secrets + monitoring), adapted from
`../onlytty/infra`. **LIVE — this is production.** Cloud DNS is authoritative
and the registrar DS completes a validating DNSSEC chain. Read `README.md` for
the shape and `.agent/COMPLIANCE.md` (internal, git-ignored) for the control
mapping; this file is the rules.

## Gate

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint
```

All three green before commit; CI (the `infra` job in `.github/workflows/ci.yml`) runs the same
with no cloud credentials. The app-side clustering (`Emisar.Cluster.GCE` +
`…/gce/client.ex`, `application.ex`, `runtime.exs`, `rel/env.sh.eex`, `mix.exs`)
lives in `portal/` and is gated by the portal loop (`mix compile --warnings-as-errors
&& mix format --check-formatted && mix credo && mix test`). A live `plan`/`apply` is
the separate, creds-gated deploy step.

## Non-negotiable rules

1. **Private by default — never add a public surface.** The database is private-IP
   only, compute has no external IP, SSH is IAP + OS Login only. Never add
   `ipv4_enabled = true`, an `access_config` (external IP), or a `0.0.0.0/0` firewall
   source. Egress is Cloud NAT; ingress is the LB + IAP ranges only.
2. **Least-privilege IAM — no Owner/Editor.** The VM SA gets exactly the roles in
   `iam.tf` and per-secret `secretAccessor`. Add the minimum role for a new need;
   never a broad `roles/editor`.
3. **Stateful resources are destroy-guarded.** The DNS zone and Cloud SQL carry
   `prevent_destroy` + (DB) `deletion_protection`. Removing either is a deliberate,
   reviewed act — never to make a `terraform destroy` "work".
4. **Secrets discipline.** Secret custody is Terraform Cloud BY DECISION:
   externally-issued credentials enter as SENSITIVE workspace variables
   (`variables.tf`), machine secrets such as SECRET_KEY_BASE are generated
   ephemerally in-config, and write-only provider arguments keep payloads out of
   new state snapshots while delivering them to Secret Manager or Cloud SQL.
   Never put a secret value in git, a `.tf` default, or a tfvars file — the TFC
   workspace (org `Dryga` / project `emisar`) is the only entry point, and access
   to it is production access. A new secret = a sensitive variable + an
   `app_secrets` entry + (if optional) an `optional_secret_values` entry.
5. **The zone is authoritative and DNSSEC-validating.** Every durable public
   record belongs in `dns.tf`. Keep the registrar DS aligned with
   `dnssec_ds_record`; a future key rotation must activate the child key before
   adding its parent DS and retain the old DS until resolver convergence.
6. **Clustering is flag-gated.** `Emisar.Cluster.GCE` activates only when
   `EMISAR_CLUSTER_PROJECT` is set. Local and single-node releases leave the
   topology empty.
7. **DMARC / MTA-STS ramp, never jump.** `none → quarantine → reject` and
   `testing → enforce`, gated on clean reports.
8. **Migrations run on boot under Ecto's advisory lock** (the release server entrypoint), so concurrent
   instances are safe. Committed portal migrations stay frozen (portal AGENTS.md §8).
9. **Portal rollouts preserve serving capacity.** Reserve exactly the steady-state
   fleet with automatic consumption and let the rollout surge use on-demand
   capacity; a stockout may delay deployment but must not remove a serving VM.
   Auto-healing uses DB-independent `/healthz`; the load balancer uses DB-aware
   `/readyz`. Never collapse the probes or return to delete-before-create updates.
   A regional MIG's fixed surge must be at least its zone count; keep
   `max_surge_fixed = length(var.zones)` and `max_unavailable_fixed = 0`. Old and
   new app versions overlap during a rollout, so schema changes must be compatible
   with both until a later release contracts the old shape. Readiness-contract
   replacements use generation-named health checks and backend services with
   `create_before_destroy`, so the URL map switches between complete serving paths
   only after `backendServices.getHealth` reports every expected VM healthy.
   Retain the previous backend for the documented edge-propagation hold after the
   URL-map switch; a pre-switch sleep does not protect edge proxies that still
   resolve the previous backend reference. Never edit the only live backend's
   readiness contract in place, or replace the health barrier with only a fixed
   sleep. The regional MIG is named `emisar`;
   changing its zone set requires an explicitly staged migration because two
   same-named MIGs cannot overlap. Portal port 4000 is a committed fleet contract,
   not a workspace variable; changing it requires a separately staged successor
   fleet and backend rather than an ordinary rollout.
10. **The pack registry is one bucket.** Keep immutable packs, catalog snapshots,
   schemas, and the two live pointers in the existing public registry bucket.
   Enforce create-only immutable prefixes and pointer-only create/delete needed
   for replacement through conditional IAM; do not add a history bucket, mirror
   publisher, or route cutover.
11. **Infrastructure sidecars stay out of the portal image.** Run the Cloud SQL
   Auth Proxy and future host-level helpers as separately pinned, cloud-init-managed
   containers. The portal Dockerfile contains the application release only; never
   bake a VM sidecar binary into it or couple application rollback to that binary.
12. **Validate notebook runtimes in their real writable paths.** Livebook's
   `Mix.install/1` executes downloaded build tools from `HOME`, so its bounded,
   ephemeral home tmpfs must opt into `exec` while retaining `nosuid` and `nodev`.
   Behavior-probe the rendered mount with the pinned runtime image; a test-only
   cache or environment override is not proof that a real notebook session works.

## House style

Match `../onlytty/infra`: comments explain **why** (the abuse case, the ordering
hazard, the SOC 2 control), never restate the resource. One concern per file
(`network`/`compute`/`db`/`lb`/`secrets`/`iam`/`monitoring`/`dns`). Values that vary
or carry a security decision are variables with a description that IS the
documentation. **This is a PUBLIC repo — committed defaults are a generic
reference configuration, never the production deployment's actual shape.**
Environment sizing (machine type, node count, DB tier/availability/disk) and
contact addresses are Terraform Cloud workspace variables; never commit values,
prose, or comments that reveal the deployment's scale, spend posture, or a
personal email. When you change what the stack enforces, keep `.agent/COMPLIANCE.md`
(the internal control mapping — git-ignored BY DECISION: candid gap notes are
for us, not the public repo) honest and current in the same change.

Keep repeatable validation, verification, and recovery tooling. Delete one-time
bootstrap, migration, and live-cleanup executables once their operation is
complete; git history retains the evidence without leaving a stale mutation path.

Operator-visible names are product copy. Private alerting objects use Title Case
and an `Emisar:` prefix so they group clearly in vendor consoles. Monitor names
must also read naturally when spoken by an automated call, so omit punctuation
there (`Emisar Control Plane`). Public status-page resources use customer-facing
product terms (`Control Plane`, `Action Pack Registry`), never CLI commands,
Terraform identifiers, or lowercase implementation labels. Put related monitors
in a named group instead of leaving them ungrouped. Stable top-level workload
resources use the product name, not topology hashes or implementation suffixes.
