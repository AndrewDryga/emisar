# Dev-only fixtures & harnesses

Local-only development commands, dependencies, fixtures, and harnesses. None
of this ships with production releases — the runner tarball
produced by the release workflow contains exactly the runner binary and its
config skeleton.

## Compose topologies

The repository has three intentionally separate Compose environments:

- `dev/compose.yml` runs PostgreSQL and Keycloak for the fast host-native and
  Coop development loop.
- `docker-compose.yml` builds the packaged Portal release and runs the seeded
  demo, runners, MCP, and signing smoke tests.
- `dev/test-packs/docker-compose.yaml` runs real backing services for action-pack
  integration tests.

The application server stays out of the fast dependency stack, while the
packaged stack verifies the release image and the pack harness remains isolated
from both application environments.

## Fast development loop

`dev/run` is the shared human/agent command surface. `compose.yml` contains the
Postgres and Keycloak dependencies used by both host-native Phoenix and Coop;
Phoenix itself runs directly in the active workspace.

The repository keeps tooling in four ownership buckets:

- `dev/run` exposes contributor commands and thin environment orchestration.
- `tools/` holds reusable Go checks/drivers and the browser-only JavaScript.
- `.github/scripts/` holds CI-only wrappers; the root `.agent/` holds agent
  configuration and state, not another command surface.
- Shell programs under `packs/` and `infra/` execute with their owned runtime
  artifacts; they are product/operations code, not alternative dev commands.

```sh
dev/run setup
dev/run seed
dev/run serve
```

`serve` records one owner per workspace and exits before running Mix when that
owner is still alive. Its error includes the PID to stop. Dead ownership records
are reclaimed automatically, and an untracked listener on either Phoenix port
fails immediately instead of leaving later Mix commands waiting on a build lock.

Common feedback commands:

```sh
dev/run check changed
dev/run test portal --stale
dev/run test portal --failed
dev/run test portal --stale --listen-on-stdin
dev/run test portal apps/emisar_web/test/emisar_web/marketing_test.exs
dev/run check portal
dev/run check agent-setup
dev/run gate portal
dev/run check tooling
dev/run shot /pricing --label after --heading Pricing --out .agent/screenshots/pricing
dev/run capture console
dev/run capture docs
dev/run e2e sso
dev/run e2e signing
dev/run e2e billing
dev/run pack check redis
```

`check changed` incrementally compiles the umbrella, then format-checks and runs
Credo only on staged, unstaged, and untracked Portal source files. It does not
start the dependency stack. `mix test --stale` uses Mix's module dependency
graph rather than guessing test paths from filenames; add `--listen-on-stdin`
and press Enter after a save to repeat that set in the same shell. `--failed`
re-runs only the previous failures. `check portal` and `gate portal` remain the
full pre-commit surfaces.

`dev/run urls` discovers the assigned URLs without reproducing Coop's hash.
The Keycloak CA and leaf files are created under `keycloak/certs/generated/`.
On macOS, opt into browser trust once per workspace and remove it explicitly:

```sh
dev/run certs trust
dev/run certs status
dev/run certs untrust
```

Trust is limited to SSL for `localhost` in the user keychain and removal targets
the exact CA fingerprint, so parallel workspaces do not remove each other's
certificates. `dev/run certs --rotate` removes the old fingerprint and restores
trust only when it was already enabled. The automated browser uses an exception
for the exact leaf certificate SPKI, never a blanket TLS bypass. `dev/run doctor`
verifies services, browser trust on macOS, the exact OIDC issuer, and that
generated private keys remain ignored.

Setup, serve, and reset never seed implicitly. `dev/run seed` is idempotent;
`dev/run reset --seed` is the explicit destructive shortcut.

## Browser and screenshot tooling

`dev/run` owns the public commands; the reusable Puppeteer implementation and
its pinned npm dependencies live in `tools/browser/`. The persistent browser is
shared across captures for the active workspace, including inside Coop:

```sh
dev/run browser start
dev/run shot /app/demo/runners --label before --shot runners
# edit; Phoenix reloads
dev/run shot /app/demo/runners --label after --shot runners
dev/run browser stop
```

`shot` accepts a stable `data-shot` name, a CSS selector, an exact heading, or a
class fragment as its crop anchor. Use `--width 390` for a mobile capture and
put before/after artifacts under the owning task's screenshot directory.

`dev/run capture docs` regenerates the cropped console screenshots embedded in
the documentation. `dev/run capture console` walks the signed-out and
authenticated console at desktop and mobile widths. Both require an active
seeded workspace and reuse the persistent browser. Automated Chromium allows
only the active Keycloak leaf certificate's SPKI; certificate validation is not
disabled globally.

The same implementation carries the real Paddle sandbox browser driver, exposed
as `dev/run e2e billing`. Its ignored credentials remain in
`portal/.agent/secrets/paddle-sandbox.env`.

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
(postgres, redis, consul, …), then runs each pack's `test/cases.json`
through the runner binary and asserts on exit code + stdout:

```sh
docker compose -f dev/test-packs/docker-compose.yaml up -d redis
docker compose -f dev/test-packs/docker-compose.yaml run --rm runner-tools \
    /workspace/test-packs/harness.sh redis
```

The pack catalog (`packs/`) is mounted read-only at `/packs`; the test cases
live with each pack at `packs/<pack>/test/cases.json` (generated by
`tools/cmd/gencases` — regenerate, never hand-edit). See
`test-packs/README.md` for the full schema and skip rationale.

## `signing/`

End-to-end coverage for **signed dispatch** (the CA-issued-certificate feature)
against the root demo stack. Two profile-gated `test` services in
`docker-compose.yml` plus the `dev/run e2e signing` driver:

- **`signing-init`** mints a CA + leaf key + certificate at stack-up via
  `emisar signing init` (run `init.sh`), into the shared `signing_material`
  volume. **Generate-at-startup** — no CA or leaf private key is committed;
  `docker compose down -v` rotates them.
- **`runner-signed`** is a 4th runner that **enforces** signing: it points
  `--config` at the config `signing-init` wrote (with the freshly-minted CA's
  public key) and runs a dispatch only if it carries a valid, in-scope,
  CA-vouched attestation. Group `signed-iad`, matching the cert's scope.
- **`tools/cmd/signing-e2e`** drives the real MCP bridge to prove the property end to end — a
  **signed** dispatch runs, the **same** dispatch **unsigned** is refused with
  `signature_required` (the portal won't relay an unsigned call to an
  enforcing runner):

```sh
dev/run e2e signing
```

The host-side stdlib Go driver performs every
discovery and dispatch call through the bridge over the in-network
`portal:4000`, so signing happens exactly as on a real stdio client.
Each workspace gets an isolated Compose project with Docker-assigned host ports;
the driver removes its containers, network, and test volumes when it exits.
