//go:build linux

package executor

import (
	"fmt"
	"os"
	"os/exec"
	"testing"
)

// The kernel keeps its own copy of the runner's environment under
// /proc/<pid>/environ — runner.env, with the enrollment key and every pack
// credential systemd loaded — and gates it on ptrace access, which a same-uid
// child passes while the runner is dumpable. Every action runs as the runner's
// user unless its pack drops further, so the test is the exact attack: a child
// of this process reads this process's environ, before and after
// ProtectProcess. Only the kernel can say whether the flag took, so the child
// does the reading rather than the test asserting a function was called.
func TestProtectProcess_HidesEnvironFromSameUIDChildren(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every /proc entry through CAP_SYS_PTRACE; the refusal is a same-uid fact")
	}
	environ := fmt.Sprintf("/proc/%d/environ", os.Getpid())

	// Before: the read succeeds unless the host already hardens ptrace beyond
	// Yama's default (scope 2+), in which case only the after half is provable.
	before, beforeErr := exec.Command("/bin/cat", environ).Output()
	dumpable, err := processDumpable()
	if err != nil {
		t.Fatalf("read dumpable: %v", err)
	}
	if dumpable == 1 && beforeErr != nil {
		t.Skipf("a same-uid child could not read our environ even while dumpable (%v); ptrace is hardened here", beforeErr)
	}
	if dumpable == 1 && len(before) == 0 {
		t.Fatal("the before read returned nothing; the test needs an environment to protect")
	}

	if err := ProtectProcess(); err != nil {
		t.Fatalf("ProtectProcess: %v", err)
	}
	if dumpable, err := processDumpable(); err != nil || dumpable != 0 {
		t.Fatalf("dumpable = %d (%v), want 0", dumpable, err)
	}

	after, err := exec.Command("/bin/cat", environ).Output()
	if err == nil {
		t.Fatalf("a same-uid child still read %d bytes of our environ after ProtectProcess", len(after))
	}

	// The process keeps what it needs from its own entry: selfupdate resolves
	// /proc/self/exe, and the link handler checks ptrace access, which a
	// process always has to itself. (environ and mem become root-owned files,
	// so even the process cannot open them by path any more — nothing in the
	// runner does.)
	if _, err := os.Readlink("/proc/self/exe"); err != nil {
		t.Fatalf("the process lost /proc/self/exe: %v", err)
	}
	if _, err := os.Executable(); err != nil {
		t.Fatalf("os.Executable after ProtectProcess: %v", err)
	}
}
