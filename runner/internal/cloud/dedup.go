package cloud

import (
	"bufio"
	"encoding/json"
	"log/slog"
	"os"
	"sync"
)

// dedupRing is a bounded FIFO of completed action results keyed by
// request_id. If cloud retries a request_id we've already executed,
// startRun replays the cached result instead of re-running the action.
//
// When storePath is set the ring is ALSO persisted to disk and reloaded on
// the next start, so dedup survives a runner restart (and isn't lost the way
// a purely in-memory ring is). Without this, a result lost in flight makes
// the cloud re-dispatch (RunDispatchTimeout); if that re-dispatch lands after
// a restart the empty ring re-executes the action — double-running a mutating
// action. The file is the "persistent dispatch log": an atomic rewrite of the
// current ring on every remember (so it stays bounded to max entries), and a
// crash-torn trailing line is skipped on load.
//
// The persisted ActionResultMsg carries only status, exit code, byte counts,
// and output HASHES — never raw stdout/stderr (streamed separately) and never
// an unmasked arg (executed_command is masked runner-side) — so the file holds
// no secret material. It is written 0600 in the runner's data_dir regardless.
type dedupRing struct {
	mu        sync.Mutex
	max       int
	keys      []string // insertion order, oldest at index 0
	cached    map[string]ActionResultMsg
	storePath string // "" = in-memory only
	logger    *slog.Logger
}

// dedupEntry is one persisted line: a request_id and the result to replay.
type dedupEntry struct {
	RequestID string          `json:"request_id"`
	Result    ActionResultMsg `json:"result"`
}

func newDedupRing(max int, storePath string, logger *slog.Logger) *dedupRing {
	if max <= 0 {
		max = 1024
	}
	if logger == nil {
		logger = slog.Default()
	}
	d := &dedupRing{max: max, cached: map[string]ActionResultMsg{}, storePath: storePath, logger: logger}
	d.load()
	return d
}

// load reads a persisted ring at startup. A missing/unreadable file starts
// empty; a crash-torn or garbage line is skipped (the file is rewritten whole
// on the next remember). The in-file order is the insertion order, so the
// FIFO bound is re-applied keeping the most recent entries.
func (d *dedupRing) load() {
	if d.storePath == "" {
		return
	}
	f, err := os.Open(d.storePath)
	if err != nil {
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		var e dedupEntry
		if json.Unmarshal(sc.Bytes(), &e) != nil || e.RequestID == "" {
			continue
		}
		if _, exists := d.cached[e.RequestID]; !exists {
			d.keys = append(d.keys, e.RequestID)
		}
		d.cached[e.RequestID] = e.Result
	}
	for len(d.keys) > d.max {
		delete(d.cached, d.keys[0])
		d.keys = d.keys[1:]
	}
}

// remember caches a completed result. Duplicate inserts are ignored.
func (d *dedupRing) remember(requestID string, result ActionResultMsg) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, exists := d.cached[requestID]; exists {
		return
	}
	if len(d.keys) >= d.max {
		oldest := d.keys[0]
		d.keys = d.keys[1:]
		delete(d.cached, oldest)
	}
	d.keys = append(d.keys, requestID)
	d.cached[requestID] = result
	d.persist()
}

// persist atomically rewrites the store from the current ring (caller holds
// mu). Best-effort: a write failure leaves the in-memory ring intact and the
// previous file in place (the atomic rename means the file is never torn), and
// the next remember retries — dedup degrades to in-memory (the pre-persistence
// behaviour), never to a corrupt store. A failure is logged at Warn because it
// silently reopens the restart-double-execution window. The runner's dispatch
// rate is low enough that a whole-file rewrite per completed action is not a
// hot path.
func (d *dedupRing) persist() {
	if d.storePath == "" {
		return
	}
	if err := d.writeStore(); err != nil {
		d.logger.Warn("cloud.dedup_persist_failed", "error", err, "path", d.storePath)
	}
}

func (d *dedupRing) writeStore() error {
	tmp := d.storePath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriter(f)
	for _, k := range d.keys {
		line, err := json.Marshal(dedupEntry{RequestID: k, Result: d.cached[k]})
		if err != nil {
			continue
		}
		_, _ = w.Write(line)
		_ = w.WriteByte('\n')
	}
	if err := w.Flush(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, d.storePath)
}

// lookup returns the cached result for requestID, if any.
func (d *dedupRing) lookup(requestID string) (ActionResultMsg, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	r, ok := d.cached[requestID]
	return r, ok
}

// size returns the number of cached entries (for tests / metrics).
func (d *dedupRing) size() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.keys)
}
