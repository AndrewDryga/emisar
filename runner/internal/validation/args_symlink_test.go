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

func TestSymlink_UnresolvableExistingComponentRejected(t *testing.T) {
	dir := t.TempDir()
	allowed := filepath.Join(dir, "allowed")
	if err := os.MkdirAll(allowed, 0o755); err != nil {
		t.Fatal(err)
	}
	schema := []actionspec.Arg{{
		Name: "p", Type: actionspec.ArgPath, Required: true,
		Validation: &actionspec.Validation{AllowedPrefixes: []string{allowed}},
	}}

	t.Run("dangling symlink", func(t *testing.T) {
		escape := filepath.Join(allowed, "dangling")
		if err := os.Symlink(filepath.Join(dir, "missing-outside"), escape); err != nil {
			t.Fatal(err)
		}
		if _, err := Validate(schema, map[string]any{"p": filepath.Join(escape, "new.log")}); err == nil {
			t.Fatal("path through dangling symlink must fail closed")
		}
	})

	t.Run("symlink loop", func(t *testing.T) {
		left := filepath.Join(allowed, "left")
		right := filepath.Join(allowed, "right")
		if err := os.Symlink(right, left); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(left, right); err != nil {
			t.Fatal(err)
		}
		if _, err := Validate(schema, map[string]any{"p": filepath.Join(left, "new.log")}); err == nil {
			t.Fatal("path through symlink loop must fail closed")
		}
	})
}

func TestPathValidation_ReturnsCanonicalCheckedTargets(t *testing.T) {
	dir := t.TempDir()
	actual := filepath.Join(dir, "actual")
	if err := os.MkdirAll(actual, 0o755); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(dir, "alias")
	if err := os.Symlink(actual, alias); err != nil {
		t.Fatal(err)
	}

	schema := []actionspec.Arg{
		{
			Name: "single", Type: actionspec.ArgPath, Required: true,
			Validation: &actionspec.Validation{AllowedPrefixes: []string{dir}},
		},
		{
			Name: "many", Type: actionspec.ArgStringArray, Required: true,
			Validation: &actionspec.Validation{AllowedPrefixes: []string{dir}},
		},
	}
	input := filepath.Join(alias, "future.log")
	validated, err := Validate(schema, map[string]any{
		"single": input,
		"many":   []string{input},
	})
	if err != nil {
		t.Fatal(err)
	}
	resolvedActual, err := filepath.EvalSymlinks(actual)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(resolvedActual, "future.log")
	if got := validated["single"]; got != want {
		t.Fatalf("single = %q, want canonical target %q", got, want)
	}
	gotMany, ok := validated["many"].([]string)
	if !ok || len(gotMany) != 1 || gotMany[0] != want {
		t.Fatalf("many = %#v, want []string{%q}", validated["many"], want)
	}
}

// TestPath_RelativeValueRejectedUnderPathRules — a relative path value never
// matches an absolute allow/deny list, so without this guard it slips past a
// denied_prefixes rule and the executor runs it under its CWD, resolving to
// the very denied location. Any path arg carrying path rules must reject a
// non-absolute value the same as it rejects the equivalent absolute one.
func TestPath_RelativeValueRejectedUnderPathRules(t *testing.T) {
	deny := []actionspec.Arg{
		{
			Name: "p", Type: actionspec.ArgPath, Required: true,
			Validation: &actionspec.Validation{DeniedPrefixes: []string{"/etc"}},
		},
	}
	// The absolute form is denied by the /etc rule...
	if _, err := Validate(deny, map[string]any{"p": "/etc/shadow"}); err == nil {
		t.Fatal("expected /etc/shadow to be denied")
	}
	// ...and the relative form, which resolves to the same file under CWD "/",
	// must be rejected too rather than slipping past the deny list.
	if _, err := Validate(deny, map[string]any{"p": "etc/shadow"}); err == nil {
		t.Fatal("expected relative etc/shadow to be rejected under denied_prefixes")
	}

	// An allowed_prefixes arg keeps rejecting relative values as well.
	allow := []actionspec.Arg{
		{
			Name: "p", Type: actionspec.ArgPath, Required: true,
			Validation: &actionspec.Validation{AllowedPrefixes: []string{"/var/log"}},
		},
	}
	if _, err := Validate(allow, map[string]any{"p": "var/log/app.log"}); err == nil {
		t.Fatal("expected relative var/log/app.log to be rejected under allowed_prefixes")
	}
	if _, err := Validate(allow, map[string]any{"p": "/var/log/app.log"}); err != nil {
		t.Fatalf("absolute path under allowed prefix should pass: %v", err)
	}
}
