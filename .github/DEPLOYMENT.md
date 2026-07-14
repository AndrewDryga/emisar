# CI/CD production setup

Workflow files are public. Store only secret **names**, never values, in the
repository. Pull requests run `.github/workflows/ci.yml`. After a push to
`main`, `.github/workflows/cd.yml` calls that reusable CI workflow from the same
commit, then performs delivery:

1. `Required - CI` completes for the exact commit.
2. The already-smoke-tested and vulnerability-scanned portal image is published
   by digest and attested with its CI-produced SBOM. No second image build occurs.
3. The same commit's `infra/` directory is uploaded as a provisional HCP
   Terraform configuration version and planned with the immutable image digest.
4. CD stops. A reviewer inspects the linked plan and uses HCP Terraform's
   **Confirm & Apply** button. GitHub never calls the apply API. Before applying,
   verify the run's commit in its `main <sha>` message is the commit intended
   for deployment. CD creates saved plans: they can plan concurrently without
   holding the workspace lock, never auto-apply, and HCP discards them if an
   earlier apply changes state before confirmation.

When one commit changes packs and the portal, production planning waits for the
reviewed pack publication. Rejecting or canceling that publication halts the
plan. After the pack is published, rerun the newer commit's failed
`deployment-plan` job; its canonical-catalog check must pass before HCP receives
a configuration.

## GitHub environments

Configure these environments with deployment branches restricted to `main`:

| Environment | Approval | Secret | Required scope |
|---|---|---|---|
| `portal-production-plan` | Required reviewer + protected `main` | `TFC_PLAN_TOKEN` | Uploads the reviewed configuration and creates the saved production plan. Workspace auto-apply stays disabled and apply remains manual. |
| `pack-registry-approval` | Required reviewer + protected `main` | None | Cancellable approval-only gate. A newer selected pack release supersedes an older waiting approval. |
| `pack-registry-production` | Required reviewer + protected `main` | None | Non-cancellable serialized publication through short-lived, environment-bound GCP WIF credentials. A second approval is intentional: a rerun of an old publication job cannot mint fresh credentials from an approval granted to the original run. |
| `public-releases` | Required reviewer + `runner-v*` and `mcp-v*` policies | None | Signed runner and MCP bridge builds. A failed tag run is recovered by rerunning that same run, preserving its original tag and source SHA. |
| `mcp-registry-publication` | Required reviewer + `v*` and `main` recovery policies | `MCP_PRIVATE_KEY` | Publishes the hosted server listing. `main` is allowed only so the current hardened publisher can recover an existing product release. |

Run `infra/scripts/verify-pack-environment.sh` and retain the green output before
enabling pack publication or treating an old job rerun as safe.

Keep HCP Terraform workspace auto-apply disabled. Never store an HCP token as a
repository secret. The token remains organization-owner-equivalent because Free
has no team RBAC; the workflow never calls the apply API, and the
reviewer-protected environment exposes the token only to protected `main`.
Treat approving this GitHub job as production access, then review and apply the
saved plan in HCP Terraform. Do not change CD back to standard plan-and-apply
runs: an unconfirmed standard plan holds the workspace lock indefinitely.

HCP dynamic GCP credentials use separate identities. Plans impersonate
`terraform-plan@emisar.iam.gserviceaccount.com`, which has read-only review
roles and cannot access secret payloads or mutate the project. Applies
impersonate `terraform@emisar.iam.gserviceaccount.com` through an
apply-phase-only WIF binding and service-specific administrative roles. The
provider condition is pinned to workspace `Dryga/emisar/emisar` and the
`plan`/`apply` phases. Never restore the pool-wide impersonation binding or
`roles/editor`. The single workspace owns the complete production stack, so
its HCP token and apply identity are production-admin credentials.

## Repository rules

Protect `main` with pull requests and the single required check `Required - CI`.
Require signed commits, linear history, resolved conversations, and include
administrators. Force pushes and branch deletion stay disabled. This personal
repository currently has one collaborator, so the PR approval count is zero;
raise it to one and require approval of the latest push when a second maintainer
is added. Do not require area-specific jobs: unchanged areas intentionally
report `skipped`, while `Required - CI` is stable and always reports a
conclusion.

## Release tags

Runner, MCP bridge, and product releases accept only exact SemVer signed
annotated tags targeting current `main`. Their workflows verify GitHub's
signature result and the tag's commit before building or publishing. A runner
or MCP bridge rerun keeps the original tag and source SHA, so recovery after
`main` advances requires rerunning the failed Actions run rather than creating
another trigger. Product `v*` tags publish only the hosted
MCP Registry listing; infrastructure deploys only from reviewed `main` plans.

| Workflow | Tag | Publishes |
|---|---|---|
| `Release - Runner` | `runner-vX.Y.Z` | On-host runner binaries, checksums, pack assets, and provenance. |
| `Release - MCP Bridge` | `mcp-vX.Y.Z` | Local stdio-to-HTTP bridge binaries, checksums, and provenance. |
| `Portal - Publish MCP Registry Listing` | `vX.Y.Z` | The hosted server's signed `server.json` listing; no binary artifact. |

## Apply and verify a production plan

1. Open the saved plan linked from the successful `deployment-plan` job.
2. Verify its run message names the intended `main <commit>` and inspect every
   resource action, output, and immutable portal image digest.
3. Select **Confirm & Apply** in HCP Terraform. GitHub never applies the plan.
4. Wait for the managed instance group to replace instances with zero
   unavailable capacity. A replacement must pass `/readyz` before an old
   instance drains.
5. Verify liveness, readiness, sign-in, runner reconnections, registry output,
   the expected two running MIG instances across distinct zones, and the BEAM
   cluster view. Any `cluster discovery failed` or `cluster: can't connect` log
   now pages and blocks calling the rollout complete.

```sh
curl -fsS https://emisar.dev/healthz
curl -fsS https://emisar.dev/readyz
curl -fsS https://registry.emisar.dev/v1/catalog.json | jq '.schema_version'
```

## Runtime contract

Terraform renders production values into Secret Manager and the instance's
root-readable environment file. `portal/config/runtime.exs` is the source of
truth for required combinations. Do not duplicate secret values in GitHub
Actions, Terraform defaults, or local `.tfvars` files.

The Docker build context is the repository root because the portal embeds the
installer and pack catalog:

```sh
docker build -f portal/Dockerfile -t emisar/portal:local .
```

The release contains `bin/migrate`, `bin/server`, the remote console, compiled
assets, and runtime diagnostics. Cloud-init pulls the reviewed digest, runs
`/app/bin/migrate`, and starts the container under `emisar.service`. Ecto's
advisory migration lock serializes concurrent instance boots.

## Schema changes and rollback

Committed migrations are immutable. Rolling deployments overlap old and new
application versions, so schema work uses expand/contract sequencing: add a
compatible shape, deploy code that tolerates both versions and backfill, then
remove the old shape in a later release after the earlier version has drained.

Rollback is another reviewed saved plan setting `container_image` to a
previously published `ghcr.io/andrewdryga/emisar@sha256:...` digest. An
application rollback does not reverse database changes; expand/contract
compatibility keeps the prior image runnable. Data recovery restores Cloud SQL
to a new instance or point in time and promotes it only after isolated
verification.

IAM database mode adds one transition rule: images published before passwordless
database runtime configuration was added are not image-only rollback candidates.
While the password rollback path is retained, reverting to one of those images
must set `database_auth_mode=password` in the same saved plan. The separately
pinned Cloud SQL Auth Proxy container is infrastructure and does not change with
an application rollback.

## Health and observability

- `/healthz` requires one successful database check after BEAM startup, then
  becomes database-independent liveness and drives auto-healing.
- `/readyz` checks database readiness and controls load-balancer eligibility.
- `/metrics` on `METRICS_PORT` (default 9091) is private.
- `/admin/live` is the admin-gated Phoenix LiveDashboard.
- Production logs use structured Google Cloud JSON with secret-shaped metadata
  keys redacted.
- Sentry activates only when `SENTRY_DSN` is configured.

The GCP load balancer terminates TLS, preserves `X-Forwarded-Proto`, and appends
the client and forwarding-rule addresses to `X-Forwarded-For`. Backend ingress
is restricted to Google proxy and health-check ranges.
