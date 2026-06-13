# Dev-only fixtures & harnesses

Local-only development scaffolding for the docker-compose stacks — fixtures
for the root demo stack and the standalone pack-test harness. None of this
ships with production releases — the runner tarball produced by the release
workflow contains exactly the runner binary and its config skeleton.

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
