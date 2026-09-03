package cloud

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode"
	"unicode/utf8"
)

// shutdown.Message is free text the control plane chooses, and doctor renders
// it straight into the operator's terminal — the one command every runbook says
// to run when a runner stops. A compromised portal must not be able to send ESC
// sequences that clear the screen and repaint a fabricated all-green report over
// its own rejection, nor bidi overrides that reverse the reason it gives. The
// message is sanitized where it enters durable state, so every reader gets safe
// text.
func TestWriteTerminalShutdownStripsTerminalControlSequences(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "terminal_shutdown.json")
	hostile := "\x1b[2J\x1b[H  \u2713  cloud  reachable\r\nall checks passed\u202egnitseT\u2069 next"

	if err := WriteTerminalShutdown(statePath, "runner_revoked", hostile); err != nil {
		t.Fatal(err)
	}
	state, err := ReadRecentTerminalShutdown(statePath, time.Now().UTC())
	if err != nil || state == nil {
		t.Fatalf("read persisted shutdown: state=%v err=%v", state, err)
	}

	for _, r := range state.Message {
		if unicode.IsControl(r) || unicode.Is(unicode.Bidi_Control, r) || r == '\u2028' || r == '\u2029' {
			t.Fatalf("persisted message keeps U+%04X: %q", r, state.Message)
		}
	}
	// One line: nothing the peer sends may start a second report line.
	if strings.ContainsAny(state.Message, "\n\r") {
		t.Fatalf("persisted message spans lines: %q", state.Message)
	}
	// The visible words survive, so a stripped message still reads as tampered
	// rather than as clean prose.
	if !strings.Contains(state.Message, "all checks passed") {
		t.Fatalf("sanitizing dropped the visible text: %q", state.Message)
	}
	// The payload must not survive on disk either, in raw or JSON-escaped form —
	// an operator may read the state file directly.
	raw, err := os.ReadFile(statePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"\x1b", "\\u001b", "\\u202e"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatalf("state file still carries %q: %s", forbidden, raw)
		}
	}
}

// The record may be 16 KiB; one aligned doctor line may not. A bounded message
// stays valid UTF-8 so the JSON state and the report both survive a cut inside
// a multi-byte rune.
func TestWriteTerminalShutdownBoundsTheMessage(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "terminal_shutdown.json")
	if err := WriteTerminalShutdown(statePath, "runner_revoked", strings.Repeat("é", 4000)); err != nil {
		t.Fatal(err)
	}
	state, err := ReadRecentTerminalShutdown(statePath, time.Now().UTC())
	if err != nil || state == nil {
		t.Fatalf("read persisted shutdown: state=%v err=%v", state, err)
	}
	if len(state.Message) > maxShutdownMessageBytes+len("…") {
		t.Fatalf("message is %d bytes, want at most %d", len(state.Message), maxShutdownMessageBytes+len("…"))
	}
	if !utf8.ValidString(state.Message) {
		t.Fatalf("bounded message is not valid UTF-8: %q", state.Message)
	}
	if !strings.HasSuffix(state.Message, "…") {
		t.Fatalf("a cut message must say so: %q", state.Message)
	}
}

// An ordinary operator-facing explanation must survive untouched — sanitizing
// is not allowed to mangle the message the console actually sends.
func TestWriteTerminalShutdownKeepsOrdinaryText(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "terminal_shutdown.json")
	want := "Removed by alice@example.com on 2026-09-03 — re-register to restore it."
	if err := WriteTerminalShutdown(statePath, "runner_revoked", want); err != nil {
		t.Fatal(err)
	}
	state, err := ReadRecentTerminalShutdown(statePath, time.Now().UTC())
	if err != nil || state == nil {
		t.Fatalf("read persisted shutdown: state=%v err=%v", state, err)
	}
	if state.Message != want {
		t.Fatalf("message = %q, want %q", state.Message, want)
	}
}
