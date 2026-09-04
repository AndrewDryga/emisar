//go:build !windows

package installtest

import (
	"testing"
)

func TestRunnerChecksHaveFifteenPortableAndThreePrivilegedCases(t *testing.T) {
	var portable []string
	var privileged []string
	for _, check := range runnerChecks() {
		if check.requiresRoot {
			privileged = append(privileged, check.name)
			continue
		}
		portable = append(portable, check.name)
	}
	if len(portable) != 15 {
		t.Fatalf("portable checks = %v, want fifteen", portable)
	}
	wantPrivileged := []string{
		"enrollment state transitions",
		"binary installation rollback",
		"root-owned policy state",
	}
	if len(privileged) != len(wantPrivileged) {
		t.Fatalf("privileged checks = %v, want %v", privileged, wantPrivileged)
	}
	for index, name := range wantPrivileged {
		if privileged[index] != name {
			t.Fatalf("privileged checks = %v, want %v", privileged, wantPrivileged)
		}
	}
}
