# emisar portal

The Elixir/Phoenix control plane for [emisar](../README.md). It owns accounts,
runner identity and state, pack trust, policy and approvals, runs and runbooks,
audit, billing, the LiveView operator console, the public website, and the
remote MCP/OAuth surface. It decides whether an action may be dispatched; the on-host runner remains the execution authority.

This README gets a contributor to a working local portal. Product behavior and
trust boundaries live in [`../docs/architecture.md`](../docs/architecture.md)
and [`../docs/security-model.md`](../docs/security-model.md); context boundaries,
authorization rules, and the required gate live in [`AGENTS.md`](AGENTS.md).

## Layout

```text
apps/emisar/      domain contexts, Ecto schemas, recurrent jobs, and pack baseline
apps/emisar_web/  HTTP, LiveView, runner websocket, MCP/OAuth, and marketing pages
config/           compile-time and runtime configuration
rel/              release commands and overlays
Dockerfile        production release image, built from the repository root
```

## Local development

Run from the repository root:

```sh
dev/run setup
dev/run seed       # only when demo data is wanted
dev/run serve
```

Phoenix runs directly in the current workspace for fast code reload. The
printed URL is stable for that workspace and distinct across Coop forks. The
seeded owner is `demo@emisar.dev`; request a magic sign-in link and read it at
`<portal-url>/dev/mailbox`. Seeds also print a reusable runner enrollment key.

`dev/run setup`, `serve`, and `reset` migrate but do not seed. Use `dev/run seed`
or `dev/run reset --seed` when the fixtures need to be refreshed.

The repository-root `docker-compose.yml` starts the complete local stack,
including sample runners. Production delivery is documented in
[`.github/DEPLOYMENT.md`](../.github/DEPLOYMENT.md).

## Gate

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo
../.agent/scripts/check-portal-test-output.sh
```

The final command runs both umbrella test suites and rejects warning/error log
pollution. Project architecture and security rules are in [`AGENTS.md`](AGENTS.md).
