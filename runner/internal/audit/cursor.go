package audit

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// Cursor is a sidecar file that records which JSONL event IDs have been
// acknowledged by the cloud control plane. It lets a future cleanup pass
// know it can prune JSONL up to a given event without losing forensic
// data that hasn't been confirmed received.
//
// Format on disk is a tiny JSON document; updates are written
// atomically via write-then-rename. The cursor is bounded to the most
// recent N acked event IDs (default 4096) to keep the file small.
type Cursor struct {
	path string
	max  int

	mu      sync.Mutex
	acked   map[string]struct{}
	order   []string // insertion order, oldest at index 0
	updated time.Time
}

// CursorState is the on-disk shape of the cursor file.
type CursorState struct {
	AckedEventIDs []string  `json:"acked_event_ids"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// OpenCursor reads the cursor file at path (or returns an empty one if
// the file does not yet exist). max bounds the in-memory + on-disk
// retention; 0 falls back to 4096.
func OpenCursor(path string, max int) (*Cursor, error) {
	if max <= 0 {
		max = 4096
	}
	c := &Cursor{
		path:  path,
		max:   max,
		acked: map[string]struct{}{},
	}
	if path == "" {
		return c, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return nil, fmt.Errorf("cursor: read %s: %w", path, err)
	}
	var s CursorState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("cursor: parse %s: %w", path, err)
	}
	for _, id := range s.AckedEventIDs {
		c.acked[id] = struct{}{}
		c.order = append(c.order, id)
	}
	c.updated = s.UpdatedAt
	c.trim()
	return c, nil
}

// MarkAcked records that eventID has been acked. Persists atomically.
// Returns the underlying write error if the disk update fails — the
// in-memory state is still updated so subsequent IsAcked calls work
// correctly even if the file is unavailable.
func (c *Cursor) MarkAcked(eventID string) error {
	c.mu.Lock()
	if _, exists := c.acked[eventID]; exists {
		c.mu.Unlock()
		return nil
	}
	c.acked[eventID] = struct{}{}
	c.order = append(c.order, eventID)
	c.trim()
	c.updated = time.Now().UTC()
	state := c.snapshot()
	c.mu.Unlock()
	return c.persist(state)
}

// IsAcked reports whether eventID has been acked.
func (c *Cursor) IsAcked(eventID string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	_, ok := c.acked[eventID]
	return ok
}

// Size returns the number of acked entries (test/metrics helper).
func (c *Cursor) Size() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.order)
}

func (c *Cursor) trim() {
	for len(c.order) > c.max {
		oldest := c.order[0]
		c.order = c.order[1:]
		delete(c.acked, oldest)
	}
}

func (c *Cursor) snapshot() CursorState {
	out := CursorState{
		AckedEventIDs: append([]string(nil), c.order...),
		UpdatedAt:     c.updated,
	}
	sort.Strings(out.AckedEventIDs)
	return out
}

func (c *Cursor) persist(state CursorState) error {
	if c.path == "" {
		return nil
	}
	if dir := filepath.Dir(c.path); dir != "" {
		if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
			return fmt.Errorf("cursor: mkdir %s: %w", dir, err)
		}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("cursor: marshal: %w", err)
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("cursor: write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, c.path); err != nil {
		return fmt.Errorf("cursor: rename %s: %w", c.path, err)
	}
	return nil
}
