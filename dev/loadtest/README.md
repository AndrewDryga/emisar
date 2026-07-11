# loadtest — runner & MCP-client concurrency harness

Dev-only tooling to measure the control plane's capacity under concurrent **MCP
clients** and connected **runners**, and to record where it bottlenecks. Two
halves, one boring principle each:

- **MCP-client load** — a stdlib-only Go generator (`main.go`) that hammers
  `POST /api/mcp/rpc` with a fixed pool of concurrent virtual clients and prints
  a latency/error profile. Purpose-built because the real `emisar-mcp` bridge is
  one-request-at-a-time over stdio; a concurrent HTTP driver is the right tool.
- **Runner-connection load** — **no new code**: fan out N copies of the real
  `emisar connect` binary. The runner already is the load client; reproducing its
  websocket protocol in a fake would only drift from the real thing.

This harness is a **separate Go module, deliberately not in `../../go.work`**, so
it never ships and never joins the `runner/`/`mcp/` gates. Because it's outside
the workspace, every `go` command here needs `GOWORK=off`.

> **No `docker` in your box?** The measured run below needs the `docker-compose`
> stack (repo root). If your environment can't run Docker, you can still build,
> gate, and unit-test this harness (it self-tests against an in-process stub);
> the live capacity numbers must be gathered on a Docker-capable host. The
> **code-derived design limits** in the table below need no run at all.

## Build & gate

```sh
cd dev/loadtest
GOWORK=off gofmt -l -s .        # zero output
GOWORK=off go vet ./...
GOWORK=off go test -race -count=1 ./...
GOWORK=off go build -o /tmp/loadtest .
```

## Scenario A — MCP client concurrency

Bring the stack up (from the repo root), then drive the seeded dev MCP key:

```sh
docker compose up -d            # portal + db + 3 runners
cd dev/loadtest && GOWORK=off go build -o /tmp/loadtest .

# 32 concurrent clients listing the tool catalog for 30s (2s warmup dropped):
/tmp/loadtest -clients 32 -duration 30s -scenario tools_list
```

Flags: `-url` (default `http://localhost:4010`, the compose-published port),
`-key` (default = the seeded `emk-...` dev key), `-scenario`
(`tools_list` | `ping` | `initialize`), `-clients`, `-duration`, `-warmup`,
`-timeout`. It is **closed-loop**: each client fires the next request the instant
the previous returns, so offered concurrency == `-clients` and throughput is
bounded by latency. Sweep `-clients` upward (8 → 16 → 32 → 64 → 128) and find the
knee where p95 inflects or non-`ok` outcomes appear.

Sample output (shape):

```
emisar MCP load — http://localhost:4010
  scenario=tools_list clients=32 duration=30s (warmup 2s excluded)
  measured requests: 8790
  throughput: 293.0 req/s
  latency: p50=98ms p90=140ms p95=180ms p99=320ms min=40ms max=900ms mean=110ms
  outcomes: ok=8490 rate_limited=300
```

**Two gotchas that will dominate your first run — both are real limits, not bugs:**

1. **The per-key rate limit caps you at 300 req/min ≈ 5 req/s** for one bearer
   (`mcp_rpc_controller.ex:41`), so `tools_list`/`ping` runs turn to `429`s almost
   immediately. To measure *server* capacity rather than the limiter, mint N MCP
   keys and run N harness processes (one `-key` each) in parallel, or measure the
   limiter itself with one key. The harness prints a `note:` when it sees `429`s.
2. **`tools/call` blocks up to 60s by default** (`service.ex:24`) — the request
   holds a Bandit process **and** a DB connection for the whole long-poll. With
   the pool at 10 (below), ~10 concurrent blocking dispatches saturate it and new
   work queues on checkout. The harness ships `initialize`/`ping`/`tools_list`
   (safe, side-effect-free); do **not** point `tools/call` at real runners in a
   load run — it would enqueue real dispatches. Measure dispatch concurrency via
   Scenario B + the portal's own run metrics instead.

## Scenario B — Runner connection concurrency

Scale the real runner. The compose stack runs 3; add more by fanning out
`emisar connect` against the portal with distinct `external_id`s (runner identity
is `(account, external_id)`, and `/runner/register` is idempotent on it). Each
extra runner needs its own `runner.id`, `token_path`, and `data_dir` — colliding
paths corrupt each other's token/dedup state. Generate one config per runner from
a template and launch them against the host-published port `4010`:

```sh
# runner built as /tmp/emisar (from repo root: go build -o /tmp/emisar ./runner)
export EMISAR_AUTH_KEY=emkey-auth-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD
for i in $(seq 1 50); do
  d=$(mktemp -d)
  cat > "$d/config.yaml" <<YAML
schema_version: 1
runner: { id: "load-$i", group: "loadtest", labels: { role: load } }
cloud:
  url: "http://localhost:4010"
  allow_insecure: true
  auth_key_env: "EMISAR_AUTH_KEY"
  token_path: "$d/token.json"
  heartbeat_every: "30s"
paths: { data_dir: "$d", work_dir: "$d/work", packs: ["/opt/emisar/packs/linux-core"] }
YAML
  /tmp/emisar connect --config "$d/config.yaml" &
done
```

**Gotcha:** the account's **plan runner-limit** rejects registration past the
entitlement with HTTP `402 runner_limit_exceeded` (`runners.ex:1131-1178`). To
push past 3, seed a high-limit account/plan first (see `apps/emisar/priv/repo/seeds.exs`),
or raise the demo plan's runner entitlement. That plan cap is itself the *product*
concurrency limit on connected runners — record it as such.

What to watch while runners are connected and dispatching: the portal's
`/app/runners` online count, connection churn in the portal logs
(`cloud.session_ended` on the runner side, socket close on the portal side), the
**per-runner** in-flight cap (below), and the DB pool.

## Code-derived design limits (no run required)

These are the concurrency ceilings baked into the code today — the honest answer
to "what are the limits" before a single request is sent.

| Limit | Value | Where | Effect under load |
|---|---|---|---|
| **DB pool** | **10** (`POOL_SIZE`) | `portal/config/runtime.exs:70`, `dev.exs:11` | Global ceiling. Every dispatch, run-finalize, progress append, register, and page load competes for 10 connections. The first thing to raise. |
| **MCP rate limit** | **300 req/min per bearer** | `mcp_rpc_controller.ex:41` | ~5 req/s per key, fixed-window (2× burst at window edges). Off in `test` env. |
| **`tools/call` long-poll** | **60s** default, cap **300s** | `service.ex:24,28` | A blocking dispatch pins a Bandit process + a DB connection for its whole wait — the pool-starvation path. |
| **Runner in-flight actions** | **8** per runner | `runner/internal/cloud/client.go:47` | Over-cap `run_action` gets an immediate `concurrency_cap_reached`, not a queue. |
| **Runner per-run outbox** | **2048** msgs | `runner/internal/cloud/client.go:53` | Oldest progress chunk dropped when full (drop count reported on the result). |
| **Runner socket** | frame ≤ **1 MiB**, heartbeat timeout **90s**, upgrade timeout **60s** | `runner_connect_controller.ex:91-94`, `runner_socket.ex:29` | A silent runner is reaped at 90s. |
| **Result dedup ring** | **5000** | `runner_socket.ex:350` | Bounded replay cache for `action_result` per socket. |
| **HTTP acceptors / max conns** | ThousandIsland defaults (~**100** / **16384**) | `endpoint.ex:2`, `runtime.exs:103-115` | Not explicitly configured — the accept path is not the near-term bottleneck; the pool is. |
| **Runner count** | **per-plan entitlement** | `runners.ex:1131-1178` | Registration past the plan limit → HTTP `402`. The product cap on connected runners. |
| **`/runner/*` rate limit** | **none** | `router.ex:336-339` | Register + websocket are unthrottled at the plug layer — worth a stress pass for abuse (a hostile enrollment key floods register). |

## What to measure alongside the harness

- **DB pool pressure** — the signal that matters most given pool=10. Watch
  `Emisar.Repo` telemetry / `pg_stat_activity` for connections all busy and
  checkout queueing. If checkout wait climbs, the pool is the bottleneck.
- **BEAM** — scheduler utilization, process count (one per socket + per in-flight
  request), memory. `:observer` / `:recon` against the running node.
- **Postgres** — `pg_stat_activity`, slow queries, lock waits during dispatch
  finalize and register (register locks the account row).
- **HTTP** — p50/p95/p99 + error mix straight from this harness.

## First tuning recommendations (hypotheses to confirm with a run)

1. **Raise `POOL_SIZE`** well above 10 for any real fleet — it's the global
   ceiling and the cheapest lever. Confirm against Postgres `max_connections`.
2. **Don't hold a DB connection across the `tools/call` long-poll.** Check the
   connection back in before the wait and re-acquire on wake, or give the wait its
   own small pool, so N blocking dispatches can't starve the main pool.
3. **Tune the MCP rate limit to real agent behavior** — 300/min is generous for a
   human-paced agent but throttles a burst-y automation; consider a per-key
   override for trusted keys, and note the fixed-window 2×-at-edge burst.
4. **Consider a modest cap / backpressure on `/runner/register`** — it's
   unthrottled; a stress pass should confirm a hostile enrollment key can't flood
   it (the account-row lock serializes but doesn't rate-limit).

## Native boot (no Docker) — how the run below was produced

No Docker? You don't need the compose stack; boot the portal natively and drive
port **4000**. This is exactly how the measured run below was gathered.

```sh
# 1. Postgres (asdf, no docker) — see portal memory `portal-test-db-bootstrap`
export ASDF_POSTGRES_VERSION=16.14
PGBIN=$(asdf where postgres)/bin
[ -d ~/.pgdata-emisar ] || "$PGBIN/initdb" -U postgres --auth=trust -D ~/.pgdata-emisar
"$PGBIN/pg_ctl" -D ~/.pgdata-emisar -l /tmp/pglog.log \
  -o "-p 5432 -k /tmp -c listen_addresses=localhost" start

# 2. Dev DB (from portal/)
cd portal && export PGHOST=localhost PGPORT=5432 MIX_ENV=dev
mix ecto.create && mix ecto.migrate

# 3. Boot the endpoint WITHOUT the asset watchers (the box has no Linux
#    esbuild/tailwind binary) via a throwaway boot script — put_env disables
#    watchers + code_reloader, sets server:true, then starts :emisar_web:
#      ep = Application.get_env(:emisar_web, EmisarWeb.Endpoint)
#      Application.put_env(:emisar_web, EmisarWeb.Endpoint,
#        Keyword.merge(ep, watchers: [], server: true, code_reloader: false))
#      {:ok, _} = Application.ensure_all_started(:emisar_web); Process.sleep(:infinity)
#    Run it with:  mix run --no-start --no-halt /tmp/boot_portal.exs &
```

The full `seeds.exs` currently raises `missing shipped-pack baseline for caddy
0.1.6` (its `pack_versions` are ahead of `priv/packs/catalog.json`) — **you don't
need it.** Mint the MCP keys you drive directly against the already-seeded demo
account with a tiny `mix run --no-start` script (start only `:emisar` so the
`:prometheus_metrics` port doesn't collide with the running endpoint), building
each key row exactly as `seeds.exs` does — `ApiKeys.ApiKey.Changeset.create(...,
String.slice(raw,0,12), Emisar.Crypto.hash(raw), attrs)`. Each key needs a
**distinct 12-char prefix** (`peek_api_key_by_secret` looks up by prefix), so vary
the first 12 chars per key.

## Results log

Measured run — 2026-07-11, native boot (above), portal `dev` env, pool=10, MCP
rate limit ON, on a shared 12-vCPU / 16 GB coop container. **Read the caveat under
the table before quoting any absolute number.**

| Scenario | offered conc. (16 keys ×) | throughput | p50 | p95 | rate-limited | pg active peak (of 10) |
|---|---|---|---|---|---|---|
| tools_list | 16 (×1) | 162 req/s | ~98 ms | ~110 ms | 0 | 2 |
| tools_list | 32 (×2) | 203 req/s | ~156 ms | ~176 ms | 291 | 5 |
| tools_list | 64 (×4) | 235 req/s | ~262 ms | ~294 ms | 2816 | ≤5 |
| tools_list | 128 (×8) | **192 req/s** (collapse) | ~575 ms | ~857 ms | 768 | ≤5 |
| ping | 16 → 128 | 160 → 235 req/s | 98 → 511 ms | 113 → 580 ms | 0 → engages | ≤2 |

Single-client, unthrottled per-request latency (warm): `initialize` p50 26 ms /
p95 31 ms · `ping` p50 22 ms / p95 26 ms · `tools_list` p50 22 ms / p95 26 ms.

**Two limits pinned to exact numbers:**

- **MCP rate limit = 300 req / 60 s / bearer, shared across methods.** A *fresh*
  bearer fired 800 pings as fast as possible returned **exactly 300 × `200` then
  500 × `429`** with `retry-after: 60`. `initialize` counts against the same
  window as `ping`/`tools/call` (an `initialize`-then-`ping` run exhausts one
  shared budget). The "2×-at-edge burst" only appears when a burst straddles two
  windows; wholly inside one window the allowance is a hard 300.
- **`/runner/register` is unthrottled.** 600 rapid POSTs with distinct bogus
  enrollment bearers returned **600 × `401`, zero `429`** — confirming the abuse
  surface: a hostile enrollment key floods register (one DB lookup each) with no
  plug-layer backpressure. Rec #4 stands.

**What the numbers say (the transferable findings — trust these over the absolute req/s):**

1. **The DB pool (10) is NOT the bottleneck for MCP read/control methods.**
   Postgres active connections peaked at ≤5 of 10 at every concurrency level;
   `ping` (≈no DB) and `tools_list` (a DB read + large JSON) share the *same*
   throughput ceiling, so the cost is per-request pipeline/CPU, not pool checkout.
   The pool-starvation path is specifically `tools/call`'s 60 s long-poll (each
   holds a connection) — **not exercised here** (needs connected runners
   dispatching real actions), so tuning rec #1/#2 remains a hypothesis for that
   path, not something this read-path run reproduced.
2. **Latency scales linearly with offered concurrency** (Little's law: ~98 ms at
   16 → ~575 ms at 128) and **throughput plateaus ~200–240 req/s then suffers
   congestion collapse past ~64 offered concurrency** (192 req/s at 128). The knee
   is ~32–64 concurrent MCP requests on this box.
3. **The rate limiter, not the server, is the first wall a single busy agent
   hits** — one key is capped at 300/min long before it can pressure the pool.

> **Caveat — absolute req/s here is a floor, not a capacity claim.** This ran in
> `MIX_ENV=dev` (`plug_init_mode: :runtime` re-inits plugs per request;
> `enable_expensive_runtime_checks`) on a *shared* coop container. Those are dev
> artifacts, not server limits — a `prod` release on dedicated hardware will do
> materially more req/s. What transfers is the **shape** (linear latency, ~200/s
> plateau + collapse past the knee) and the **bottleneck ordering** (rate limit →
> per-request CPU → pool), plus the two exact limits above. Re-run on a `prod`
> build / dedicated host to get quotable capacity ceilings.

> Harness self-validation (not a portal number): built binary against an
> in-process stub sustained ~6k req/s at `-clients 8` with an all-`ok` profile —
> confirms the generator and the report path work end to end.
