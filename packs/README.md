# Emisar example packs

80 packs / 1,269 actions covering Linux ops, web/proxy, databases,
container orchestration, cloud, message buses, runtimes, observability,
networking, storage, and infrastructure tools.

Each pack is independent: a `pack.yaml` manifest + one YAML per action
under `actions/`. Load a pack into a runner by pointing the runner config
at the directory:

```yaml
packs:
  - /opt/emisar/packs/postgres
  - /opt/emisar/packs/linux-core
```

Validate locally:

```sh
emisar pack validate packs/postgres
```

---

## Auth model

Packs don't carry credentials. An action names a binary and arguments;
the tool it runs (psql, aws, kubectl, …) reads its own target and
credentials from the **runner host's environment**. Per-call credentials
are never sent over the wire from the control plane.

Two things make a pack work, both on the runner host:

1. **Provide the credentials.** Set the env vars the pack's tool reads —
   or use its config file (`~/.pgpass`, `~/.aws/credentials`, a kubeconfig),
   which is read from disk and needs no allowlisting.
2. **Allowlist them.** The runner does NOT inherit the host environment.
   Add each var to `inherit_env` or the runner drops it before exec:

   ```yaml
   # /etc/emisar/config.yaml
   inherit_env: [PATH, LANG, PGHOST, PGUSER, PGPASSWORD]
   ```

   If a documented var is missing from `inherit_env`, the action fails
   with whatever the tool reports ("password authentication failed",
   "connection refused", …).

**Each pack documents its own setup** in a `setup:` block — the env vars
it reads, file-based alternatives, required privileges, and a low-risk
action to verify it works. `emisar pack install` prints this after
installing; re-read it any time:

```sh
emisar pack info postgres   # full setup; also flags vars missing from inherit_env once config is found
```

In the inventory below, the **Auth** column is the short form: `PG*` =
"the PG* env vars"; `local-host` = acts on the runner machine, no
credentials; `(opt)` = the vars are optional (the tool has a working
default — a config file or localhost).

---

## Pack inventory

80 packs, 1,269 actions, sorted by id. **Risk** is the pack's ceiling —
its highest-risk action (see tiers below). **Auth** legend is in the Auth
model section above. Run `emisar pack info <id>` for a pack's full setup.

| Pack | Actions | Risk | Auth |
|---|---|---|---|
| `apache-httpd` | 10 | critical | HTTPD_* (opt) |
| `aws-cloudwatch` | 7 | low | AWS_* |
| `aws-cost` | 5 | low | AWS_* (opt) |
| `aws-ec2` | 11 | critical | AWS_* |
| `aws-iam` | 11 | critical | AWS_* (opt) |
| `aws-rds` | 8 | high | AWS_* |
| `aws-s3` | 8 | low | AWS_* (opt) |
| `bind` | 11 | high | local-host |
| `bonding` | 3 | low | local-host |
| `caddy` | 10 | high | CADDY_* (opt) |
| `cassandra` | 45 | critical | CQLSH_* (opt) |
| `clickhouse` | 31 | critical | CH_* (opt) |
| `cloud-init` | 23 | critical | local-host |
| `cloudflare` | 11 | critical | CF_API_TOKEN |
| `cockroach` | 25 | high | COCKROACH_URL |
| `consul` | 44 | critical | CONSUL_HTTP_* (opt) |
| `debian` | 9 | high | local-host |
| `debugging` | 31 | high | local-host |
| `dell-idrac` | 15 | critical | IDRAC_* |
| `dell-ipmi` | 15 | critical | IPMI_* |
| `dnf-rpm` | 13 | high | local-host |
| `docker` | 25 | critical | local-host |
| `elasticsearch` | 21 | critical | ELASTIC_* |
| `elixir-beam` | 25 | high | ELIXIR_RELEASE_CTL (opt) |
| `envoy` | 14 | high | ENVOY_ADMIN (opt) |
| `fail2ban` | 8 | high | local-host |
| `firewall` | 11 | critical | local-host |
| `frr` | 5 | low | local-host |
| `fs-search` | 15 | low | local-host |
| `git-local` | 8 | low | GIT_REPO |
| `github-cli` | 19 | high | GH_TOKEN (opt) |
| `grafana` | 10 | low | GRAFANA_* |
| `haproxy` | 12 | high | HAPROXY_SOCK |
| `iperf3` | 4 | medium | local-host |
| `iscsi` | 4 | low | local-host |
| `java-jvm` | 16 | critical | local-host |
| `kafka` | 20 | critical | KAFKA_BOOTSTRAP |
| `kubernetes` | 43 | critical | KUBECONFIG (opt) |
| `linux-core` | 34 | critical | local-host |
| `memcached` | 7 | critical | MEMCACHED_* (opt) |
| `minio` | 12 | high | MC_HOST_minio |
| `mongodb` | 35 | critical | MONGO_URI |
| `multipath` | 4 | low | local-host |
| `mysql` | 25 | high | MYSQL_* (opt) |
| `network-tls` | 13 | low | local-host |
| `nfs` | 9 | high | local-host |
| `nginx` | 22 | critical | local-host |
| `nic` | 6 | low | local-host |
| `nodejs-pm2` | 15 | high | local-host |
| `nomad` | 49 | critical | NOMAD_* (opt) |
| `pfsense` | 29 | critical | PFSENSE_* |
| `php-fpm` | 10 | low | PHP_FPM_STATUS_URL (opt) |
| `podman` | 12 | high | local-host |
| `postfix` | 14 | critical | local-host |
| `postgres` | 48 | high | PG* |
| `process-forensics` | 10 | high | local-host |
| `prometheus` | 14 | high | PROM_URL |
| `pure-flasharray` | 14 | low | PURE_* (opt) |
| `python-app` | 10 | low | PY_VENV (opt) |
| `rabbitmq` | 18 | critical | local-host |
| `redis` | 59 | critical | REDISCLI_AUTH (opt) |
| `rke2` | 5 | low | local-host |
| `shell` ⚠️ | 1 | critical | local-host |
| `showcase` | 5 | low | local-host |
| `snmp` | 7 | low | SNMP_* |
| `ssl-local` | 7 | low | local-host |
| `systemd-deep` | 24 | high | local-host |
| `tailscale` | 9 | low | local-host |
| `terraform-readonly` | 8 | medium | TF_DIR |
| `time-sync` | 7 | high | local-host |
| `traefik` | 16 | low | TRAEFIK_* (opt) |
| `typesense` | 8 | low | TYPESENSE_* (opt) |
| `vault` | 14 | critical | VAULT_* |
| `vector` | 7 | low | VECTOR_API (opt) |
| `victorialogs` | 7 | low | VL_* (opt) |
| `victoriametrics` | 8 | low | VM_* (opt) |
| `wireguard` | 8 | high | local-host |
| `zfs` | 13 | critical | local-host |
| `zookeeper` | 8 | low | local-host |
| `zot` | 7 | low | ZOT_* (opt) |

> ⚠️ **`shell` is a staging-only break-glass pack** — its one action runs an
> arbitrary `/bin/sh` script on the host, bypassing the declared-action
> model. Install it only on staging runners used to verify fixes; never in
> production. It is critical-risk (denied by default policy) and ships with
> no `detect:` block, so it is never auto-suggested. See
> [`shell/README.md`](shell/README.md).

---

## Risk tiers

| Tier | Meaning | Examples |
|---|---|---|
| `low` | Read-only or near-zero impact | `df`, `nodetool status`, `SELECT version()`, `cat /proc/…` |
| `medium` | Mutates state with limited blast radius; reversible | `apt-get update`, `JFR.start`, `set maxconn`, `mysql flush_logs` |
| `high` | Production-affecting; user-visible impact | `systemctl restart`, `docker restart`, `kubectl scale`, `kill_query` |
| `critical` | Hard to undo or wide blast | `reboot`, `terminate-instances`, `FLUSHDB`, `purge_queue`, `drain` |

A pack's effective ceiling is set by the action it includes — every pack
above lists its max tier. Use runner-side **admission allowlists** to
hide tiers you don't want (e.g., allow only `low + medium` on
production runners).

---

## Authoring a new pack

Start from `showcase/` — it exercises every schema feature. The minimum
is `pack.yaml` + one action YAML. Action IDs are `<ns>.<action>`
(lowercase, dot-separated).

Add a `setup:` block to `pack.yaml` so operators know how to make the
pack work. It renders on `pack install` and `pack info`:

```yaml
setup:
  summary: >
    One or two sentences on how this pack authenticates.
  env:                        # omit for a pack that needs no credentials
    - name: SOME_TOKEN
      required: true
      description: What the tool reads it for.
      example: abc123         # or: default: "5432"
  notes:                      # non-obvious caveats only
    - File-based alternative, required privilege, or token scope.
  verify: <pack>.<read_action>  # a low-risk read; the loader checks it exists
```

Document only env vars the tool actually reads — verify against the
binary/argv, don't assume. For dangerous operations, write
`side_effects:` honestly: the runner surfaces it to LLMs and to the
approval UI, and misleading copy here defeats the safety story.
