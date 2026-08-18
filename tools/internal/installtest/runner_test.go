package installtest

import (
	"testing"
)

func TestRunnerChecksHaveNinePortableAndThreePrivilegedCases(t *testing.T) {
	var portable []string
	var privileged []string
	for _, check := range runnerChecks() {
		if check.requiresRoot {
			privileged = append(privileged, check.name)
			continue
		}
		portable = append(portable, check.name)
	}
	if len(portable) != 9 {
		t.Fatalf("portable checks = %v, want nine", portable)
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
