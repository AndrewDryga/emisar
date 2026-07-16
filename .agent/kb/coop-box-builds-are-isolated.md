---
name: coop-box-builds-are-isolated
description: how a coop box reaches postgres (PGHOST=db) and why its BEAM/Go builds must never share the host's _build (darwin NIFs poison linux runs, and vice versa)
subsystem: agent-stack
sources: [Dockerfile.agent, .agent/compose.yml, portal/config/dev.exs, portal/config/test.exs, .agent/scripts/check-portal-test-output.sh]
updated: 2026-07-16
---

Three seams make every gate run green inside a coop box; break any one and you get
confusing, hard-to-attribute failures:

1. **Database:** the sibling postgres (`.agent/compose.yml`) is reachable at its compose
   service name `db`, never localhost. `Dockerfile.agent` bakes `ENV PGHOST=db`; portal's
   dev/test config reads `System.get_env("PGHOST", "localhost")` — so host dev and CI
   (both genuinely localhost) need nothing. `mix test` self-creates `emisar_test` (the
   `ecto.create --quiet` test alias), so a fresh box + empty volume just works.

2. **Build isolation:** the repo mount shares `portal/_build` with the macOS host, but
   BEAM builds are platform-specific — a darwin-compiled NIF (LazyHTML) made 716 of 2232
   emisar_web tests crash in a linux box (`LazyHTML.NIF is not available`), and an in-box
   compile would poison the host's artifacts right back. `Dockerfile.agent` sets
   `MIX_BUILD_ROOT=/home/node/.cache/mix-build/emisar` (+ `GOMODCACHE` for persistence,
   not isolation): box artifacts live under the coop-cache volume — first box pays a
   ~2-min cold compile, every later box reuses it (warm full portal gate: ~52s).

3. **The output-hygiene guard needs a warm dep tree:** on a cold build root the guard's
   first scanned step (`ecto.create`) compiles every dependency, and THIRD-PARTY compile
   warnings (sentry's `unused require Logger`) trip the pollution regex on noise that
   isn't ours. `check-portal-test-output.sh` warms `mix deps.compile` UNSCANNED first;
   emisar's own apps still compile inside the scanned steps, so our warnings are still
   caught.

Related trap: asdf toolchains vanish in `bash -lc` unless `/etc/profile.d/asdf.sh`
re-prepends the shims (Debian's /etc/profile resets PATH) — Dockerfile.agent carries the
drop-in at the END of the file so editing it never invalidates the cached Erlang layer.

## Changelog
- 2026-07-16 — created, from the first full in-box gate matrix (all five projects green:
  portal 2248+2232 tests, runner/mcp `go test -race`, terraform fmt, every pack validates).
