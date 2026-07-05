# infra — agent manual

Terraform for running emisar on **Google Cloud** to a **SOC 2 Type II** posture
(compute + Cloud SQL + LB + DNS + secrets + monitoring), adapted from
`../onlytty/infra`. **Prepared, not applied** — emisar serves from Fly today;
applying this is a deliberate Fly→GCP migration. Read `README.md` for the shape and
`COMPLIANCE.md` for the control mapping; this file is the rules.

## Gate

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
tflint --init && tflint
```

All three green before commit; CI (`.github/workflows/infra-ci.yml`) runs the same
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
4. **Secrets discipline.** Externally-issued secrets (SECRET_KEY_BASE, Paddle/Postmark
   tokens) are Secret Manager containers here, VALUES added out-of-band — never in
   state or git. The ONE exception is the Terraform-generated DB password (in state,
   mitigated by the locked-down bucket); don't add more secrets to state.
5. **The zone is authoritative — replicate before cutover.** Only records in `dns.tf`
   resolve once delegated. **DNSSEC DS is published LAST**, after NS delegation
   resolves — a DS ahead of working delegation takes the domain offline.
6. **Clustering is flag-gated — never break the Fly path.** `Emisar.Cluster.GCE`
   activates only when `EMISAR_CLUSTER_PROJECT` is set; Fly keeps using `dns_cluster`.
   Any change here must leave the Fly deployment's clustering untouched.
7. **DMARC / MTA-STS ramp, never jump.** `none → quarantine → reject` and
   `testing → enforce`, gated on clean reports.
8. **Migrations run on boot under Ecto's advisory lock** (cloud-init), so concurrent
   instances are safe. Committed portal migrations stay frozen (portal AGENTS.md §8).

## House style

Match `../onlytty/infra`: comments explain **why** (the abuse case, the ordering
hazard, the SOC 2 control), never restate the resource. One concern per file
(`network`/`compute`/`db`/`lb`/`secrets`/`iam`/`monitoring`/`dns`). Values that vary
or carry a security decision are variables with a description that IS the
documentation; emisar's production values are the defaults. When you change what the
stack enforces, keep `COMPLIANCE.md` honest and current in the same change.
