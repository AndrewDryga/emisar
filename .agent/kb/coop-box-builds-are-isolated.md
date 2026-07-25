---
name: coop-box-builds-are-isolated
description: how host and Coop development share workspace-local service URLs while keeping platform-specific build output isolated
subsystem: agent-stack
sources: [.agent/Dockerfile, .agent/project.yaml, dev/compose.yml, run, tools/internal/devtool, portal/config/dev.exs, portal/config/test.exs]
updated: 2026-07-24
---

Six constraints make every gate run green inside a coop box; break any one and you get
confusing, hard-to-attribute failures:

1. **Direct box database, forwarded host database:** `.agent/project.yaml` gives every
   box `PGHOST=db` and `PGPORT=5432`, so a bare `mix test` uses Compose DNS without
   leaking box-only values into host commands. `dev/compose.yml` still declares only
   container ports. Coop assigns stable workspace-specific host ports, publishes
   them on loopback, and mirrors the same `localhost:<port>` URLs into the box.
   `./run` reads those URLs as `COOP_SERVICE_*` in a box and from
   `coop fork ls --json` on the host. Host commands use the forwarded URL; box
   commands keep `db:5432`, including the `DATABASE_URL` supplied to Portal.
   Routing a full test suite through the localhost sidecar forwarder can exhaust
   database checkout timeouts, so it is for host reachability rather than box traffic.

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

4. **Serve has one owner:** `./run serve` holds an advisory lock scoped by
   workspace and listen port. A second launcher fails before invoking Mix, and
   occupied Phoenix/metrics ports fail before database preparation. Go supervises
   Phoenix and the in-process Coop TCP proxies as one lifecycle.

5. **OIDC keeps one issuer:** Keycloak sees the same forwarded
   `https://localhost:<workspace-port>` Host header from the host browser and the box.
   `./run` patches one exact callback URL for that workspace and installs the ignored
   dev CA beside the system roots for Erlang. Dynamic hostname acceptance and the
   well-known admin credentials belong only to this loopback-published dev sidecar.

6. **Identity is explicit:** Coop injects `COOP_BOX=1` into every box. Devtool
   branches on that marker instead of `/.dockerenv` or a conditional port mapping.
   `COOP_SERVE_URL_*` carries the workspace's assigned URLs for configuration even
   when an existing host listener means the current box cannot publish them.

Coop's shared base owns asdf, login-shell PATH repair, agent CLIs,
and the localhost sidecar forwarders. `.agent/Dockerfile` extends it only for Emisar's
extra OS dependencies and platform-specific cache locations. Copying the base image
setup into this repo would duplicate Coop-owned behavior and cache layers.

Related rules: [human development tooling is not agent state](rules/shared-human-dev-tooling-is-not-agent-state.md) and [Docker inputs enter at their narrowest layer](rules/shared-docker-inputs-enter-at-narrowest-layer.md).

## Changelog
- 2026-07-24 — declared direct PostgreSQL defaults in project box policy, kept
  them through devtool orchestration, and replaced serve-URL-based box detection
  with Coop's stable identity marker.
- 2026-07-22 — moved development orchestration and browser automation into the
  shared Go tools module; replaced PID records, socat, OpenSSL, jq, curl, and npm.
- 2026-07-22 — added fail-fast serve ownership and listener checks after an
  abandoned launcher kept an unhealthy Phoenix process and Mix build lock alive.
- 2026-07-22 — unified host and box sidecars/URLs, moved the box onto Coop's base,
  and added the dynamic Keycloak issuer/callback trust path.
- 2026-07-16 — created, from the first full in-box gate matrix (all five projects green:
  portal 2248+2232 tests, runner/mcp `go test -race`, terraform fmt, every pack validates).
