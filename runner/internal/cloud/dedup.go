package cloud

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"sync"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

// dedupRing is a bounded persistent dispatch log. A reservation is durably
// written before execution begins, then replaced by the terminal result. This
// gives each runner at-most-once execution across process and host crashes:
// after a restart, an unfinished reservation is reported as outcome-unknown
// instead of re-running an action that may already have changed the host.
//
// A completed result remains non-evictable until the control plane acknowledges
// receipt. Each request_id is also bound to a digest of every delivered execution fact.
// Reusing an id with different facts is refused rather than replaying an
// unrelated result. Persisted results contain hashes and byte counts, never raw
// stdout/stderr or unmasked arguments, and the store is always mode 0600.
type dedupRing struct {
	mu        sync.Mutex
	max       int
	keys      []string // insertion order, oldest at index 0
	records   map[string]dedupEntry
	storePath string // "" = in-memory only
	logger    *slog.Logger
	loadErr   error
}

type dispatchState string

const (
	dispatchReserved     dispatchState = "reserved"
	dispatchCompleted    dispatchState = "completed"
	dispatchAcknowledged dispatchState = "acknowledged"
)

type dedupEntry struct {
	RequestID      string          `json:"request_id"`
	DispatchSHA256 string          `json:"dispatch_sha256"`
	State          dispatchState   `json:"state"`
	Result         ActionResultMsg `json:"result,omitempty"`
}

type reservationDecision int

const (
	reservationNew reservationDecision = iota
	reservationReplay
	reservationPending
	reservationConflict
)

func newDedupRing(max int, storePath string, logger *slog.Logger) *dedupRing {
	if max <= 0 {
		max = 1024
	}
	if logger == nil {
		logger = slog.Default()
	}
	d := &dedupRing{max: max, records: map[string]dedupEntry{}, storePath: storePath, logger: logger}
	d.load()
	return d
}

// load accepts only records produced by the current runner. Corruption,
// impossible state, and crash-torn trailing data all fail closed.
func (d *dedupRing) load() {
	if d.storePath == "" {
		return
	}
	f, err := os.Open(d.storePath)
	if err != nil {
		if !os.IsNotExist(err) {
			d.loadErr = fmt.Errorf("open dispatch log: %w", err)
			d.logger.Error("cloud.dedup_load_failed", "error", d.loadErr, "path", d.storePath)
		}
		return
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	lineNumber := 0
	for sc.Scan() {
		lineNumber++
		e, err := decodeDedupEntry(sc.Bytes())
		if err != nil {
			d.keys = nil
			d.records = map[string]dedupEntry{}
			d.loadErr = fmt.Errorf("invalid dispatch log entry on line %d", lineNumber)
			d.logger.Error("cloud.dedup_load_failed", "error", d.loadErr, "path", d.storePath)
			return
		}
		if _, exists := d.records[e.RequestID]; exists {
			d.keys = nil
			d.records = map[string]dedupEntry{}
			d.loadErr = fmt.Errorf("duplicate dispatch log entry on line %d", lineNumber)
			d.logger.Error("cloud.dedup_load_failed", "error", d.loadErr, "path", d.storePath)
			return
		}
		d.keys = append(d.keys, e.RequestID)
		d.records[e.RequestID] = e
	}
	if err := sc.Err(); err != nil {
		d.keys = nil
		d.records = map[string]dedupEntry{}
		d.loadErr = fmt.Errorf("read dispatch log: %w", err)
		d.logger.Error("cloud.dedup_load_failed", "error", d.loadErr, "path", d.storePath)
		return
	}
	for len(d.keys) > d.max {
		if !d.evictOldestAcknowledgedLocked() {
			break
		}
	}
}

func decodeDedupEntry(line []byte) (dedupEntry, error) {
	if err := validateUniqueJSON(line); err != nil {
		return dedupEntry{}, fmt.Errorf("decode dispatch log entry: %w", err)
	}
	var entry dedupEntry
	decoder := json.NewDecoder(bytes.NewReader(line))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&entry); err != nil || !validDedupEntry(entry) {
		return dedupEntry{}, fmt.Errorf("decode dispatch log entry")
	}
	return entry, nil
}

func validDedupEntry(e dedupEntry) bool {
	if e.RequestID == "" || len(e.DispatchSHA256) != sha256.Size*2 {
		return false
	}
	if _, err := hex.DecodeString(e.DispatchSHA256); err != nil {
		return false
	}
	switch e.State {
	case dispatchReserved:
		return reflect.ValueOf(e.Result).IsZero()
	case dispatchCompleted, dispatchAcknowledged:
		return validActionResult(e.Result, e.RequestID)
	default:
		return false
	}
}

func validActionResult(result ActionResultMsg, requestID string) bool {
	if result.Type != MsgActionResult || result.ProtocolVersion != ProtocolVersion || result.RequestID != requestID {
		return false
	}
	switch result.Status {
	case "success", "failed", "error", "validation_failed", "unknown_action", "timed_out",
		"blocked_by_admission", "cancelled", "signature_invalid", "pack_hash_mismatch":
		return true
	default:
		return false
	}
}

// reserve binds requestID to digest and persists the reservation before the
// caller may execute. Existing exact records replay; an unfinished record is
// reported separately so the caller can fail it closed; fact conflicts refuse.
func (d *dedupRing) reserve(requestID, digest string) (reservationDecision, ActionResultMsg, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loadErr != nil {
		return reservationNew, ActionResultMsg{}, d.loadErr
	}
	if !validDispatchDigest(digest) {
		return reservationNew, ActionResultMsg{}, fmt.Errorf("cloud: invalid dispatch digest")
	}

	if existing, ok := d.records[requestID]; ok {
		if existing.DispatchSHA256 != digest {
			return reservationConflict, ActionResultMsg{}, nil
		}
		if existing.State == dispatchCompleted || existing.State == dispatchAcknowledged {
			return reservationReplay, existing.Result, nil
		}
		return reservationPending, ActionResultMsg{}, nil
	}

	oldKeys := append([]string(nil), d.keys...)
	oldRecords := cloneDedupRecords(d.records)
	if len(d.keys) >= d.max && !d.evictOldestAcknowledgedLocked() {
		return reservationNew, ActionResultMsg{}, fmt.Errorf("cloud: dispatch log capacity reached with active or unacknowledged dispatches")
	}
	d.keys = append(d.keys, requestID)
	d.records[requestID] = dedupEntry{
		RequestID: requestID, DispatchSHA256: digest, State: dispatchReserved,
	}
	if err := d.writeStore(); err != nil {
		d.keys = oldKeys
		d.records = oldRecords
		return reservationNew, ActionResultMsg{}, err
	}
	return reservationNew, ActionResultMsg{}, nil
}

// inspect classifies an existing record without creating a new reservation.
// The client uses it before the concurrency cap so cached replays and fact
// conflicts are deterministic even while every execution slot is occupied.
func (d *dedupRing) inspect(requestID, digest string) (reservationDecision, ActionResultMsg, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loadErr != nil {
		return reservationNew, ActionResultMsg{}, d.loadErr
	}
	if !validDispatchDigest(digest) {
		return reservationNew, ActionResultMsg{}, fmt.Errorf("cloud: invalid dispatch digest")
	}
	existing, ok := d.records[requestID]
	if !ok {
		return reservationNew, ActionResultMsg{}, nil
	}
	if existing.DispatchSHA256 != digest {
		return reservationConflict, ActionResultMsg{}, nil
	}
	if existing.State == dispatchCompleted || existing.State == dispatchAcknowledged {
		return reservationReplay, existing.Result, nil
	}
	return reservationPending, ActionResultMsg{}, nil
}

func validDispatchDigest(digest string) bool {
	if len(digest) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(digest)
	return err == nil
}

func (d *dedupRing) evictOldestAcknowledgedLocked() bool {
	for index, key := range d.keys {
		if d.records[key].State == dispatchAcknowledged {
			delete(d.records, key)
			d.keys = append(d.keys[:index], d.keys[index+1:]...)
			return true
		}
	}
	return false
}

func cloneDedupRecords(records map[string]dedupEntry) map[string]dedupEntry {
	cloned := make(map[string]dedupEntry, len(records))
	for key, entry := range records {
		cloned[key] = entry
	}
	return cloned
}

// complete replaces an exact reservation with its terminal result. A digest
// mismatch is a programming error: it must never overwrite another intent.
func (d *dedupRing) complete(requestID, digest string, result ActionResultMsg) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if !validActionResult(result, requestID) {
		return fmt.Errorf("cloud: invalid terminal result for %q", requestID)
	}

	existing, ok := d.records[requestID]
	if !ok {
		return fmt.Errorf("cloud: complete unreserved dispatch %q", requestID)
	}
	if existing.DispatchSHA256 != digest {
		return fmt.Errorf("cloud: dispatch digest changed for %q", requestID)
	}
	if existing.State == dispatchCompleted || existing.State == dispatchAcknowledged {
		if reflect.DeepEqual(existing.Result, result) {
			return nil
		}
		return fmt.Errorf("cloud: terminal result changed for %q", requestID)
	}
	if existing.State != dispatchReserved {
		return fmt.Errorf("cloud: complete dispatch %q with invalid state %q", requestID, existing.State)
	}
	existing.State = dispatchCompleted
	existing.Result = result
	d.records[requestID] = existing
	if err := d.writeStore(); err != nil {
		existing.State = dispatchReserved
		existing.Result = ActionResultMsg{}
		d.records[requestID] = existing
		return err
	}
	return nil
}

// acknowledge records that the control plane durably received a terminal
// result. Only acknowledged entries may later be evicted to make room.
func (d *dedupRing) acknowledge(requestID string) error {
	d.mu.Lock()
	defer d.mu.Unlock()

	existing, ok := d.records[requestID]
	if !ok {
		return nil
	}
	switch existing.State {
	case dispatchReserved:
		return fmt.Errorf("cloud: acknowledge incomplete dispatch %q", requestID)
	case dispatchAcknowledged:
		return nil
	case dispatchCompleted:
		existing.State = dispatchAcknowledged
		d.records[requestID] = existing
		if err := d.writeStore(); err != nil {
			existing.State = dispatchCompleted
			d.records[requestID] = existing
			return err
		}
		return nil
	default:
		return fmt.Errorf("cloud: acknowledge dispatch %q with invalid state %q", requestID, existing.State)
	}
}

func (d *dedupRing) writeStore() error {
	if d.storePath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(d.storePath), 0o750); err != nil {
		return err
	}
	tmp := d.storePath + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	removeTemp := func() {
		_ = f.Close()
		_ = os.Remove(tmp)
	}
	w := bufio.NewWriter(f)
	for _, key := range d.keys {
		line, err := json.Marshal(d.records[key])
		if err != nil {
			removeTemp()
			return err
		}
		if _, err := w.Write(line); err != nil {
			removeTemp()
			return err
		}
		if err := w.WriteByte('\n'); err != nil {
			removeTemp()
			return err
		}
	}
	if err := w.Flush(); err != nil {
		removeTemp()
		return err
	}
	if err := f.Sync(); err != nil {
		removeTemp()
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, d.storePath); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return fsutil.SyncDirectory(filepath.Dir(d.storePath))
}

func (d *dedupRing) unacknowledgedResults() []ActionResultMsg {
	d.mu.Lock()
	defer d.mu.Unlock()
	results := make([]ActionResultMsg, 0)
	for _, requestID := range d.keys {
		entry := d.records[requestID]
		if entry.State == dispatchCompleted {
			results = append(results, entry.Result)
		}
	}
	return results
}

func (d *dedupRing) contains(requestID string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	_, ok := d.records[requestID]
	return ok
}

// dispatchDigest covers all facts that can change what the runner authorizes
// or executes. ArgsRaw preserves large JSON numbers and exact scalar spellings.
func dispatchDigest(m RunActionMsg) (string, error) {
	args := m.ArgsRaw
	if len(args) == 0 {
		var err error
		args, err = json.Marshal(m.Args)
		if err != nil {
			return "", fmt.Errorf("cloud: marshal dispatch args: %w", err)
		}
	}
	facts := struct {
		ActionID         string          `json:"action_id"`
		ExpectedPackHash string          `json:"expected_pack_hash"`
		PackRef          string          `json:"pack_ref"`
		Args             json.RawMessage `json:"args"`
		Opts             *RunOpts        `json:"opts"`
		Reason           string          `json:"reason"`
		OperationID      string          `json:"operation_id"`
		Attestation      *Attestation    `json:"attestation"`
	}{m.ActionID, m.ExpectedPackHash, m.PackRef, args, m.Opts, m.Reason, m.OperationID, m.Attestation}
	raw, err := json.Marshal(facts)
	if err != nil {
		return "", fmt.Errorf("cloud: marshal dispatch facts: %w", err)
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:]), nil
}
