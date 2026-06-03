---
name: deploy
description: Pre-deploy checklist and release sanity for the portal control plane on Fly.io — migrations, required secrets, asset build, and that the release actually boots. Use before deploying, when changing the Dockerfile/release config/fly.toml, or to validate a release will start. Does not run the deploy.
effort: medium
allowed-tools: Read, Grep, Glob, Bash
---

# Deploy check (Fly.io control plane)

Deploying is **outward-facing**: this skill produces a checklist and verifies the
release builds/boots locally — it does **not** run the deploy. Confirm with the user
before any actual `fly deploy`.

## Read the source of truth first

`../docs/deploy.md` is canonical. Cross-read `portal/fly.toml`, `portal/Dockerfile`
(multi-stage release), `portal/rel/` (`env.sh.eex`, overlays, `bin/server`,
`bin/migrate`), and `portal/config/runtime.exs` (the real required-env set). **Don't
guess the deploy command or secret names — read them** (`/verify-api`).

The app on Fly is `emisar` (managed Postgres, dedicated IPs); the deploy runs from
the repo root per the deploy runbook. Confirm the exact command in `../docs/deploy.md`.

## Checklist

- **Migrations** — every new migration is reversible and runs on release
  (`rel/.../bin/migrate` / the release migrate step). No data-destructive change
  without an explicit plan. (IL-11: unshipped → edit in place; already-shipped →
  standalone corrective migration.)
- **Required env/secrets are set on Fly** — derive the list from `runtime.exs` (e.g.
  `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, plus Paddle/mailer/runner secrets).
  Read it; don't assume the list. Secrets via `fly secrets`, never committed.
- **Assets** built in the Docker image (esbuild/tailwind in the release stage).
- **Release boots locally** — build the release or run the prod-config server
  locally and confirm it starts and connects to the DB before shipping.
- **Health** — the health endpoint (`/health` controller) responds; `fly.toml`
  checks point at it.
- **Verify gate** (IL-20) — `mix compile --warnings-as-errors && mix test` is green
  on the commit being shipped.

## Output

A go/no-go checklist with each item checked or flagged, the exact deploy command
from the runbook, and any migration/secret that needs attention. Then stop — the
user runs the deploy.
