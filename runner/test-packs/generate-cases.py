#!/usr/bin/env python3
"""
Generate test/cases.yaml for every pack from its actions/*.yaml files.

Strategy:
- One case per action.
- Args derived from the action's first example (if present), else from each
  required arg's default value or a generated safe default.
- Read-only actions: expect_exit 0.
- Risk: medium/high/critical mutators get a `skip:` note unless they're
  idempotent or the pack-specific overrides list whitelists them.
- Per-pack overrides in this file customize: skip-by-action,
  expect-stdout substrings, env extras, etc.
"""

import os
import re
import sys
import yaml
from pathlib import Path

ROOT = Path(__file__).parent.parent / "examples" / "packs"
OUT_FILE = "test/cases.yaml"

# --- Per-pack policy --------------------------------------------------------
# Most defaults are sensible; tweak per-pack where the harness needs help.

PACK_ENV = {
    "postgres": {"PGHOST": "postgres", "PGUSER": "postgres", "PGPASSWORD": "testpass", "PGDATABASE": "testdb"},
    "mysql":    {"MYSQL_HOST": "mysql", "MYSQL_USER": "root", "MYSQL_PWD": "testpass"},
    "redis":    {"REDIS_HOST": "redis"},
    "mongodb":  {"MONGO_URI": "mongodb://root:testpass@mongodb:27017/?authSource=admin"},
    "cassandra":{"CQLSH_HOST": "cassandra"},
    "clickhouse":{"CH_HOST": "clickhouse", "CH_USER": "default"},
    "elasticsearch":{"ELASTIC_USER":"elastic","ELASTIC_PASSWORD":"testpass","ES_URL":"http://elasticsearch:9200"},
    "consul":   {"CONSUL_HTTP_ADDR": "http://consul:8500"},
    "vault":    {"VAULT_ADDR": "http://vault:8200", "VAULT_TOKEN": "test-root-token"},
    "nomad":    {"NOMAD_ADDR": "http://nomad:4646"},
    "prometheus":{"PROM_URL":"http://prometheus:9090"},
    "envoy":    {"ENVOY_ADMIN": "http://envoy:9901"},
    "caddy":    {"CADDY_ADMIN": "http://caddy:2019"},
    "rabbitmq": {},
    "kafka":    {"KAFKA_BOOTSTRAP": "kafka:9092"},
    "memcached":{"MC_HOST":"memcached","MC_PORT":"11211"},
    "minio":    {"MC_HOST_local": "http://minio_admin:testpass@minio:9000"},
    "grafana":  {"GRAFANA_URL":"http://grafana:3000","GRAFANA_USER":"admin","GRAFANA_PASS":"testpass"},
}

# Actions whose mutators can run repeatedly without harming anything.
# Other mutators (risk >= high) are skipped by default.
SAFE_MUTATORS = {
    # idempotent
    "redis.config_resetstat", "redis.memory_purge", "redis.script_flush",
    "redis.config_set",  # we set a benign param in cases override
    "postgres.analyze_table", "postgres.vacuum_table",
    "mysql.flush_logs", "mysql.flush_status", "mysql.analyze_table",
    "mongo.kill_op",  # killing nonexistent op is fine
    "ch.system_flush_logs", "ch.optimize_table",
    "es.cache_clear", "es.flush_synced",
    "consul.reload",
    "rmq.sync_queue",
    "systemd.daemon_reload", "systemd.reset_failed",
    "f2b.reload",
    "nginx.test_config", "nginx.reload",
    "caddy.validate", "caddy.reload_config",
    "httpd.test_config", "httpd.graceful_reload",
    "prom.reload_config", "prom.snapshot", "prom.clean_tombstones",
    "envoy.reset_counters", "envoy.healthcheck_ok", "envoy.healthcheck_fail", "envoy.drain_listeners",
    "postfix.reload",
    "zfs.start_scrub", "zfs.scrub_stop",
    "time.chronyc_makestep", "time.timedatectl_set_ntp",
    "dnf.dnf_clean_metadata",
    "rpm.dnf_clean_metadata",
}

# Per-action arg overrides (when example arg would touch real data badly).
ACTION_ARGS = {
    "redis.config_set":       {"parameter": "tcp-keepalive", "value": "60"},
    "redis.cluster_failover": {"mode": ""},  # would fail outside cluster; expect non-zero
    "redis.flush_db":         {"db": 1, "mode": "ASYNC"},  # never default DB 0
    "redis.flushall":         None,  # skip — would wipe SUT
    "redis.shutdown_nosave":  None,  # skip — kills SUT
    "redis.swapdb":           {"i": 14, "j": 15},
    "redis.replicaof":        None,  # would change topology
    "redis.cluster_forget":   None,
    "redis.client_pause":     {"ms": 100},
    "redis.client_kill":      None,  # need a real client addr
    "redis.scan":             {"cursor": "0", "match": "*", "count": 100},

    "postgres.pg_terminate":  None,
    "postgres.kill_pid":      None,
    "postgres.drop_role":     None,
    "postgres.create_role":   None,

    "mysql.kill_query":       None,
    "mysql.kill_connection":  None,
    "mysql.optimize_table":   None,  # needs an existing table

    "mongo.replset_stepdown": None,
    "mongo.compact_collection": None,
    "mongo.drop_index":       None,

    "vault.operator_seal":    None,  # locks SUT
    "vault.lease_revoke_prefix": None,
    "vault.operator_step_down": None,
    "vault.revoke_lease":     None,

    "consul.snapshot_restore": None,
    "consul.raft_remove_peer": None,
    "consul.deregister_service": None,
    "consul.force_check_fail": None,
    "consul.force_check_pass": None,
    "consul.force_check_warn": None,
    "consul.destroy_session":  None,
    "consul.node_maintenance": None,
    "consul.service_maintenance": None,

    "kafka.reset_offsets_to_earliest": None,
    "kafka.reset_offsets_to_latest":   None,
    "kafka.delete_consumer_group":     None,
    "kafka.alter_topic_retention":     None,
    "kafka.preferred_leader_election": None,

    "ch.system_drop_replica":   None,
    "ch.system_restart_replica": None,
    "ch.system_sync_replica":   None,
    "ch.kill_query":            None,

    "docker.kill":           None,
    "docker.restart":        None,
    "docker.stop":           None,
    "docker.system_prune":   None,
    "docker.volume_prune":   None,
    "docker.compose_restart": None,
    "docker.pull_image":     {"image": "busybox:1.36"},

    "podman.kill":           None,
    "podman.stop":           None,
    "podman.restart":        None,
    "podman.system_prune":   None,

    "kubernetes.delete_pod":    None,
    "kubernetes.cordon":        None,
    "kubernetes.uncordon":      None,
    "kubernetes.drain":         None,
    "kubernetes.rollout_undo":  None,
    "kubernetes.rollout_restart": None,
    "kubernetes.set_image":     None,
    "kubernetes.scale_deployment": None,

    "iam.deactivate_access_key": None,
    "iam.delete_access_key":     None,
    "iam.detach_user_policy":    None,

    "ec2.stop_instance":      None,
    "ec2.start_instance":     None,
    "ec2.reboot_instance":    None,
    "ec2.terminate_instance": None,

    "rds.reboot_instance":  None,
    "rds.create_snapshot":  None,

    "systemd.unit_restart": None,
    "systemd.unit_reload":  None,
    "systemd.unit_stop":    None,
    "systemd.unit_start":   None,
    "systemd.unit_kill":    None,
    "systemd.unit_mask":    None,
    "systemd.unit_unmask":  None,

    "rmq.stop_app":         None,
    "rmq.start_app":        None,
    "rmq.purge_queue":      None,
    "rmq.close_connection": None,

    "fw.iptables_block_ip":   None,
    "fw.iptables_unblock_ip": None,
    "fw.iptables_flush_chain": None,

    "f2b.banip":          None,
    "f2b.unban_ip":       None,
    "f2b.banip_remove":   None,

    "bind.rndc_freeze":  None,
    "bind.rndc_thaw":    None,
    "bind.rndc_reload":  None,
    "bind.rndc_flush":   None,

    "postfix.delete_qid":          None,
    "postfix.flush_queue":         None,
    "postfix.postsuper_hold":      None,
    "postfix.postsuper_release":   None,
    "postfix.postsuper_requeue":   None,

    "zfs.clear_pool_errors": None,
    "zfs.snapshot_destroy":  None,
    "zfs.dataset_rollback":  None,

    "minio.user_disable":   None,
    "minio.user_enable":    None,
    "minio.heal_bucket":    None,
    "minio.service_restart": None,

    "gh.pr_merge":            None,
    "gh.pr_close":            None,
    "gh.workflow_rerun":      None,
    "gh.workflow_dispatch":   None,

    "pm2.restart": None,
    "pm2.reload":  None,
    "pm2.scale":   None,
    "pm2.stop":    None,
    "pm2.flush_logs": None,

    "wg.quick_up":         None,
    "wg.quick_down":       None,
    "wg.set_peer_remove":  None,

    "debugging.kill_pid":       None,
    "debugging.sysctl_set":     None,
    "debugging.drop_caches":    None,

    "nginx.stop_immediate":     None,
    "nginx.quit_graceful":      None,

    "caddy.stop":               None,

    "linux.kill_pid":           None,
    "linux.restart_unit":       None,
    "linux.start_unit":         None,
    "linux.stop_unit":          None,

    "git.checkout_ref":         None,
    "git.reset_hard":           None,

    "apt.apt_install":          None,
    "apt.apt_remove":           None,
    "apt.apt_purge":            None,
    "apt.apt_update":           None,
    "apt.apt_upgrade":          None,

    "dnf.dnf_install":          None,
    "dnf.dnf_remove":           None,
    "dnf.upgrade_pkg":          None,
    "dnf.reinstall_pkg":        None,
    "dnf.autoremove":           None,
}


def safe_default(arg):
    """Return a reasonable default literal for one arg schema."""
    name = arg.get("name", "")
    typ = arg.get("type", "string")
    default = arg.get("default", None)
    if default is not None:
        return default

    if typ == "integer":
        # PIDs / port / minute defaults
        if name in ("pid",): return 1
        if name in ("port",): return 80
        if name in ("limit","count","top","n","max"): return 10
        return 0
    if typ == "boolean":
        return False

    # string fallback
    val = arg.get("validation", {})
    enum = val.get("enum", [])
    if enum:
        return enum[0]
    pattern = val.get("pattern", "")
    if "^/" in pattern:
        return "/etc/hostname"
    return "smoke"


def derive_args(action_def):
    """Pick args for one test case from the action definition."""
    args = action_def.get("args", []) or []
    examples = action_def.get("examples", []) or []
    if examples:
        ex = examples[0].get("args", {}) or {}
        # fill missing required args
        for a in args:
            if a.get("required") and a["name"] not in ex:
                ex[a["name"]] = safe_default(a)
        return ex
    return {a["name"]: safe_default(a) for a in args if a.get("required") or a.get("default") is not None}


def emit_pack(pack_dir):
    pack_id = pack_dir.name
    actions_dir = pack_dir / "actions"
    if not actions_dir.is_dir():
        return None
    case_list = []
    for af in sorted(actions_dir.glob("*.yaml")):
        with open(af) as fh:
            try:
                a = yaml.safe_load(fh)
            except yaml.YAMLError as e:
                print(f"WARN: {af}: yaml parse error: {e}", file=sys.stderr)
                continue
        aid = a.get("id")
        if not aid:
            continue
        risk = a.get("risk", "low")
        case = {"action": aid}
        # Args override
        if aid in ACTION_ARGS:
            override = ACTION_ARGS[aid]
            if override is None:
                case["args"] = derive_args(a)
                case["skip"] = f"mutator skipped by default ({risk}); set --include={aid} to run"
                case_list.append(case)
                continue
            else:
                case["args"] = override
        else:
            case["args"] = derive_args(a)

        # Read-only baseline: expect exit 0
        if risk == "low":
            case["expect_exit"] = 0
        elif aid in SAFE_MUTATORS:
            case["expect_exit"] = 0
        else:
            case["expect_exit"] = [0, 1]  # accept either since precondition fragile
            case["skip"] = f"mutator skipped by default ({risk})"
        case_list.append(case)

    env = PACK_ENV.get(pack_id, {})
    return {"defaults": {"env": env} if env else {"env": {}}, "cases": case_list}


def main():
    n_packs = 0
    n_cases = 0
    for pack_dir in sorted(ROOT.iterdir()):
        if not (pack_dir / "pack.yaml").exists():
            continue
        result = emit_pack(pack_dir)
        if result is None:
            continue
        out = pack_dir / OUT_FILE
        out.parent.mkdir(exist_ok=True)
        with open(out, "w") as fh:
            yaml.dump(result, fh, sort_keys=False, default_flow_style=False, width=200)
        n_packs += 1
        n_cases += len(result["cases"])
        print(f"{pack_dir.name}: {len(result['cases'])} cases", file=sys.stderr)
    print(f"\nTotal: {n_packs} packs, {n_cases} cases", file=sys.stderr)


if __name__ == "__main__":
    main()
