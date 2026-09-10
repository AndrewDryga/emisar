package infraops

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeAdminAction(t *testing.T, pack, name, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(pack, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pack, "actions", name), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

// The real pack has two actions sitting exactly on the ceiling, so the check
// must accept five entries and refuse six.
func TestAdminActionArgvCeiling(t *testing.T) {
	pack := t.TempDir()
	writeAdminAction(t, pack, "member_set_role.yaml", `execution:
  script: {path: scripts/callback.sh, interpreter: /bin/sh}
  argv: ["emisar.admin.member.set_role", "account={{ args.account }}", "member={{ args.member }}", "role={{ args.role }}", "runner_access={{ args.runner_access? }}"]
`)
	writeAdminAction(t, pack, "runtime_status.yaml", `execution:
  script: {path: scripts/other.sh, interpreter: /bin/sh}
  argv: ["a", "b", "c", "d", "e", "f"]
`)
	if err := checkAdminActionArgvCeiling(pack); err != nil {
		t.Fatalf("ceiling rejected a compliant pack: %v", err)
	}

	writeAdminAction(t, pack, "member_set_role.yaml", `execution:
  script: {path: scripts/callback.sh, interpreter: /bin/sh}
  argv: ["emisar.admin.member.set_role", "account={{ args.account }}", "member={{ args.member }}", "role={{ args.role }}", "runner_access={{ args.runner_access? }}", "note={{ args.note }}"]
`)
	err := checkAdminActionArgvCeiling(pack)
	if err == nil || !strings.Contains(err.Error(), "member_set_role.yaml passes 6 argv entries") {
		t.Fatalf("a sixth argv entry was not reported: %v", err)
	}
}

// The check reads the real pack: it is the one place an author would learn the
// bound before an operator hits it at run time.
func TestAdminActionArgvCeilingHoldsInTheRepository(t *testing.T) {
	if err := checkAdminActionArgvCeiling(filepath.Join("..", "..", "..", "infra", "packs", "emisar-admin")); err != nil {
		t.Fatal(err)
	}
}
