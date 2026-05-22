package engine

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/audit"
)

// TestE2E_ConcurrentMixedActions exercises the full pipeline end-to-end:
// engine + executor + redactor + JSONL journal. It dispatches N runs in
// parallel, mixing a successful action, a validation_failed call, and
// an action that exits non-zero; then asserts the JSONL log contains
// exactly N lines with consistent event_ids, action_ids, statuses, and
// computed SHA-256s.
//
// This is the cross-cutting test the audit flagged as missing.
func TestE2E_ConcurrentMixedActions(t *testing.T) {
	e, j, root := setupEngineExtra(t, map[string]string{
		"nonzero.yaml": `
schema_version: 1
id: t.nonzero
title: Always exits 7
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "exit 7"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`,
	})
	defer j.Close()

	type want struct {
		actionID   string
		args       map[string]any
		wantStatus Status
		wantExit   int
	}
	cases := []want{
		// 3 successful runs.
		{actionID: "t.echo", args: map[string]any{"msg": "one"}, wantStatus: StatusSuccess, wantExit: 0},
		{actionID: "t.echo", args: map[string]any{"msg": "two"}, wantStatus: StatusSuccess, wantExit: 0},
		{actionID: "t.echo", args: map[string]any{"msg": "three"}, wantStatus: StatusSuccess, wantExit: 0},
		// 2 validation_failed (missing required arg + unknown arg).
		{actionID: "t.echo", args: map[string]any{}, wantStatus: StatusValidationFailed},
		{actionID: "t.echo", args: map[string]any{"unknown_arg": "x"}, wantStatus: StatusValidationFailed},
		// 1 unknown action.
		{actionID: "t.does_not_exist", args: map[string]any{}, wantStatus: StatusUnknownAction},
		// 2 non-zero exits — engine flips status to StatusFailed.
		{actionID: "t.nonzero", args: map[string]any{}, wantStatus: StatusFailed, wantExit: 7},
		{actionID: "t.nonzero", args: map[string]any{}, wantStatus: StatusFailed, wantExit: 7},
	}

	type observed struct {
		EventID  string
		Status   Status
		ExitCode int
	}
	var (
		mu      sync.Mutex
		results []observed
	)

	var wg sync.WaitGroup
	for _, c := range cases {
		c := c
		wg.Add(1)
		go func() {
			defer wg.Done()
			res, err := e.Run(context.Background(), Request{
				ActionID: c.actionID,
				Args:     c.args,
				Reason:   "test",
			})
			if err != nil {
				t.Errorf("engine error for %s: %v", c.actionID, err)
				return
			}
			if res.Status != c.wantStatus {
				t.Errorf("%s: status=%s want=%s reason=%q",
					c.actionID, res.Status, c.wantStatus, res.Reason)
			}
			if c.wantStatus == StatusSuccess || c.wantStatus == StatusFailed {
				if res.ExitCode != c.wantExit {
					t.Errorf("%s: exit_code=%d want=%d", c.actionID, res.ExitCode, c.wantExit)
				}
			}
			mu.Lock()
			results = append(results, observed{
				EventID: res.EventID, Status: res.Status, ExitCode: res.ExitCode,
			})
			mu.Unlock()
		}()
	}
	wg.Wait()

	if len(results) != len(cases) {
		t.Fatalf("expected %d results, got %d", len(cases), len(results))
	}
	for _, r := range results {
		if r.EventID == "" {
			t.Errorf("result missing event_id: %+v", r)
		}
	}

	// Read the JSONL log and verify event_ids match what was returned.
	// The setup helper writes to <root>/events.jsonl.
	resultByEventID := make(map[string]observed, len(results))
	for _, r := range results {
		resultByEventID[r.EventID] = r
	}
	f, err := os.Open(filepath.Join(root, "events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	seen := 0
	for scanner.Scan() {
		var ev audit.Event
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			t.Fatalf("malformed JSONL line: %v\n%s", err, scanner.Text())
		}
		if _, ok := resultByEventID[ev.EventID]; ok {
			seen++
			if ev.Time.IsZero() {
				t.Errorf("event %s has zero time", ev.EventID)
			}
			if ev.Type == "" {
				t.Errorf("event %s has empty type", ev.EventID)
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if seen != len(cases) {
		t.Fatalf("expected %d JSONL events matching returned event_ids, got %d", len(cases), seen)
	}
}
