---
name: coop-box-builds-are-isolated
description: how host and Coop development share workspace-local service URLs while keeping platform-specific build output isolated
subsystem: agent-stack
sources: [.agent/Dockerfile, .agent/project.yaml, dev/compose.yml, dev/run, tools/internal/devtool, portal/config/dev.exs, portal/config/test.exs]
updated: 2026-07-22
---

Four seams make every gate run green inside a coop box; break any one and you get
confusing, hard-to-attribute failures:

1. **One URL on both sides:** `dev/compose.yml` declares only container ports.
   Coop assigns stable workspace-specific host ports, publishes them on loopback, and
   mirrors the same `localhost:<port>` URLs into the box. `dev/run` reads those URLs as
   `COOP_SERVICE_*` in a box and from `coop fork ls --json` on the host. Portal receives
   the resulting `DATABASE_URL`; tests receive `PGHOST=localhost` plus the assigned
   `PGPORT`. Service-name-only URLs such as `db:5432` split host and box configuration
   because the host cannot resolve the Compose service name.

2. **Build isolation:** the repo mount shares `portal/_build` with the macOS host, but
   BEAM builds are platform-specific — a darwin-compiled NIF (LazyHTML) made 716 of 2232
   emisar_web tests crash in a linux box (`LazyHTML.NIF is not available`), and an in-box
   compile would poison the host's artifacts right back. `.agent/Dockerfile` sets
   `MIX_BUILD_ROOT=/home/node/.cache/mix-build/emisar` (+ `GOMODCACHE` for persistence,
   not isolation): box artifacts live under the coop-cache volume — first box pays a
   ~2-min cold compile, every later box reuses it (warm full portal gate: ~52s).

3. **The output-hygiene guard needs a warm dep tree:** on a cold build root the guard's
   first scanned step (`ecto.create`) compiles every dependency, and THIRD-PARTY compile
   warnings (sentry's `unused require Logger`) trip the pollution regex on noise that
   isn't ours. The Go portal gate warms `mix deps.compile` UNSCANNED first;
   emisar's own apps still compile inside the scanned steps, so our warnings are still
   caught.

4. **Serve has one owner:** `dev/run serve` holds an advisory lock scoped by
   workspace and listen port. A second launcher fails before invoking Mix, and
   occupied Phoenix/metrics ports fail before database preparation. Go supervises
   Phoenix and the in-process Coop TCP proxies as one lifecycle.

5. **OIDC keeps one issuer:** Keycloak sees the same forwarded
   `https://localhost:<workspace-port>` Host header from the host browser and the box.
   `dev/run` patches one exact callback URL for that workspace and installs the ignored
   dev CA beside the system roots for Erlang. Dynamic hostname acceptance and the
   well-known admin credentials belong only to this loopback-published dev sidecar.

Coop's shared base owns asdf, login-shell PATH repair, agent CLIs,
and the localhost sidecar forwarders. `.agent/Dockerfile` extends it only for Emisar's
extra OS dependencies and platform-specific cache locations. Copying the base image
setup into this repo would duplicate Coop-owned behavior and cache layers.

Related rules: [human development tooling is not agent state](rules/shared-human-dev-tooling-is-not-agent-state.md) and [Docker inputs enter at their narrowest layer](rules/shared-docker-inputs-enter-at-narrowest-layer.md).

## Changelog
- 2026-07-22 — moved development orchestration and browser automation into the
  shared Go tools module; replaced PID records, socat, OpenSSL, jq, curl, and npm.
- 2026-07-22 — added fail-fast serve ownership and listener checks after an
  abandoned launcher kept an unhealthy Phoenix process and Mix build lock alive.
- 2026-07-22 — unified host and box sidecars/URLs, moved the box onto Coop's base,
  and added the dynamic Keycloak issuer/callback trust path.
- 2026-07-16 — created, from the first full in-box gate matrix (all five projects green:
  portal 2248+2232 tests, runner/mcp `go test -race`, terraform fmt, every pack validates).
