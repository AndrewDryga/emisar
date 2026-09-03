package cloud

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// TerminalShutdownFreshness is the maximum age for which doctor treats a
// persisted terminal shutdown as the current cloud status.
const TerminalShutdownFreshness = 24 * time.Hour

// ReasonProtocolVersionUnsupported is the runner's OWN terminal condition: the
// control plane speaks a wire-protocol version this build cannot read. It is
// never accepted from a shutdown frame — terminalShutdownReason still governs
// what the portal may declare — so a peer cannot claim it.
const ReasonProtocolVersionUnsupported = "protocol_version_unsupported"

const (
	terminalShutdownStateFilename = "terminal_shutdown.json"
	maxTerminalShutdownStateBytes = 16 << 10
	// maxShutdownMessageBytes bounds the peer's free-text explanation. The
	// record as a whole may be 16 KiB, which is still a wall of text on one
	// aligned line of the doctor report.
	maxShutdownMessageBytes = 300
)

// terminalSafeLine makes control-plane free text safe to print on an operator's
// terminal, collapsed onto one line. Reason is checked against a fixed set;
// Message is whatever the peer chose, and doctor renders it into the terminal —
// so a message carrying ESC sequences could clear the screen and paint a
// fabricated all-green report over the very rejection the operator ran doctor
// to read. Controls become spaces rather than vanishing, so tampered text still
// reads as tampered. (Same shape as the MCP bridge's renderer; separate
// modules, no shared import.)
func terminalSafeLine(value string) string {
	safe := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Bidi_Control, r) || r == '\u2028' || r == '\u2029' {
			return ' '
		}
		return r
	}, value)
	safe = strings.Join(strings.Fields(safe), " ")
	if len(safe) <= maxShutdownMessageBytes {
		return safe
	}
	cut := maxShutdownMessageBytes
	for cut > 0 && !utf8.RuneStart(safe[cut]) {
		cut--
	}
	return safe[:cut] + "…"
}

// TerminalShutdownState is the small durable record written when the cloud
// tells this runner it must stop until an operator changes its state.
type TerminalShutdownState struct {
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

// TerminalShutdownStatePath returns the state path in the runner's existing
// durable data directory, alongside dispatches.jsonl.
func TerminalShutdownStatePath(dataDir string) string {
	if strings.TrimSpace(dataDir) == "" {
		return ""
	}
	return filepath.Join(dataDir, terminalShutdownStateFilename)
}

// persistedShutdownReason accepts what may live in the durable state: the
// portal's terminal shutdown reasons plus the conditions the runner records
// about itself. It stays separate from terminalShutdownReason, which classifies
// what a SHUTDOWN FRAME may declare, so a peer can never send a locally-owned
// reason and have it treated as its own rejection.
func persistedShutdownReason(reason string) bool {
	return terminalShutdownReason(reason) || reason == ReasonProtocolVersionUnsupported
}

// WriteTerminalShutdown persists a terminal cloud rejection using the same
// synced temp-file replacement used by the runner's other durable state.
func WriteTerminalShutdown(path, reason, message string) error {
	if path == "" {
		return errors.New("cloud: terminal shutdown state path is empty")
	}
	if !persistedShutdownReason(reason) {
		return fmt.Errorf("cloud: %q is not a terminal shutdown reason", reason)
	}

	body, err := json.Marshal(TerminalShutdownState{
		Reason:    reason,
		Message:   terminalSafeLine(message),
		Timestamp: time.Now().UTC(),
	})
	if err != nil {
		return fmt.Errorf("cloud: marshal terminal shutdown state: %w", err)
	}
	body = append(body, '\n')
	if len(body) > maxTerminalShutdownStateBytes {
		return fmt.Errorf("cloud: terminal shutdown state exceeds %d bytes", maxTerminalShutdownStateBytes)
	}

	if err := fsutil.ReplaceFile(path, func(w io.Writer) error {
		_, err := w.Write(body)
		return err
	}); err != nil {
		return fmt.Errorf("cloud: persist terminal shutdown state: %w", err)
	}
	return nil
}

// ReadRecentTerminalShutdown returns a terminal rejection only while it is
// fresh. Missing and stale state are normal: doctor should then report the
// current reachability probe instead.
func ReadRecentTerminalShutdown(path string, now time.Time) (*TerminalShutdownState, error) {
	if path == "" {
		return nil, nil
	}
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cloud: stat terminal shutdown state: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("cloud: terminal shutdown state is not a regular file")
	}
	if info.Size() > maxTerminalShutdownStateBytes {
		return nil, fmt.Errorf("cloud: terminal shutdown state exceeds %d bytes", maxTerminalShutdownStateBytes)
	}
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cloud: read terminal shutdown state: %w", err)
	}
	if len(body) > maxTerminalShutdownStateBytes {
		return nil, fmt.Errorf("cloud: terminal shutdown state exceeds %d bytes", maxTerminalShutdownStateBytes)
	}

	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var state TerminalShutdownState
	if err := decoder.Decode(&state); err != nil {
		return nil, fmt.Errorf("cloud: decode terminal shutdown state: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("cloud: terminal shutdown state has trailing JSON")
		}
		return nil, fmt.Errorf("cloud: decode terminal shutdown state trailer: %w", err)
	}
	if !persistedShutdownReason(state.Reason) || state.Timestamp.IsZero() {
		return nil, nil
	}

	age := now.UTC().Sub(state.Timestamp.UTC())
	if age < 0 || age > TerminalShutdownFreshness {
		return nil, nil
	}
	return &state, nil
}

// ClearTerminalShutdown removes a previously recorded rejection after a
// successful cloud session. Failure is surfaced so callers can retain the
// conservative warning rather than silently claiming it is gone.
func ClearTerminalShutdown(path string) error {
	if path == "" {
		return nil
	}
	if err := os.Remove(path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("cloud: clear terminal shutdown state: %w", err)
	}
	if err := fsutil.SyncDirectory(filepath.Dir(path)); err != nil {
		return fmt.Errorf("cloud: sync terminal shutdown state directory: %w", err)
	}
	return nil
}
