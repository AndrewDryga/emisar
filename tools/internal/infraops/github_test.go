package infraops

import (
	"bytes"
	"strings"
	"testing"
)

func TestVerifyReleaseEnvironmentRequiresKnownExplicitScope(t *testing.T) {
	var output bytes.Buffer
	app := New(t.TempDir(), strings.NewReader(""), &output, &output)
	for _, args := range [][]string{
		{"verify-release-environment"},
		{"verify-release-environment", "AndrewDryga/emisar"},
		{"verify-release-environment", "AndrewDryga/emisar", "pack-registry-production", "extra"},
	} {
		if err := app.Run(t.Context(), args); err == nil || !IsUsage(err) {
			t.Fatalf("Run(%v) error = %v, want usage error", args, err)
		}
	}
	if err := app.Run(t.Context(), []string{
		"verify-release-environment", "AndrewDryga/emisar", "not-a-release-environment",
	}); err == nil || !strings.Contains(err.Error(), "unknown release environment") {
		t.Fatalf("unknown environment error = %v", err)
	}
}
