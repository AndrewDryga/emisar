package admission

import (
	"strings"
	"testing"
)

func TestAdmit_EmptyPolicyAllowsAll(t *testing.T) {
	p, err := New(nil, nil)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if ok, _ := p.Admit("cassandra.nodetool_repair"); !ok {
		t.Fatal("expected empty policy to allow")
	}
	if p.Active() {
		t.Fatal("Active() should be false for empty policy")
	}
}

func TestAdmit_NilPolicyAllowsAll(t *testing.T) {
	var p *Policy
	if ok, _ := p.Admit("anything.at_all"); !ok {
		t.Fatal("nil policy must allow")
	}
}

func TestAdmit_AllowlistRequiresMatch(t *testing.T) {
	p, err := New([]string{"linux.*", "cassandra.nodetool_status"}, nil)
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
	p, err := New(nil, []string{"cassandra.nodetool_repair", "*.drop_database"})
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
	p, err := New([]string{"linux.*"}, []string{"linux.systemctl_restart"})
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
	p, err := New([]string{"*"}, []string{"cassandra.nodetool_repair"})
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
	if _, err := New([]string{""}, nil); err == nil {
		t.Fatal("expected empty pattern in allow to error")
	}
	if _, err := New(nil, []string{""}); err == nil {
		t.Fatal("expected empty pattern in deny to error")
	}
}

func TestNew_RejectsMalformedPattern(t *testing.T) {
	// Unterminated character class — filepath.Match returns ErrBadPattern.
	if _, err := New([]string{"linux.[uptime"}, nil); err == nil {
		t.Fatal("expected malformed pattern to error")
	}
}

func TestActive(t *testing.T) {
	empty, _ := New(nil, nil)
	if empty.Active() {
		t.Fatal("empty policy should not be Active")
	}
	allow, _ := New([]string{"linux.*"}, nil)
	if !allow.Active() {
		t.Fatal("allow-only policy should be Active")
	}
	deny, _ := New(nil, []string{"*.repair"})
	if !deny.Active() {
		t.Fatal("deny-only policy should be Active")
	}
}
