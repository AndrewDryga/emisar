package validation

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func ptrFloat(f float64) *float64 { return &f }
func ptrInt(n int) *int           { return &n }
func ptrDur(d time.Duration) *actionspec.Duration {
	v := actionspec.Duration(d)
	return &v
}

func TestValidate_UnknownArg(t *testing.T) {
	schema := []actionspec.Arg{{Name: "x", Type: actionspec.ArgString}}
	_, err := Validate(schema, map[string]any{"y": "foo"})
	if err == nil || !strings.Contains(err.Error(), "unknown argument") {
		t.Fatalf("expected unknown arg error, got %v", err)
	}
}

func TestValidate_RequiredMissing(t *testing.T) {
	schema := []actionspec.Arg{{Name: "x", Type: actionspec.ArgString, Required: true}}
	_, err := Validate(schema, nil)
	if err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("expected required error, got %v", err)
	}
}

func TestValidate_DefaultApplied(t *testing.T) {
	schema := []actionspec.Arg{{Name: "x", Type: actionspec.ArgString, Default: "fallback"}}
	out, err := Validate(schema, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out["x"] != "fallback" {
		t.Fatalf("default not applied, got %v", out["x"])
	}
}

func TestValidate_Enum(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "x", Type: actionspec.ArgString,
		Validation: &actionspec.Validation{Enum: []any{"a", "b"}},
	}}
	if _, err := Validate(schema, map[string]any{"x": "a"}); err != nil {
		t.Fatalf("a should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"x": "c"}); err == nil {
		t.Fatal("c should fail enum")
	}
}

func TestValidate_Pattern(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "x", Type: actionspec.ArgString,
		Validation: &actionspec.Validation{Pattern: "^[a-z]+$"},
	}}
	if _, err := Validate(schema, map[string]any{"x": "abc"}); err != nil {
		t.Fatalf("abc should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"x": "abc1"}); err == nil {
		t.Fatal("abc1 should fail pattern")
	}
}

func TestValidate_MinMax(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "x", Type: actionspec.ArgInteger,
		Validation: &actionspec.Validation{Min: ptrFloat(1), Max: ptrFloat(10)},
	}}
	if _, err := Validate(schema, map[string]any{"x": 5}); err != nil {
		t.Fatalf("5 should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"x": 0}); err == nil {
		t.Fatal("0 should fail min")
	}
	if _, err := Validate(schema, map[string]any{"x": 11}); err == nil {
		t.Fatal("11 should fail max")
	}
}

func TestValidate_AllowedPathsDenied(t *testing.T) {
	// Use non-existent paths so symlink resolution falls back to
	// filepath.Clean (predictable on every OS — macOS has /var/log
	// symlinked to /private/var/log which would otherwise change
	// the resolved path).
	schema := []actionspec.Arg{{
		Name: "p", Type: actionspec.ArgPath,
		Validation: &actionspec.Validation{
			AllowedPrefixes: []string{"/var", "/tmp"},
			DeniedPaths:     []string{"/var/secrets-no-such-file"},
		},
	}}
	if _, err := Validate(schema, map[string]any{"p": "/var/log/no-such-file"}); err != nil {
		t.Fatalf("/var/log/no-such-file should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"p": "/etc/passwd"}); err == nil {
		t.Fatal("/etc/passwd should fail allowed_prefixes")
	}
	if _, err := Validate(schema, map[string]any{"p": "/var/secrets-no-such-file"}); err == nil {
		t.Fatal("/var/secrets-no-such-file should fail denied_paths")
	}
}

func TestValidate_SymlinkEscapeRejected(t *testing.T) {
	// Create a symlink under tmpdir that points outside the allowed prefix,
	// then confirm validation resolves the symlink and rejects the path.
	tmp := t.TempDir()
	outside := filepath.Join(tmp, "outside")
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	allowed := filepath.Join(tmp, "allowed")
	if err := os.MkdirAll(allowed, 0o755); err != nil {
		t.Fatal(err)
	}
	// Create a symlink "allowed/escape" -> "outside".
	escape := filepath.Join(allowed, "escape")
	if err := os.Symlink(outside, escape); err != nil {
		t.Fatal(err)
	}
	schema := []actionspec.Arg{{
		Name: "p", Type: actionspec.ArgPath,
		Validation: &actionspec.Validation{
			AllowedPrefixes: []string{allowed},
		},
	}}
	// A path under `allowed` that is actually `outside` via the symlink
	// must be rejected. Resolved path will be outside, which doesn't
	// share the allowed prefix.
	if _, err := Validate(schema, map[string]any{"p": escape}); err == nil {
		t.Fatal("symlinked path should be rejected after EvalSymlinks")
	}
}

func TestValidate_StringArrayItems(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "xs", Type: actionspec.ArgStringArray,
		Validation: &actionspec.Validation{MaxItems: ptrInt(2)},
	}}
	if _, err := Validate(schema, map[string]any{"xs": []any{"a", "b"}}); err != nil {
		t.Fatalf("2 items should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"xs": []any{"a", "b", "c"}}); err == nil {
		t.Fatal("3 items should fail max_items")
	}
	if _, err := Validate(schema, map[string]any{"xs": []any{1, "b"}}); err == nil {
		t.Fatal("non-string element should fail")
	}
}

func TestValidate_StringArrayElementPattern(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "tags", Type: actionspec.ArgStringArray,
		Validation: &actionspec.Validation{
			Pattern:  "^[a-z]+$",
			MaxItems: ptrInt(4),
		},
	}}
	if _, err := Validate(schema, map[string]any{"tags": []any{"alpha", "beta"}}); err != nil {
		t.Fatalf("valid tags should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"tags": []any{"alpha", "BAD1"}}); err == nil {
		t.Fatal("element BAD1 should fail pattern")
	}
}

func TestValidate_StringArrayElementEnum(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "modes", Type: actionspec.ArgStringArray,
		Validation: &actionspec.Validation{
			Enum: []any{"fast", "slow"},
		},
	}}
	if _, err := Validate(schema, map[string]any{"modes": []any{"fast", "slow"}}); err != nil {
		t.Fatalf("valid modes should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"modes": []any{"fast", "lol"}}); err == nil {
		t.Fatal("element lol should fail enum")
	}
}

func TestValidate_IntegerArrayElementMinMax(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "ports", Type: actionspec.ArgIntegerArray,
		Validation: &actionspec.Validation{
			Min: ptrFloat(1),
			Max: ptrFloat(65535),
		},
	}}
	if _, err := Validate(schema, map[string]any{"ports": []any{80, 443}}); err != nil {
		t.Fatalf("valid ports should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"ports": []any{80, 99999}}); err == nil {
		t.Fatal("element 99999 should fail max")
	}
}

func TestValidate_DurationMax(t *testing.T) {
	schema := []actionspec.Arg{{
		Name: "since", Type: actionspec.ArgDuration,
		Validation: &actionspec.Validation{MaxDuration: ptrDur(2 * time.Hour)},
	}}
	if _, err := Validate(schema, map[string]any{"since": "1h"}); err != nil {
		t.Fatalf("1h should pass: %v", err)
	}
	if _, err := Validate(schema, map[string]any{"since": "3h"}); err == nil {
		t.Fatal("3h should fail max_duration")
	}
}

func TestValidate_DefaultsBeforePolicy(t *testing.T) {
	// Confirms that a default value is type-coerced + validated, not bypassed.
	schema := []actionspec.Arg{{
		Name:    "port",
		Type:    actionspec.ArgInteger,
		Default: 7199,
		Validation: &actionspec.Validation{
			Allowed: []any{7199},
		},
	}}
	out, err := Validate(schema, nil)
	if err != nil {
		t.Fatalf("default 7199 should validate: %v", err)
	}
	if out["port"].(int64) != 7199 {
		t.Fatalf("expected 7199, got %v", out["port"])
	}
}
