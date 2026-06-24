package packs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// repoPacksDir resolves the real pack library at the repo root
// (../../../packs from runner/internal/packs). Skips the test if it is not
// present (e.g. the runner module checked out on its own).
func repoPacksDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "packs"))
	if err != nil {
		t.Fatalf("resolve packs dir: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "AGENTS.md")); err != nil {
		t.Skipf("real pack library not found at %s: %v", dir, err)
	}
	return dir
}

// loadRealLibrary loads the entire pack library through the production
// loader. SkipScriptChecksum keeps it stable and fast; we only assert on
// parsed metadata (ids, risk), not script hashes.
func loadRealLibrary(t *testing.T) *Registry {
	t.Helper()
	reg, err := LoadAll([]string{repoPacksDir(t)}, LoadOptions{SkipScriptChecksum: true})
	if err != nil {
		t.Fatalf("the whole pack library must load clean through the production loader: %v", err)
	}
	return reg
}

// the risk distribution across the WHOLE library is a
// regression guard. The counts are PINNED to the measured current values, so
// any future risk relabel (or an added destructive action) trips this test
// and forces a deliberate re-pin + a look at whether the new label is honest.
//
// Measured 2026-06-24 by grepping `^risk: <level>$` across
// packs/*/actions/*.yaml — low 945 · med 78 · high 154 · critical 42 = 1219.
// The shape (low ≫ medium; high + critical both present and non-trivial) is
// the invariant the exact numbers encode.
func TestLibrary_RiskDistribution(t *testing.T) {
	reg := loadRealLibrary(t)
	actions := reg.Actions()

	counts := map[actionspec.Risk]int{}
	for _, a := range actions {
		counts[a.Risk]++
	}

	const (
		wantLow      = 945
		wantMedium   = 78
		wantHigh     = 154
		wantCritical = 42
		wantTotal    = 1219
	)

	if got := len(actions); got != wantTotal {
		t.Errorf("total actions = %d, want %d (re-pin counts if the library grew/shrank deliberately)", got, wantTotal)
	}
	for _, c := range []struct {
		risk actionspec.Risk
		want int
	}{
		{actionspec.RiskLow, wantLow},
		{actionspec.RiskMedium, wantMedium},
		{actionspec.RiskHigh, wantHigh},
		{actionspec.RiskCritical, wantCritical},
	} {
		if counts[c.risk] != c.want {
			t.Errorf("risk %q count = %d, want %d (a risk relabel must be deliberate — re-pin and confirm honesty)", c.risk, counts[c.risk], c.want)
		}
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

// closes the PCK-101…114 `-T05`-representative named-action risk checks —
// the genuinely destructive actions each category names MUST carry the
// high/critical risk the policy gate depends on. A silent downgrade of one
// of these to a lower tier would bypass approval; this pins the label to the
// real action YAML loaded from disk.
func TestLibrary_NamedDestructiveActionRisk(t *testing.T) {
	reg := loadRealLibrary(t)

	// id -> expected risk, sampled by name across the inventory categories.
	wantCritical := []string{
		// PCK-101 web/proxy
		"nginx.stop_immediate", "httpd.graceful_stop",
		// PCK-102 relational DB
		"cockroach.set_cluster_setting",
		// PCK-103 NoSQL/KV/cache/search (data-loss + topology criticals)
		"redis.flushall", "redis.flush_db", "redis.shutdown_nosave",
		"redis.cluster_failover", "redis.replicaof",
		"mongo.replset_stepdown",
		"cassandra.nodetool_assassinate", "cassandra.nodetool_decommission",
		"cassandra.nodetool_drain", "cassandra.nodetool_removenode",
		"ch.kill_mutation", "ch.system_drop_replica",
		"mc.flush_all", "es.close_index",
		// PCK-104 messaging/streaming
		"kafka.reset_offsets_to_earliest", "kafka.reset_offsets_to_latest",
		"rmq.purge_queue",
		// PCK-105 containers/registries
		"docker.volume_prune",
		// PCK-106 orchestration/mesh
		"consul.raft_remove_peer", "consul.snapshot_restore",
		"nomad.node_purge", "nomad.operator_raft_remove_peer",
		"kubernetes.drain",
		// PCK-108 linux host
		"linux.reboot_host",
		// PCK-110 firewall
		"fw.iptables_flush_chain", "pfsense.reboot",
		// PCK-111 storage
		"zfs.dataset_rollback",
		// PCK-112 cloud APIs
		"ec2.terminate_instance", "iam.deactivate_access_key",
		"iam.delete_access_key", "cf.purge_all_cache",
		// PCK-113 runtimes
		"jvm.heap_dump", "postfix.delete_qid",
		// PCK-114 provisioning/secrets/break-glass
		"cloud-init.clean", "vault.operator_seal", "vault.operator_step_down",
		"shell.run_script",
	}
	wantHigh := []string{
		// PCK-101 web reloads
		"nginx.reload", "httpd.graceful_reload",
		// PCK-102 connection-severing mutators
		"postgres.terminate_backend",
		// PCK-103 high mutators
		"redis.client_kill", "redis.config_set",
		// PCK-105 stop/kill/restart
		"docker.stop",
		// PCK-106 workload/node mutations
		"kubernetes.cordon", "nomad.node_drain",
		// PCK-107 irreversible TSDB deletes
		"prom.delete_series",
		// PCK-108 service/unit mutations
		"linux.systemctl_restart",
		// PCK-110 block/ban
		"fw.iptables_block_ip",
		// PCK-112 state/detach
		"ec2.stop_instance",
		// PCK-114 kill/strace/sysctl
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
