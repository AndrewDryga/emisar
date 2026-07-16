//go:build darwin

package executor

import (
	"os/exec"
	"syscall"
	"testing"
)

func TestApplyProcAttrDarwinSetsProcessGroup(t *testing.T) {
	cmd := exec.Command("/usr/bin/true")
	applyProcAttr(cmd)

	if cmd.SysProcAttr == nil || !cmd.SysProcAttr.Setpgid {
		t.Fatal("Setpgid should be enabled")
	}
}

func TestApplyProcAttrDarwinPreservesExistingAttributes(t *testing.T) {
	cmd := exec.Command("/usr/bin/true")
	cmd.SysProcAttr = &syscall.SysProcAttr{Foreground: false}
	applyProcAttr(cmd)

	if !cmd.SysProcAttr.Setpgid {
		t.Fatal("Setpgid should be enabled on existing SysProcAttr")
	}
}
