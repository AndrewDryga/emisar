package validation

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// TestSymlink_NonexistentTargetThroughSymlinkedParent — the classic
// time-of-check/time-of-use attack: the leaf doesn't exist yet, but a
// parent in the path is a symlink to outside the allowed prefix. The
// fix is to walk up to the deepest existing parent, EvalSymlinks it,
// then re-attach the missing tail and recheck.
func TestSymlink_NonexistentTargetThroughSymlinkedParent(t *testing.T) {
	dir := t.TempDir()

	// Allowed area: dir/allowed
	allowed := filepath.Join(dir, "allowed")
	if err := os.MkdirAll(allowed, 0o755); err != nil {
		t.Fatal(err)
	}
	// Forbidden area outside: dir/forbidden
	forbidden := filepath.Join(dir, "forbidden")
	if err := os.MkdirAll(forbidden, 0o755); err != nil {
		t.Fatal(err)
	}
	// allowed/escape -> forbidden (symlink)
	if err := os.Symlink(forbidden, filepath.Join(allowed, "escape")); err != nil {
		t.Fatal(err)
	}

	schema := []actionspec.Arg{
		{
			Name: "p", Type: actionspec.ArgPath, Required: true,
			Validation: &actionspec.Validation{AllowedPrefixes: []string{allowed + string(filepath.Separator)}},
		},
	}

	// Honest read inside allowed area: passes.
	if _, err := Validate(schema, map[string]any{"p": filepath.Join(allowed, "ok.log")}); err != nil {
		t.Fatalf("honest path should pass: %v", err)
	}

	// Escape attempt: leaf doesn't exist yet, but parent symlinks out.
	// The deepest existing parent is `allowed/escape` which resolves to
	// `forbidden`, so the resolved leaf is `forbidden/new.log` — not
	// under the allowed prefix.
	_, err := Validate(schema, map[string]any{
		"p": filepath.Join(allowed, "escape", "new.log"),
	})
	if err == nil {
		t.Fatal("expected validation to reject path through symlinked parent")
	}
}
