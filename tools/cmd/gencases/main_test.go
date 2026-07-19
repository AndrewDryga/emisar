package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSafeDefault(t *testing.T) {
	arg := func(name, typ string, mut func(*argDef)) argDef {
		a := argDef{Name: name, Type: typ}
		if mut != nil {
			mut(&a)
		}
		return a
	}
	cases := []struct {
		name string
		arg  argDef
		want any
	}{
		{"declared default wins", arg("x", "string", func(a *argDef) { a.Default = "declared" }), "declared"},
		{"pid", arg("pid", "integer", nil), 1},
		{"port", arg("port", "integer", nil), 80},
		{"limit-ish", arg("count", "integer", nil), 10},
		{"other integer", arg("ttl", "integer", nil), 0},
		{"boolean", arg("verbose", "boolean", nil), false},
		{"enum head", arg("mode", "string", func(a *argDef) { a.Validation.Enum = []any{"fast", "slow"} }), "fast"},
		{"absolute-path pattern", arg("path", "string", func(a *argDef) { a.Validation.Pattern = "^/etc/.+" }), "/etc/hostname"},
		{"string fallback", arg("name", "string", nil), "smoke"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := safeDefault(c.arg); got != c.want {
				t.Errorf("safeDefault = %v, want %v", got, c.want)
			}
		})
	}
}

func TestDeriveArgs(t *testing.T) {
	t.Run("example wins, missing required filled", func(t *testing.T) {
		action := actionDef{
			Args: []argDef{
				{Name: "db", Type: "integer", Required: true},
				{Name: "given", Type: "string", Required: true},
			},
		}
		action.Examples = []struct {
			Args map[string]any `yaml:"args"`
		}{{Args: map[string]any{"given": "from-example"}}}

		got := deriveArgs(action)
		want := map[string]any{"given": "from-example", "db": 0}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("deriveArgs = %v, want %v", got, want)
		}
	})

	t.Run("no example: required + defaulted args only", func(t *testing.T) {
		action := actionDef{
			Args: []argDef{
				{Name: "required", Type: "string", Required: true},
				{Name: "defaulted", Type: "string", Default: "d"},
				{Name: "optional", Type: "string"},
			},
		}
		got := deriveArgs(action)
		want := map[string]any{"required": "smoke", "defaulted": "d"}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("deriveArgs = %v, want %v", got, want)
		}
	})
}

func TestEmitPack_RiskAndOverrideBranches(t *testing.T) {
	// A fixture pack named "redis" so packEnv and the redis.flushall
	// nil-override (skip-by-default) policy entries both engage.
	dir := t.TempDir()
	packDir := filepath.Join(dir, "redis")
	writeAction := func(file, content string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(packDir, "actions", file), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeAction("a_info.yaml", "id: redis.info\nrisk: low\nargs: []\n")
	writeAction("b_flushall.yaml", "id: redis.flushall\nrisk: critical\nargs: []\n")
	writeAction("c_failover.yaml", "id: redis.failover_unlisted\nrisk: high\nargs: []\n")

	got, err := emitPack(packDir)
	if err != nil {
		t.Fatalf("emitPack: %v", err)
	}
	if got.Defaults.Env["REDIS_HOST"] != "redis" {
		t.Errorf("packEnv not applied: %v", got.Defaults.Env)
	}

	want := []testCase{
		{Action: "redis.info", Args: map[string]any{}, ExpectExit: 0},
		// actionArgs nil override: skipped with the --include hint, no expect_exit.
		{Action: "redis.flushall", Args: map[string]any{},
			Skip: "mutator skipped by default (critical); set --include=redis.flushall to run"},
		// Unlisted non-low mutator: tolerant exit + default skip.
		{Action: "redis.failover_unlisted", Args: map[string]any{},
			ExpectExit: []int{0, 1}, Skip: "mutator skipped by default (high)"},
	}
	if !reflect.DeepEqual(got.Cases, want) {
		t.Errorf("cases = %#v\nwant %#v", got.Cases, want)
	}
}

func TestEmitPackAddsStdoutAssertions(t *testing.T) {
	dir := t.TempDir()
	packDir := filepath.Join(dir, "nomad")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(packDir, "actions", "autopilot.yaml")
	if err := os.WriteFile(path, []byte("id: nomad.operator_autopilot_state\nrisk: low\nargs: []\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := emitPack(packDir)
	if err != nil {
		t.Fatalf("emitPack: %v", err)
	}
	want := []string{`"Healthy"`}
	if len(got.Cases) != 1 || !reflect.DeepEqual(got.Cases[0].ExpectStdoutContains, want) {
		t.Fatalf("stdout assertions = %#v, want %#v", got.Cases, want)
	}
}
