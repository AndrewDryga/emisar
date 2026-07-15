package audit

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// This file closes the PHASE-2 "gap" rows for RSEC-012 that concern the Event
// payload and the on-disk file/dir permissions — the secrets-in-argv trade-off
// (event.go:54-73) and the "audit log must never become world-readable, even
// across rotation" invariant (jsonl.go:48-55,229-244).

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

// TestEvent_RawSecretInArgvButMaskedCommand —
// documented trade-off: Execution.Argv keeps the RAW argv (including secret
// values) for on-host forensics, while ExecutedCommand is the masked
// human-readable form. Confidentiality of the raw bytes rests only on the
// 0o600 file perm, not on redaction. This asserts the contract as-is.
func TestEvent_RawSecretInArgvButMaskedCommand(t *testing.T) {
	const secret = "emk-supersecrettoken"

	ev := Event{
		Type:     EventExecutionCompleted,
		ActionID: "db.connect",
		Execution: &ExecutionInfo{
			Binary:          "psql",
			Argv:            []string{"psql", "--password", secret},
			ExecutedCommand: "psql --password [REDACTED]",
		},
	}

	// Round-trip through the wire form the sink uses.
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatal(err)
	}
	var got Event
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if got.Execution == nil {
		t.Fatal("execution dropped on round-trip")
	}

	// Raw secret IS preserved in Argv (forensics trade-off).
	foundRaw := false
	for _, a := range got.Execution.Argv {
		if a == secret {
			foundRaw = true
		}
	}
	if !foundRaw {
		t.Fatalf("Argv must retain the raw secret for forensics, got %v", got.Execution.Argv)
	}
	// ...but the human-readable command must NOT contain it.
	if strings.Contains(got.Execution.ExecutedCommand, secret) {
		t.Fatalf("ExecutedCommand must be masked, leaked secret: %q", got.Execution.ExecutedCommand)
	}
	if got.Execution.ExecutedCommand != "psql --password [REDACTED]" {
		t.Fatalf("ExecutedCommand = %q, want the masked form", got.Execution.ExecutedCommand)
	}
}
