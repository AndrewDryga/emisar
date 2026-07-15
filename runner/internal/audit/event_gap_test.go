package audit

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// This file closes the PHASE-2 "gap" rows for RSEC-012 that concern the Event
// payload and the "audit log must never become world-readable, even across
// rotation" invariant (jsonl.go:48-55,229-244).

// TestJSONLSink_PermsNeverDowngraded — the directory is created
// 0o750 and the file 0o600; rotation must reopen the active file at 0o600 and
// must not loosen the directory. The log can carry redacted-but-sensitive
// metadata, so it must never become group/world-readable mid-life.
func TestJSONLSink_PermsNeverDowngraded(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix permission bits are not meaningful on windows")
	}
	// Nest one level so OpenJSONL's MkdirAll(dir, 0o750) — not t.TempDir's
	// 0o700 — is the directory under test.
	dir := filepath.Join(t.TempDir(), "audit")
	path := filepath.Join(dir, "events.jsonl")

	// Tiny threshold + several events so rotation reopens the active file.
	s, err := OpenJSONL(path, JSONLOptions{MaxSizeBytes: 200, MaxBackups: 3})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a"}, s)
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

	if di, err := os.Stat(dir); err != nil {
		t.Fatal(err)
	} else if got := di.Mode().Perm(); got != 0o750 {
		t.Fatalf("audit dir perm = %#o, want 0o750", got)
	}

	// The active file plus every rotated sibling must all be 0o600.
	checked := 0
	for _, suffix := range []string{"", ".1", ".2", ".3"} {
		p := path + suffix
		fi, err := os.Stat(p)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if got := fi.Mode().Perm(); got != 0o600 {
			t.Fatalf("%s perm = %#o, want 0o600 (must not downgrade on rotation)", p, got)
		}
		checked++
	}
	if checked < 2 {
		t.Fatalf("expected rotation to leave the active file + at least one backup, checked %d", checked)
	}
}

// TestEvent_AllTypesSerializeAndVerify — every EventType,
// including action_blocked_by_admission (the SIEM-targetable host trail), must
// serialize one-per-line and chain-verify. A new event type that breaks the
// chain would fail here.
func TestEvent_AllTypesSerializeAndVerify(t *testing.T) {
	types := []EventType{
		EventValidationFailed,
		EventDispatchRefused,
		EventExecutionStarted,
		EventExecutionCompleted,
		EventExecutionFailed,
		EventActionCancelled,
		EventActionBlockedByAdmission,
	}

	path := filepath.Join(t.TempDir(), "events.jsonl")
	s, err := OpenJSONL(path, JSONLOptions{})
	if err != nil {
		t.Fatal(err)
	}
	j := New(Defaults{AgentID: "a", Group: "g"}, s)
	for _, et := range types {
		if _, err := j.Record(context.Background(), Event{Type: et, ActionID: "x.do"}); err != nil {
			t.Fatalf("record %q: %v", et, err)
		}
	}
	if err := j.Close(); err != nil {
		t.Fatal(err)
	}

	if err := VerifyChain(path); err != nil {
		t.Fatalf("all event types should serialize into a verifiable chain, got %v", err)
	}

	// Confirm action_blocked_by_admission round-trips with its documented
	// wire value so a SIEM rule keyed on the string still fires.
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	wantWire := `"event_type":"action_blocked_by_admission"`
	if got := string(body); !strings.Contains(got, wantWire) {
		t.Fatalf("expected an event carrying %s, file:\n%s", wantWire, got)
	}
}
