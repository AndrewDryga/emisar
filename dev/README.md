# Dev-only fixtures & harnesses

Local-only development scaffolding for the docker-compose stacks — per-runner
configs + fixtures for the root demo stack, and the standalone pack-test
harness. None of this ships with production releases — the runner tarball
produced by the release workflow contains exactly the runner binary and its
config skeleton.

## `runners/`

One config file per docker-compose runner (`edge-fra-01.yaml`,
`api-iad-02.yaml`, `pg-primary-iad.yaml`), mounted over the image's baked-in
`/etc/emisar/config.yaml`:

```yaml
volumes:
  - ./dev/runners/edge-fra-01.yaml:/etc/emisar/config.yaml:ro
```

Each pins a fixed `runner.id` (the durable `external_id`) that **matches the
`external_id` the seed writes on that runner's row** (`apps/emisar/priv/repo/seeds.exs`).
Because runner identity is `(account, external_id)`, the live container
*adopts* its pre-seeded row on register — coming up **online** while keeping
the seeded run history, approvals, grants, and trusted pack catalog — instead
of registering a second, empty runner. The config also sets each runner's
`group`, `labels`, and which role packs it loads + advertises (edge → caddy,
api → systemd-deep, pg → postgres; all three also load linux-core, which runs
for real off the container via the fixtures below).

To add a runner: add a `dev/runners/<name>.yaml`, a matching `runner_specs`
entry in the seed (same `external_id`), and a service in `docker-compose.yml`.

## `runner-fixtures/`

Mounted into each runner container at runtime via `docker-compose.yml`:

```yaml
volumes:
  - ./dev/runner-fixtures/bin/systemctl:/usr/bin/systemctl:ro
  - ./dev/runner-fixtures/bin/journalctl:/usr/bin/journalctl:ro
  - ./dev/runner-fixtures/var-log/syslog:/var/log/syslog:ro
  - ./dev/runner-fixtures/var-log/auth.log:/var/log/auth.log:ro
  - ./dev/runner-fixtures/var-log/nginx:/var/log/nginx:ro
```

* `bin/systemctl`, `bin/journalctl` — bash stubs that print
  realistic-looking output for the units the `linux-core` actions can
  target (cassandra, nginx, postgresql, docker). The container has no
  systemd; without these the actions error with "no such file or
  directory" and the demo looks broken.
* `var-log/*` — sample `syslog`, `auth.log`, and `nginx/access.log`
  files so `linux.tail_log` and `linux.grep_log` have content to read.

Real Linux hosts (where production runners install via `install.sh`)
already have the real `/usr/bin/systemctl`, `/usr/bin/journalctl`,
`/var/log/syslog`, etc. The runner image is unchanged from production.

## `test-packs/`

A standalone docker-compose **integration harness** for the action packs —
separate from the root demo stack. It boots the real backing services
(postgres, redis, consul, …), then runs each pack's `test/cases.yaml`
through the runner binary and asserts on exit code + stdout:

```sh
docker compose -f dev/test-packs/docker-compose.yaml up -d redis
docker compose -f dev/test-packs/docker-compose.yaml run --rm runner-tools \
    /workspace/test-packs/harness.sh redis
```

The pack catalog (`packs/`) is mounted read-only at `/packs`; the test cases
live with each pack at `packs/<pack>/test/cases.yaml`. See
`test-packs/README.md` for the full schema and skip rationale.

## `signing/`

End-to-end coverage for **signed dispatch** (the CA-issued-certificate feature)
against the root demo stack. Two profile-gated `test` services in
`docker-compose.yml` plus a host driver:

- **`signing-init`** mints a CA + leaf key + certificate at stack-up via
  `emisar signing init` (run `init.sh`), into the shared `signing_material`
  volume. **Generate-at-startup** — no CA or leaf private key is committed;
  `docker compose down -v` rotates them.
- **`runner-signed`** is a 4th runner that **enforces** signing: it points
  `--config` at the config `signing-init` wrote (with the freshly-minted CA's
  public key) and runs a dispatch only if it carries a valid, in-scope,
  CA-vouched attestation. Group `signed-iad`, matching the cert's scope.
- **`e2e/`** drives the real MCP bridge to prove the property end to end — a
  **signed** dispatch runs, the **same** dispatch **unsigned** is refused with
  `runner_requires_attestation` (the portal won't relay an unsigned call to an
  enforcing runner):

```sh
docker compose up -d         # the base stack
./dev/signing/e2e/run.sh     # builds current runner/mcp images, then asserts
```

`run.sh` is host-side (stdlib Python 3, like the SSO e2e) — it reaches the
portal over the published `localhost:4010` and the bridge over the in-network
`portal:4000`, so signing happens in the bridge exactly as on a real client.
