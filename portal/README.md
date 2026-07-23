# emisar portal

The Elixir/Phoenix control plane for [emisar](../README.md). It owns accounts,
runner identity and state, pack trust, policy and approvals, runs and runbooks,
audit, billing, the LiveView operator console, the public website, and the
remote MCP/OAuth surface. It decides whether an action may be dispatched; the on-host runner remains the execution authority.

This README gets a contributor to a working local portal. Product behavior and
trust boundaries live in [`../.agent/kb/architecture.md`](../.agent/kb/architecture.md)
and [the security model](../.agent/kb/specs/security-model.md); context boundaries,
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
./run setup
./run certs trust # macOS, once per workspace
./run seed       # only when demo data is wanted
./run serve
```

Phoenix runs directly in the current workspace for fast code reload. The
printed URL is stable for that workspace and distinct across Coop forks. The
seeded owner is `demo@emisar.dev`; request a magic sign-in link and read it at
`<portal-url>/dev/mailbox`. Seeds also print a reusable runner enrollment key.

`./run setup`, `serve`, and `reset` migrate but do not seed. Use `./run seed`
or `./run reset --seed` when the fixtures need to be refreshed.

For the shortest feedback loop, use `./run check changed` and
`./run test portal --stale`; `./run test portal --failed` re-runs only the
previous failures. The full pre-commit surface remains `./run gate portal`.

The repository-root `docker-compose.yml` starts the complete local stack,
including sample runners. Production delivery is documented in
[`.github/DEPLOYMENT.md`](../.github/DEPLOYMENT.md).

## Gate

```sh
../run gate portal
```

The gate compiles, checks formatting and Credo, runs both test suites, and rejects warning/error log
pollution. Project architecture and security rules are in [`AGENTS.md`](AGENTS.md).
