# CI/CD production setup

Workflow files are public. Store only secret **names**, never values, in the
repository. Production delivery runs from `.github/workflows/ci.yml` after a
push to `main`:

1. `Required - CI` completes for the exact commit.
2. The already-smoke-tested portal image is scanned, published by digest, and
   attested. No second image build occurs.
3. The same commit's `infra/` directory is uploaded as an HCP Terraform
   configuration version and planned with the immutable image digest.
4. CI stops. A reviewer inspects the linked plan and uses HCP Terraform's
   **Confirm & Apply** button. GitHub never calls the apply API. Before applying,
   verify the run's commit in its `main <sha>` message is still current `main`;
   discard superseded plans.

## GitHub environments

Configure these environments with deployment branches restricted to `main`:

| Environment | Approval | Secret | Required scope |
|---|---|---|---|
| `production-plan` | Protected `main`, no reviewer | `TFC_PLAN_TOKEN` | Dedicated `Dryga` owners-team automation token used only to upload configuration and create the plan. HCP Free cannot make it plan-only; HCP workspace auto-apply stays disabled and apply remains manual. |
| `pack-registry` | Required reviewer | None | Main-branch pack publishing through short-lived GCP WIF credentials. |
| `release` | Required reviewer | `MCP_PRIVATE_KEY` | Signed tag releases. The MCP Registry listing uses the HTTP signing key; binary releases use keyless Sigstore. |

Keep HCP Terraform workspace auto-apply disabled. Never store an HCP token as a
repository secret. The token remains organization-owner-equivalent because Free
has no team RBAC; the workflow never calls the apply API, and the environment
exposes the token only to protected `main`. Review and apply the saved plan in
HCP Terraform.

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
annotated tags. Their workflows verify GitHub's signature result and the tag's
commit before building or publishing. Product `v*` tags publish only the hosted
MCP Registry listing; infrastructure deploys only from reviewed `main` plans.

| Workflow | Tag | Publishes |
|---|---|---|
| `Release - Runner` | `runner-vX.Y.Z` | On-host runner binaries, checksums, pack assets, and provenance. |
| `Release - MCP Bridge` | `mcp-vX.Y.Z` | Local stdio-to-HTTP bridge binaries, checksums, and provenance. |
| `Release - MCP Registry Listing` | `vX.Y.Z` | The hosted server's signed `server.json` listing; no binary artifact. |
