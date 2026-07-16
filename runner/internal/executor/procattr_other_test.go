//go:build !linux

package executor

import (
	"os/exec"
	"strings"
	"testing"
)

func TestApplyCredentialRejectsUnsupportedPlatform(t *testing.T) {
	cmd := exec.Command("true")
	err := applyCredential(cmd, "service-user")
	if err == nil || !strings.Contains(err.Error(), "execution.user") {
		t.Fatalf("applyCredential error = %v, want unsupported execution.user", err)
	}
}
