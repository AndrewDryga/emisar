# Dev-only fixtures & harnesses

Local-only development commands, dependencies, fixtures, and harnesses. None
of this ships with production releases; release workflows assemble product
artifacts from the runner, MCP, pack, and root installer sources.

## Compose topologies

The repository has three intentionally separate Compose environments:

- `dev/compose.yml` runs PostgreSQL and Keycloak for the fast host-native and
  Coop development loop.
- `docker-compose.yml` builds the packaged Portal release and runs the seeded
  demo, runners, MCP, and signing smoke tests.
- `dev/test-packs/compose.yaml` supplies the shared action-client container;
  each `packs/<name>/test/compose.yaml` owns its disposable system under test.

The application server stays out of the fast dependency stack, while the
packaged stack verifies the release image and every pack behavior project stays
isolated from both application environments and other packs.

## Fast development loop

`./run` is the shared human/agent command surface. `compose.yml` contains the
Postgres and Keycloak dependencies used by both host-native Phoenix and Coop;
Phoenix itself runs directly in the active workspace.

Run `./run` or `./run help` for the complete map, or
`./run help <check|test|gate|pack|ops>` for one command family.
`./run setup` verifies the pinned Go/Elixir toolchain plus Chrome or Chromium
and ImageMagick. Coop supplies the browser and image tools in its project image;
host-native development uses the corresponding host installations.

The repository keeps tooling in three ownership buckets:

- `./run` is only a cached Go-binary bootstrap and the contributor command surface.
- `tools/` holds the reusable Go implementation, including browser automation.
- `dev/*/Dockerfile` recipes build Compose and validation fixtures, never published images.
- The root `.agent/` holds agent configuration and state, not another command surface.
- Shell programs under `packs/`, `infra/runtime/`, and container fixtures
  execute with their owned runtime artifacts; they are shipped or deployed
  code, not alternative dev commands.

```sh
./run setup
./run seed
./run serve
```

`serve` takes an advisory lock per workspace and exits before running Mix when
another launcher owns it. An untracked listener on either Phoenix port fails
immediately instead of leaving later Mix commands waiting on a build lock.

Common feedback commands:

```sh
./run check changed
./run test portal --stale
./run test portal --failed
./run test portal --stale --listen-on-stdin
./run test portal apps/emisar_web/test/emisar_web/marketing_test.exs
./run check portal
./run check staged
./run check infra-templates
./run check packs
./run check agent-setup
./run gate portal
./run gate runner
./run gate mcp
./run gate packs
./run gate infra
./run gate tooling
./run gate all
./run shot /pricing --label after --heading Pricing --group pricing
./run capture console
./run capture docs
./run e2e sso
./run e2e signing
./run e2e billing
./run pack check redis
./run pack hashes
./run test packs redis
./run test packs redis --case redis.ping
```

`check changed` incrementally compiles the umbrella, then format-checks and runs
Credo only on staged, unstaged, and untracked Portal source files. It does not
start the dependency stack. `mix test --stale` uses Mix's module dependency
graph rather than guessing test paths from filenames; add `--listen-on-stdin`
and press Enter after a save to repeat that set in the same shell. `--failed`
re-runs only the previous failures. `check portal` and `gate portal` remain the
quick static and complete pre-commit surfaces, respectively. `test` is focused
feedback, `check` is quick or specialized validation, and `gate` is the complete
Definition of Done for its target.

Production workstation helpers use the same entrypoint. Their implementation
lives in `tools/internal/infraops`; `infra/` contains the Terraform project and
the artifacts Terraform deploys, not a second command directory:

```sh
./run ops portal --help
./run ops database --help
./run ops drill pitr
```

`./run check infra-templates` uses the host `cloud-init` CLI when available.
On macOS it builds and reuses the digest-pinned `cloud-init/Dockerfile`
validator, so the same schema check works without adding Linux packages to the
workstation.

`./run urls` discovers the assigned URLs without reproducing Coop's hash.
The Keycloak CA and leaf files are created under `dev/keycloak/certs/generated/`.
On macOS, opt into browser trust once per workspace and remove it explicitly:

```sh
./run certs trust
./run certs status
./run certs untrust
```

Trust is limited to SSL for `localhost` in the user keychain and removal targets
the exact CA fingerprint, so parallel workspaces do not remove each other's
certificates. `./run certs --rotate` removes the old fingerprint and restores
trust only when it was already enabled. The automated browser uses an exception
for the exact leaf certificate SPKI, never a blanket TLS bypass. `./run doctor`
verifies services, browser trust on macOS, the exact OIDC issuer, and that
generated private keys remain ignored.

Setup, serve, and reset never seed implicitly. `./run seed` is idempotent;
`./run reset --seed` is the explicit destructive shortcut.

## Browser and screenshot tooling

`./run` owns the contributor commands; the chromedp implementation lives in the
shared `tools` Go module. The persistent browser is shared across captures for
the active workspace, including inside Coop:

```sh
./run browser start
./run shot /app/demo/runners --label before --shot runners
# edit; Phoenix reloads
./run shot /app/demo/runners --label after --shot runners
./run browser stop
```

`shot` accepts a stable `data-shot` name, a CSS selector, an exact heading, or a
class fragment as its crop anchor. Use `--width 390` for a mobile capture and
`--group <name>` for a task-local capture set. It writes into the sole
in-progress task's `screenshots/` directory; use `--task <id>` when several
tasks are active. With no active task, create and claim even a basic one before
capturing.

`./run capture docs` regenerates the cropped console screenshots embedded in
the documentation. `./run capture console` walks the signed-out and
authenticated console at desktop and mobile widths, writing the audit under the
active task's `screenshots/console-audit/` directory. Both require an active
seeded workspace and reuse the persistent browser. Documentation captures are
committed product assets, while console captures are disposable task evidence.
Automated Chromium allows only the active Keycloak leaf certificate's SPKI;
certificate validation is not disabled globally.

The same Go implementation carries the real Paddle sandbox browser driver,
exposed as `./run e2e billing`. Its ignored credentials remain in
`portal/.agent/secrets/paddle-sandbox.env`.

## `runners/`

One config file per docker-compose runner (`edge-fra-01.yaml`,
`api-iad-02.yaml`, `pg-primary-iad.yaml`), mounted into the development image
built from `dev/runner/Dockerfile`:

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
`/var/log/syslog`, etc. No development fixture is presented as a production
runner image.

## `test-packs/`

A standalone Compose **behavior harness** for action packs, separate from the
root demo stack. `./run` cross-builds the runner and Go harness, boots only the
disposable services declared by the selected packs, runs their semantic
behavior cases, writes per-pack logs, and tears the topology down:

```sh
./run test packs redis
./run test packs
```

The pack catalog (`packs/`) is mounted read-only at `/packs`; handwritten
plans live at `packs/<pack>/test/cases.yaml`. Exit-only cases and permanent
skips are rejected: omitted actions remain contract-tested and are reported
as contract-only. See `test-packs/README.md` for the schema.

## SSO end to end

`./run e2e sso` owns its Portal, PostgreSQL, and Keycloak lifecycle. It builds
the current Portal image, allocates isolated localhost ports, rewrites a
temporary Keycloak realm with the matching callback, seeds the database, runs
SCIM provision/deprovision behavior, and completes a real OIDC login. No
separate `./run serve` process is required, and cleanup removes the scenario's
containers, network, volumes, and temporary realm.

## `signing/`

End-to-end coverage for **signed dispatch** (the CA-issued-certificate feature)
against the root demo stack. Two profile-gated `test` services in
`docker-compose.yml` plus the `./run e2e signing` driver:

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
./run e2e signing
```

The host-side stdlib Go driver performs every
discovery and dispatch call through the bridge over the in-network
`portal:4000`, so signing happens exactly as on a real stdio client.
Each workspace gets an isolated Compose project with Docker-assigned host ports;
the driver removes its containers, network, and test volumes when it exits.
