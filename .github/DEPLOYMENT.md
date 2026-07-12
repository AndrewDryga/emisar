# CI/CD production setup

Workflow files are public. Store only secret **names**, never values, in the
repository. Production delivery runs from `.github/workflows/ci.yml` after a
push to `main`:

1. `CI Gate` completes for the exact commit.
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
| `production-plan` | Required reviewer | `TFC_PLAN_TOKEN` | Dedicated `Dryga` owners-team automation token used only to upload configuration and create the plan. HCP Free cannot make it plan-only; the environment gate and manual HCP apply are compensating controls. |
| `release` | Required reviewer | `MCP_PRIVATE_KEY` | MCP Registry HTTP signing key. GCP pack publishing uses short-lived OIDC and has no stored cloud credential. |

Keep HCP Terraform workspace auto-apply disabled. Never store an HCP token as a
repository secret. The token remains organization-owner-equivalent because Free
has no team RBAC; CI cannot apply runs and the token is exposed only after a
reviewer approves the protected `production-plan` environment.

## Repository rules

Protect `main` with pull requests and the single required check `CI Gate`.
Require signed commits, linear history, resolved conversations, and include
administrators. Force pushes and branch deletion stay disabled. This personal
repository currently has one collaborator, so the PR approval count is zero;
raise it to one and require approval of the latest push when a second maintainer
is added. Do not require area-specific jobs: unchanged areas intentionally
report `skipped`, while `CI Gate` is stable and always reports a conclusion.

These rules are already active. The change introducing `CI Gate` must therefore
land through a pull request; its `pull_request` run provides the required check.

## Release tags

Runner, MCP bridge, and product releases accept only exact SemVer signed
annotated tags. Their workflows verify GitHub's signature result and the tag's
commit before building or publishing. Product `v*` tags publish only the hosted
MCP Registry listing; infrastructure deploys only from reviewed `main` plans.
