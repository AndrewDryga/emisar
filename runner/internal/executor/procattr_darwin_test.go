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
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65534, Gid: 65534}}
	applyProcAttr(cmd)

	if cred := cmd.SysProcAttr.Credential; cred == nil || cred.Uid != 65534 || cred.Gid != 65534 {
		t.Errorf("existing Credential was not preserved: %+v", cred)
	}
	if !cmd.SysProcAttr.Setpgid {
		t.Fatal("Setpgid should be enabled on existing SysProcAttr")
	}
}
