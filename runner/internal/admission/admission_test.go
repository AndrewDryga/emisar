package admission

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestAdmit_EmptyPolicyAllowsAll(t *testing.T) {
	p, err := New(nil, nil, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("cassandra.nodetool_repair"); !ok {
		t.Fatal("expected empty policy to allow")
	}
	if policyActive(p) {
		t.Fatal("empty policy should be inactive")
	}
}

func TestAdmit_NilPolicyAllowsAll(t *testing.T) {
	var p *Policy
	if ok, _ := p.Admit("anything.at_all"); !ok {
		t.Fatal("nil policy must allow")
	}
}

func TestAdmit_AllowlistRequiresMatch(t *testing.T) {
	p, err := New([]string{"linux.*", "cassandra.nodetool_status"}, nil, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("linux.uptime"); !ok {
		t.Fatal("linux.uptime should be allowed")
	}
	if ok, _ := p.Admit("linux.systemctl_restart"); !ok {
		t.Fatal("linux.systemctl_restart should match linux.*")
	}
	if ok, _ := p.Admit("cassandra.nodetool_status"); !ok {
		t.Fatal("exact cassandra.nodetool_status should be allowed")
	}
	if ok, reason := p.Admit("cassandra.nodetool_repair"); ok {
		t.Fatal("cassandra.nodetool_repair should be blocked when not on allowlist")
	} else if !strings.Contains(reason, "not on runner allowlist") {
		t.Fatalf("unexpected reason: %s", reason)
	}
}

func TestAdmit_DenylistBlocks(t *testing.T) {
	p, err := New(nil, []string{"cassandra.nodetool_repair", "*.drop_database"}, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("linux.uptime"); !ok {
		t.Fatal("anything not on the denylist should pass")
	}
	if ok, reason := p.Admit("cassandra.nodetool_repair"); ok {
		t.Fatal("cassandra.nodetool_repair must be blocked")
	} else if !strings.Contains(reason, "blocked by runner denylist") {
		t.Fatalf("unexpected reason: %s", reason)
	}
	if ok, _ := p.Admit("postgres.drop_database"); ok {
		t.Fatal("*.drop_database must match across packs")
	}
}

func TestAdmit_AllowlistThenDenylist(t *testing.T) {
	// Allow everything in linux except the destructive systemctl_restart.
	p, err := New([]string{"linux.*"}, []string{"linux.systemctl_restart"}, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("linux.uptime"); !ok {
		t.Fatal("linux.uptime should pass allowlist + denylist")
	}
	if ok, reason := p.Admit("linux.systemctl_restart"); ok {
		t.Fatal("linux.systemctl_restart should be denied even though it matched allowlist")
	} else if !strings.Contains(reason, "denylist") {
		t.Fatalf("expected denylist reason, got %s", reason)
	}
	// Not in allowlist at all.
	if ok, reason := p.Admit("postgres.uptime"); ok {
		t.Fatal("postgres.uptime should fail at allowlist gate")
	} else if !strings.Contains(reason, "allowlist") {
		t.Fatalf("expected allowlist reason, got %s", reason)
	}
}

func TestAdmit_StarMatchesEverything(t *testing.T) {
	p, err := New([]string{"*"}, []string{"cassandra.nodetool_repair"}, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("anything.anywhere"); !ok {
		t.Fatal("* allowlist should pass anything")
	}
	if ok, _ := p.Admit("cassandra.nodetool_repair"); ok {
		t.Fatal("denylist still binds when allowlist=*")
	}
}

func TestNew_RejectsEmptyPattern(t *testing.T) {
	if _, err := New([]string{""}, nil, ""); err == nil {
		t.Fatal("expected empty pattern in allow to error")
	}
	if _, err := New(nil, []string{""}, ""); err == nil {
		t.Fatal("expected empty pattern in deny to error")
	}
}

func TestNew_RejectsMalformedPattern(t *testing.T) {
	// Unterminated character class — filepath.Match returns ErrBadPattern.
	if _, err := New([]string{"linux.[uptime"}, nil, ""); err == nil {
		t.Fatal("expected malformed pattern to error")
	}
}

func TestPolicyActive(t *testing.T) {
	empty, _ := New(nil, nil, "")
	if policyActive(empty) {
		t.Fatal("empty policy should be inactive")
	}
	allow, _ := New([]string{"linux.*"}, nil, "")
	if !policyActive(allow) {
		t.Fatal("allow-only policy should be active")
	}
	deny, _ := New(nil, []string{"*.repair"}, "")
	if !policyActive(deny) {
		t.Fatal("deny-only policy should be active")
	}
	risk, _ := New(nil, nil, actionspec.RiskMedium)
	if !policyActive(risk) {
		t.Fatal("risk-ceiling-only policy should be active")
	}
}

func policyActive(policy *Policy) bool {
	return policy != nil && (len(policy.allow) > 0 || len(policy.deny) > 0 || policy.maxRisk != "")
}

// TestAdmitRisk covers the risk ceiling: with no ceiling everything passes;
// with a ceiling, an action at or below it is admitted and one above it is
// rejected with a reason. An invalid risk fails closed.
func TestAdmitRisk(t *testing.T) {
	tests := []struct {
		name    string
		ceiling actionspec.Risk
		risk    actionspec.Risk
		admit   bool
	}{
		{"no ceiling admits critical", "", actionspec.RiskCritical, true},
		{"medium ceiling admits low", actionspec.RiskMedium, actionspec.RiskLow, true},
		{"medium ceiling admits medium", actionspec.RiskMedium, actionspec.RiskMedium, true},
		{"medium ceiling rejects high", actionspec.RiskMedium, actionspec.RiskHigh, false},
		{"medium ceiling rejects critical", actionspec.RiskMedium, actionspec.RiskCritical, false},
		{"low ceiling rejects medium", actionspec.RiskLow, actionspec.RiskMedium, false},
		{"critical ceiling admits high", actionspec.RiskCritical, actionspec.RiskHigh, true},
		{"invalid risk fails closed under a ceiling", actionspec.RiskMedium, actionspec.Risk("bogus"), false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p, err := New(nil, nil, tc.ceiling)
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			ok, reason := p.AdmitRisk(tc.risk)
			if ok != tc.admit {
				t.Fatalf("AdmitRisk(ceiling=%q, risk=%q): got %v, want %v", tc.ceiling, tc.risk, ok, tc.admit)
			}
			if !ok && reason == "" {
				t.Fatal("a rejection must carry an operator-readable reason")
			}
		})
	}
}

// TestAdmit_DotIsNotPathSeparator covers: action ids are globbed
// as opaque whole strings — the dot in `pack.action` is an ordinary character,
// not a path separator. So `cassandra.*` matches every action in the pack and
// `*.restart` matches any pack's restart action (even multi-level ids).
func TestAdmit_DotIsNotPathSeparator(t *testing.T) {
	tests := []struct {
		name    string
		pattern string
		id      string
		match   bool
	}{
		{"pack-wildcard matches action", "cassandra.*", "cassandra.repair", true},
		{"pack-wildcard matches another action", "cassandra.*", "cassandra.nodetool_status", true},
		{"pack-wildcard does not cross packs", "cassandra.*", "postgres.repair", false},
		{"leading-wildcard matches restart across packs", "*.restart", "pg.restart", true},
		{"leading-wildcard matches restart in another pack", "*.restart", "host.restart", true},
		{"leading-wildcard matches multi-level id", "*.restart", "a.b.restart", true},
		{"star matches a multi-level id", "*", "a.b.c", true},
		{"leading-wildcard requires the suffix", "*.restart", "pg.reload", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Drive it through the allowlist gate: a match means admitted.
			p, err := New([]string{tc.pattern}, nil, "")
			if err != nil {
				t.Fatalf("New: %v", err)
			}
			ok, _ := p.Admit(tc.id)
			if ok != tc.match {
				t.Fatalf("allow=%q Admit(%q): got %v, want %v", tc.pattern, tc.id, ok, tc.match)
			}
			// And through the denylist gate: a match means blocked.
			pd, err := New(nil, []string{tc.pattern}, "")
			if err != nil {
				t.Fatalf("New (deny): %v", err)
			}
			okd, _ := pd.Admit(tc.id)
			if okd != !tc.match {
				t.Fatalf("deny=%q Admit(%q): got admitted=%v, want %v", tc.pattern, tc.id, okd, !tc.match)
			}
		})
	}
}

// TestAdmit_FailsClosedOnMatchError covers: New rejects malformed
// globs so a runtime filepath.Match error is unreachable through the public
// API. This white-box test bypasses New to plant a malformed pattern directly
// in the (unexported) policy and asserts the defensive `err == nil` branches in
// matchAny/firstMatch treat a match error as "no match" — i.e. admission fails
// closed: a broken allow pattern never admits, a broken deny pattern never
// silently waves an action through as a "match".
func TestAdmit_FailsClosedOnMatchError(t *testing.T) {
	// Sanity: this pattern really does make filepath.Match error, so the
	// branch under test is genuinely exercised (not a no-op assertion).
	if _, err := filepath.Match("db.[", "db.drop"); err == nil {
		t.Fatal("precondition: expected filepath.Match to error on the malformed pattern")
	}

	t.Run("broken allow pattern fails closed (denies)", func(t *testing.T) {
		// allow=["db.["] would be rejected by New; plant it directly.
		p := &Policy{allow: []string{"db.["}}
		if ok, reason := p.Admit("db.drop"); ok {
			t.Fatalf("a match-error allow pattern must not admit; got admitted (reason=%q)", reason)
		}
	})

	t.Run("broken deny pattern treated as no-match", func(t *testing.T) {
		// deny=["db.["] would be rejected by New; plant it directly. A match
		// error must be swallowed as "no match" so it never blocks (and, more
		// importantly, the err-guard stops Match's false/err result from being
		// mistaken for a real hit).
		p := &Policy{deny: []string{"db.["}}
		if ok, reason := p.Admit("db.drop"); !ok {
			t.Fatalf("a match-error deny pattern must be ignored, not block; got blocked (reason=%q)", reason)
		}
	})
}

// TestNew_StoresDefensiveCopies covers: New copies the caller's
// allow/deny slices, so mutating the originals after construction cannot alter
// a compiled policy's decisions (the policy is immutable post-boot).
func TestNew_StoresDefensiveCopies(t *testing.T) {
	allow := []string{"linux.*"}
	deny := []string{"linux.systemctl_restart"}
	p, err := New(allow, deny, "")
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	// Mutate the caller's slices out from under the policy.
	allow[0] = "*"                     // would widen the allowlist to everything
	deny[0] = "postgres.drop_database" // would move the deny off linux

	// Decisions must reflect the snapshot taken at New, not the mutations.
	if ok, _ := p.Admit("postgres.uptime"); ok {
		t.Fatal("allowlist mutation leaked: postgres.uptime should still fail the linux.* allowlist")
	}
	if ok, reason := p.Admit("linux.systemctl_restart"); ok {
		t.Fatalf("denylist mutation leaked: linux.systemctl_restart should still be denied, got admitted (reason=%q)", reason)
	}
}

// BenchmarkAdmit_LargeRuleSet covers: Admit is linear in the rule
// count and compiled once at boot — no per-call recompile. The id matches the
// last allow pattern and no deny pattern (the worst case: every allow scanned).
func BenchmarkAdmit_LargeRuleSet(b *testing.B) {
	const n = 256
	allow := make([]string, n)
	deny := make([]string, n)
	for i := range allow {
		allow[i] = fmt.Sprintf("pack%03d.*", i)
		deny[i] = fmt.Sprintf("pack%03d.drop_database", i)
	}
	p, err := New(allow, deny, "")
	if err != nil {
		b.Fatalf("New: %v", err)
	}
	id := fmt.Sprintf("pack%03d.restart", n-1) // matches last allow, no deny

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if ok, _ := p.Admit(id); !ok {
			b.Fatal("expected admit")
		}
	}
}
