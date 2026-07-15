package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/audit"
)

type eventLineWriter chan string

func (w eventLineWriter) Write(p []byte) (int, error) {
	w <- string(p)
	return len(p), nil
}

// appendLine appends raw bytes to an existing file (used to inject a corrupt
// line into a chained JSONL log).
func appendLine(t *testing.T, path, line string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open for append: %v", err)
	}
	defer f.Close()
	if _, err := f.WriteString(line); err != nil {
		t.Fatalf("append: %v", err)
	}
}

// writeJournal records the given events into a real chained JSONL file at
// path (through the production audit sink, so the on-disk file is a genuine
// hash chain — exactly what the events/audit commands read). Returns nothing;
// the file is left closed and ready to read.
func writeJournal(t *testing.T, path string, events ...audit.Event) {
	t.Helper()
	sink, err := audit.OpenJSONL(path, audit.JSONLOptions{})
	if err != nil {
		t.Fatalf("OpenJSONL: %v", err)
	}
	j := audit.New(audit.Defaults{Group: "test"}, sink)
	for _, ev := range events {
		if ev.Type == "" {
			ev.Type = audit.EventExecutionCompleted
		}
		if _, err := j.Record(context.Background(), ev); err != nil {
			t.Fatalf("Record: %v", err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatalf("close journal: %v", err)
	}
}

// configWithJournal writes a minimal config (no cloud, no pack) whose
// events.jsonl_path holds a pre-built chain of three events with distinct
// action ids, event ids, and caller request ids — enough to exercise tail,
// cat, and every grep filter. Returns the config path and the jsonl path.
func configWithJournal(t *testing.T, dir string) (cfgPath, jsonlPath string) {
	t.Helper()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	cfgPath = writeMinimalConfig(t, dir, packDir)
	jsonlPath = filepath.Join(dir, "events.jsonl")
	writeJournal(t, jsonlPath,
		audit.Event{EventID: "evt_a", ActionID: "linux.uptime", Caller: audit.CallerRef{ControlPlaneRequestID: "req-aaa"}},
		audit.Event{EventID: "evt_b", ActionID: "linux.memory", Caller: audit.CallerRef{ControlPlaneRequestID: "req-bbb"}},
		audit.Event{EventID: "evt_c", ActionID: "linux.uptime", Caller: audit.CallerRef{ControlPlaneRequestID: "req-ccc"}},
	)
	return cfgPath, jsonlPath
}

// `emisar events tail --lines N` prints the last N events from the JSONL log.
// Non-follow path only (follow loops forever by design).
func TestEventsTailCmd_LastN(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsTailCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--lines", "1"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events tail: %v", execErr)
	}
	// Only the last event (evt_c) — not the earlier two.
	if !strings.Contains(out, "evt_c") {
		t.Fatalf("tail --lines 1 should print the last event:\n%s", out)
	}
	if strings.Contains(out, "evt_a") || strings.Contains(out, "evt_b") {
		t.Fatalf("tail --lines 1 should print ONLY the last event:\n%s", out)
	}
}

func TestEventsTailCmd_NegativeLinesRejected(t *testing.T) {
	cmd := eventsTailCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--lines", "-1"})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "non-negative") {
		t.Fatalf("negative --lines error = %v", err)
	}
}

func TestFollowJSONL_ReopensAfterRenameRotation(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(active, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(active)
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	lines := make(eventLineWriter, 1)
	go func() { done <- followJSONL(ctx, active, f, lines) }()

	if err := os.Rename(active, active+".1"); err != nil {
		t.Fatal(err)
	}
	const fresh = "{\"event_id\":\"evt_after_rotation\"}\n"
	if err := os.WriteFile(active, []byte(fresh), 0o600); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-lines:
		if got != fresh {
			t.Fatalf("followed line = %q, want %q", got, fresh)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("follow did not reopen the rotated active path")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("follow shutdown: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("follow ignored context cancellation")
	}
}

func TestPollFollowedJSONL_DrainsOldFileBeforeReplacement(t *testing.T) {
	dir := t.TempDir()
	active := filepath.Join(dir, "events.jsonl")
	if err := os.WriteFile(active, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(active)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	const oldLine = "{\"event_id\":\"evt_before_rotation\"}\n"
	appendLine(t, active, oldLine)
	if err := os.Rename(active, active+".1"); err != nil {
		t.Fatal(err)
	}
	const newLine = "{\"event_id\":\"evt_after_rotation\"}\n"
	if err := os.WriteFile(active, []byte(newLine), 0o600); err != nil {
		t.Fatal(err)
	}

	var out strings.Builder
	next, pos, err := pollFollowedJSONL(active, f, &out, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer next.Close()
	if got, want := out.String(), oldLine+newLine; got != want {
		t.Fatalf("followed bytes = %q, want old then new %q", got, want)
	}
	if pos != int64(len(newLine)) {
		t.Fatalf("new active position = %d, want %d", pos, len(newLine))
	}
}

// `events tail` with no --lines flag defaults to 50, so a short log prints
// every event.
func TestEventsTailCmd_DefaultLines(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsTailCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(nil)
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events tail: %v", execErr)
	}
	for _, id := range []string{"evt_a", "evt_b", "evt_c"} {
		if !strings.Contains(out, id) {
			t.Fatalf("default tail should print all 3 events, missing %q:\n%s", id, out)
		}
	}
}

// `events tail` over a short log (fewer events than --lines) prints exactly
// what exists, no padding and no error — the chunked tail handles a file with
// a single event. An empty log prints nothing.
func TestEventsTailCmd_ShortAndEmptyLog(t *testing.T) {
	t.Run("fewer events than --lines prints what exists", func(t *testing.T) {
		withFlags(t)
		dir := t.TempDir()
		packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
		flagConfig = writeMinimalConfig(t, dir, packDir)
		jsonl := filepath.Join(dir, "events.jsonl")
		writeJournal(t, jsonl, audit.Event{EventID: "only_one", ActionID: "linux.uptime"})

		var execErr error
		out := captureStdout(t, func() {
			cmd := eventsTailCmd()
			cmd.SilenceUsage, cmd.SilenceErrors = true, true
			cmd.SetArgs([]string{"--lines", "50"}) // far more than the one event
			execErr = cmd.Execute()
		})
		if execErr != nil {
			t.Fatalf("events tail (short log): %v", execErr)
		}
		if !strings.Contains(out, "only_one") {
			t.Fatalf("a one-event log should print that event:\n%s", out)
		}
		if n := strings.Count(strings.TrimRight(out, "\n"), "\n"); n != 0 {
			t.Fatalf("one event should be one line (0 interior newlines), got %d:\n%s", n, out)
		}
	})

	t.Run("empty log prints nothing", func(t *testing.T) {
		withFlags(t)
		dir := t.TempDir()
		packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
		flagConfig = writeMinimalConfig(t, dir, packDir)
		// Create an empty events.jsonl so openJSONL succeeds with zero events.
		if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		var execErr error
		out := captureStdout(t, func() {
			cmd := eventsTailCmd()
			cmd.SilenceUsage, cmd.SilenceErrors = true, true
			cmd.SetArgs([]string{"--lines", "10"})
			execErr = cmd.Execute()
		})
		if execErr != nil {
			t.Fatalf("events tail (empty log): %v", execErr)
		}
		if strings.TrimSpace(out) != "" {
			t.Fatalf("an empty log should produce no output, got:\n%q", out)
		}
	})
}

// `events tail` errors when the JSONL file can't be opened — here the path
// is not a readable file. The command surfaces `open jsonl: …` rather than
// printing garbage.
func TestEventsTailCmd_FileOpenFailure(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	// Point jsonl_path at a directory so the read-only open fails.
	asDir := filepath.Join(dir, "events.jsonl")
	if err := os.MkdirAll(asDir, 0o750); err != nil {
		t.Fatal(err)
	}
	flagConfig = writeMinimalConfig(t, dir, packDir)

	cmd := eventsTailCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--lines", "5"})
	if err := cmd.Execute(); err == nil {
		t.Fatal("events tail must error when the JSONL path is not a readable file")
	}
}

// `emisar events cat` dumps the entire JSONL log to stdout, byte for byte.
func TestEventsCatCmd_FullDump(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsCatCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events cat: %v", execErr)
	}
	for _, id := range []string{"evt_a", "evt_b", "evt_c"} {
		if !strings.Contains(out, id) {
			t.Fatalf("cat should dump every event, missing %q:\n%s", id, out)
		}
	}
	// JSONL: one line per event.
	if n := strings.Count(strings.TrimRight(out, "\n"), "\n"); n != 2 {
		t.Fatalf("cat of a 3-event log should have 3 lines (2 interior newlines), got %d:\n%s", n, out)
	}
}

// `events cat` errors when the JSONL path can't be opened as a file — here it
// resolves to a directory, so the command surfaces that error rather than
// dumping garbage.
func TestEventsCatCmd_BadPathErrors(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	// Point jsonl_path at a directory. Reading it as JSONL must fail.
	asDir := filepath.Join(dir, "events.jsonl")
	if err := os.MkdirAll(asDir, 0o750); err != nil {
		t.Fatal(err)
	}
	flagConfig = writeMinimalConfig(t, dir, packDir)

	cmd := eventsCatCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	if err := cmd.Execute(); err == nil {
		t.Fatal("events cat must error when the JSONL path is not a readable file")
	}
}

// `events cat` over an empty log copies zero bytes — no output, no error.
func TestEventsCatCmd_EmptyLog(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	flagConfig = writeMinimalConfig(t, dir, packDir)
	if err := os.WriteFile(filepath.Join(dir, "events.jsonl"), nil, 0o600); err != nil {
		t.Fatal(err)
	}

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsCatCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events cat (empty log): %v", execErr)
	}
	if out != "" {
		t.Fatalf("cat of an empty log should print nothing, got:\n%q", out)
	}
}

// `emisar events grep --action <id>` keeps only lines whose action_id matches
// exactly.
func TestEventsGrepCmd_FilterByAction(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsGrepCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--action", "linux.uptime"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events grep: %v", execErr)
	}
	// evt_a and evt_c are linux.uptime; evt_b (linux.memory) is excluded.
	if !strings.Contains(out, "evt_a") || !strings.Contains(out, "evt_c") {
		t.Fatalf("grep --action linux.uptime should keep both uptime events:\n%s", out)
	}
	if strings.Contains(out, "evt_b") {
		t.Fatalf("grep --action linux.uptime must exclude the linux.memory event:\n%s", out)
	}
}

// grep by event id matches exactly one event.
func TestEventsGrepCmd_FilterByEventID(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsGrepCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--event", "evt_b"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events grep: %v", execErr)
	}
	if !strings.Contains(out, "evt_b") || strings.Contains(out, "evt_a") || strings.Contains(out, "evt_c") {
		t.Fatalf("grep --event evt_b should match only evt_b:\n%s", out)
	}
}

// grep by caller does a substring match on caller.control_plane_request_id.
func TestEventsGrepCmd_FilterByCaller(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsGrepCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"--caller", "req-bbb"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events grep: %v", execErr)
	}
	if !strings.Contains(out, "evt_b") || strings.Contains(out, "evt_a") {
		t.Fatalf("grep --caller req-bbb should match only evt_b:\n%s", out)
	}
}

// Combined filters AND together: an action that matches but a caller that
// doesn't yields nothing. and (no matches).
func TestEventsGrepCmd_CombinedFiltersAndNoMatch(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	flagConfig, _ = configWithJournal(t, dir)

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsGrepCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		// linux.uptime exists, but never with caller req-bbb (that's linux.memory).
		cmd.SetArgs([]string{"--action", "linux.uptime", "--caller", "req-bbb"})
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events grep: %v", execErr)
	}
	if strings.TrimSpace(out) != "" {
		t.Fatalf("AND of action+caller that never co-occur should print nothing:\n%s", out)
	}
}

// A single line beyond the scanner's 4 MiB max buffer makes `events grep`
// return the scanner's error (bufio.ErrTooLong) rather than silently truncating
// — a pathologically long log line is surfaced, not swallowed. closes
func TestEventsGrepCmd_OversizedLineErrors(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	packDir := writePack(t, filepath.Join(dir, "packs"), "linux")
	flagConfig = writeMinimalConfig(t, dir, packDir)
	jsonl := filepath.Join(dir, "events.jsonl")

	// One JSON line whose total length exceeds the 4 MiB max-token buffer.
	// (Valid JSON so the failure is the scanner's size cap, not a parse skip.)
	big := make([]byte, 5*1024*1024)
	for i := range big {
		big[i] = 'x'
	}
	line := append([]byte(`{"event_id":"big","blob":"`), big...)
	line = append(line, []byte(`"}`+"\n")...)
	if err := os.WriteFile(jsonl, line, 0o600); err != nil {
		t.Fatal(err)
	}

	cmd := eventsGrepCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs(nil)
	// captureStdout drains the pipe so a partial write can't deadlock; we only
	// care that Execute returns the scanner error.
	var execErr error
	captureStdout(t, func() { execErr = cmd.Execute() })
	if execErr == nil {
		t.Fatal("a line beyond the 4 MiB max buffer must surface the scanner error")
	}
}

// A corrupt (unparseable) line is skipped, not fatal — grep keeps scanning and
// returns the good lines.
func TestEventsGrepCmd_SkipsUnparseableLine(t *testing.T) {
	withFlags(t)
	dir := t.TempDir()
	cfgPath, jsonlPath := configWithJournal(t, dir)
	flagConfig = cfgPath

	// Append a garbage line that is not valid JSON. It must not break the scan.
	appendLine(t, jsonlPath, "this is not json\n")

	var execErr error
	out := captureStdout(t, func() {
		cmd := eventsGrepCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(nil) // no filters → all parseable lines
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("events grep should not fail on a corrupt line: %v", execErr)
	}
	if !strings.Contains(out, "evt_a") || !strings.Contains(out, "evt_c") {
		t.Fatalf("grep should still emit the parseable events:\n%s", out)
	}
	if strings.Contains(out, "this is not json") {
		t.Fatalf("the unparseable line must be skipped, not echoed:\n%s", out)
	}
}
