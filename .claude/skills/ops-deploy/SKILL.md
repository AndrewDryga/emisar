---
name: ops-deploy
description: Pre-deploy checklist and release sanity for the GCP portal control plane - migrations, secrets, image build, HCP Terraform plan, and health. Use before deploying or when changing the Dockerfile, release config, runtime config, or infra delivery path. Does not apply infrastructure.
effort: medium
argument-hint: "[commit or deployment change]"
allowed-tools: Read, Grep, Glob, Bash
---

# Deploy check (GCP control plane)

Production delivery is outward-facing. This skill verifies the commit, release,
and planned rollout; it never confirms or applies an HCP Terraform run.

## Read the source of truth first

Read `.github/DEPLOYMENT.md`, `portal/Dockerfile`, `portal/rel/`,
`portal/config/runtime.exs`, `infra/README.md`, and the main-only delivery job
in `.github/workflows/cd.yml`. Verify commands and required variables from
those files instead of relying on memory.

## Checklist

- **Commit and CI** - the intended commit is current and the complete required CI
  workflow is green.
- **Migrations** - committed migrations are untouched; new migrations are
  forward-only and compatible with old and new images during the rolling overlap.
- **Secrets** - every required runtime value has a Secret Manager source or an
  explicit non-secret cloud-init value. No secret is committed or printed.
- **Image** - CI built and smoke-tested the image; CD publishes that exact image
  by immutable GHCR digest.
- **Infrastructure** - Terraform format, validation, and tflint pass. HCP
  workspace auto-apply is disabled.
- **Plan** - wait for the complete saved HCP plan. Check the run's commit message,
  image digest, replacements, database/DNS changes, and output changes.
- **Capacity** - the MIG keeps `max_unavailable_fixed = 0`, uses readiness-gated
  replacement, and does not reduce the serving fleet unexpectedly.
- **Health** - `/healthz` and `/readyz` pass; managed certificates, external
  monitors, logs, and expected runner reconnections are checked after apply.
- **Rollback** - name the previous immutable digest and confirm it remains
  compatible with all schema changes in the plan.

## Output

Return a go/no-go checklist with evidence for each item, the HCP run link when one
exists, the exact image digest, and any migration, secret, or capacity concern.
Stop before **Confirm & Apply**; the user performs the production apply.
