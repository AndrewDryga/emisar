//go:build linux

package executor

import (
	"os/exec"
	"syscall"
	"testing"
)

// TestApplyProcAttr_LinuxSetsPdeathsigAndSetpgid is a static sanity
// check. It does not verify the kernel actually delivers SIGKILL on
// parent death (that requires fork-bomb-style multi-process plumbing
// to test reliably). Instead it asserts the flags we ship are the
// ones the kernel reads — if these go missing, no zombie protection.
func TestApplyProcAttr_LinuxSetsPdeathsigAndSetpgid(t *testing.T) {
	cmd := exec.Command("/bin/true")
	applyProcAttr(cmd)

	if cmd.SysProcAttr == nil {
		t.Fatal("SysProcAttr should be set")
	}
	if got, want := cmd.SysProcAttr.Pdeathsig, syscall.SIGKILL; got != want {
		t.Errorf("Pdeathsig = %v, want %v", got, want)
	}
	if !cmd.SysProcAttr.Setpgid {
		t.Error("Setpgid should be true")
	}
}

// TestApplyProcAttr_LinuxPreservesExistingSysProcAttr — the helper
// should add to, not overwrite, any SysProcAttr the caller already
// configured (defence against a future refactor that wants to set
// Credential, Foreground, etc.).
func TestApplyProcAttr_LinuxPreservesExistingSysProcAttr(t *testing.T) {
	cmd := exec.Command("/bin/true")
	cmd.SysProcAttr = &syscall.SysProcAttr{Foreground: false}
	applyProcAttr(cmd)
	if cmd.SysProcAttr.Pdeathsig != syscall.SIGKILL {
		t.Error("Pdeathsig not applied on top of existing SysProcAttr")
	}
	if !cmd.SysProcAttr.Setpgid {
		t.Error("Setpgid not applied on top of existing SysProcAttr")
	}
}
