package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/pkg/packspec"
)

// withPacksDir points the read-only pack commands at dir via the global
// --packs-dir flag, so `pack list`/`info` resolve without a full config.
// Also clears EMISAR_CONFIG so resolvePackDirs can't fall back to a real
// /etc config on the dev box.
func withPacksDir(t *testing.T, dirs ...string) {
	t.Helper()
	origPacks, origConfig := flagPacksDir, flagConfig
	t.Cleanup(func() { flagPacksDir, flagConfig = origPacks, origConfig })
	t.Setenv("EMISAR_CONFIG", "")
	flagPacksDir = dirs
	flagConfig = ""
}

// `emisar pack list` renders installed packs as a table: id, version, action
// count, short hash, description. Driven read-only through --packs-dir (no
// config / boot) against one valid pack.
func TestPackListCmd_Table(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list: %v", execErr)
	}
	for _, want := range []string{"ID", "VERSION", "ACTIONS", "HASH", "redis", "0.0.1", "sha256:"} {
		if !strings.Contains(out, want) {
			t.Fatalf("pack list table missing %q:\n%s", want, out)
		}
	}
}

// `pack list --json` prints the full pack structs; we decode back into the
// real packspec.Pack type so the check is field-tag agnostic.
func TestPackListCmd_JSON(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, true)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list --json: %v", execErr)
	}
	var ps []packspec.Pack
	if err := json.Unmarshal([]byte(out), &ps); err != nil {
		t.Fatalf("--json output is not a pack array: %v\n%s", err, out)
	}
	if len(ps) != 1 || ps[0].ID != "redis" {
		t.Fatalf("want one pack redis, got %+v", ps)
	}
}

// `pack list --packs-dir` works without any config (read-only path). Pointing
// at an empty dir yields just the header row, no pack rows.
// (no-config read) and (empty dir).
func TestPackListCmd_EmptyDirNoConfig(t *testing.T) {
	empty := t.TempDir()
	withPacksDir(t, empty)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packListCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack list (empty dir): %v", execErr)
	}
	if !strings.Contains(out, "ID") {
		t.Fatalf("expected the header row:\n%s", out)
	}
	// No pack id rows.
	if strings.Contains(out, "0.0.1") {
		t.Fatalf("empty dir should list no packs:\n%s", out)
	}
}

// `pack list` with neither --packs-dir nor a resolvable config is a hard
// error that wraps the config-resolution failure (so the operator knows to
// pass --packs-dir or --config).
func TestPackListCmd_NoDirNoConfigErrors(t *testing.T) {
	origPacks, origConfig := flagPacksDir, flagConfig
	t.Cleanup(func() { flagPacksDir, flagConfig = origPacks, origConfig })
	flagPacksDir = nil
	flagConfig = ""
	t.Setenv("EMISAR_CONFIG", "")
	t.Setenv("HOME", t.TempDir()) // no well-known per-user config either

	cmd := packListCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	err := cmd.Execute()
	if err == nil {
		t.Fatal("pack list with no --packs-dir and no config must error")
	}
	if !strings.Contains(err.Error(), "packs-dir") {
		t.Fatalf("error %q should tell the operator to pass --packs-dir", err)
	}
}

// `pack list` surfaces a load error when the packs dir holds a malformed pack:
// LoadAll fails and the command returns that error (exit 1) rather than
// silently listing nothing.
func TestPackListCmd_MalformedPackErrors(t *testing.T) {
	root := t.TempDir()
	// A pack dir with a pack.yaml that references an action file declaring a
	// single-segment id (no pack prefix) — LoadAll rejects it.
	packDir := filepath.Join(root, "broken")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "pack.yaml"), []byte(
		"schema_version: 1\nid: broken\nname: t\nversion: 0.0.1\ndescription: t\nactions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: ping\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: /bin/echo\n    argv: []\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withPacksDir(t, root)
	withJSONOut(t, false)

	cmd := packListCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	if err := cmd.Execute(); err == nil {
		t.Fatal("pack list must surface a malformed-pack load error")
	}
}

// `pack info <id>` prints the operator summary: header line with id/name/
// version, the action+risk profile, and — for a pack with no setup block —
// the honest "no credentials needed" line. Read-only via --packs-dir.
// (summary) and (no-setup message).
func TestPackInfoCmd_Summary(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info: %v", execErr)
	}
	for _, want := range []string{"redis", "v0.0.1", "Actions:", "Setup", "No credentials needed"} {
		if !strings.Contains(out, want) {
			t.Fatalf("pack info summary missing %q:\n%s", want, out)
		}
	}
}

// `pack info <id> --json` prints the full pack struct instead of the human
// summary.
func TestPackInfoCmd_JSON(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, true)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info --json: %v", execErr)
	}
	var p packspec.Pack
	if err := json.Unmarshal([]byte(out), &p); err != nil {
		t.Fatalf("--json output is not a pack struct: %v\n%s", err, out)
	}
	if p.ID != "redis" {
		t.Fatalf("pack id = %q, want redis", p.ID)
	}
}

// `pack info <unknown>` errors, naming the id and where it looked.
func TestPackInfoCmd_NotInstalled(t *testing.T) {
	root := t.TempDir()
	writeValidPack(t, root, "redis")
	withPacksDir(t, root)
	withJSONOut(t, false)

	cmd := packInfoCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"nope"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("pack info for an uninstalled pack must error")
	}
	if !strings.Contains(err.Error(), "nope") || !strings.Contains(err.Error(), "not installed") {
		t.Fatalf("error %q should say the pack isn't installed", err)
	}
}

// `pack info <id>` with no resolvable config renders best-effort — it skips
// the "missing from inherit_env" cross-check entirely (that check needs a
// config to know the runner's inherit_env). The env block still prints, but
// the "! Required vars not in this config's inherit_env" warning does not, even
// for a required var.
func TestPackInfoCmd_NoConfigSkipsInheritEnvCrossCheck(t *testing.T) {
	root := t.TempDir()
	// A pack whose setup declares a REQUIRED env var. With a config, an empty
	// inherit_env would flag PGHOST; without one, the cross-check is skipped.
	packDir := filepath.Join(root, "withenv")
	if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "pack.yaml"), []byte(
		"schema_version: 1\nid: withenv\nname: t\nversion: 0.0.1\ndescription: t\n"+
			"setup:\n  summary: needs a host\n  env:\n    - name: PGHOST\n      required: true\n"+
			"actions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: withenv.a\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: /bin/echo\n    argv: [\"hi\"]\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// --packs-dir set, no config (withPacksDir clears EMISAR_CONFIG + flagConfig).
	withPacksDir(t, root)
	t.Setenv("HOME", t.TempDir()) // and no well-known per-user config to discover
	withJSONOut(t, false)

	var execErr error
	out := captureStdout(t, func() {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"withenv"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack info (no config): %v", execErr)
	}
	// The env var is still documented in the Environment block...
	if !strings.Contains(out, "PGHOST") {
		t.Fatalf("the env block should still list the var:\n%s", out)
	}
	// ...but the inherit_env cross-check warning is suppressed (no config).
	if strings.Contains(out, "not in this config's inherit_env") {
		t.Fatalf("no-config pack info must skip the inherit_env cross-check:\n%s", out)
	}
}

// `pack info` enforces ExactArgs(1): zero or two positional args is a cobra
// arg-count error, surfaced before any pack load.
func TestPackInfoCmd_ExactArgs(t *testing.T) {
	for _, args := range [][]string{{}, {"a", "b"}} {
		cmd := packInfoCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("pack info with %d args must be an arg-count error", len(args))
		}
	}
}

// `emisar pack validate ./pack` prints a machine-parseable OK line and the
// content hash to stdout for a valid pack. Driven on a path from t.TempDir(),
// no config/network.
func TestPackValidateCmd_OK(t *testing.T) {
	src := writeValidPack(t, t.TempDir(), "redis")

	var execErr error
	out := captureStdout(t, func() {
		cmd := packValidateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{src})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("pack validate: %v", execErr)
	}
	if !strings.Contains(out, "pack redis OK: 1 actions") {
		t.Fatalf("validate should print the OK line with the action count:\n%s", out)
	}
	if !strings.Contains(out, "hash: sha256:") {
		t.Fatalf("validate should print the content hash:\n%s", out)
	}
}

// `pack validate` on a schema-broken pack errors (exit 1) with the loader's
// reason. Here: an action whose id is a single segment (no pack prefix),
// which LoadOne rejects.
func TestPackValidateCmd_InvalidPackErrors(t *testing.T) {
	root := filepath.Join(t.TempDir(), "broken")
	if err := os.MkdirAll(filepath.Join(root, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	// id "broken" with an action id "ping" (no "broken." prefix) — a
	// single-segment action id the loader refuses.
	if err := os.WriteFile(filepath.Join(root, "pack.yaml"), []byte(
		"schema_version: 1\nid: broken\nname: t\nversion: 0.0.1\ndescription: t\nactions:\n  - actions/a.yaml\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "actions", "a.yaml"), []byte(
		"schema_version: 1\nid: ping\ntitle: t\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\nargs: []\n"+
			"execution:\n  command:\n    binary: /bin/echo\n    argv: []\n  timeout: 5s\n"+
			"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmd := packValidateCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{root})
	if err := cmd.Execute(); err == nil {
		t.Fatal("pack validate of a schema-broken pack must error")
	}
}

// `pack validate` enforces ExactArgs(1): zero or two paths is a cobra
// arg-count error.
func TestPackValidateCmd_ExactArgs(t *testing.T) {
	for _, args := range [][]string{{}, {"a", "b"}} {
		cmd := packValidateCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Fatalf("validate with %d args must be an arg-count error", len(args))
		}
	}
}
