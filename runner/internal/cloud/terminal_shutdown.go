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

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// TerminalShutdownFreshness is the maximum age for which doctor treats a
// persisted terminal shutdown as the current cloud status.
const TerminalShutdownFreshness = 24 * time.Hour

const (
	terminalShutdownStateFilename = "terminal_shutdown.json"
	maxTerminalShutdownStateBytes = 16 << 10
)

// TerminalShutdownState is the small durable record written when the cloud
// tells this runner it must stop until an operator changes its state.
type TerminalShutdownState struct {
	Reason    string    `json:"reason"`
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

// TerminalShutdownStatePath returns the state path in the runner's existing
// durable data directory, alongside runner_id and dispatches.jsonl.
func TerminalShutdownStatePath(dataDir string) string {
	if strings.TrimSpace(dataDir) == "" {
		return ""
	}
	return filepath.Join(dataDir, terminalShutdownStateFilename)
}

// WriteTerminalShutdown persists a terminal cloud rejection using the same
// synced temp-file replacement used by the runner's other durable state.
func WriteTerminalShutdown(path, reason, message string) error {
	if path == "" {
		return errors.New("cloud: terminal shutdown state path is empty")
	}
	if !terminalShutdownReason(reason) {
		return fmt.Errorf("cloud: %q is not a terminal shutdown reason", reason)
	}

	body, err := json.Marshal(TerminalShutdownState{
		Reason:    reason,
		Message:   message,
		Timestamp: time.Now().UTC(),
	})
	if err != nil {
		return fmt.Errorf("cloud: marshal terminal shutdown state: %w", err)
	}
	body = append(body, '\n')
	if len(body) > maxTerminalShutdownStateBytes {
		return fmt.Errorf("cloud: terminal shutdown state exceeds %d bytes", maxTerminalShutdownStateBytes)
	}

	dir := filepath.Dir(path)
	if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("cloud: create terminal shutdown state directory: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return fmt.Errorf("cloud: create terminal shutdown state: %w", err)
	}
	tmpPath := tmp.Name()
	removeTemp := true
	defer func() {
		if removeTemp {
			_ = os.Remove(tmpPath)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("cloud: secure terminal shutdown state: %w", err)
	}
	written, err := tmp.Write(body)
	if err != nil {
		_ = tmp.Close()
		return fmt.Errorf("cloud: write terminal shutdown state: %w", err)
	}
	if written != len(body) {
		_ = tmp.Close()
		return fmt.Errorf("cloud: write terminal shutdown state: %w", io.ErrShortWrite)
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return fmt.Errorf("cloud: sync terminal shutdown state: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("cloud: close terminal shutdown state: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("cloud: activate terminal shutdown state: %w", err)
	}
	removeTemp = false
	if err := fsutil.SyncDirectory(dir); err != nil {
		return fmt.Errorf("cloud: sync terminal shutdown state directory: %w", err)
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
	if !terminalShutdownReason(state.Reason) || state.Timestamp.IsZero() {
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
