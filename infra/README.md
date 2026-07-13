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

Changing an externally issued secret's workspace value alone is intentionally
not a rotation: write-only values cannot produce a useful Terraform diff at a
stable version. Rotate one in a reviewed maintenance commit by changing the
credential and incrementing the optional resource's `secret_data_wo_version` in
`secrets.tf`. That resource shares one version number, so the
maintenance apply writes fresh versions for every populated optional secret;
inspect that exact set and the resulting instance-template rollout.
Machine-generated database and `SECRET_KEY_BASE` rotation is separate
maintenance and is not part of ordinary deployment.

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

The DS must match `terraform output -raw dnssec_ds_record`; both resolver
responses must contain the `ad` flag. A future DNSSEC key rotation follows the
same parent/child ordering discipline: publish the replacement DS only after the
new child key is active, and remove the old DS only after resolver convergence.

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
```

These checks are credential-free. A live plan or apply is a separate,
credentials-gated production action performed through HCP Terraform.
