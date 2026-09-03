# CI/CD production setup

Workflow files are public. Store only secret **names**, never values, in the
repository. Pull requests run `.github/workflows/ci.yml`. After a push to
`main`, `.github/workflows/cd.yml` calls that reusable CI workflow from the same
commit, then performs delivery:

1. `Required - CI` completes for the exact commit.
2. Every successful `main` push builds, smoke-tests, vulnerability-scans, and
   publishes a portal image for that exact commit. CD publishes it by digest and
   attests it with its CI-produced SBOM. No second image is built for the private
   admin runner; COS installs its pinned runner release.
3. The same commit's `infra/` directory is uploaded as a provisional HCP
   Terraform configuration version and planned with that commit's immutable
   image digest. Production planning fails closed if publication does not finish.
4. CD stops. A reviewer inspects the linked plan and uses HCP Terraform's
   **Confirm & Apply** button. GitHub never calls the apply API. Before applying,
   verify the run's commit in its `main <sha>` message is the commit intended
   for deployment. CD creates saved plans: they can plan concurrently without
   holding the workspace lock, never auto-apply, and HCP discards them if an
   earlier apply changes state before confirmation.

`main` is the desired portal state. A failed or rejected plan never makes a
later run silently substitute the older applied image: the later commit receives
its own tested image and saved plan. Revert an application change from `main`
before applying later infrastructure work when that application state should not
ship.

When one commit changes packs and the portal, production planning waits for the
reviewed pack publication. Rejecting or canceling that publication halts the
plan. After the pack is published, rerun the newer commit's failed
`deployment-plan` job; its canonical-catalog check must pass before HCP receives
a configuration.

## GitHub environments

Configure these environments with the ref policies shown below:

| Environment | Approval | Secret | Required scope |
|---|---|---|---|
| `portal-production-plan` | Protected `main` only (no reviewer) | `TFC_PLAN_TOKEN` | Uploads the reviewed configuration and creates the saved production plan. Workspace auto-apply stays disabled and apply remains manual — the HCP Confirm & Apply is the human gate, so a second GitHub approval here would be redundant. |
| `pack-registry-approval` | Exactly one required reviewer + protected `main` | None | Cancellable approval-only gate. This is the single human release decision for a pack publication; a newer selected pack release supersedes an older waiting approval. |
| `pack-registry-production` | Protected `main` only (no reviewer) | None | Non-cancellable serialized publication through short-lived, environment-bound GCP WIF credentials. The release decision lives on `pack-registry-approval`; a bare rerun of an old publication job is refused by the workflow's superseded-release check when a newer release has since published. |
| `public-releases` | Independent required reviewer; prevent self-review; block admin bypass; `runner-v*` and `mcp-v*` tag policies | None | Signed runner and MCP bridge builds plus GCS publication through short-lived WIF credentials bound to the called workflow's exact path and SHA. The tag creator and environment reviewer must be different people. After source verification passes, recover a downstream failure with **Re-run failed jobs**; source verification always requires current main and a full rerun after main advances fails closed. |
| `mcp-registry-publication` | Exact `main` branch policy; block admin bypass; no reviewer | `MCP_PRIVATE_KEY` | Publishes the hosted server listing. Only the scheduled or manually dispatched workflow on protected `main` can receive the key. It independently verifies the selected signed release tag, its green Required - CI, and the live publisher-key proof before the secret is used. |

`pack-registry-approval` is the pack publication decision. `public-releases`
deliberately adds a second person after the signed component tag: its reviewer
must have repository read access, must not be the tag creator, and cannot
bypass the wait as an administrator. Do not cut another runner or MCP release
until this independent reviewer exists. HCP's Confirm & Apply remains the
portal deployment decision.

The pack publication path, hosted MCP Registry publication job, and component
release verifier check the named GitHub environment before using release
authority. Contributors can run the same check as `./run check
release-environment AndrewDryga/emisar <environment>`. Retain the green output
when qualifying a release; it compares the reviewer and ref settings, plus
no-admin-bypass where that named environment requires it.

Keep HCP Terraform workspace auto-apply disabled. Never store an HCP token as a
repository secret. The token remains organization-owner-equivalent because Free
has no team RBAC; the workflow never calls the apply API, and the environment's
branch policy exposes the token only to protected `main`.
Treat HCP's Confirm & Apply as the production gate: review the saved plan
there before applying. Do not change CD back to standard plan-and-apply
runs: an unconfirmed standard plan holds the workspace lock indefinitely.

HCP dynamic GCP credentials use separate identities. Plans impersonate
`terraform-plan@emisar.iam.gserviceaccount.com`, which has read-only review
roles and cannot access secret payloads or mutate the project. Applies
impersonate `terraform@emisar.iam.gserviceaccount.com` through an
apply-phase-only WIF binding and service-specific administrative roles. The
workspace records its required `roles/logging.configWriter` binding in
`infra/iam.tf`; bootstrap it once before the first apply that creates Logging
configuration. The provider condition is pinned to workspace
`Dryga/emisar/emisar` and the `plan`/`apply` phases. Never restore the pool-wide
impersonation binding or `roles/editor`. The single workspace owns the complete
production stack, so its HCP token and apply identity are production-admin
credentials.

## Repository rules

Protect `main` with pull requests and the single required check `Required - CI`.
Require signed commits, linear history, resolved conversations, and include
administrators. Force pushes and branch deletion stay disabled. Require one
approval of the latest push from the second maintainer used for independent
release review. Do not require area-specific jobs: unchanged areas
intentionally report `skipped`, while `Required - CI` is stable and always
reports a conclusion.

## Release tags

Runner, MCP bridge, and product releases accept only exact SemVer signed
annotated tags targeting current `main`. Their workflows verify GitHub's
signature result and the tag's commit before building or publishing. The thin
tag workflows call component-specific, no-input reusable workflows at one exact
commit SHA; the release WIF provider and service-account binding admit only
those called workflow identities. Rotate the pin only by first landing the new
called workflows, then updating both callers and Terraform in one reviewed
plan. Inside each reusable workflow, GitHub's `$/` self-repository reference
loads the shared verifier from that pinned commit even though the workspace
contains the release tag; the verifier also runs the environment-policy check
from its own trusted repository copy. Once verification succeeds, a runner or
MCP bridge recovery after `main`
advances uses **Re-run failed jobs**, preserving the successful verifier and
the original tag/source SHA; a full rerun deliberately fails instead of
weakening the current-main check. Product `v*` tags identify immutable source
for the hosted MCP Registry listing, but do not trigger its key-bearing workflow.
That workflow runs from protected `main` on its schedule or by manual dispatch
and verifies the selected tag before publication. Infrastructure deploys only
from reviewed `main` plans.

Use two release-tag rulesets. The creation-only ruleset matches `runner-v*` and
`mcp-v*` and grants bypass only to the named release tagger (user or dedicated
App), never the administrator role. The immutable-tag ruleset denies updates
and deletion with no bypass actors. Keeping these separate lets the release
tagger create a new tag without gaining authority to move or delete one.

The exact-workflow WIF and environment controls protect GCS publication and the
Sigstore identity. They do not remove a workflow's ability to request the
repository's native `GITHUB_TOKEN` with `contents: write` or `packages: write`.
GitHub Releases and GHCR therefore remain secondary mirrors: trust a binary or
image only after its provenance verifies against the exact reusable workflow
path and digest. Fully independent GitHub publication requires a separate
repository and publisher credential unavailable to workflows in this source
repository.

| Workflow | Tag | Publishes |
|---|---|---|
| `Release - Runner` | `runner-vX.Y.Z` | On-host runner binaries, checksums, and manifests under `emisar.dev/releases`, the identical files on GitHub Releases as a secondary mirror, and GitHub provenance. |
| `Release - MCP Bridge` | `mcp-vX.Y.Z` | Local stdio-to-HTTP bridge binaries, checksums, and manifests under `emisar.dev/releases`, the identical files on GitHub Releases as a secondary mirror, and GitHub provenance. |
| `Portal - Publish MCP Registry Listing` | `vX.Y.Z` source selected by a manual or scheduled `main` workflow | The hosted server's signed `server.json` listing; no binary artifact. Reconciles against the LIVE deploy: it publishes a version only once `/healthz` on emisar.dev reports it (applies are founder-gated, so the tag can precede its deploy by days — the listing follows the apply, not the tag). |

## Apply and verify a production plan

1. Open the saved plan linked from the successful `deployment-plan` job.
2. Verify its run message names the intended `main <commit>`, the image revision
   matches that commit, and inspect every resource action, output, and immutable
   portal image digest.
3. Select **Confirm & Apply** in HCP Terraform. GitHub never applies the plan.
4. Wait for the managed instance group to replace instances with zero
   unavailable capacity. A replacement must pass `/healthz` after reaching the
   database once before the MIG removes an old instance; the load balancer
   independently requires `/readyz` before sending traffic.
5. Verify liveness, readiness, sign-in, runner reconnections, registry output,
   the expected MIG instance count across distinct zones, and the BEAM
   cluster view. Any `cluster discovery failed` or `cluster: can't connect` log
   now pages and blocks calling the rollout complete.

The public health endpoints report only status and product `version` — the exact
deployed Git revision is bound by the reviewed image digest at apply time (step 2)
and is deliberately not disclosed over the public probes (the repository is public).

```sh
expected_version="$(cat portal/VERSION)"
curl -fsS https://emisar.dev/healthz \
  | jq -e --arg version "$expected_version" '.status == "ok" and .version == $version'
curl -fsS https://emisar.dev/readyz \
  | jq -e --arg version "$expected_version" '.status == "ok" and .version == $version'
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
assets, and runtime diagnostics. Cloud-init pulls the reviewed digest and starts
the container under `emisar.service`; the image's `bin/server` entry point runs
`bin/migrate` before booting the endpoint, so a failed migration aborts the
container and the previous version keeps serving. There is no separate migrate
step and no separate log — `emisar.service` is `Restart=always RestartSec=5`, so
a migration that keeps failing shows up as the unit restarting every five
seconds and retrying it. Ecto's advisory migration lock serializes concurrent
instance boots.

## Schema changes and rollback

Committed migrations are immutable. Rolling deployments overlap old and new
application versions, so schema work uses expand/contract sequencing: add a
compatible shape, deploy code that tolerates both versions and backfill, then
remove the old shape in a later release after the earlier version no longer runs.

Rollback is another reviewed saved plan setting `container_image` to a
previously published `ghcr.io/andrewdryga/emisar@sha256:...` digest. An
application rollback does not reverse database changes; expand/contract
compatibility keeps the prior image runnable. Data recovery restores Cloud SQL
to a new instance or point in time and promotes it only after isolated
verification.

Images published before IAM database runtime was added are not rollback
candidates: production has no database password or DATABASE_URL secret. The
separately pinned Cloud SQL Auth Proxy container is infrastructure and does not
change with an application rollback.

## Health and observability

- `/healthz` requires one successful database check after BEAM startup, then
  becomes database-independent liveness and drives auto-healing.
- `/readyz` checks database readiness and controls load-balancer eligibility.
- Both probes report the product `version`; post-apply verification compares it
  with `portal/VERSION`. The immutable source `revision` is bound by the reviewed
  image digest at apply time and is not disclosed over these public probes (the
  repository is public, so the exact deployed Git SHA would map production to any
  known advisory in that tree).
- `/metrics` on `METRICS_PORT` (default 9091) is private.
- `/admin/live` is the admin-gated Phoenix LiveDashboard.
- Production logs use structured Google Cloud JSON with secret-shaped metadata
  keys redacted.
- Sentry activates only when `SENTRY_DSN` is configured.

The GCP load balancer terminates TLS, preserves `X-Forwarded-Proto`, and appends
the client and forwarding-rule addresses to `X-Forwarded-For`. Backend ingress
is restricted to Google proxy and health-check ranges.
