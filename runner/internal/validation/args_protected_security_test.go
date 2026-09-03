package validation

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// The runner's own config and state roots are refused for every path arg,
// whatever the pack declared. These directories hold runner.env (the
// enrollment key plus the operator's exported pack credentials) and the
// control-plane bearer token, so a read of either impersonates the runner —
// and the generic filesystem packs that would reach them are risk: low, which
// the shipped default policy auto-runs with no approval.

func TestProtected_RefusedWithNoValidationBlock(t *testing.T) {
	state := t.TempDir()
	// The arg declares nothing at all: no denied_paths, no prefixes. This is
	// the case that skips applyPathValidation entirely, so the guard has to
	// stand on its own.
	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}

	_, err := Validate(schema, map[string]any{"path": filepath.Join(state, "token")}, []string{state})
	if err == nil {
		t.Fatal("a path arg naming the runner's state must be refused even with no validation block")
	}
	assertProtected(t, err)
}

func TestProtected_RefusedDespiteUnrelatedDenylist(t *testing.T) {
	config := t.TempDir()
	// A denylist that names other secrets but not the runner's own root — the
	// shipped fs-search shape before this guard existed.
	schema := []actionspec.Arg{{
		Name:     "path",
		Type:     actionspec.ArgPath,
		Required: true,
		Validation: &actionspec.Validation{
			DeniedPaths:    []string{"/etc/shadow"},
			DeniedPrefixes: []string{"/etc/ssh"},
		},
	}}

	_, err := Validate(schema, map[string]any{"path": filepath.Join(config, "runner.env")}, []string{config})
	if err == nil {
		t.Fatal("a pack denylist that omits the runner's own root must not authorize the read")
	}
	assertProtected(t, err)
}

func TestProtected_RefusesTheRootItselfAndSubpaths(t *testing.T) {
	state := t.TempDir()
	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}

	for _, target := range []string{
		state,
		filepath.Join(state, "token"),
		filepath.Join(state, "nonces", "seen.json"),
		// Dot-dot back into the root resolves to the same place.
		filepath.Join(state, "..", filepath.Base(state), "token"),
	} {
		if _, err := Validate(schema, map[string]any{"path": target}, []string{state}); err == nil {
			t.Fatalf("path %s must be refused", target)
		}
	}
}

func TestProtected_RefusesSymlinkIntoTheRoot(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(state, "token"), []byte("rnrtok-secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A link whose own spelling is innocent but which lands in the state dir.
	link := filepath.Join(dir, "innocent.log")
	if err := os.Symlink(filepath.Join(state, "token"), link); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}

	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}
	if _, err := Validate(schema, map[string]any{"path": link}, []string{state}); err == nil {
		t.Fatal("a symlink resolving into the runner's state must be refused")
	}
}

func TestProtected_AllowsPathsOutsideTheRoots(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "state")
	if err := os.MkdirAll(state, 0o700); err != nil {
		t.Fatal(err)
	}
	logs := filepath.Join(dir, "log")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		t.Fatal(err)
	}
	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}

	target := filepath.Join(logs, "syslog")
	out, err := Validate(schema, map[string]any{"path": target}, []string{state})
	if err != nil {
		t.Fatalf("an ordinary read outside the runner's own state must still pass: %v", err)
	}
	if got := out["path"]; got != target {
		t.Fatalf("path = %v, want %v", got, target)
	}
	// A sibling whose name merely starts with the root's name is not inside it.
	sibling := state + "-backup"
	if err := os.MkdirAll(sibling, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := Validate(schema, map[string]any{"path": filepath.Join(sibling, "f")}, []string{state}); err != nil {
		t.Fatalf("a sibling sharing the root's name prefix must not be refused: %v", err)
	}
}

func TestProtected_CoversStringArrayArgsCarryingPaths(t *testing.T) {
	state := t.TempDir()
	schema := []actionspec.Arg{{
		Name: "paths",
		Type: actionspec.ArgStringArray,
		Validation: &actionspec.Validation{
			DeniedPaths: []string{"/etc/shadow"},
		},
	}}

	raw := map[string]any{"paths": []any{"/var/log/syslog", filepath.Join(state, "token")}}
	if _, err := Validate(schema, raw, []string{state}); err == nil {
		t.Fatal("one protected element must refuse the whole array")
	}
}

// A pack that spells a host path `type: string` with only a pattern loses
// applyPathValidation; it must not also lose the runner-identity refusal. The
// registry ships third-party packs, and `cat {{ args.file }}` at risk: low is
// auto-run with no approval.
func TestProtected_CoversPlainStringArgsCarryingPaths(t *testing.T) {
	config := t.TempDir()
	schema := []actionspec.Arg{{
		Name:       "file",
		Type:       actionspec.ArgString,
		Required:   true,
		Validation: &actionspec.Validation{Pattern: `^/[A-Za-z0-9._/-]{1,256}$`},
	}}

	_, err := Validate(schema, map[string]any{"file": filepath.Join(config, "runner.env")}, []string{config})
	if err == nil {
		t.Fatal("a string arg naming the runner's config must be refused")
	}
	assertProtected(t, err)
}

// A string arg that merely looks like a path — a CloudWatch log group, a
// ZooKeeper znode — must still validate. Extending the refusal to every
// string-shaped arg must not turn a remote identifier into a run failure,
// including one whose leading component is a local directory this process
// cannot read.
func TestProtected_AllowsRemoteIdentifiersShapedLikePaths(t *testing.T) {
	dir := t.TempDir()
	unreadable := filepath.Join(dir, "sealed")
	if err := os.MkdirAll(unreadable, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(unreadable, 0o700) })
	if _, err := os.Lstat(filepath.Join(unreadable, "probe")); !os.IsPermission(err) {
		t.Skipf("this process can traverse a 0000 directory (running as root?): %v", err)
	}

	schema := []actionspec.Arg{{Name: "group", Type: actionspec.ArgString, Required: true}}
	for _, target := range []string{
		"/aws/lambda/checkout",
		"relative/identifier",
		filepath.Join(unreadable, "znode"),
	} {
		if _, err := Validate(schema, map[string]any{"group": target}, []string{t.TempDir()}); err != nil {
			t.Fatalf("identifier %s must still validate: %v", target, err)
		}
	}
}

// Deny rules and the protected roots must hold on a case-insensitive
// filesystem. filepath.EvalSymlinks does not normalize case, so before the
// fold compare `/etc/EMISAR/runner.env` matched neither the pack's
// denied_prefixes nor the runner's own roots — and opened the same file.
func TestProtected_RefusesCaseVariantsOfTheRoot(t *testing.T) {
	config := filepath.Join(t.TempDir(), "emisar")
	if err := os.MkdirAll(config, 0o700); err != nil {
		t.Fatal(err)
	}
	variant := filepath.Join(filepath.Dir(config), "EMISAR", "runner.env")

	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}
	_, err := Validate(schema, map[string]any{"path": variant}, []string{config})
	if err == nil {
		t.Fatalf("case variant %s of the runner's config root must be refused", variant)
	}
	assertProtected(t, err)

	// On a case-insensitive volume the variant really is the same directory,
	// which is what makes the exact compare a bypass rather than a nicety.
	if err := os.WriteFile(filepath.Join(config, "runner.env"), []byte("emkey-enroll-x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(variant); err != nil {
		t.Skipf("filesystem is case-sensitive; the fold compare is proven above: %v", err)
	}
}

func TestDeniedPaths_RefuseCaseVariants(t *testing.T) {
	dir := t.TempDir()
	secret := filepath.Join(dir, "shadow")
	if err := os.WriteFile(secret, []byte("root:!:"), 0o600); err != nil {
		t.Fatal(err)
	}
	schema := []actionspec.Arg{{
		Name:     "path",
		Type:     actionspec.ArgPath,
		Required: true,
		Validation: &actionspec.Validation{
			DeniedPaths:    []string{secret},
			DeniedPrefixes: []string{filepath.Join(dir, "private")},
		},
	}}

	for _, target := range []string{
		filepath.Join(dir, "SHADOW"),
		filepath.Join(dir, "PRIVATE", "server.key"),
	} {
		if _, err := Validate(schema, map[string]any{"path": target}, nil); err == nil {
			t.Fatalf("case variant %s must not slip past the deny rules", target)
		}
	}
}

func TestProtected_EmptyListLeavesValidationUnchanged(t *testing.T) {
	state := t.TempDir()
	schema := []actionspec.Arg{{Name: "path", Type: actionspec.ArgPath, Required: true}}

	target := filepath.Join(state, "token")
	if _, err := Validate(schema, map[string]any{"path": target}, nil); err != nil {
		t.Fatalf("with no protected roots configured the guard must not fire: %v", err)
	}
}

func assertProtected(t *testing.T, err error) {
	t.Helper()
	var e *Error
	if !errors.As(err, &e) {
		t.Fatalf("want a structured *validation.Error, got %T: %v", err, err)
	}
	if e.Code != "protected_path" {
		t.Fatalf("code = %q, want protected_path", e.Code)
	}
	// The operator/LLM sees this string; it must say why without naming the
	// credential file as a hint about where to look next.
	if !strings.Contains(e.Error(), "runner's own configuration or state") {
		t.Fatalf("message %q does not explain the refusal", e.Error())
	}
}
