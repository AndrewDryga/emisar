package cloud

import "sync"

// dedupRing is a bounded FIFO of completed action results keyed by
// request_id. If cloud retries a request_id we've already executed,
// startRun replays the cached result instead of re-running the action.
//
// The ring is in-memory only — an runner restart loses all cached
// results. With Pdeathsig active, an runner restart also kills any
// in-flight processes, so there's nothing to dedup across restarts in
// the first place.
type dedupRing struct {
	mu     sync.Mutex
	max    int
	keys   []string // insertion order, oldest at index 0
	cached map[string]ActionResultMsg
}

func newDedupRing(max int) *dedupRing {
	if max <= 0 {
		max = 1024
	}
	return &dedupRing{max: max, cached: map[string]ActionResultMsg{}}
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
