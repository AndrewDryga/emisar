# infra - emisar on Google Cloud

This directory is the production Terraform configuration for the emisar control
plane. HCP Terraform workspace `Dryga/emisar` owns state and applies. GitHub CD
uploads reviewed configurations and creates saved plans; it never applies them.

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
| Database | Cloud SQL PostgreSQL 18, private IP, TLS required, PITR, automated backups, deletion protection |
| Network | Dedicated VPC, flow logs, Cloud NAT, load-balancer-only application ingress, IAP-only SSH |
| TLS | Certificate Manager DNS authorization, managed certificates, restricted TLS 1.2+ policy |
| Secrets | HCP Terraform sensitive variables feed Secret Manager; VM access is per-secret and read-only |
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

Normal image rollouts create one replacement VM, wait for `/readyz`, and only
then drain an old VM. Old and new application versions overlap, so schema
changes use expand/contract sequencing. Rollback is another reviewed plan that
sets `container_image` to a previously published digest.

## Runtime shape

Cloud-init writes the release environment from Secret Manager, assigns the
instance's internal IP to `NODE_IP`, runs Ecto migrations under their advisory
lock, and starts the container. `Emisar.Cluster.GCE` discovers running peers by
the `cluster_name` label through the Compute API. Erlang distribution is limited
to tagged application instances on TCP 4369 and 9100-9105.

The load balancer uses DB-independent `/healthz` for auto-healing and DB-aware
`/readyz` for traffic eligibility. Backend HTTP accepts only Google proxy and
health-check source ranges. Public traffic terminates TLS at the load balancer.

## Secrets

Externally issued credentials are sensitive HCP Terraform workspace variables.
Machine credentials such as the database password and initial
`SECRET_KEY_BASE` are generated in Terraform and stored as Secret Manager
versions. Adding a secret requires:

1. A sensitive variable in `variables.tf` when the value is externally issued.
2. An `app_secrets` entry in `secrets.tf`.
3. An `optional_secret_values` entry when the application can boot without it.
4. The minimum per-secret IAM binding for the instance service account.

Never place values in git, defaults, command history, or `.tfvars` files.

## DNS and DNSSEC

`dns.tf` is the complete authoritative zone. Add durable records there before
expecting them to resolve publicly. Cloud DNS supplies the apex NS and SOA
records itself.

DNSSEC signing is enabled in Cloud DNS. The registrar DS is deliberately a
manual final step because publishing a DS while recursive resolvers still use a
different delegation makes the domain fail validation. Before publishing it:

```sh
dig +trace emisar.dev NS
dig @1.1.1.1 emisar.dev NS +short
dig @8.8.8.8 emisar.dev NS +short
dig @9.9.9.9 emisar.dev NS +short
terraform output -raw dnssec_ds_record
```

All traces and public resolvers must return the four Cloud DNS nameservers. Add
the exact DS output at the registrar, then verify:

```sh
dig +dnssec emisar.dev A
dig @1.1.1.1 +dnssec emisar.dev A
```

The response must contain the `ad` flag. A DNSSEC key rotation follows the same
parent/child ordering discipline; never replace the parent DS speculatively.

## Pack registry

`registry.emisar.dev` terminates at the same load balancer and routes directly
to the public-read GCS backend bucket. Publisher credentials are create-only;
published objects are versioned. Customer-facing URLs always use the registry
domain, while the backing URL is for administration.

```sh
curl -fsS https://registry.emisar.dev/v1/catalog.json | jq '.schema_version'
gcloud storage ls -a gs://$(terraform output -raw pack_registry_bucket)/v1/catalog.json
```

Pack publication has a separate GitHub environment approval and is serialized
so an active publication cannot be canceled halfway through.

## Operations

Use [the operations runbook](../docs/operations.md) for incident commands,
backups, restore drills, and production access. Useful outputs:

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
```

These checks are credential-free. A live plan or apply is a separate,
credentials-gated production action performed through HCP Terraform.
