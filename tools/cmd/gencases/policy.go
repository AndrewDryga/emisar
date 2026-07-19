package main

// The test-case policy tables. These are judgment calls, not derivations:
// which SUT env each pack's cases run under, which mutators are safe to
// exercise repeatedly, and which actions need hand-picked (or no) args
// because their example would harm the SUT.

// packEnv is the defaults.env block per pack — the docker-compose SUT
// endpoints/credentials (dev/test-packs/docker-compose.yaml).
var packEnv = map[string]map[string]string{
	"postgres":      {"PGHOST": "postgres", "PGUSER": "postgres", "PGPASSWORD": "testpass", "PGDATABASE": "testdb"},
	"mysql":         {"MYSQL_HOST": "mysql", "MYSQL_USER": "root", "MYSQL_PWD": "testpass"},
	"redis":         {"REDIS_HOST": "redis"},
	"mongodb":       {"MONGO_URI": "mongodb://root:testpass@mongodb:27017/?authSource=admin"},
	"cassandra":     {"CQLSH_HOST": "cassandra"},
	"clickhouse":    {"CH_HOST": "clickhouse", "CH_USER": "default"},
	"elasticsearch": {"ELASTIC_USER": "elastic", "ELASTIC_PASSWORD": "testpass", "ELASTIC_URL": "http://elasticsearch:9200"},
	"consul":        {"CONSUL_HTTP_ADDR": "http://consul:8500"},
	"vault":         {"VAULT_ADDR": "http://vault:8200", "VAULT_TOKEN": "test-root-token"},
	"nomad":         {"NOMAD_ADDR": "http://nomad:4646"},
	"prometheus":    {"PROM_URL": "http://prometheus:9090"},
	"envoy":         {"ENVOY_ADMIN": "http://envoy:9901"},
	"caddy":         {"CADDY_ADMIN": "http://caddy:2019"},
	"rabbitmq":      {},
	"kafka":         {"KAFKA_BOOTSTRAP": "kafka:9092"},
	"memcached":     {"MC_HOST": "memcached", "MC_PORT": "11211"},
	"minio":         {"MC_HOST_local": "http://minio_admin:testpass@minio:9000"},
	"grafana":       {"GRAFANA_URL": "http://grafana:3000", "GRAFANA_USER": "admin", "GRAFANA_PASS": "testpass"},
}

// stdoutAssertions reject successful commands that returned an empty or
// semantically unrelated response. Keep needles stable across supported
// upstream versions.
var stdoutAssertions = map[string][]string{
	"nomad.operator_autopilot_state": {`"Healthy"`},
}

// safeMutators are actions whose mutations can run repeatedly without harming
// the SUT (idempotent or self-healing). Other mutators are skipped by default.
var safeMutators = map[string]bool{
	"redis.config_resetstat": true, "redis.memory_purge": true, "redis.script_flush": true,
	"redis.config_set":       true, // we set a benign param in the cases override
	"postgres.analyze_table": true, "postgres.vacuum_table": true,
	"mysql.flush_logs": true, "mysql.flush_status": true, "mysql.analyze_table": true,
	"mongo.kill_op":        true, // killing a nonexistent op is fine
	"ch.system_flush_logs": true, "ch.optimize_table": true,
	"es.cache_clear": true, "es.flush_synced": true,
	"consul.reload":         true,
	"rmq.sync_queue":        true,
	"systemd.daemon_reload": true, "systemd.reset_failed": true,
	"f2b.reload":        true,
	"nginx.test_config": true, "nginx.reload": true,
	"caddy.validate": true, "caddy.reload_config": true,
	"httpd.test_config": true, "httpd.graceful_reload": true,
	"prom.reload_config": true, "prom.snapshot": true, "prom.clean_tombstones": true,
	"envoy.reset_counters": true, "envoy.healthcheck_ok": true, "envoy.healthcheck_fail": true, "envoy.drain_listeners": true,
	"postfix.reload":        true,
	"zfs.start_scrub":       true,
	"zfs.scrub_stop":        true,
	"time.chronyc_makestep": true, "time.timedatectl_set_ntp": true,
	"dnf.dnf_clean_metadata": true,
	"rpm.dnf_clean_metadata": true,
}

// actionArgs holds per-action arg overrides for cases whose example args
// would touch real data badly. A nil value means "generate the case but skip
// it by default" (the mutation is unsafe against the shared SUT).
var actionArgs = map[string]map[string]any{
	"redis.config_set":       {"parameter": "tcp-keepalive", "value": "60"},
	"redis.cluster_failover": {"mode": ""},               // fails outside a cluster; expect non-zero
	"redis.flush_db":         {"db": 1, "mode": "ASYNC"}, // never default DB 0
	"redis.flushall":         nil,                        // would wipe the SUT
	"redis.shutdown_nosave":  nil,                        // kills the SUT
	"redis.swapdb":           {"i": 14, "j": 15},
	"redis.replicaof":        nil, // would change topology
	"redis.cluster_forget":   nil,
	"redis.client_pause":     {"ms": 100},
	"redis.client_kill":      nil, // needs a real client addr
	"redis.scan":             {"cursor": "0", "match": "*", "count": 100},

	"postgres.pg_terminate": nil,
	"postgres.kill_pid":     nil,
	"postgres.drop_role":    nil,
	"postgres.create_role":  nil,

	"mysql.kill_query":      nil,
	"mysql.kill_connection": nil,
	"mysql.optimize_table":  nil, // needs an existing table

	"mongo.replset_stepdown":   nil,
	"mongo.compact_collection": nil,
	"mongo.drop_index":         nil,

	"vault.operator_seal":       nil, // locks the SUT
	"vault.lease_revoke_prefix": nil,
	"vault.operator_step_down":  nil,
	"vault.revoke_lease":        nil,

	"consul.snapshot_restore":    nil,
	"consul.raft_remove_peer":    nil,
	"consul.deregister_service":  nil,
	"consul.force_check_fail":    nil,
	"consul.force_check_pass":    nil,
	"consul.force_check_warn":    nil,
	"consul.destroy_session":     nil,
	"consul.node_maintenance":    nil,
	"consul.service_maintenance": nil,

	"kafka.reset_offsets_to_earliest": nil,
	"kafka.reset_offsets_to_latest":   nil,
	"kafka.delete_consumer_group":     nil,
	"kafka.alter_topic_retention":     nil,
	"kafka.preferred_leader_election": nil,

	"ch.system_drop_replica":    nil,
	"ch.system_restart_replica": nil,
	"ch.system_sync_replica":    nil,
	"ch.kill_query":             nil,

	"docker.kill":            nil,
	"docker.restart":         nil,
	"docker.stop":            nil,
	"docker.system_prune":    nil,
	"docker.volume_prune":    nil,
	"docker.compose_restart": nil,
	"docker.pull_image":      {"image": "busybox:1.36"},

	"podman.kill":         nil,
	"podman.stop":         nil,
	"podman.restart":      nil,
	"podman.system_prune": nil,

	"kubernetes.delete_pod":       nil,
	"kubernetes.cordon":           nil,
	"kubernetes.uncordon":         nil,
	"kubernetes.drain":            nil,
	"kubernetes.rollout_undo":     nil,
	"kubernetes.rollout_restart":  nil,
	"kubernetes.set_image":        nil,
	"kubernetes.scale_deployment": nil,

	"iam.deactivate_access_key": nil,
	"iam.delete_access_key":     nil,
	"iam.detach_user_policy":    nil,

	"ec2.stop_instance":      nil,
	"ec2.start_instance":     nil,
	"ec2.reboot_instance":    nil,
	"ec2.terminate_instance": nil,

	"rds.reboot_instance": nil,
	"rds.create_snapshot": nil,

	"systemd.unit_restart": nil,
	"systemd.unit_reload":  nil,
	"systemd.unit_stop":    nil,
	"systemd.unit_start":   nil,
	"systemd.unit_kill":    nil,
	"systemd.unit_mask":    nil,
	"systemd.unit_unmask":  nil,

	"rmq.stop_app":         nil,
	"rmq.start_app":        nil,
	"rmq.purge_queue":      nil,
	"rmq.close_connection": nil,

	"fw.iptables_block_ip":    nil,
	"fw.iptables_unblock_ip":  nil,
	"fw.iptables_flush_chain": nil,

	"f2b.banip":        nil,
	"f2b.unban_ip":     nil,
	"f2b.banip_remove": nil,

	"bind.rndc_freeze": nil,
	"bind.rndc_thaw":   nil,
	"bind.rndc_reload": nil,
	"bind.rndc_flush":  nil,

	"postfix.delete_qid":        nil,
	"postfix.flush_queue":       nil,
	"postfix.postsuper_hold":    nil,
	"postfix.postsuper_release": nil,
	"postfix.postsuper_requeue": nil,

	"zfs.clear_pool_errors": nil,
	"zfs.snapshot_destroy":  nil,
	"zfs.dataset_rollback":  nil,

	"minio.user_disable":    nil,
	"minio.user_enable":     nil,
	"minio.heal_bucket":     nil,
	"minio.service_restart": nil,

	"gh.pr_merge":          nil,
	"gh.pr_close":          nil,
	"gh.workflow_rerun":    nil,
	"gh.workflow_dispatch": nil,

	"pm2.restart":    nil,
	"pm2.reload":     nil,
	"pm2.scale":      nil,
	"pm2.stop":       nil,
	"pm2.flush_logs": nil,

	"wg.quick_up":        nil,
	"wg.quick_down":      nil,
	"wg.set_peer_remove": nil,

	"debugging.kill_pid":    nil,
	"debugging.sysctl_set":  nil,
	"debugging.drop_caches": nil,

	"nginx.stop_immediate": nil,
	"nginx.quit_graceful":  nil,

	"caddy.stop": nil,

	"linux.kill_pid":     nil,
	"linux.restart_unit": nil,
	"linux.start_unit":   nil,
	"linux.stop_unit":    nil,

	"git.checkout_ref": nil,
	"git.reset_hard":   nil,

	"apt.apt_install": nil,
	"apt.apt_remove":  nil,
	"apt.apt_purge":   nil,
	"apt.apt_update":  nil,
	"apt.apt_upgrade": nil,

	"dnf.dnf_install":   nil,
	"dnf.dnf_remove":    nil,
	"dnf.upgrade_pkg":   nil,
	"dnf.reinstall_pkg": nil,
	"dnf.autoremove":    nil,
}
