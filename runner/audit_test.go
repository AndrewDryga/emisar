package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/audit"
)

// writeChain records n events into a real chained JSONL file at path and
// returns it — a genuine, intact hash chain for `audit verify` to walk.
func writeChain(t *testing.T, path string, n int) {
	t.Helper()
	sink, err := audit.OpenJSONL(path, audit.JSONLOptions{})
	if err != nil {
		t.Fatalf("OpenJSONL: %v", err)
	}
	j := audit.New(audit.Defaults{Group: "test"}, sink)
	for i := 0; i < n; i++ {
		if _, err := j.Record(context.Background(), audit.Event{
			Type:     audit.EventExecutionCompleted,
			EventID:  "evt_" + string(rune('a'+i)),
			ActionID: "linux.uptime",
		}); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
}

// `emisar audit verify` on an intact chain (no path → the configured
// events.jsonl) prints "chain intact" and returns nil (exit 0). Driven through
// the real command with a temp config whose journal we pre-fill with a valid
// chain.
func TestAuditVerifyCmd_IntactChainNoPath(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	flagConfig = writeMinimalConfig(t, dir, packDir)
	writeChain(t, filepath.Join(dir, "events.jsonl"), 3)

	var execErr error
	out := captureStdout(t, func() {
		cmd := auditVerifyCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(nil)
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("audit verify on an intact chain must succeed: %v", execErr)
	}
	if !strings.Contains(out, "chain intact") {
		t.Fatalf("expected the chain-intact line:\n%s", out)
	}
}

// `audit verify <path>` verifies a specific file (a path arg short-circuits
// config resolution — no boot needed).
func TestAuditVerifyCmd_ExplicitPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rotated.1")
	writeChain(t, path, 4)

	var execErr error
	out := captureStdout(t, func() {
		cmd := auditVerifyCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{path})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("audit verify <path> on an intact chain must succeed: %v", execErr)
	}
	if !strings.Contains(out, "chain intact") || !strings.Contains(out, path) {
		t.Fatalf("expected chain-intact for the explicit path:\n%s", out)
	}
}

// `audit verify <missing>` is a hard error (the open failure is NOT a
// *VerifyError, so it propagates as a returned error rather than the exit-1
// chain-break path).
func TestAuditVerifyCmd_MissingFileErrors(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist.jsonl")

	cmd := auditVerifyCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{missing})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("audit verify of a missing file must return an error")
	}
	// It must be the open error, not a chain-break (which would os.Exit(1)).
	if strings.Contains(err.Error(), "chain break") {
		t.Fatalf("missing file should be an open error, not a chain break: %v", err)
	}
}

// `audit verify --all` with no rotated siblings verifies just the active file:
// discoverRotated returns only the active path, so the command checks it and
// (intact) returns nil with a single chain-intact line.
func TestAuditVerifyCmd_AllWithNoRotatedSiblings(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	flagConfig = writeMinimalConfig(t, dir, packDir)
	active := filepath.Join(dir, "events.jsonl")
	writeChain(t, active, 3)
	// No events.jsonl.1 / .2 exist — only the active file.

	var execErr error
	out := captureStdout(t, func() {
		cmd := auditVerifyCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--all"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("audit verify --all (no siblings) must succeed: %v", execErr)
	}
	// Exactly one chain-intact line — the active file, nothing else.
	if c := strings.Count(out, "chain intact"); c != 1 {
		t.Fatalf("expected exactly one verified file (the active one), got %d:\n%s", c, out)
	}
	if !strings.Contains(out, active) {
		t.Fatalf("the active file should be the one verified:\n%s", out)
	}
}

// `audit verify` enforces MaximumNArgs(1): two positional paths is a cobra
// arg-count error.
func TestAuditVerifyCmd_MaximumNArgs(t *testing.T) {
	cmd := auditVerifyCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"a", "b"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("audit verify with 2 args must be an arg-count error")
	}
}
