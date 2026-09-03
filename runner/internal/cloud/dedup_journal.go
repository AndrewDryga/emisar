package cloud

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/andrewdryga/emisar/runner/internal/fsutil"
)

const (
	dispatchJournalFormat         = "emisar_dispatch_log"
	dispatchJournalVersion        = 2
	maxDispatchJournalRecordBytes = 16 * 1024 * 1024
	maxDispatchJournalFileBytes   = int64(256 * 1024 * 1024)
	maxDispatchJournalLines       = 32_769
	dispatchJournalCompactAfter   = 1_024
	maxDispatchJournalTailBytes   = int64(32 * 1024 * 1024)
)

type dispatchJournalHeader struct {
	Format  string `json:"format"`
	Version int    `json:"version"`
}

type dispatchJournalOperation string

const (
	dispatchJournalReserve     dispatchJournalOperation = "reserve"
	dispatchJournalComplete    dispatchJournalOperation = "complete"
	dispatchJournalAcknowledge dispatchJournalOperation = "acknowledge"
)

type dispatchJournalTransition struct {
	Op               dispatchJournalOperation `json:"op"`
	RequestID        string                   `json:"request_id"`
	DispatchSHA256   string                   `json:"dispatch_sha256"`
	EvictedRequestID string                   `json:"evicted_request_id,omitempty"`
	Result           *ActionResultMsg         `json:"result,omitempty"`
}

type dispatchLogContents struct {
	entries         []dedupEntry
	needsMigration  bool
	journalV2       bool
	fileBytes       int64
	checkpointBytes int64
	tailBytes       int64
	changes         int
	lines           int
}

type dispatchJournalAppender func(path string, record []byte) (int64, error)
type dispatchJournalReplacer func(path string, write func(io.Writer) error) error

type ambiguousDispatchJournalError struct {
	err error
}

func (e *ambiguousDispatchJournalError) Error() string { return e.err.Error() }
func (e *ambiguousDispatchJournalError) Unwrap() error { return e.err }

// readDispatchLog decodes a v2 journal or any older unversioned snapshot
// without mutating it. Open errors keep os.ErrNotExist reachable via errors.Is.
func readDispatchLog(path string) (dispatchLogContents, error) {
	return readDispatchLogWithOwnership(path, false)
}

func inspectDispatchLog(path string) (dispatchLogContents, error) {
	return readDispatchLogWithOwnership(path, true)
}

func readDispatchLogWithOwnership(path string, allowRootInspection bool) (dispatchLogContents, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return dispatchLogContents{}, fmt.Errorf("inspect dispatch log: %w", err)
	}
	if err := validateDispatchJournalFile(pathInfo, allowRootInspection); err != nil {
		return dispatchLogContents{}, err
	}
	file, err := openSecureLocalFile(path)
	if err != nil {
		return dispatchLogContents{}, fmt.Errorf("open dispatch log: %w", err)
	}
	defer func() { _ = file.Close() }()

	info, err := file.Stat()
	if err != nil {
		return dispatchLogContents{}, fmt.Errorf("stat dispatch log: %w", err)
	}
	if err := validateDispatchJournalFile(info, allowRootInspection); err != nil {
		return dispatchLogContents{}, err
	}
	if info.Size() > maxDispatchJournalFileBytes {
		return dispatchLogContents{}, fmt.Errorf(
			"dispatch journal is %d bytes, limit %d", info.Size(), maxDispatchJournalFileBytes,
		)
	}
	if !os.SameFile(pathInfo, info) {
		return dispatchLogContents{}, fmt.Errorf("dispatch journal path changed while opening")
	}

	if info.Size() == 0 {
		return dispatchLogContents{}, fmt.Errorf("dispatch journal is empty")
	}
	var finalByte [1]byte
	if _, err := file.ReadAt(finalByte[:], info.Size()-1); err != nil {
		return dispatchLogContents{}, fmt.Errorf("read dispatch log tail: %w", err)
	}
	return decodeDispatchLogSnapshot(file, info.Size(), finalByte[0])
}

// decodeDispatchLogSnapshot reads exactly the size observed from the opened
// inode. A live daemon may append after that stat; those later bytes belong to
// the next inspection and must not turn this complete snapshot into a torn one.
func decodeDispatchLogSnapshot(reader io.Reader, size int64, finalByte byte) (dispatchLogContents, error) {
	loaded := dispatchLogContents{fileBytes: size}
	seen := make(map[string]struct{})
	records := make(map[string]dedupEntry)
	keys := make([]string, 0)
	transitionPhase := false
	limited := &io.LimitedReader{R: reader, N: size}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 0, 64*1024), maxDispatchJournalRecordBytes)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		if lineNumber > maxDispatchJournalLines {
			return dispatchLogContents{}, fmt.Errorf("dispatch journal has more than %d lines", maxDispatchJournalLines)
		}
		line := scanner.Bytes()
		if lineNumber == 1 && looksLikeDispatchJournalHeader(line) {
			header, err := decodeDispatchJournalHeader(line)
			if err != nil {
				return dispatchLogContents{}, fmt.Errorf("invalid dispatch journal header: %w", err)
			}
			if header.Format != dispatchJournalFormat || header.Version != dispatchJournalVersion {
				return dispatchLogContents{}, fmt.Errorf(
					"unsupported dispatch journal format %q version %d", header.Format, header.Version,
				)
			}
			loaded.journalV2 = true
			loaded.checkpointBytes = int64(len(line) + 1)
			continue
		}

		if !loaded.journalV2 {
			entry, _, err := decodeDedupEntry(line)
			if err != nil {
				return dispatchLogContents{}, fmt.Errorf("invalid dispatch log entry on line %d", lineNumber)
			}
			if _, duplicate := seen[entry.RequestID]; duplicate {
				return dispatchLogContents{}, fmt.Errorf("duplicate dispatch log entry on line %d", lineNumber)
			}
			seen[entry.RequestID] = struct{}{}
			loaded.entries = append(loaded.entries, entry)
			continue
		}

		if looksLikeDispatchJournalTransition(line) {
			transitionPhase = true
			transition, err := decodeDispatchJournalTransition(line)
			if err != nil {
				return dispatchLogContents{}, fmt.Errorf("invalid dispatch journal transition on line %d: %w", lineNumber, err)
			}
			if err := replayDispatchJournalTransition(&keys, records, transition); err != nil {
				return dispatchLogContents{}, fmt.Errorf("invalid dispatch journal transition on line %d: %w", lineNumber, err)
			}
			loaded.tailBytes += int64(len(line) + 1)
			loaded.changes++
			continue
		}
		if transitionPhase {
			return dispatchLogContents{}, fmt.Errorf("dispatch journal checkpoint entry after transition on line %d", lineNumber)
		}
		entry, err := decodeDispatchJournalCheckpoint(line)
		if err != nil {
			return dispatchLogContents{}, fmt.Errorf("invalid dispatch journal checkpoint on line %d", lineNumber)
		}
		if _, duplicate := records[entry.RequestID]; duplicate {
			return dispatchLogContents{}, fmt.Errorf("duplicate dispatch journal checkpoint on line %d", lineNumber)
		}
		records[entry.RequestID] = entry
		keys = append(keys, entry.RequestID)
		loaded.checkpointBytes += int64(len(line) + 1)
	}
	if err := scanner.Err(); err != nil {
		return dispatchLogContents{}, fmt.Errorf("read dispatch log: %w", err)
	}
	if limited.N != 0 {
		return dispatchLogContents{}, fmt.Errorf("dispatch journal changed while reading")
	}
	if loaded.journalV2 {
		if finalByte != '\n' {
			return dispatchLogContents{}, fmt.Errorf("dispatch journal has a torn trailing record")
		}
		loaded.entries = make([]dedupEntry, 0, len(keys))
		for _, key := range keys {
			loaded.entries = append(loaded.entries, records[key])
		}
		loaded.lines = lineNumber
		return loaded, nil
	}

	loaded.needsMigration = true
	loaded.lines = lineNumber
	return loaded, nil
}

var (
	dispatchJournalHeaderFieldNames = []string{"format", "version"}
	dispatchJournalEntryFieldNames  = []string{"request_id", "dispatch_sha256", "state", "result"}
	dispatchJournalOpFieldNames     = []string{"op", "request_id", "dispatch_sha256", "evicted_request_id", "result"}
	// This is the frozen result envelope stored by journal v2. Do not derive it
	// from ActionResultMsg: an additive wire field must not silently reinterpret
	// already-deployed disk format v2. The parity test requires a deliberate new
	// journal version before the two shapes can diverge.
	dispatchJournalResultFieldNames = []string{
		"type", "protocol_version", "request_id", "status", "exit_code", "duration_ms",
		"timed_out", "emitted_stdout_bytes", "emitted_stderr_bytes", "progress_chunks",
		"dropped_progress_chunks", "truncated_stdout", "truncated_stderr", "reason", "error",
		"structured_output", "event_id", "local_audit_failed", "executed_command",
		"executed_command_truncated",
	}
	dispatchSnapshotResultFieldNames = append(
		append([]string(nil), dispatchJournalResultFieldNames...),
		"emitted_stdout_sha256", "emitted_stderr_sha256", "redactions",
	)
)

func decodeDispatchJournalHeader(line []byte) (dispatchJournalHeader, error) {
	if err := validateCanonicalDispatchFields(line, "dispatch journal header", dispatchJournalHeaderFieldNames, false); err != nil {
		return dispatchJournalHeader{}, err
	}
	var header dispatchJournalHeader
	if err := decodeStrictDispatchJSON(line, &header); err != nil {
		return dispatchJournalHeader{}, err
	}
	return header, nil
}

func decodeDispatchJournalCheckpoint(line []byte) (dedupEntry, error) {
	if err := validateCanonicalDispatchFields(line, "dispatch journal checkpoint", dispatchJournalEntryFieldNames, true); err != nil {
		return dedupEntry{}, err
	}
	entry, legacy, err := decodeDedupEntry(line)
	if err != nil || legacy {
		return dedupEntry{}, fmt.Errorf("decode checkpoint")
	}
	return entry, nil
}

func validateCanonicalDispatchFields(line []byte, label string, canonical []string, validateResult bool) error {
	fields, err := rawJSONObject(line, label)
	if err != nil {
		return err
	}
	if err := rejectKnownAliases(fields, label, canonical); err != nil {
		return err
	}
	if !validateResult {
		return nil
	}
	resultRaw, ok := fields["result"]
	if !ok || bytes.Equal(resultRaw, []byte("null")) {
		return nil
	}
	result, err := rawJSONObject(resultRaw, label+" result")
	if err != nil {
		return err
	}
	return rejectKnownAliases(result, label+" result", dispatchJournalResultFieldNames)
}

func looksLikeDispatchJournalHeader(line []byte) bool {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return false
	}
	_, hasFormat := fields["format"]
	_, hasVersion := fields["version"]
	return hasFormat || hasVersion
}

func looksLikeDispatchJournalTransition(line []byte) bool {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return false
	}
	_, ok := fields["op"]
	return ok
}

func decodeStrictDispatchJSON(data []byte, destination any) error {
	if err := validateUniqueJSON(data); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return fmt.Errorf("trailing JSON data")
	}
	return nil
}

func decodeDispatchJournalTransition(line []byte) (dispatchJournalTransition, error) {
	if err := validateCanonicalDispatchFields(line, "dispatch journal transition", dispatchJournalOpFieldNames, true); err != nil {
		return dispatchJournalTransition{}, err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(line, &fields); err != nil || fields == nil {
		return dispatchJournalTransition{}, fmt.Errorf("decode transition")
	}
	var transition dispatchJournalTransition
	if err := decodeStrictDispatchJSON(line, &transition); err != nil {
		return dispatchJournalTransition{}, err
	}
	required := map[string]bool{
		"op": true, "request_id": true, "dispatch_sha256": true,
	}
	allowed := map[string]bool{
		"op": true, "request_id": true, "dispatch_sha256": true,
	}
	switch transition.Op {
	case dispatchJournalReserve:
		allowed["evicted_request_id"] = true
		if _, present := fields["evicted_request_id"]; present && transition.EvictedRequestID == "" {
			return dispatchJournalTransition{}, fmt.Errorf("reserve has an empty evicted_request_id")
		}
	case dispatchJournalComplete:
		allowed["result"] = true
		required["result"] = true
		if transition.Result == nil {
			return dispatchJournalTransition{}, fmt.Errorf("complete has a null result")
		}
	case dispatchJournalAcknowledge:
	default:
		return dispatchJournalTransition{}, fmt.Errorf("unknown operation %q", transition.Op)
	}
	for field := range fields {
		if !allowed[field] {
			return dispatchJournalTransition{}, fmt.Errorf("operation %q does not allow field %q", transition.Op, field)
		}
	}
	for field := range required {
		if _, present := fields[field]; !present {
			return dispatchJournalTransition{}, fmt.Errorf("operation %q is missing field %q", transition.Op, field)
		}
	}
	return transition, nil
}

func replayDispatchJournalTransition(
	keys *[]string,
	records map[string]dedupEntry,
	transition dispatchJournalTransition,
) error {
	if transition.RequestID == "" || !validDispatchDigest(transition.DispatchSHA256) {
		return fmt.Errorf("invalid request id or dispatch digest")
	}
	switch transition.Op {
	case dispatchJournalReserve:
		if transition.Result != nil {
			return fmt.Errorf("reserve carries a terminal result")
		}
		if _, exists := records[transition.RequestID]; exists {
			return fmt.Errorf("reserve repeats request %q", transition.RequestID)
		}
		if transition.EvictedRequestID != "" {
			index, requestID, ok := oldestAcknowledged(*keys, records)
			if !ok || requestID != transition.EvictedRequestID {
				return fmt.Errorf("reserve evicts %q instead of the oldest acknowledged request", transition.EvictedRequestID)
			}
			delete(records, requestID)
			*keys = append((*keys)[:index], (*keys)[index+1:]...)
		}
		records[transition.RequestID] = dedupEntry{
			RequestID: transition.RequestID, DispatchSHA256: transition.DispatchSHA256, State: dispatchReserved,
		}
		*keys = append(*keys, transition.RequestID)
		return nil

	case dispatchJournalComplete:
		if transition.EvictedRequestID != "" || transition.Result == nil {
			return fmt.Errorf("complete has invalid fields")
		}
		entry, ok := records[transition.RequestID]
		if !ok || entry.State != dispatchReserved {
			return fmt.Errorf("complete does not match a reservation")
		}
		if entry.DispatchSHA256 != transition.DispatchSHA256 {
			return fmt.Errorf("complete changes the dispatch digest")
		}
		if !validActionResult(*transition.Result, transition.RequestID) {
			return fmt.Errorf("complete carries an invalid terminal result")
		}
		entry.State = dispatchCompleted
		entry.Result = *transition.Result
		records[transition.RequestID] = entry
		return nil

	case dispatchJournalAcknowledge:
		if transition.EvictedRequestID != "" || transition.Result != nil {
			return fmt.Errorf("acknowledge has invalid fields")
		}
		entry, ok := records[transition.RequestID]
		if !ok || entry.State != dispatchCompleted {
			return fmt.Errorf("acknowledge does not match a completion")
		}
		if entry.DispatchSHA256 != transition.DispatchSHA256 {
			return fmt.Errorf("acknowledge changes the dispatch digest")
		}
		entry.State = dispatchAcknowledged
		records[transition.RequestID] = entry
		return nil

	default:
		return fmt.Errorf("unknown operation %q", transition.Op)
	}
}

func oldestAcknowledged(keys []string, records map[string]dedupEntry) (int, string, bool) {
	for index, key := range keys {
		if records[key].State == dispatchAcknowledged {
			return index, key, true
		}
	}
	return 0, "", false
}

func (d *dedupRing) applyJournalMetadata(loaded dispatchLogContents) {
	d.journalV2 = loaded.journalV2
	d.journalFileBytes = loaded.fileBytes
	d.journalCheckpointBytes = loaded.checkpointBytes
	d.journalTailBytes = loaded.tailBytes
	d.journalChanges = loaded.changes
	d.journalLines = loaded.lines
}

func (d *dedupRing) shouldCompactJournalLocked() bool {
	if d.storePath == "" || !d.journalV2 {
		return false
	}
	return d.journalTailBytes >= maxDispatchJournalTailBytes ||
		d.journalChanges >= dispatchJournalCompactAfter && d.journalChanges >= len(d.records)
}

func (d *dedupRing) persistJournalTransitionLocked(transition dispatchJournalTransition) error {
	if d.storePath == "" {
		return nil
	}
	if !d.journalV2 {
		return fmt.Errorf("cloud: dispatch journal is not initialized")
	}
	line, err := marshalDispatchJournalLine(transition)
	if err != nil {
		return fmt.Errorf("cloud: marshal dispatch journal transition: %w", err)
	}
	if d.journalFileBytes+int64(len(line)) > maxDispatchJournalFileBytes ||
		d.journalLines+1 > maxDispatchJournalLines {
		if err := d.rewriteJournalLocked(); err != nil {
			return d.latchJournalReplacementFailureLocked("capacity compaction", err)
		}
		if d.journalFileBytes+int64(len(line)) > maxDispatchJournalFileBytes ||
			d.journalLines+1 > maxDispatchJournalLines {
			return fmt.Errorf("cloud: dispatch journal capacity reached")
		}
	}
	written, err := d.appendRecord(d.storePath, line)
	if err != nil {
		var ambiguous *ambiguousDispatchJournalError
		if errors.As(err, &ambiguous) {
			d.loadErr = fmt.Errorf("cloud: dispatch journal persistence became uncertain: %w", err)
			d.loadErrPath = d.storePath
			return d.loadErr
		}
		return fmt.Errorf("cloud: persist dispatch journal transition: %w", err)
	}
	if written != int64(len(line)) {
		d.loadErr = fmt.Errorf("cloud: dispatch journal persistence became uncertain: %w", io.ErrShortWrite)
		d.loadErrPath = d.storePath
		return d.loadErr
	}
	d.journalFileBytes += written
	d.journalTailBytes += written
	d.journalChanges++
	d.journalLines++
	return nil
}

func (d *dedupRing) applyJournalTransitionLocked(transition dispatchJournalTransition) {
	switch transition.Op {
	case dispatchJournalReserve:
		if transition.EvictedRequestID != "" {
			for index, key := range d.keys {
				if key == transition.EvictedRequestID {
					delete(d.records, key)
					d.keys = append(d.keys[:index], d.keys[index+1:]...)
					break
				}
			}
		}
		d.records[transition.RequestID] = dedupEntry{
			RequestID: transition.RequestID, DispatchSHA256: transition.DispatchSHA256, State: dispatchReserved,
		}
		d.keys = append(d.keys, transition.RequestID)

	case dispatchJournalComplete:
		entry := d.records[transition.RequestID]
		entry.State = dispatchCompleted
		entry.Result = *transition.Result
		d.records[transition.RequestID] = entry

	case dispatchJournalAcknowledge:
		entry := d.records[transition.RequestID]
		entry.State = dispatchAcknowledged
		d.records[transition.RequestID] = entry
	}
}

func (d *dedupRing) rewriteJournalLocked() error {
	if d.storePath == "" {
		return nil
	}
	written := int64(0)
	lines := 0
	err := d.replaceFile(d.storePath, func(writer io.Writer) error {
		values := make([]any, 0, len(d.keys)+1)
		values = append(values, dispatchJournalHeader{
			Format: dispatchJournalFormat, Version: dispatchJournalVersion,
		})
		for _, key := range d.keys {
			values = append(values, d.records[key])
		}
		for _, value := range values {
			line, err := marshalDispatchJournalLine(value)
			if err != nil {
				return err
			}
			if written+int64(len(line)) > maxDispatchJournalFileBytes || lines+1 > maxDispatchJournalLines {
				return fmt.Errorf("dispatch journal checkpoint exceeds its storage bounds")
			}
			n, err := writer.Write(line)
			written += int64(n)
			if err != nil {
				return err
			}
			if n != len(line) {
				return io.ErrShortWrite
			}
			lines++
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("persist dispatch journal checkpoint: %w", err)
	}
	d.journalV2 = true
	d.journalFileBytes = written
	d.journalCheckpointBytes = written
	d.journalTailBytes = 0
	d.journalChanges = 0
	d.journalLines = lines
	return nil
}

func (d *dedupRing) latchJournalReplacementFailureLocked(operation string, err error) error {
	d.loadErr = fmt.Errorf("cloud: dispatch journal %s became uncertain: %w", operation, err)
	d.loadErrPath = d.storePath
	return d.loadErr
}

func replaceDispatchJournal(path string, write func(io.Writer) error) error {
	return fsutil.ReplaceFile(path, write)
}

func marshalDispatchJournalLine(value any) ([]byte, error) {
	line, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(line) == 0 || len(line)+1 > maxDispatchJournalRecordBytes {
		return nil, fmt.Errorf("dispatch journal record has invalid size %d", len(line))
	}
	return append(line, '\n'), nil
}

func appendDispatchJournalRecord(path string, record []byte) (int64, error) {
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return 0, fmt.Errorf("inspect dispatch journal for append: %w", err)
	}
	if err := validateDispatchJournalFile(pathInfo, false); err != nil {
		return 0, err
	}
	file, err := openSecureLocalFileForAppend(path)
	if err != nil {
		return 0, fmt.Errorf("open dispatch journal for append: %w", err)
	}
	closeBeforeWrite := func(err error) (int64, error) {
		_ = file.Close()
		return 0, err
	}

	openedInfo, err := file.Stat()
	if err != nil {
		return closeBeforeWrite(fmt.Errorf("stat dispatch journal for append: %w", err))
	}
	if err := validateDispatchJournalFile(openedInfo, false); err != nil {
		return closeBeforeWrite(&ambiguousDispatchJournalError{err: err})
	}
	initialInfo := pathInfo
	if !os.SameFile(initialInfo, openedInfo) {
		return closeBeforeWrite(&ambiguousDispatchJournalError{
			err: fmt.Errorf("dispatch journal path changed while opening for append"),
		})
	}
	pathInfo, err = os.Lstat(path)
	if err != nil {
		return closeBeforeWrite(&ambiguousDispatchJournalError{
			err: fmt.Errorf("stat dispatch journal path for append: %w", err),
		})
	}
	if err := validateDispatchJournalFile(pathInfo, false); err != nil {
		return closeBeforeWrite(&ambiguousDispatchJournalError{err: err})
	}
	if !os.SameFile(pathInfo, openedInfo) {
		return closeBeforeWrite(&ambiguousDispatchJournalError{
			err: fmt.Errorf("dispatch journal path changed before append"),
		})
	}

	written, writeErr := file.Write(record)
	if writeErr != nil || written != len(record) {
		_ = file.Close()
		if writeErr == nil {
			writeErr = io.ErrShortWrite
		}
		return int64(written), &ambiguousDispatchJournalError{
			err: fmt.Errorf("append dispatch journal: %w", writeErr),
		}
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return int64(written), &ambiguousDispatchJournalError{
			err: fmt.Errorf("sync dispatch journal: %w", err),
		}
	}
	pathInfo, err = os.Lstat(path)
	if err != nil || !os.SameFile(pathInfo, openedInfo) {
		_ = file.Close()
		if err == nil {
			err = fmt.Errorf("path names a different file")
		}
		return int64(written), &ambiguousDispatchJournalError{
			err: fmt.Errorf("verify dispatch journal after append: %w", err),
		}
	}
	if err := validateDispatchJournalFile(pathInfo, false); err != nil {
		_ = file.Close()
		return int64(written), &ambiguousDispatchJournalError{err: err}
	}
	if err := file.Close(); err != nil {
		return int64(written), &ambiguousDispatchJournalError{
			err: fmt.Errorf("close dispatch journal: %w", err),
		}
	}
	return int64(written), nil
}

func validateDispatchJournalFile(info os.FileInfo, allowRootInspection bool) error {
	if !info.Mode().IsRegular() {
		return fmt.Errorf("dispatch journal is not a regular file")
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("dispatch journal permissions are %s, want -rw-------", info.Mode().Perm())
	}
	if !localFileOwnerTrusted(info, allowRootInspection) {
		return fmt.Errorf("dispatch journal is not owned by the runner user")
	}
	return nil
}
