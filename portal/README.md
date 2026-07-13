# Portal

The Elixir/Phoenix control plane for [emisar](../README.md). It owns accounts,
runner identity and state, pack trust, policy and approvals, runs and runbooks,
audit, billing, the LiveView operator console, the public website, and the
remote MCP/OAuth surface. The on-host runner remains the execution authority.

## Layout

```text
apps/emisar/      domain contexts, Ecto schemas, recurrent jobs, and pack baseline
apps/emisar_web/  HTTP, LiveView, runner websocket, MCP/OAuth, and marketing pages
config/           compile-time and runtime configuration
rel/              release commands and overlays
Dockerfile        production release image, built from the repository root
docker-compose.yml local PostgreSQL for native development
```

## Local development

Run from `portal/`:

```sh
docker compose up -d db
mix deps.get
mix ecto.setup
mix phx.server
```

Open <http://localhost:4000>. The seeded owner is `demo@emisar.dev`; request a
magic sign-in link and read it at <http://localhost:4000/dev/mailbox>. Seeds
also print a reusable runner bootstrap key for connecting a local runner.

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
