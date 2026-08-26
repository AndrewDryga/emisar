package cloud

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

const (
	runtimeStatusFilename = "runtime-status.json"
	maxRuntimeStatusBytes = 16 << 10

	RuntimeStateConnecting   = "connecting"
	RuntimeStateConnected    = "connected"
	RuntimeStateReconnecting = "reconnecting"
	RuntimeStateStopped      = "stopped"
)

// RuntimeStatus is the daemon's small local health snapshot. It deliberately
// carries counts and timestamps only: never request ids, action arguments,
// provider output, credentials, or raw connection errors.
type RuntimeStatus struct {
	SchemaVersion         int        `json:"schema_version"`
	PID                   int        `json:"pid"`
	State                 string     `json:"state"`
	StartedAt             time.Time  `json:"started_at"`
	UpdatedAt             time.Time  `json:"updated_at"`
	ConnectedAt           *time.Time `json:"connected_at,omitempty"`
	LastHeartbeatSentAt   *time.Time `json:"last_heartbeat_sent_at,omitempty"`
	HeartbeatEverySeconds int64      `json:"heartbeat_every_seconds"`
	Packs                 int        `json:"packs"`
	Actions               int        `json:"actions"`
	UnavailableActions    int        `json:"unavailable_actions"`
	DegradedPacks         int        `json:"degraded_packs"`
	AdvertisementPending  bool       `json:"advertisement_pending"`
	InflightRuns          int        `json:"inflight_runs"`
	ConnectionAttempts    int64      `json:"connection_attempts"`
}

// RuntimeStatusPath returns the snapshot path in the runner's existing data
// directory. Empty disables the optional diagnostic snapshot in test clients.
func RuntimeStatusPath(dataDir string) string {
	if strings.TrimSpace(dataDir) == "" {
		return ""
	}
	return filepath.Join(dataDir, runtimeStatusFilename)
}

// writeRuntimeStatus atomically replaces the status snapshot with a strict
// mode-0600 file. Durability is useful but not authoritative: the reader still
// evaluates heartbeat freshness because a crash can leave the last bytes behind.
func writeRuntimeStatus(path string, status RuntimeStatus) error {
	if path == "" {
		return nil
	}
	if err := validateRuntimeStatus(status); err != nil {
		return err
	}

	body, err := json.Marshal(status)
	if err != nil {
		return fmt.Errorf("cloud: marshal runtime status: %w", err)
	}
	body = append(body, '\n')
	if len(body) > maxRuntimeStatusBytes {
		return fmt.Errorf("cloud: runtime status exceeds %d bytes", maxRuntimeStatusBytes)
	}

	dir := filepath.Dir(path)
	if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("cloud: create runtime status directory: %w", err)
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return fmt.Errorf("cloud: create runtime status: %w", err)
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
		return fmt.Errorf("cloud: secure runtime status: %w", err)
	}
	written, err := tmp.Write(body)
	if err != nil {
		_ = tmp.Close()
		return fmt.Errorf("cloud: write runtime status: %w", err)
	}
	if written != len(body) {
		_ = tmp.Close()
		return fmt.Errorf("cloud: write runtime status: %w", io.ErrShortWrite)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("cloud: close runtime status: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("cloud: activate runtime status: %w", err)
	}
	removeTemp = false
	return nil
}

// ReadRuntimeStatus strictly reads the daemon snapshot. Missing is a normal
// first-install state; every malformed or ambiguous file is an actionable error.
func ReadRuntimeStatus(path string) (*RuntimeStatus, error) {
	if path == "" {
		return nil, nil
	}
	file, err := openRuntimeStatusFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cloud: open runtime status: %w", err)
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("cloud: stat runtime status: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("cloud: runtime status is not a regular file")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, fmt.Errorf("cloud: runtime status has insecure permissions %#o (want 0600)", info.Mode().Perm())
	}
	if info.Size() > maxRuntimeStatusBytes {
		return nil, fmt.Errorf("cloud: runtime status exceeds %d bytes", maxRuntimeStatusBytes)
	}
	body, err := io.ReadAll(io.LimitReader(file, maxRuntimeStatusBytes+1))
	if err != nil {
		return nil, fmt.Errorf("cloud: read runtime status: %w", err)
	}
	if len(body) > maxRuntimeStatusBytes {
		return nil, fmt.Errorf("cloud: runtime status exceeds %d bytes", maxRuntimeStatusBytes)
	}

	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var status RuntimeStatus
	if err := decoder.Decode(&status); err != nil {
		return nil, fmt.Errorf("cloud: decode runtime status: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("cloud: runtime status has trailing JSON")
		}
		return nil, fmt.Errorf("cloud: decode runtime status trailer: %w", err)
	}
	if err := validateRuntimeStatus(status); err != nil {
		return nil, err
	}
	return &status, nil
}

func validateRuntimeStatus(status RuntimeStatus) error {
	if status.SchemaVersion != 1 {
		return fmt.Errorf("cloud: unsupported runtime status schema_version %d", status.SchemaVersion)
	}
	switch status.State {
	case RuntimeStateConnecting, RuntimeStateConnected, RuntimeStateReconnecting, RuntimeStateStopped:
	default:
		return fmt.Errorf("cloud: invalid runtime status state %q", status.State)
	}
	if status.PID <= 0 || status.StartedAt.IsZero() || status.UpdatedAt.IsZero() {
		return errors.New("cloud: runtime status is missing process identity or timestamps")
	}
	if status.UpdatedAt.Before(status.StartedAt) {
		return errors.New("cloud: runtime status updated_at precedes started_at")
	}
	if status.HeartbeatEverySeconds <= 0 {
		return errors.New("cloud: runtime status has an invalid heartbeat interval")
	}
	if status.State == RuntimeStateConnected && status.ConnectedAt == nil {
		return errors.New("cloud: connected runtime status is missing connected_at")
	}
	if status.ConnectedAt != nil && status.ConnectedAt.Before(status.StartedAt) {
		return errors.New("cloud: runtime status connected_at precedes started_at")
	}
	if status.LastHeartbeatSentAt != nil && status.ConnectedAt == nil {
		return errors.New("cloud: runtime status heartbeat has no connection")
	}
	if status.LastHeartbeatSentAt != nil && status.LastHeartbeatSentAt.Before(*status.ConnectedAt) {
		return errors.New("cloud: runtime status heartbeat precedes connection")
	}
	if status.Packs < 0 || status.Actions < 0 || status.UnavailableActions < 0 ||
		status.DegradedPacks < 0 || status.InflightRuns < 0 || status.ConnectionAttempts < 0 {
		return errors.New("cloud: runtime status contains a negative counter")
	}
	if status.UnavailableActions > status.Actions {
		return errors.New("cloud: runtime status has more unavailable actions than actions")
	}
	return nil
}

// runtimeStatusWriter coalesces frequent observations behind one non-blocking
// wake-up. A slow or failing disk must never delay a heartbeat or action.
type runtimeStatusWriter struct {
	path   string
	logger *slog.Logger

	mu     sync.Mutex
	latest RuntimeStatus
	wake   chan struct{}
	stop   chan struct{}
	done   chan struct{}
	failed bool
}

func newRuntimeStatusWriter(path string, initial RuntimeStatus, logger *slog.Logger, failed bool) *runtimeStatusWriter {
	w := &runtimeStatusWriter{
		path: path, logger: logger, latest: initial, failed: failed,
		wake: make(chan struct{}, 1), stop: make(chan struct{}), done: make(chan struct{}),
	}
	go w.run()
	return w
}

func (w *runtimeStatusWriter) submit(status RuntimeStatus) {
	if w == nil {
		return
	}
	w.mu.Lock()
	w.latest = status
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

func (w *runtimeStatusWriter) close(final RuntimeStatus) {
	if w == nil {
		return
	}
	w.mu.Lock()
	w.latest = final
	w.mu.Unlock()
	close(w.stop)
	<-w.done
}

func (w *runtimeStatusWriter) run() {
	defer close(w.done)
	for {
		select {
		case <-w.wake:
			w.writeLatest()
		case <-w.stop:
			w.writeLatest()
			return
		}
	}
}

func (w *runtimeStatusWriter) writeLatest() {
	w.mu.Lock()
	status := w.latest
	w.mu.Unlock()
	if err := writeRuntimeStatus(w.path, status); err != nil {
		if !w.failed {
			w.logger.Warn("runtime_status.write_failed", "error", err)
		}
		w.failed = true
		return
	}
	if w.failed {
		w.logger.Info("runtime_status.write_recovered")
		w.failed = false
	}
}

func (c *Client) startRuntimeStatus() {
	if c.opts.RuntimeStatusPath == "" {
		return
	}
	c.statusMu.Lock()
	defer c.statusMu.Unlock()
	initial := c.runtimeStatus
	// Clear a previous daemon's apparent health before any network work. The
	// held runner lock and PID correlation remain the stronger liveness proof.
	initialFailed := false
	if err := writeRuntimeStatus(c.opts.RuntimeStatusPath, initial); err != nil {
		c.opts.Logger.Warn("runtime_status.write_failed", "error", err)
		initialFailed = true
	}
	c.runtimeWriter = newRuntimeStatusWriter(c.opts.RuntimeStatusPath, initial, c.opts.Logger, initialFailed)
}

func (c *Client) stopRuntimeStatus() {
	c.statusMu.Lock()
	writer := c.runtimeWriter
	if writer == nil {
		c.statusMu.Unlock()
		return
	}
	inflight := c.countInflight()
	c.runtimeStatus.State = RuntimeStateStopped
	c.runtimeStatus.InflightRuns = inflight
	c.runtimeStatus.UpdatedAt = time.Now().UTC()
	final := c.runtimeStatus
	c.runtimeWriter = nil
	c.statusMu.Unlock()
	writer.close(final)
}

func (c *Client) updateRuntimeStatus(update func(*RuntimeStatus, time.Time)) {
	c.statusMu.Lock()
	defer c.statusMu.Unlock()
	writer := c.runtimeWriter
	if writer == nil {
		return
	}
	inflight := c.countInflight()
	now := time.Now().UTC()
	update(&c.runtimeStatus, now)
	c.runtimeStatus.InflightRuns = inflight
	c.runtimeStatus.UpdatedAt = now
	snapshot := c.runtimeStatus
	// Submit while holding statusMu so two observations cannot reach the
	// coalescing writer in the reverse of the order in which they were sampled.
	writer.submit(snapshot)
}

func setRuntimeCatalog(status *RuntimeStatus, state RunnerStateMsg) {
	status.Packs = len(state.Packs)
	status.Actions = len(state.Actions)
	status.DegradedPacks = len(state.DegradedPacks)
	status.UnavailableActions = 0
	for _, action := range state.Actions {
		if !action.PrimaryExecutableAvailable {
			status.UnavailableActions++
		}
	}
	status.AdvertisementPending = false
}
