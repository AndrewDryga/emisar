# Emisar example packs

36 packs / ~500 actions covering Linux ops, web/proxy, databases,
container orchestration, cloud, message buses, runtimes, observability,
and infrastructure tools.

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
emisar pack validate examples/packs/postgres
```

---

## Auth model

Packs that talk to external systems (databases, cloud APIs, k8s, …)
authenticate via **environment variables on the runner host**. Per-call
credentials are never sent over the wire.

The runner does NOT auto-inherit OS env. You must allowlist any env vars
your packs need in the runner's `inherit_env` config:

```yaml
# /etc/emisar/config.yaml
inherit_env:
  - PATH
  - LANG
  # Postgres / Redis / MySQL
  - PGHOST
  - PGPORT
  - PGUSER
  - PGPASSWORD
  - PGDATABASE
  - REDISCLI_AUTH
  - REDIS_HOST
  - REDIS_PORT
  - MYSQL_PWD
  - MYSQL_HOST
  - MYSQL_USER
  # Kubernetes
  - KUBECONFIG
  # Elasticsearch
  - ELASTIC_URL
  - ELASTIC_USER
  - ELASTIC_PASSWORD
  # Kafka
  - KAFKA_BOOTSTRAP
  - KAFKA_COMMAND_CONFIG
  # MongoDB
  - MONGO_URI
  # AWS (uses standard SDK env vars)
  - AWS_PROFILE
  - AWS_REGION
  - AWS_DEFAULT_REGION
  # Vault
  - VAULT_ADDR
  - VAULT_TOKEN
  # Cloudflare
  - CF_API_TOKEN
  # Consul
  - CONSUL_HTTP_ADDR
  - CONSUL_HTTP_TOKEN
  # MinIO (per-alias)
  - MC_HOST_minio
  # HAProxy
  - HAPROXY_SOCK
  # ZooKeeper
  - ZK_SERVERS
  # Prometheus
  - PROM_URL
  # Apache HTTPD
  - HTTPD_STATUS_URL
  - HTTPD_ERROR_LOG
  - HTTPD_ACCESS_LOG
  # Terraform
  - TF_DIR
```

Only the env vars listed in `inherit_env` are passed to the executed
process. Anything not listed is dropped.

If an action documents an env var (e.g. `$PGPASSWORD`) but the operator
hasn't added it to `inherit_env`, the action will fail with whatever
error the underlying tool gives ("password authentication failed",
"connection refused", etc.).

---

## Pack inventory

| Pack | Actions | Risk profile | Auth env |
|---|---|---|---|
| `linux-core` | 34 | mostly low, 3 high mutators (systemctl), 1 critical (reboot) | — |
| `debugging` | 28 | all low (read-only diagnostics) | — |
| `kubernetes` | 31 | 22 low, 7 high mutators, 1 critical (drain) | `KUBECONFIG` |
| `docker` | 25 | 17 low, 4 high, 1 critical (volume_prune) | (docker group) |
| `mysql` | 25 | 19 low, 2 high (kill), 4 medium | `MYSQL_PWD` etc |
| `nginx` | 22 | 18 low, 2 high (reload, quit), 1 critical (stop_immediate) | — |
| `elasticsearch` | 21 | 16 low, 2 high (cache_clear, force_merge), 1 medium (flush_synced), 1 critical (close_index) | `ELASTIC_*` |
| `kafka` | 20 | 14 low, 3 high, 2 critical (reset_offsets) | `KAFKA_BOOTSTRAP` |
| `mongodb` | 20 | 19 low, 1 high (kill_op) | `MONGO_URI` |
| `systemd-deep` | 15 | 14 low, 1 high (vacuum_journal) | — |
| `java-jvm` | 15 | 13 low, 1 medium (jfr_start), 1 critical (heap_dump) | (uid match) |
| `rabbitmq` | 15 | 13 low, 1 high (close_connection), 1 critical (purge_queue) | — |
| `github-cli` | 15 | all low (read-only) | (gh's stored token) |
| `nodejs-pm2` | 15 | 10 low, 4 high (restart/reload/stop/scale), 1 medium | (uid match) |
| `network-tls` | 13 | all low | — |
| `vault` | 12 | 10 low, 1 high (revoke_lease), 1 critical (step_down) | `VAULT_*` |
| `haproxy` | 12 | 9 low, 2 high (enable/disable), 1 medium (set_maxconn) | `HAPROXY_SOCK` |
| `aws-ec2` | 11 | 7 low, 3 high (stop/start/reboot), 1 critical (terminate) | `AWS_*` |
| `consul` | 11 | 9 low, 2 high (deregister, maint) | `CONSUL_*` |
| `cloudflare` | 11 | 8 low, 1 medium, 1 high, 1 critical (purge_all) | `CF_API_TOKEN` |
| `minio` | 10 | 7 low, 2 high (user enable/disable), 1 medium (heal) | `MC_HOST_*` |
| `prometheus` | 10 | all low | `PROM_URL` |
| `redis` | 10 | 8 low, 1 high (client_kill), 1 critical (flush_db) | `REDIS_*` |
| `postgres` | 10 | 7 low, 3 high | `PG*` |
| `apache-httpd` | 10 | 8 low, 1 high (graceful_reload), 1 critical (graceful_stop) | (HTTPD_*) |
| `debian` | 9 | 4 low, 1 medium, 4 high (apt mutators) | — |
| `zfs` | 9 | 7 low, 1 medium (snapshot), 1 high (scrub) | — |
| `zookeeper` | 8 | all low | — |
| `aws-iam` | 8 | all low (read-only) | `AWS_*` |
| `aws-s3` | 8 | all low (read-only) | `AWS_*` |
| `aws-rds` | 8 | 6 low, 2 high (reboot, snapshot) | `AWS_*` |
| `terraform-readonly` | 8 | 7 low, 1 medium (plan) | `TF_DIR` |
| `aws-cloudwatch` | 7 | all low | `AWS_*` |
| `cassandra` | 6 | 5 low, 1 high (repair) | (JMX) |
| `aws-cost` | 5 | all low | `AWS_*` (`ce:*` perms) |
| `showcase` | 5 | reference pack, not for production | — |

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
is `pack.yaml` + one action YAML. Action IDs are `<pack-id>.<action>`
(lowercase, dot-separated).

For dangerous operations, write `side_effects:` honestly. The runner
surfaces it to LLMs and to the approval UI; misleading copy here
defeats the safety story.
