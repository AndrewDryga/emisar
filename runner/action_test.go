package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
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
// array. We decode back into the real actionspec.Action type so the assertion
// is independent of field-tag naming.
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
	var actions []actionspec.Action
	if err := json.Unmarshal([]byte(out), &actions); err != nil {
		t.Fatalf("--json output is not a JSON action array: %v\n%s", err, out)
	}
	if len(actions) != 1 || actions[0].ID != "linux.ping" {
		t.Fatalf("want one action linux.ping, got %+v", actions)
	}
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
		var actions []actionspec.Action
		if err := json.Unmarshal([]byte(out), &actions); err != nil {
			t.Fatalf("--json output is not a JSON array: %v\n%s", err, out)
		}
		if len(actions) != 0 {
			t.Fatalf("empty registry should yield [], got %d actions", len(actions))
		}
	})
}

// `action list` reflects the LOADED registry, not the admission-filtered
// catalog: an action denied by runner admission still appears in `action list`
// (admission only hides actions from the catalog advertised to cloud, RUN-035;
// the local command shows what's installed so an operator can see a denied
// action exists).
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
	var a actionspec.Action
	if err := json.Unmarshal([]byte(out), &a); err != nil {
		t.Fatalf("describe output is not a JSON action: %v\n%s", err, out)
	}
	if a.ID != "linux.ping" {
		t.Fatalf("described id = %q, want linux.ping", a.ID)
	}
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
