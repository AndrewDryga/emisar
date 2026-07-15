//go:build linux

package executor

import (
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

// TestApplyCredential_PopulatesUidGidFromName — verifies the central
// invariant: an action with `user: <name>` resolves to the right
// uid/gid in SysProcAttr.Credential. Doesn't require root: we resolve
// to the current user so the lookup must succeed.
func TestApplyCredential_PopulatesUidGidFromName(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatalf("user.Current: %v", err)
	}
	wantUid, _ := strconv.Atoi(u.Uid)
	wantGid, _ := strconv.Atoi(u.Gid)

	cmd := exec.Command("/bin/true")
	if err := applyCredential(cmd, u.Username); err != nil {
		t.Fatalf("applyCredential by name: %v", err)
	}
	if cmd.SysProcAttr == nil || cmd.SysProcAttr.Credential == nil {
		t.Fatal("expected Credential to be set on SysProcAttr")
	}
	c := cmd.SysProcAttr.Credential
	if int(c.Uid) != wantUid || int(c.Gid) != wantGid {
		t.Fatalf("Credential={Uid:%d Gid:%d}; want {Uid:%d Gid:%d}", c.Uid, c.Gid, wantUid, wantGid)
	}
	if c.NoSetGroups || len(c.Groups) != 0 {
		t.Errorf("Credential must clear supplementary groups: %+v", c)
	}
}

func TestApplyCredential_ClearsSupplementaryGroups(t *testing.T) {
	const helperEnv = "EMISAR_TEST_CREDENTIAL_GROUPS"
	if os.Getenv(helperEnv) == "1" {
		if err := syscall.Setgroups([]int{42424}); err != nil {
			t.Fatalf("seed supplementary group: %v", err)
		}
		u, err := user.LookupId("0")
		if err != nil {
			t.Fatalf("lookup root: %v", err)
		}
		id, err := exec.LookPath("id")
		if err != nil {
			t.Fatalf("look up id: %v", err)
		}
		cmd := exec.Command(id, "-G")
		if err := applyCredential(cmd, u.Uid); err != nil {
			t.Fatalf("applyCredential: %v", err)
		}
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("run id: %v: %s", err, out)
		}
		if got := strings.TrimSpace(string(out)); got != u.Gid {
			t.Fatalf("groups after credential drop = %q, want only primary gid %q", got, u.Gid)
		}
		return
	}

	if os.Geteuid() != 0 {
		t.Skip("requires root to seed and clear supplementary groups")
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestApplyCredential_ClearsSupplementaryGroups$")
	cmd.Env = append(os.Environ(), helperEnv+"=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("credential helper: %v\n%s", err, out)
	}
}

// TestApplyCredential_AcceptsNumericUid — pack authors can write
// `user: "999"` for a non-named system uid. Same end state.
func TestApplyCredential_AcceptsNumericUid(t *testing.T) {
	u, err := user.Current()
	if err != nil {
		t.Fatalf("user.Current: %v", err)
	}

	cmd := exec.Command("/bin/true")
	if err := applyCredential(cmd, u.Uid); err != nil {
		t.Fatalf("applyCredential by uid string: %v", err)
	}
	if cmd.SysProcAttr.Credential == nil {
		t.Fatal("Credential not set")
	}
}

// TestApplyCredential_UnknownUserErrors — a typo in the YAML must
// surface before exec rather than producing a silent default uid.
func TestApplyCredential_UnknownUserErrors(t *testing.T) {
	cmd := exec.Command("/bin/true")
	err := applyCredential(cmd, "definitely-not-a-real-user-xx7")
	if err == nil {
		t.Fatal("expected unknown user to error")
	}
}
