package audit

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestJSONLSink_AppendsOnePerLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a", Group: "g"}, s)
	for i := 0; i < 3; i++ {
		if _, err := j.Record(context.Background(), Event{
			Type:     EventExecutionCompleted,
			ActionID: "x.do",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	count := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatalf("line %d: %v", count+1, err)
		}
		if ev.ActionID != "x.do" {
			t.Fatalf("line %d: action_id=%q", count+1, ev.ActionID)
		}
		if ev.EventID == "" {
			t.Fatalf("line %d: missing event_id", count+1)
		}
		count++
	}
	if count != 3 {
		t.Fatalf("expected 3 events, got %d", count)
	}
}

func TestJSONLSink_RotatesAtThreshold(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.jsonl")
	// Tiny threshold so a handful of events trigger rotation.
	s, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 200, MaxBackups: 2})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a", Group: "g"}, s)
	for i := 0; i < 30; i++ {
		if _, err := j.Record(context.Background(), Event{
			Type: EventExecutionCompleted, ActionID: "x.do",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	// Active file plus at most MaxBackups rotated files should exist.
	for _, suffix := range []string{"", ".1", ".2"} {
		if _, err := os.Stat(path + suffix); err != nil {
			t.Fatalf("missing %s: %v", path+suffix, err)
		}
	}
	// .3 (the oldest pre-rotation backup) should NOT exist — we capped at 2.
	if _, err := os.Stat(path + ".3"); !os.IsNotExist(err) {
		t.Fatalf("expected %s to be absent: %v", path+".3", err)
	}
}

func TestJSONLSink_BackupRotationFailureKeepsActiveChain(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{MaxBackups: 2})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.first"}); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".1", original, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path+".2", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path+".2", "obstruction"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	chainHead := s.lastHash
	s.maxSizeBytes = 1
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.blocked"}); err == nil {
		t.Fatal("expected obstructed backup rotation to fail")
	}
	if s.f == nil {
		t.Fatal("rotation failure must reopen the unchanged active log")
	}
	if s.lastHash != chainHead {
		t.Fatalf("chain head changed after failed rotation: got %q, want %q", s.lastHash, chainHead)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("failed rotation modified the active log")
	}
	if obstruction, err := os.ReadFile(filepath.Join(path+".2", "obstruction")); err != nil || string(obstruction) != "x" {
		t.Fatalf("failed backup replacement modified its destination: body=%q err=%v", obstruction, err)
	}

	if err := os.RemoveAll(path + ".2"); err != nil {
		t.Fatal(err)
	}
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.retry"}); err == nil || !strings.Contains(err.Error(), "previously failed") {
		t.Fatalf("rotation failure must remain latched until restart, got %v", err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}

	s, err = OpenJSONL(path, JSONLOptions{MaxSizeBytes: 1, MaxBackups: 2})
	if err != nil {
		t.Fatal(err)
	}
	j = New(Defaults{AgentID: "a"}, s)
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.retry"}); err != nil {
		t.Fatalf("restart after clearing obstruction: %v", err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{path, path + ".1"} {
		if err := VerifyChain(p); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
	}
}

func TestJSONLSink_ActiveRotationFailureKeepsActiveChain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{MaxBackups: 1})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.first"}); err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path+".1", 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path+".1", "obstruction"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	chainHead := s.lastHash
	s.maxSizeBytes = 1
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.blocked"}); err == nil {
		t.Fatal("expected obstructed active rotation to fail")
	}
	if s.f == nil {
		t.Fatal("rotation failure must reopen the unchanged active log")
	}
	if s.lastHash != chainHead {
		t.Fatalf("chain head changed after failed rotation: got %q, want %q", s.lastHash, chainHead)
	}
	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("failed rotation modified the active log")
	}
	if obstruction, err := os.ReadFile(filepath.Join(path+".1", "obstruction")); err != nil || string(obstruction) != "x" {
		t.Fatalf("failed active replacement modified its destination: body=%q err=%v", obstruction, err)
	}
	if err := os.RemoveAll(path + ".1"); err != nil {
		t.Fatal(err)
	}
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.retry"}); err == nil || !strings.Contains(err.Error(), "previously failed") {
		t.Fatalf("rotation failure must remain latched until restart, got %v", err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}

	s, err = OpenJSONL(path, JSONLOptions{MaxSizeBytes: 1, MaxBackups: 1})
	if err != nil {
		t.Fatal(err)
	}
	j = New(Defaults{AgentID: "a"}, s)
	if _, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted, ActionID: "x.retry"}); err != nil {
		t.Fatalf("restart after clearing obstruction: %v", err)
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}
	if err := VerifyChain(path); err != nil {
		t.Fatal(err)
	}
}

func TestJournal_DefaultsStamped(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenJSONL(filepath.Join(dir, "e.jsonl"), JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "agt", Group: "g1"}, s)
	defer j.Close()
	ev, err := j.Record(context.Background(), Event{Type: EventExecutionCompleted})
	if err != nil {
		t.Fatal(err)
	}
	if ev.AgentID != "agt" || ev.Group != "g1" {
		t.Fatalf("defaults not stamped: runner=%q group=%q", ev.AgentID, ev.Group)
	}
}
