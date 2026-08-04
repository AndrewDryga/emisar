package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// `emisar action list` renders the loaded registry as a table by default.
// Driven through the real command (read-only load → registry.Actions() → tabwriter)
// against a temp config + one-action pack; the header and the single action's
// id/pack/risk land in the output.
func TestActionListCmd_Table(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false)
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)

	var execErr error
	out := captureStdout(t, func() {
		cmd := actionListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("action list: %v", execErr)
	}
	if _, err := os.Stat(filepath.Join(dir, "events.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("action list created the audit journal: %v", err)
	}
	for _, want := range []string{"ID", "PACK", "KIND", "RISK", "TITLE", "linux.ping", "linux", "low"} {
		if !strings.Contains(out, want) {
			t.Fatalf("table output missing %q:\n%s", want, out)
		}
	}
}

// `action list --json` (global flag) prints the full action structs as a JSON
// array. Decoded as raw maps — not back into actionspec.Action, which would
// pass whatever the tags say — so the KEYS a fleet script parses are pinned:
// one snake_case shape all the way down, no exported Go field names.
func TestActionListCmd_JSON(t *testing.T) {
	withFlags(t)
	withJSONOut(t, true)
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)

	var execErr error
	out := captureStdout(t, func() {
		cmd := actionListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("action list --json: %v", execErr)
	}
	var actions []map[string]any
	if err := json.Unmarshal([]byte(out), &actions); err != nil {
		t.Fatalf("--json output is not a JSON action array: %v\n%s", err, out)
	}
	if len(actions) != 1 {
		t.Fatalf("want one action, got %d:\n%s", len(actions), out)
	}
	assertActionJSONShape(t, actions[0])
}

// assertActionJSONShape pins the documented action payload: snake_case keys
// including the loader-stamped pack_id, no PascalCase Go field names, and no
// loader-only host paths.
func assertActionJSONShape(t *testing.T, action map[string]any) {
	t.Helper()
	if action["id"] != "linux.ping" {
		t.Errorf(`id = %#v, want "linux.ping"`, action["id"])
	}
	if action["pack_id"] != "linux" {
		t.Errorf(`pack_id = %#v, want "linux"`, action["pack_id"])
	}
	for _, want := range []string{"schema_version", "side_effects", "execution", "output"} {
		if _, ok := action[want]; !ok {
			t.Errorf("payload missing %q key: %v", want, keysOf(action))
		}
	}
	// The legacy PascalCase spelling (untagged exported fields) must be gone,
	// and the loader's host paths must never have been in the document.
	for _, forbidden := range []string{"ID", "PackID", "SchemaVersion", "SideEffects", "PackRoot", "SourcePath", "pack_root", "source_path"} {
		if _, ok := action[forbidden]; ok {
			t.Errorf("payload must not carry %q: %v", forbidden, keysOf(action))
		}
	}
	// Nested objects are snake_case too — one document, one convention.
	execution, ok := action["execution"].(map[string]any)
	if !ok {
		t.Fatalf("execution is not an object: %#v", action["execution"])
	}
	if _, ok := execution["timeout_min"]; !ok {
		t.Errorf("execution missing timeout_min: %v", keysOf(execution))
	}
	if _, ok := execution["TimeoutMin"]; ok {
		t.Errorf("execution must not carry TimeoutMin: %v", keysOf(execution))
	}
	command, ok := execution["command"].(map[string]any)
	if !ok {
		t.Fatalf("execution.command is not an object: %#v", execution["command"])
	}
	if command["binary"] != "true" {
		t.Errorf(`execution.command.binary = %#v, want "true"`, command["binary"])
	}
}

func keysOf(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// Empty registry: with a packs dir that holds no packs, `action list` prints
// only the header row (and the JSON form an empty array) — no panic, no rows.
func TestActionListCmd_EmptyRegistry(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	emptyPacks := dir + "/packs" // exists but holds no packs
	if err := os.MkdirAll(emptyPacks, 0o755); err != nil {
		t.Fatal(err)
	}
	flagConfig = writeMinimalConfig(t, dir, emptyPacks)

	t.Run("table is header only", func(t *testing.T) {
		withJSONOut(t, false)
		var execErr error
		out := captureStdout(t, func() {
			cmd := actionListCmd()
			cmd.SilenceUsage, cmd.SilenceErrors = true, true
			execErr = cmd.Execute()
		})
		if execErr != nil {
			t.Fatalf("action list: %v", execErr)
		}
		if !strings.Contains(out, "ID") || strings.Contains(out, ".ping") {
			t.Fatalf("empty registry should be header-only:\n%s", out)
		}
	})

	t.Run("json is empty array", func(t *testing.T) {
		withJSONOut(t, true)
		var execErr error
		out := captureStdout(t, func() {
			cmd := actionListCmd()
			cmd.SilenceUsage, cmd.SilenceErrors = true, true
			execErr = cmd.Execute()
		})
		if execErr != nil {
			t.Fatalf("action list --json: %v", execErr)
		}
		var actions []map[string]any
		if err := json.Unmarshal([]byte(out), &actions); err != nil {
			t.Fatalf("--json output is not a JSON array: %v\n%s", err, out)
		}
		if len(actions) != 0 {
			t.Fatalf("empty registry should yield [], got %d actions", len(actions))
		}
	})
}

// `action list` shows the installed registry so an operator can inspect actions
// even when runner admission prevents advertising or executing them.
func TestActionListCmd_ShowsAdmissionDeniedAction(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false)
	dir := t.TempDir()
	packDir := writePack(t, dir+"/packs", "linux")
	// A config that denies the one loaded action.
	cfgPath := dir + "/config.yaml"
	yaml := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"paths:\n  packs:\n    - " + packDir + "\n  data_dir: " + dir + "/data\n" +
		"events:\n  jsonl_path: " + dir + "/events.jsonl\n" +
		"admission:\n  deny:\n    - linux.ping\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	flagConfig = cfgPath

	var execErr error
	out := captureStdout(t, func() {
		cmd := actionListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("action list: %v", execErr)
	}
	// The denied action is still LISTED (admission filters the advertised
	// catalog, not the local registry the command renders).
	if !strings.Contains(out, "linux.ping") {
		t.Fatalf("action list must show the loaded action even when admission denies it:\n%s", out)
	}
}

// `action describe <id>` prints the full action as indented JSON for a known
// id — always JSON, regardless of the --json flag (the wrapper ignores it).
func TestActionDescribeCmd_KnownID(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false) // describe ignores this and prints JSON anyway
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)

	var execErr error
	out := captureStdout(t, func() {
		cmd := actionDescribeCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"linux.ping"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("action describe: %v", execErr)
	}
	var a map[string]any
	if err := json.Unmarshal([]byte(out), &a); err != nil {
		t.Fatalf("describe output is not a JSON action: %v\n%s", err, out)
	}
	assertActionJSONShape(t, a)
}

// `action describe <unknown>` errors with the id named, exit non-zero (the
// RunE returns the error; cobra surfaces it).
func TestActionDescribeCmd_UnknownID(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packs := writePack(t, dir+"/packs", "linux")
	flagConfig = writeMinimalConfig(t, dir, packs)

	cmd := actionDescribeCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"nope.missing"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("describe of an unknown id must error")
	}
	if !strings.Contains(err.Error(), "unknown action") || !strings.Contains(err.Error(), "nope.missing") {
		t.Fatalf("error %q should name the unknown action", err)
	}
}

// `action describe` enforces ExactArgs(1): zero or two positional args is a
// cobra arg-count error before any boot/registry work.
func TestActionDescribeCmd_ExactArgs(t *testing.T) {
	for _, args := range [][]string{{}, {"a", "b"}} {
		cmd := actionDescribeCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("describe with %d args must be an arg-count error", len(args))
		}
	}
}
