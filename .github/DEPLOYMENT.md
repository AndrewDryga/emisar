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

## GitHub environments

Configure these environments with deployment branches restricted to `main`:

| Environment | Approval | Secret | Required scope |
|---|---|---|---|
| `production-plan` | Required reviewer + protected `main` | `TFC_PLAN_TOKEN` | Dedicated `Dryga` owners-team automation token used only to upload configuration and create the plan. HCP Free cannot make it plan-only; the reviewer gate protects this powerful token, workspace auto-apply stays disabled, and apply remains manual. |
| `pack-registry` | Required reviewer | None | Cancellable approval-only gate. A newer selected pack release supersedes an older waiting approval. |
| `pack-registry-publish` | Protected `main`, no reviewer | None | Non-cancellable serialized publication through short-lived GCP WIF credentials; starts only after `pack-registry` approval succeeds. |
| `release` | Required reviewer | `MCP_PRIVATE_KEY` | Signed tag releases. The MCP Registry listing uses the HTTP signing key; binary releases use keyless Sigstore. |

Keep HCP Terraform workspace auto-apply disabled. Never store an HCP token as a
repository secret. The token remains organization-owner-equivalent because Free
has no team RBAC; the workflow never calls the apply API, and the
reviewer-protected environment exposes the token only to protected `main`.
Treat approving this GitHub job as production access, then review and apply the
saved plan in HCP Terraform. Do not change CD back to standard plan-and-apply
runs: an unconfirmed standard plan holds the workspace lock indefinitely.

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
signature result and the tag's commit before building or publishing. Product
`v*` tags publish only the hosted
MCP Registry listing; infrastructure deploys only from reviewed `main` plans.

| Workflow | Tag | Publishes |
|---|---|---|
| `Release - Runner` | `runner-vX.Y.Z` | On-host runner binaries, checksums, pack assets, and provenance. |
| `Release - MCP Bridge` | `mcp-vX.Y.Z` | Local stdio-to-HTTP bridge binaries, checksums, and provenance. |
| `Portal - Publish MCP Registry Listing` | `vX.Y.Z` | The hosted server's signed `server.json` listing; no binary artifact. |
