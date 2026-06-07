package main

import (
	"path/filepath"
	"testing"
)

// TestCoerceArgValue_NoEvaluation: shell/JSON metacharacters in a plain value
// come back as a verbatim string — never executed, never structurally
// reinterpreted. Typed literals still coerce, preserving normal behavior.
func TestCoerceArgValue_NoEvaluation(t *testing.T) {
	verbatim := []string{"; rm -rf /", "$(touch /tmp/x)", "`reboot`", "--privileged", "a b c", "x;y|z"}
	for _, in := range verbatim {
		got := coerceArgValue(in)
		if s, ok := got.(string); !ok || s != in {
			t.Fatalf("coerceArgValue(%q) = %#v, want the verbatim string", in, got)
		}
	}
	if got := coerceArgValue("true"); got != true {
		t.Fatalf(`coerceArgValue("true") = %#v, want bool true`, got)
	}
	if got := coerceArgValue("42"); got != int64(42) {
		t.Fatalf(`coerceArgValue("42") = %#v, want int64 42`, got)
	}
}

// TestDefaultConfigPaths_ExcludesCwd: config auto-discovery must never search
// a cwd-relative path — otherwise an attacker who can drop a file in the
// process's working directory could supply the runner's config.
func TestDefaultConfigPaths_ExcludesCwd(t *testing.T) {
	for _, p := range defaultConfigPaths() {
		if !filepath.IsAbs(p) {
			t.Fatalf("config search path must be absolute, got cwd-relative %q", p)
		}
	}
}

// TestResolveConfigPath_Precedence: explicit --config wins over
// $EMISAR_CONFIG, which wins over the well-known locations.
func TestResolveConfigPath_Precedence(t *testing.T) {
	orig := flagConfig
	defer func() { flagConfig = orig }()
	t.Setenv("EMISAR_CONFIG", "/from/env.yaml")

	flagConfig = "/from/flag.yaml"
	if got, err := resolveConfigPath(); err != nil || got != "/from/flag.yaml" {
		t.Fatalf("--config must win: got %q err %v", got, err)
	}
	flagConfig = ""
	if got, err := resolveConfigPath(); err != nil || got != "/from/env.yaml" {
		t.Fatalf("$EMISAR_CONFIG must win when no flag: got %q err %v", got, err)
	}
}
