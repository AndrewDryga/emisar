package cloud

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"reflect"
	"sync"

	"github.com/andrewdryga/emisar/runner/internal/jsonvalue"
	"github.com/andrewdryga/emisar/runner/internal/outputschema"
)

const (
	dispatchLogFilename = "dispatches.jsonl"
	// Pre-v0.12 runners kept the dispatch log at this name. The file is a
	// deployed compatibility surface — hosts upgrading from any earlier
	// release still carry it — so the ring adopts it on first boot instead
	// of silently abandoning the at-most-once state it records.
	legacyDispatchLogFilename = "dedup.jsonl"
)

// DispatchLogPath returns the durable dispatch log inside dataDir.
func DispatchLogPath(dataDir string) string {
	return filepath.Join(dataDir, dispatchLogFilename)
}

// LegacyDispatchLogPath returns the pre-v0.12 dispatch log location inside
// dataDir, adopted (migrated forward) when no current log exists yet.
func LegacyDispatchLogPath(dataDir string) string {
	return filepath.Join(dataDir, legacyDispatchLogFilename)
}

// dedupRing is a bounded persistent dispatch log. A reservation is durably
// written before execution begins, then followed by the terminal result. This
// gives each runner at-most-once execution across process and host crashes:
// after a restart, an unfinished reservation is reported as outcome-unknown
// instead of re-running an action that may already have changed the host.
//
// A completed result remains non-evictable until the control plane acknowledges
// receipt. Each request_id is also bound to a digest of every delivered execution fact.
// Reusing an id with different facts is refused rather than replaying an
// unrelated result. Persisted results contain byte counts, never raw
// stdout/stderr or unmasked arguments, and the store is always mode 0600.
type dedupRing struct {
	mu          sync.Mutex
	max         int
	keys        []string // insertion order, oldest at index 0
	records     map[string]dedupEntry
	storePath   string // "" = in-memory only
	legacyPath  string // pre-v0.12 store location, adopted when storePath is absent
	logger      *slog.Logger
	loadErr     error
	loadErrPath string
	// loadErrWrite marks a boot failure the runner could not WRITE rather than
	// could not READ. The remedies are opposite: quarantining a file we just
	// failed to create cannot help, and the real cause is the data directory.
	loadErrWrite bool

	journalV2              bool
	journalFileBytes       int64
	journalCheckpointBytes int64
	journalTailBytes       int64
	journalChanges         int
	journalLines           int
	appendRecord           dispatchJournalAppender
	replaceFile            dispatchJournalReplacer
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

func newDedupRing(max int, storePath, legacyPath string, logger *slog.Logger) *dedupRing {
	if max <= 0 {
		max = 1024
	}
	if logger == nil {
		logger = slog.Default()
	}
	d := &dedupRing{
		max:          max,
		records:      map[string]dedupEntry{},
		storePath:    storePath,
		legacyPath:   legacyPath,
		logger:       logger,
		appendRecord: appendDispatchJournalRecord,
		replaceFile:  replaceDispatchJournal,
	}
	d.load()
	return d
}

// load accepts the current journal plus every older snapshot shape, which it
// migrates forward before the runner can connect. Corruption, impossible state,
// and crash-torn trailing data all fail closed.
func (d *dedupRing) load() {
	if d.storePath == "" {
		return
	}
	loaded, err := readDispatchLog(d.storePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			d.adoptLegacyStore()
			return
		}
		d.loadErr = err
		d.loadErrPath = d.storePath
		d.logger.Error("cloud.dedup_load_failed", "error", d.loadErr, "path", d.storePath)
		return
	}
	for _, e := range loaded.entries {
		d.keys = append(d.keys, e.RequestID)
		d.records[e.RequestID] = e
	}
	d.applyJournalMetadata(loaded)
	trimmed := d.evictToMax()
	if loaded.needsMigration || trimmed {
		// Rewrite once so every old snapshot and any max-size trim becomes a
		// canonical v2 checkpoint. State we cannot re-persist is fail-closed:
		// proceeding could execute an already-recorded dispatch twice.
		if err := d.rewriteJournalLocked(); err != nil {
			d.keys = nil
			d.records = map[string]dedupEntry{}
			d.failedWrite(fmt.Errorf("migrate dispatch log: %w", err))
			d.logger.Error("cloud.dedup_migration_failed", "error", d.loadErr, "path", d.storePath)
			return
		}
		d.logger.Info("cloud.dedup_migrated", "path", d.storePath, "entries", len(d.keys))
	}
}

// adoptLegacyStore migrates a pre-v0.12 dedup.jsonl (old location, possibly
// pre-v0.10 format) into storePath the first time a runner boots without a
// current dispatch log. An unreadable legacy file fails closed: it may be the
// only record that a redelivered mutation already ran on this host.
func (d *dedupRing) adoptLegacyStore() {
	if d.legacyPath == "" {
		d.createEmptyJournal()
		return
	}
	loaded, err := readDispatchLog(d.legacyPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			d.createEmptyJournal()
			return
		}
		d.loadErr = err
		d.loadErrPath = d.legacyPath
		d.logger.Error("cloud.dedup_legacy_unreadable", "error", err, "path", d.legacyPath,
			"detail", "connect refuses to start; "+
				dispatchLogQuarantineGuidance(d.storePath, d.legacyPath)+"; "+
				dispatchLogQuarantineRisk)
		return
	}
	for _, e := range loaded.entries {
		d.keys = append(d.keys, e.RequestID)
		d.records[e.RequestID] = e
	}
	d.evictToMax()
	if err := d.rewriteJournalLocked(); err != nil {
		d.keys = nil
		d.records = map[string]dedupEntry{}
		d.failedWrite(fmt.Errorf("migrate legacy dispatch log: %w", err))
		d.logger.Error("cloud.dedup_migration_failed", "error", d.loadErr, "path", d.storePath)
		return
	}
	if err := os.Rename(d.legacyPath, d.legacyPath+".migrated"); err != nil {
		d.logger.Warn("cloud.dedup_legacy_rename_failed", "error", err, "path", d.legacyPath)
	}
	d.logger.Info("cloud.dedup_migrated",
		"from", d.legacyPath, "to", d.storePath, "entries", len(d.keys))
}

// failedWrite records a boot failure that could not persist state, always
// naming the file the runner tried to write.
func (d *dedupRing) failedWrite(err error) {
	d.keys = nil
	d.records = map[string]dedupEntry{}
	d.loadErr = err
	d.loadErrPath = d.storePath
	d.loadErrWrite = true
}

// startupRefusal is why connect will not start, plus the remedy that actually
// applies. Refusing over unusable at-most-once state is deliberate — a fresh
// empty log could double-run a redelivered mutation — but the operator must be
// handed a remedy they can perform: quarantining a file the runner just failed
// to WRITE cannot help, and the real cause (a full, read-only, or wrongly-owned
// data directory) is in the wrapped error.
func (d *dedupRing) startupRefusal() error {
	if d.loadErrWrite {
		return fmt.Errorf(
			"persist durable dispatch state to %s: %w — the runner cannot write its at-most-once record; fix the data directory (free space, permissions, ownership) and restart",
			d.loadErrPath, d.loadErr)
	}
	return fmt.Errorf(
		"load durable dispatch state from %s: %w — %s, then restart to begin a clean dispatch log; %s",
		d.loadErrPath, d.loadErr,
		dispatchLogQuarantineGuidance(d.storePath, d.legacyPath),
		dispatchLogQuarantineRisk)
}

func (d *dedupRing) createEmptyJournal() {
	if err := d.rewriteJournalLocked(); err != nil {
		d.failedWrite(fmt.Errorf("create dispatch log: %w", err))
		d.logger.Error("cloud.dedup_create_failed", "error", d.loadErr, "path", d.storePath)
	}
}

func (d *dedupRing) evictToMax() bool {
	trimmed := false
	for len(d.keys) > d.max {
		if !d.evictOldestAcknowledgedLocked() {
			break
		}
		trimmed = true
	}
	return trimmed
}

// decodeDedupEntry decodes one dispatch log line: the current shape strictly,
// or the pre-v0.10 legacy shape (reported via the second return) migrated to
// a current entry.
func decodeDedupEntry(line []byte) (dedupEntry, bool, error) {
	if err := validateUniqueJSON(line); err != nil {
		return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry: %w", err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry")
	}
	if err := rejectKnownAliases(fields, "dispatch log entry", dispatchJournalEntryFieldNames); err != nil {
		return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry: %w", err)
	}
	if resultRaw, ok := fields["result"]; ok && !bytes.Equal(resultRaw, []byte("null")) {
		resultFields, err := rawJSONObject(resultRaw, "dispatch log result")
		if err != nil {
			return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry: %w", err)
		}
		if err := rejectKnownAliases(
			resultFields, "dispatch log result", dispatchSnapshotResultFieldNames,
		); err != nil {
			return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry: %w", err)
		}
	}
	_, hasDigest := fields["dispatch_sha256"]
	_, hasState := fields["state"]
	if hasDigest || hasState {
		var entry dedupEntry
		decoder := json.NewDecoder(bytes.NewReader(line))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&entry); err != nil {
			// One-shot tolerance for the three result fields older runners
			// persisted and the wire message has since dropped. The line is
			// treated as legacy so the loader rewrites the store without them;
			// every OTHER unknown field still fails the strict decode above.
			cleaned, stripped := stripRetiredResultFields(line)
			if !stripped {
				return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry")
			}
			retry := json.NewDecoder(bytes.NewReader(cleaned))
			retry.DisallowUnknownFields()
			if err := retry.Decode(&entry); err != nil || !validDedupEntry(entry) {
				return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry")
			}
			return entry, true, nil
		}
		if !validDedupEntry(entry) {
			return dedupEntry{}, false, fmt.Errorf("decode dispatch log entry")
		}
		return entry, false, nil
	}
	entry, err := decodeLegacyDedupEntry(line, fields)
	if err != nil {
		return dedupEntry{}, false, err
	}
	return entry, true, nil
}

// stripRetiredResultFields removes exactly the result fields older runners
// persisted after those fields left the wire envelope. Anything else unknown
// still fails the strict decode.
func stripRetiredResultFields(line []byte) ([]byte, bool) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return nil, false
	}
	resultRaw, ok := fields["result"]
	if !ok {
		return nil, false
	}
	var result map[string]json.RawMessage
	if err := json.Unmarshal(resultRaw, &result); err != nil || result == nil {
		return nil, false
	}
	stripped := false
	for _, field := range []string{"emitted_stdout_sha256", "emitted_stderr_sha256", "redactions"} {
		if _, ok := result[field]; ok {
			delete(result, field)
			stripped = true
		}
	}
	if !stripped {
		return nil, false
	}
	cleanedResult, err := json.Marshal(result)
	if err != nil {
		return nil, false
	}
	fields["result"] = cleanedResult
	cleaned, err := json.Marshal(fields)
	if err != nil {
		return nil, false
	}
	return cleaned, stripped
}

// decodeLegacyDedupEntry migrates one pre-v0.10 line — {"request_id", "result"}
// with no state machine and no dispatch digest. Deleting the original
// migration bricked dispatch on every upgraded host that carried v0.9 history
// (the deployed-state break .agent/kb/specs/compatibility.md warns about), so it is
// back: a legacy entry becomes an acknowledged terminal result under a
// deterministic sentinel digest. A post-migration redelivery of that
// request_id carries the real digest, mismatches the sentinel, and is refused
// as a conflict — fail-safe: never a second execution.
func decodeLegacyDedupEntry(line []byte, fields map[string]json.RawMessage) (dedupEntry, error) {
	if _, ok := fields["result"]; !ok {
		return dedupEntry{}, fmt.Errorf("decode legacy dispatch log entry")
	}
	var legacy struct {
		RequestID string          `json:"request_id"`
		Result    ActionResultMsg `json:"result"`
	}
	// Lenient decode on purpose: fields the result message has since dropped
	// must not reject a line this loader immediately rewrites.
	if err := json.Unmarshal(line, &legacy); err != nil || legacy.RequestID == "" {
		return dedupEntry{}, fmt.Errorf("decode legacy dispatch log entry")
	}
	if !validLegacyActionResult(legacy.Result, legacy.RequestID) {
		return dedupEntry{}, fmt.Errorf("decode legacy dispatch log result")
	}
	result := legacy.Result
	// Normalize the envelope to the current contract so the migrated entry
	// passes validActionResult on every future load. No durable audit event
	// id exists for a legacy run, so the honest pairing is an empty EventID
	// with LocalAuditFailed set.
	result.Envelope = Envelope{
		Type:            MsgActionResult,
		ProtocolVersion: ProtocolVersion,
		RequestID:       legacy.RequestID,
	}
	result.EventID = ""
	result.LocalAuditFailed = true
	if !validActionResult(result, legacy.RequestID) {
		return dedupEntry{}, fmt.Errorf("decode legacy dispatch log result")
	}
	return dedupEntry{
		RequestID:      legacy.RequestID,
		DispatchSHA256: legacyDispatchDigest(legacy.RequestID),
		// Acknowledged, not completed: v0.9 had no acknowledgement tracking
		// and these results were delivered long ago — resending them on the
		// next connect would burst ancient duplicates at the control plane.
		State:  dispatchAcknowledged,
		Result: result,
	}, nil
}

const dispatchLogQuarantineRisk = "quarantining forgets replay history and may allow a redelivered action to run again"

// DispatchLogQuarantineGuidance returns the safe manual recovery boundary for
// a runner data directory. Both paths matter: after the current log is moved,
// connect adopts a legacy log if one remains.
func DispatchLogQuarantineGuidance(dataDir string) string {
	return dispatchLogQuarantineGuidance(DispatchLogPath(dataDir), LegacyDispatchLogPath(dataDir))
}

func dispatchLogQuarantineGuidance(currentPath, legacyPath string) string {
	paths := currentPath
	if legacyPath != "" && legacyPath != currentPath {
		paths += " and " + legacyPath + " (if present)"
	}
	return "stop the runner and prove it is idle, then move " + paths +
		" into a new root-owned mode-0700 quarantine directory outside the runner data directory without overwriting prior evidence"
}

func validLegacyActionResult(result ActionResultMsg, requestID string) bool {
	if result.Type != MsgActionResult || result.RequestID != requestID {
		return false
	}
	return validActionResultStatus(result.Status)
}

func legacyDispatchDigest(requestID string) string {
	digest := sha256.Sum256([]byte("emisar-legacy-dispatch-v1\x00" + requestID))
	return hex.EncodeToString(digest[:])
}

// DispatchLogState classifies a durable dispatch log for diagnostics.
type DispatchLogState string

const (
	// DispatchLogAbsent — no log yet; the first connect creates it.
	DispatchLogAbsent DispatchLogState = "absent"
	// DispatchLogOK — the current log loads cleanly.
	DispatchLogOK DispatchLogState = "ok"
	// DispatchLogLegacy — readable older state (old location or an unversioned
	// snapshot); the next connect migrates it forward.
	DispatchLogLegacy DispatchLogState = "legacy"
	// DispatchLogCorrupt — unreadable; connect refuses to start over it.
	DispatchLogCorrupt DispatchLogState = "corrupt"
)

// DispatchLogReport is InspectDispatchLog's verdict on one data directory.
type DispatchLogReport struct {
	Path    string
	State   DispatchLogState
	Entries int
	Err     error
}

// InspectDispatchLog reports the durable dispatch log's health without
// touching it — the current store when present, otherwise the pre-v0.12
// location. Used by doctor and `emisar state check-dispatch-log` so
// an unloadable log is diagnosable (and installer-checkable) before it makes
// connect refuse to start.
func InspectDispatchLog(dataDir string) DispatchLogReport {
	path := DispatchLogPath(dataDir)
	loaded, err := inspectDispatchLog(path)
	switch {
	case err == nil:
		state := DispatchLogOK
		if loaded.needsMigration {
			state = DispatchLogLegacy
		}
		return DispatchLogReport{Path: path, State: state, Entries: len(loaded.entries)}
	case !errors.Is(err, os.ErrNotExist):
		return DispatchLogReport{Path: path, State: DispatchLogCorrupt, Err: err}
	}
	legacyPath := LegacyDispatchLogPath(dataDir)
	loaded, err = inspectDispatchLog(legacyPath)
	switch {
	case err == nil:
		return DispatchLogReport{Path: legacyPath, State: DispatchLogLegacy, Entries: len(loaded.entries)}
	case errors.Is(err, os.ErrNotExist):
		return DispatchLogReport{Path: path, State: DispatchLogAbsent}
	default:
		return DispatchLogReport{Path: legacyPath, State: DispatchLogCorrupt, Err: err}
	}
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
	if result.LocalAuditFailed != (result.EventID == "") {
		return false
	}
	if len(result.StructuredOutput) > 0 {
		if result.Status != "success" {
			return false
		}
		if _, err := jsonvalue.DecodeObject(result.StructuredOutput, jsonvalue.Limits{
			MaxBytes: outputschema.MaxResultBytes,
			MaxDepth: outputschema.MaxResultDepth,
			MaxNodes: outputschema.MaxResultNodes,
		}); err != nil {
			return false
		}
	}
	return validActionResultStatus(result.Status)
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

	if decision, result, known := d.classifyLocked(requestID, digest); known {
		return decision, result, nil
	}

	if d.shouldCompactJournalLocked() {
		if err := d.rewriteJournalLocked(); err != nil {
			// ReplaceFile can report an error after rename, when the directory
			// sync fails. The visible checkpoint is state-equivalent, but its
			// directory binding is not proven durable; appending behind it could
			// lose a later reservation after a crash.
			return reservationNew, ActionResultMsg{}, d.latchJournalReplacementFailureLocked("compaction", err)
		}
	}

	evictedRequestID := ""
	if len(d.keys) > d.max {
		return reservationNew, ActionResultMsg{}, fmt.Errorf("cloud: dispatch log capacity reached with active or unacknowledged dispatches")
	}
	if len(d.keys) >= d.max {
		_, oldest, ok := d.oldestAcknowledgedLocked()
		if !ok {
			return reservationNew, ActionResultMsg{}, fmt.Errorf("cloud: dispatch log capacity reached with active or unacknowledged dispatches")
		}
		evictedRequestID = oldest
	}
	transition := dispatchJournalTransition{
		Op:               dispatchJournalReserve,
		RequestID:        requestID,
		DispatchSHA256:   digest,
		EvictedRequestID: evictedRequestID,
	}
	if err := d.persistJournalTransitionLocked(transition); err != nil {
		return reservationNew, ActionResultMsg{}, err
	}
	d.applyJournalTransitionLocked(transition)
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
	decision, result, _ := d.classifyLocked(requestID, digest)
	return decision, result, nil
}

// classifyLocked decides what an ALREADY-KNOWN request id means. reserve and
// inspect asked this same question in two hand-written copies, which is the
// shape that lets a hardening land on one path and miss the other — on the
// at-most-once boundary, where that divergence is the whole failure mode.
//
// `known` is false when the id has never been seen, which is the only case the
// two callers treat differently: reserve goes on to create the reservation,
// inspect reports it as new and writes nothing.
func (d *dedupRing) classifyLocked(requestID, digest string) (reservationDecision, ActionResultMsg, bool) {
	existing, ok := d.records[requestID]
	if !ok {
		return reservationNew, ActionResultMsg{}, false
	}
	if existing.DispatchSHA256 != digest {
		return reservationConflict, ActionResultMsg{}, true
	}
	if existing.State == dispatchCompleted || existing.State == dispatchAcknowledged {
		return reservationReplay, existing.Result, true
	}
	return reservationPending, ActionResultMsg{}, true
}

func validDispatchDigest(digest string) bool {
	if len(digest) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(digest)
	return err == nil
}

// evictOldestAcknowledgedLocked frees a ring slot. Only an ACKNOWLEDGED entry
// may go: the portal has the result, so forgetting it cannot lose one.
//
// Adopted pre-v0.10 entries enter acknowledged (decodeDedupEntry) and are
// therefore evictable, which in theory allows a second execution if the portal
// redelivered that request id after eviction. It cannot: the portal only
// redelivers a run still in sent/running/cancelling, and its DispatchTimeout
// sweep resolves those within a two-minute grace — while eviction needs 1024
// newer dispatches to arrive first. Until eviction, the legacy entry's sentinel
// digest refuses the redelivery outright. Making legacy entries non-evictable
// would mean importing them as completed, which resends every ancient result on
// the next connect — a worse trade for a window that cannot open.
func (d *dedupRing) evictOldestAcknowledgedLocked() bool {
	index, key, ok := d.oldestAcknowledgedLocked()
	if !ok {
		return false
	}
	delete(d.records, key)
	d.keys = append(d.keys[:index], d.keys[index+1:]...)
	return true
}

func (d *dedupRing) oldestAcknowledgedLocked() (int, string, bool) {
	for index, key := range d.keys {
		if d.records[key].State == dispatchAcknowledged {
			return index, key, true
		}
	}
	return 0, "", false
}

// complete records the terminal result for an exact reservation. A digest
// mismatch is a programming error: it must never overwrite another intent.
func (d *dedupRing) complete(requestID, digest string, result ActionResultMsg) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loadErr != nil {
		return d.loadErr
	}
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
	transition := dispatchJournalTransition{
		Op:             dispatchJournalComplete,
		RequestID:      requestID,
		DispatchSHA256: digest,
		Result:         &result,
	}
	if err := d.persistJournalTransitionLocked(transition); err != nil {
		return err
	}
	d.applyJournalTransitionLocked(transition)
	return nil
}

// acknowledge records that the control plane durably received a terminal
// result. Only acknowledged entries may later be evicted to make room.
func (d *dedupRing) acknowledge(requestID string) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loadErr != nil {
		return d.loadErr
	}

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
		transition := dispatchJournalTransition{
			Op:             dispatchJournalAcknowledge,
			RequestID:      requestID,
			DispatchSHA256: existing.DispatchSHA256,
		}
		if err := d.persistJournalTransitionLocked(transition); err != nil {
			return err
		}
		d.applyJournalTransitionLocked(transition)
		if len(d.keys) > d.max && d.evictToMax() {
			if err := d.rewriteJournalLocked(); err != nil {
				return d.latchJournalReplacementFailureLocked("capacity trim", err)
			}
		}
		return nil
	default:
		return fmt.Errorf("cloud: acknowledge dispatch %q with invalid state %q", requestID, existing.State)
	}
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

func (d *dedupRing) unacknowledgedResult(requestID string) (ActionResultMsg, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	entry, ok := d.records[requestID]
	if !ok || entry.State != dispatchCompleted {
		return ActionResultMsg{}, false
	}
	return entry.Result, true
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
