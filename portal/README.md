# emisar — control plane

The cloud-side of [emisar](../README.md). Elixir/Phoenix umbrella that:

- Authenticates and tracks runners over WebSocket (the wire protocol lives in `../docs/wire-protocol.md`).
- Serves the operator UI (LiveView) for runners / runs / approvals / audit.
- Exposes the MCP-shaped HTTP API for LLMs.
- Handles billing (Stripe), policy evaluation, runbook expansion.

## Layout

```
apps/
  emisar/          domain — contexts, schemas, Oban workers, Stripe glue
  emisar_web/      Phoenix endpoint — UI, controllers, runner socket
config/            shared config + per-env overrides + runtime.exs
priv/repo/         migrations + seeds
rel/               release overlays (bin/server, bin/migrate)
docs/              deploy + operator guides
Dockerfile         multi-stage release build
docker-compose.yml local-dev postgres
fly.toml           fly.io deploy
```

## Getting started

```sh
docker-compose up -d db        # postgres on :5432
mix deps.get
mix ecto.setup                  # create, migrate, seed
mix phx.server                  # http://localhost:4000
```

Seed login: `demo@emisar.dev` / `Sleep-tight-1234`. The seed prints a reusable auth key — paste it into the runner installer to wire a local runner into your dev control plane.

## Deploying

See [../docs/deploy.md](../docs/deploy.md). TL;DR — set `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, then `docker build && docker run` (or `fly deploy`).

## Testing

```sh
mix test
```

CI runs the same. The `runner_socket` integration test brings up a Postgres test DB, opens a WebSocket against the local endpoint, presents a token, and exercises the full handshake → run dispatch → result envelope flow.
