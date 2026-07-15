//go:build unix

package validation

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestPath_UnreadableExistingComponentRejected(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can traverse owner-unreadable directories")
	}

	dir := t.TempDir()
	allowed := filepath.Join(dir, "allowed")
	blocked := filepath.Join(allowed, "blocked")
	if err := os.MkdirAll(blocked, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(blocked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(blocked, 0o700) })

	schema := []actionspec.Arg{{
		Name: "path", Type: actionspec.ArgPath, Required: true,
		Validation: &actionspec.Validation{AllowedPrefixes: []string{allowed}},
	}}
	_, err := Validate(schema, map[string]any{
		"path": filepath.Join(blocked, "new.log"),
	})
	if err == nil {
		t.Fatal("path below unreadable component must fail closed")
	}
}
