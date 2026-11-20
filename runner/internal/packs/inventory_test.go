package packs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// repoPacksDir resolves the real pack library at the repo root
// (../../../packs from runner/internal/packs). The library is a required
// fixture: runner tests run from the monorepo, so a missing tree fails the
// test rather than silently skipping the security contracts that load it.
func repoPacksDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "packs"))
	if err != nil {
		t.Fatalf("resolve packs dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "AGENTS.md")); err != nil {
		t.Fatalf("real pack library not found at %s: %v", dir, err)
	}
	return dir
}

// loadRealLibrary loads the entire pack library through the production loader.
func loadRealLibrary(t *testing.T) *Registry {
	t.Helper()
	reg, err := LoadAll([]string{repoPacksDir(t)}, LoadOptions{})
	if err != nil {
		t.Fatalf("the whole pack library must load clean through the production loader: %v", err)
	}
	return reg
}

// the risk distribution across the WHOLE library is a smoke test for the
// catalog shape, not a hardcoded inventory snapshot. The published release
// inventory lives behind the portal's /packs.json registry; this test only
// loads the checkout's pack YAML through the production runner loader and
// asserts the broad safety profile we expect.
func TestLibrary_RiskDistribution(t *testing.T) {
	reg := loadRealLibrary(t)
	actions := reg.Actions()

	counts := map[actionspec.Risk]int{}
	for _, a := range actions {
		counts[a.Risk]++
	}

	if len(actions) == 0 {
		t.Fatal("expected the real pack library to contain actions")
	}

	// No action carries a risk outside the four valid levels — every action
	// validated, so this also confirms the loader rejected any bad enum.
	if sum := counts[actionspec.RiskLow] + counts[actionspec.RiskMedium] + counts[actionspec.RiskHigh] + counts[actionspec.RiskCritical]; sum != len(actions) {
		t.Errorf("risk levels sum to %d but there are %d actions — an unexpected risk value slipped in", sum, len(actions))
	}

	// The qualitative invariant the numbers encode: read-only ≫ medium, and
	// the destructive tiers are non-empty.
	if counts[actionspec.RiskLow] <= counts[actionspec.RiskMedium] {
		t.Errorf("expected low (%d) ≫ medium (%d) — the catalog must be read-heavy", counts[actionspec.RiskLow], counts[actionspec.RiskMedium])
	}
	if counts[actionspec.RiskHigh] == 0 || counts[actionspec.RiskCritical] == 0 {
		t.Errorf("expected both high (%d) and critical (%d) tiers to be present", counts[actionspec.RiskHigh], counts[actionspec.RiskCritical])
	}
}

// The genuinely destructive actions each inventory category names MUST carry
// the high/critical risk the policy gate depends on. A silent downgrade of one
// of these to a lower tier would bypass approval; this pins the label to the
// real action YAML loaded from disk.
func TestLibrary_NamedDestructiveActionRisk(t *testing.T) {
	reg := loadRealLibrary(t)

	// id -> expected risk, sampled by name across the inventory categories.
	wantCritical := []string{
		// web/proxy
		"nginx.stop_immediate", "httpd.graceful_stop",
		// relational DB
		"cockroach.set_cluster_setting",
		// NoSQL/KV/cache/search (data-loss + topology criticals)
		"redis.flushall", "redis.flush_db", "redis.shutdown_nosave",
		"redis.cluster_failover", "redis.replicaof",
		"mongo.replset_stepdown",
		"cassandra.nodetool_assassinate", "cassandra.nodetool_decommission",
		"cassandra.nodetool_drain", "cassandra.nodetool_removenode",
		"ch.kill_mutation", "ch.system_drop_replica",
		"mc.flush_all", "es.close_index",
		// messaging/streaming
		"kafka.reset_offsets_to_earliest", "kafka.reset_offsets_to_latest",
		"rmq.purge_queue",
		// containers/registries
		"docker.volume_prune",
		// orchestration/mesh
		"consul.raft_remove_peer", "consul.snapshot_restore",
		"nomad.node_purge", "nomad.operator_raft_remove_peer",
		"kubernetes.drain",
		// linux host
		"linux.reboot_host",
		// firewall
		"fw.iptables_flush_chain", "pfsense.reboot",
		// storage
		"zfs.dataset_rollback",
		// cloud APIs
		"ec2.terminate_instance", "iam.deactivate_access_key",
		"iam.delete_access_key", "cf.purge_all_cache",
		// runtimes
		"jvm.heap_dump", "postfix.delete_qid",
		// provisioning/secrets/break-glass
		"cloud-init.clean", "vault.operator_seal", "vault.operator_step_down",
		"shell.run_script",
	}
	wantHigh := []string{
		// web reloads
		"nginx.reload", "httpd.graceful_reload",
		// connection-severing mutators
		"postgres.terminate_backend",
		// high mutators
		"redis.client_kill", "redis.config_set",
		// stop/kill/restart
		"docker.stop",
		// workload/node mutations
		"kubernetes.cordon", "nomad.node_drain", "frr.bgp_neighbor_shutdown",
		// irreversible TSDB deletes
		"prom.delete_series",
		// service/unit mutations
		"linux.systemctl_restart",
		// block/ban
		"fw.iptables_block_ip",
		// state/detach
		"ec2.stop_instance",
		// kill/strace/sysctl
		"debugging.kill_pid",
	}

	check := func(id string, want actionspec.Risk) {
		a, ok := reg.Action(id)
		if !ok {
			t.Errorf("named destructive action %q not found in the library (id drifted?)", id)
			return
		}
		if a.Risk != want {
			t.Errorf("action %q risk = %q, want %q (a downgrade here would bypass the approval gate)", id, a.Risk, want)
		}
	}
	for _, id := range wantCritical {
		check(id, actionspec.RiskCritical)
	}
	for _, id := range wantHigh {
		check(id, actionspec.RiskHigh)
	}
}

// the `shell` break-glass pack manifest
// has NO detect block (so `emisar pack suggest` never auto-suggests it) and
// its setup.notes advise keeping it human-gated (require_approval). These are
// the containment promises the staging-only break-glass rests on, read from
// the real packs/shell/pack.yaml.
func TestShellPack_BreakGlassContainment(t *testing.T) {
	reg := loadRealLibrary(t)

	pack, ok := reg.Pack("shell")
	if !ok {
		t.Fatal("shell pack must load")
	}

	// no detect signals at all — never auto-suggested.
	if len(pack.Detect.Binaries) != 0 || len(pack.Detect.Processes) != 0 || len(pack.Detect.Ports) != 0 {
		t.Errorf("shell pack must declare NO detect block (it must never be auto-suggested), got %+v", pack.Detect)
	}

	// setup.notes must advise keeping it human-gated.
	joined := strings.ToLower(strings.Join(pack.Setup.Notes, "\n"))
	for _, want := range []string{"require_approval", "staging only"} {
		if !strings.Contains(joined, want) {
			t.Errorf("shell pack setup.notes must mention %q (break-glass discipline), notes were:\n%s", want, strings.Join(pack.Setup.Notes, "\n"))
		}
	}

	// And the action it ships is the critical-risk break-glass action.
	a, ok := reg.Action("shell.run_script")
	if !ok {
		t.Fatal("shell.run_script must load")
	}
	if a.Risk != actionspec.RiskCritical {
		t.Errorf("shell.run_script risk = %q, want critical (default-deny is its only containment)", a.Risk)
	}
}
