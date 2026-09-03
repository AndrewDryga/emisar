package cloud

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestDispatchJournalV2ResultFieldsStayFrozen(t *testing.T) {
	got := canonicalJSONFieldNames(reflect.TypeOf(ActionResultMsg{}))
	if !reflect.DeepEqual(got, dispatchJournalResultFieldNames) {
		t.Fatalf(
			"ActionResultMsg fields = %q, journal v2 = %q; add a new journal version before changing its persisted result shape",
			got, dispatchJournalResultFieldNames,
		)
	}
}

func TestDedupJournalMigratesUnversionedCurrentSnapshot(t *testing.T) {
	dir := t.TempDir()
	path := DispatchLogPath(dir)
	entry := dedupEntry{
		RequestID:      "current-snapshot",
		DispatchSHA256: testDispatchDigest("current-snapshot"),
		State:          dispatchAcknowledged,
		Result: testActionResult("current-snapshot", ActionResultMsg{
			EventID: "evt_current_snapshot",
		}),
	}
	raw, err := json.Marshal(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if report := InspectDispatchLog(dir); report.State != DispatchLogLegacy {
		t.Fatalf("unversioned current snapshot report = %+v, want legacy", report)
	}

	d := newDedupRing(4, path, "", nil)
	if d.loadErr != nil {
		t.Fatalf("migrate current snapshot: %v", d.loadErr)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := bytes.Split(bytes.TrimSuffix(data, []byte{'\n'}), []byte{'\n'})
	if len(lines) != 2 {
		t.Fatalf("migrated journal has %d lines, want header + checkpoint", len(lines))
	}
	var header dispatchJournalHeader
	if err := decodeStrictDispatchJSON(lines[0], &header); err != nil {
		t.Fatalf("decode migrated header: %v", err)
	}
	if header.Format != dispatchJournalFormat || header.Version != dispatchJournalVersion {
		t.Fatalf("migrated header = %+v", header)
	}
	if _, _, err := decodeDedupEntry(lines[0]); err == nil {
		t.Fatal("snapshot-only reader accepted the v2 header")
	}
	if report := InspectDispatchLog(dir); report.State != DispatchLogOK || report.Entries != 1 {
		t.Fatalf("migrated report = %+v, want healthy v2", report)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("migrated mode = %s, want 0600", info.Mode().Perm())
	}
}

func TestDedupJournalAppendsOrdinaryLifecycleWithoutRewritingRing(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(1_024, path, "", nil)
	for index := 0; index < 1_024; index++ {
		requestID := fmt.Sprintf("retained-%04d", index)
		d.keys = append(d.keys, requestID)
		d.records[requestID] = dedupEntry{
			RequestID:      requestID,
			DispatchSHA256: testDispatchDigest(requestID),
			State:          dispatchAcknowledged,
			Result: testActionResult(requestID, ActionResultMsg{
				EventID: "evt_" + requestID,
			}),
		}
	}
	if err := d.rewriteJournalLocked(); err != nil {
		t.Fatalf("seed checkpoint: %v", err)
	}
	checkpoint, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	requestID := "contract-max"
	digest := testDispatchDigest(requestID)
	result := testActionResult(requestID, ActionResultMsg{
		EventID:         "evt_contract_max",
		ExecutedCommand: strings.Repeat("x", maxExecutedCommandBytes),
		StructuredOutput: json.RawMessage(
			`{"value":"` + strings.Repeat("x", 8_192-len(`{"value":""}`)) + `"}`,
		),
	})
	decision, _, err := d.reserve(requestID, digest)
	if err != nil || decision != reservationNew {
		t.Fatalf("reserve: decision=%v err=%v", decision, err)
	}
	afterReserve, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(afterReserve, checkpoint) {
		t.Fatal("reserve replaced the checkpoint instead of appending")
	}
	if err := d.complete(requestID, digest, result); err != nil {
		t.Fatalf("complete: %v", err)
	}
	afterComplete, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(afterComplete, afterReserve) {
		t.Fatal("complete replaced earlier durable bytes instead of appending")
	}
	if err := d.acknowledge(requestID); err != nil {
		t.Fatalf("acknowledge: %v", err)
	}
	final, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(final, afterComplete) {
		t.Fatal("acknowledge replaced earlier durable bytes instead of appending")
	}
	if appended := len(final) - len(checkpoint); appended > 32*1024 {
		t.Fatalf("ordinary contract-max lifecycle appended %d bytes, want <= 32 KiB", appended)
	}

	restarted := newDedupRing(1_024, path, "", nil)
	if restarted.loadErr != nil {
		t.Fatalf("restart: %v", restarted.loadErr)
	}
	if entry := restarted.records[requestID]; entry.State != dispatchAcknowledged || entry.Result.EventID != result.EventID {
		t.Fatalf("replayed entry = %+v", entry)
	}
}

func TestDedupJournalReservePersistsEvictionAtomically(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(1, path, "", nil)
	reserveCompleteAndAcknowledge(t, d, "old", testDispatchDigest("old"), ActionResultMsg{EventID: "evt_old"})
	if decision, _, err := d.reserve("new", testDispatchDigest("new")); err != nil || decision != reservationNew {
		t.Fatalf("reserve replacement: decision=%v err=%v", decision, err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := bytes.Split(bytes.TrimSuffix(data, []byte{'\n'}), []byte{'\n'})
	transition, err := decodeDispatchJournalTransition(lines[len(lines)-1])
	if err != nil {
		t.Fatalf("decode reserve transition: %v", err)
	}
	if transition.Op != dispatchJournalReserve || transition.RequestID != "new" || transition.EvictedRequestID != "old" {
		t.Fatalf("reserve transition = %+v", transition)
	}

	restarted := newDedupRing(1, path, "", nil)
	if restarted.loadErr != nil {
		t.Fatalf("restart: %v", restarted.loadErr)
	}
	if _, exists := restarted.records["old"]; exists {
		t.Fatal("evicted request survived restart")
	}
	if entry := restarted.records["new"]; entry.State != dispatchReserved {
		t.Fatalf("new reservation = %+v", entry)
	}
}

func TestDedupJournalRejectsCorruptHistory(t *testing.T) {
	requestID := "req"
	digest := testDispatchDigest(requestID)
	otherDigest := testDispatchDigest("other")
	result := testActionResult(requestID, ActionResultMsg{EventID: "evt_req"})
	checkpoint := dedupEntry{
		RequestID: requestID, DispatchSHA256: digest, State: dispatchReserved,
	}
	acknowledged := dedupEntry{
		RequestID: "old", DispatchSHA256: testDispatchDigest("old"), State: dispatchAcknowledged,
		Result: testActionResult("old", ActionResultMsg{EventID: "evt_old"}),
	}
	header := dispatchJournalHeader{Format: dispatchJournalFormat, Version: dispatchJournalVersion}
	validReserve := dispatchJournalTransition{
		Op: dispatchJournalReserve, RequestID: "new", DispatchSHA256: testDispatchDigest("new"),
	}

	tests := map[string][]byte{
		"empty file": {},
		"unsupported version": journalTestBytes(t, dispatchJournalHeader{
			Format: dispatchJournalFormat, Version: dispatchJournalVersion + 1,
		}),
		"unknown header field":   []byte(`{"format":"` + dispatchJournalFormat + `","version":2,"extra":true}` + "\n"),
		"duplicate header field": []byte(`{"format":"` + dispatchJournalFormat + `","version":2,"version":2}` + "\n"),
		"header field alias":     []byte(`{"format":"` + dispatchJournalFormat + `","Version":2}` + "\n"),
		"header canonical alias pair": []byte(
			`{"format":"` + dispatchJournalFormat + `","version":2,"Version":2}` + "\n",
		),
		"checkpoint field alias": append(journalTestBytes(t, header), []byte(
			`{"Request_ID":"req","dispatch_sha256":"`+digest+`","state":"reserved"}`+"\n",
		)...),
		"unknown operation": append(journalTestBytes(t, header), []byte(
			`{"op":"other","request_id":"req","dispatch_sha256":"`+digest+`"}`+"\n",
		)...),
		"unknown transition field": append(journalTestBytes(t, header), []byte(
			`{"op":"reserve","request_id":"req","dispatch_sha256":"`+digest+`","extra":true}`+"\n",
		)...),
		"null completion result": append(journalTestBytes(t, header, checkpoint), []byte(
			`{"op":"complete","request_id":"req","dispatch_sha256":"`+digest+`","result":null}`+"\n",
		)...),
		"completion without reservation": journalTestBytes(t, header, dispatchJournalTransition{
			Op: dispatchJournalComplete, RequestID: requestID, DispatchSHA256: digest, Result: &result,
		}),
		"completion changes digest": journalTestBytes(t, header, checkpoint, dispatchJournalTransition{
			Op: dispatchJournalComplete, RequestID: requestID, DispatchSHA256: otherDigest, Result: &result,
		}),
		"acknowledge before completion": journalTestBytes(t, header, checkpoint, dispatchJournalTransition{
			Op: dispatchJournalAcknowledge, RequestID: requestID, DispatchSHA256: digest,
		}),
		"wrong eviction": journalTestBytes(t, header, acknowledged, dispatchJournalTransition{
			Op: dispatchJournalReserve, RequestID: "new", DispatchSHA256: testDispatchDigest("new"),
			EvictedRequestID: "not-old",
		}),
		"repeated reservation": journalTestBytes(t, header, checkpoint, dispatchJournalTransition{
			Op: dispatchJournalReserve, RequestID: requestID, DispatchSHA256: digest,
		}),
		"checkpoint after transition": journalTestBytes(t, header, validReserve, acknowledged),
	}
	checkpointResultAlias := bytes.Replace(
		journalTestBytes(t, header, acknowledged), []byte(`"status"`), []byte(`"Status"`), 1,
	)
	tests["checkpoint result field alias"] = checkpointResultAlias
	checkpointResultAliasPair := bytes.Replace(
		journalTestBytes(t, header, acknowledged),
		[]byte(`"status":"success"`), []byte(`"status":"success","Status":"failed"`), 1,
	)
	tests["checkpoint result canonical alias pair"] = checkpointResultAliasPair
	transitionResultAlias := bytes.Replace(
		journalTestBytes(t, header, checkpoint, dispatchJournalTransition{
			Op: dispatchJournalComplete, RequestID: requestID, DispatchSHA256: digest, Result: &result,
		}),
		[]byte(`"status"`), []byte(`"Status"`), 1,
	)
	tests["transition result field alias"] = transitionResultAlias
	unversionedStateAliasPair := bytes.Replace(
		journalTestBytes(t, acknowledged),
		[]byte(`"state":"acknowledged"`), []byte(`"state":"acknowledged","State":"reserved"`), 1,
	)
	tests["unversioned current state canonical alias pair"] = unversionedStateAliasPair
	unversionedRequestAliasPair := bytes.Replace(
		journalTestBytes(t, acknowledged),
		[]byte(`"request_id":"old"`), []byte(`"request_id":"old","Request_ID":"other"`), 1,
	)
	tests["unversioned current request canonical alias pair"] = unversionedRequestAliasPair
	unversionedResultAliasPair := bytes.Replace(
		journalTestBytes(t, acknowledged),
		[]byte(`"status":"success"`), []byte(`"status":"success","Status":"failed"`), 1,
	)
	tests["unversioned current result canonical alias pair"] = unversionedResultAliasPair
	legacyRequestAliasPair := []byte(strings.Replace(
		legacyDispatchLine("legacy"),
		`"request_id":"legacy"`, `"request_id":"legacy","Request_ID":"other"`, 1,
	) + "\n")
	tests["legacy request canonical alias pair"] = legacyRequestAliasPair
	legacyResultAliasPair := []byte(strings.Replace(
		legacyDispatchLine("legacy"),
		`"status":"success"`, `"status":"success","Status":"failed"`, 1,
	) + "\n")
	tests["legacy result canonical alias pair"] = legacyResultAliasPair
	torn := journalTestBytes(t, header, validReserve)
	tests["missing final newline"] = bytes.TrimSuffix(torn, []byte{'\n'})

	for name, contents := range tests {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := DispatchLogPath(dir)
			if err := os.WriteFile(path, contents, 0o600); err != nil {
				t.Fatal(err)
			}
			d := newDedupRing(4, path, "", nil)
			if d.loadErr == nil {
				t.Fatal("corrupt journal did not fail closed")
			}
			if report := InspectDispatchLog(dir); report.State != DispatchLogCorrupt || report.Err == nil {
				t.Fatalf("inspection report = %+v, want corrupt", report)
			}
		})
	}
}

func TestDispatchJournalSnapshotIgnoresBytesAppendedAfterStat(t *testing.T) {
	header := dispatchJournalHeader{Format: dispatchJournalFormat, Version: dispatchJournalVersion}
	transition := dispatchJournalTransition{
		Op: dispatchJournalReserve, RequestID: "observed", DispatchSHA256: testDispatchDigest("observed"),
	}
	snapshot := journalTestBytes(t, header, transition)
	reader := bytes.NewReader(append(append([]byte(nil), snapshot...), []byte(`{"op":"complete"`)...))

	loaded, err := decodeDispatchLogSnapshot(reader, int64(len(snapshot)), snapshot[len(snapshot)-1])
	if err != nil {
		t.Fatalf("decode observed snapshot: %v", err)
	}
	if len(loaded.entries) != 1 || loaded.entries[0].RequestID != "observed" ||
		loaded.entries[0].State != dispatchReserved {
		t.Fatalf("snapshot entries = %#v", loaded.entries)
	}
}

func TestDedupJournalRejectsEmptyLegacyStore(t *testing.T) {
	dir := t.TempDir()
	legacyPath := LegacyDispatchLogPath(dir)
	if err := os.WriteFile(legacyPath, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, DispatchLogPath(dir), legacyPath, nil)
	if d.loadErr == nil || d.loadErrPath != legacyPath {
		t.Fatalf("empty legacy store: err=%v path=%q", d.loadErr, d.loadErrPath)
	}
	if report := InspectDispatchLog(dir); report.State != DispatchLogCorrupt || report.Path != legacyPath {
		t.Fatalf("empty legacy inspection = %+v", report)
	}
}

func TestDedupJournalAppendFailureBoundary(t *testing.T) {
	t.Run("pre-write error is retryable", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		d := newDedupRing(4, path, "", nil)
		appendRecord := d.appendRecord
		d.appendRecord = func(string, []byte) (int64, error) {
			return 0, errors.New("open failed before write")
		}
		if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil {
			t.Fatal("pre-write failure unexpectedly reserved")
		}
		if d.loadErr != nil || dedupSize(d) != 0 {
			t.Fatalf("pre-write failure latched or changed memory: load=%v size=%d", d.loadErr, dedupSize(d))
		}
		d.appendRecord = appendRecord
		if decision, _, err := d.reserve("req", testDispatchDigest("req")); err != nil || decision != reservationNew {
			t.Fatalf("retry: decision=%v err=%v", decision, err)
		}
	})

	t.Run("post-sync error latches but restart replays", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		d := newDedupRing(4, path, "", nil)
		appendRecord := d.appendRecord
		d.appendRecord = func(path string, record []byte) (int64, error) {
			written, err := appendRecord(path, record)
			if err != nil {
				return written, err
			}
			return written, &ambiguousDispatchJournalError{err: errors.New("caller did not observe sync")}
		}
		if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil {
			t.Fatal("ambiguous append unexpectedly returned success")
		}
		if d.loadErr == nil || dedupSize(d) != 0 {
			t.Fatalf("ambiguous append did not latch before memory mutation: load=%v size=%d", d.loadErr, dedupSize(d))
		}
		if _, _, err := d.reserve("other", testDispatchDigest("other")); err == nil {
			t.Fatal("latched journal admitted another reservation")
		}

		restarted := newDedupRing(4, path, "", nil)
		if restarted.loadErr != nil {
			t.Fatalf("restart after full durable record: %v", restarted.loadErr)
		}
		if entry := restarted.records["req"]; entry.State != dispatchReserved {
			t.Fatalf("restart did not conservatively replay reservation: %+v", entry)
		}
	})

	t.Run("partial append latches and is corrupt on restart", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		d := newDedupRing(4, path, "", nil)
		d.appendRecord = func(path string, record []byte) (int64, error) {
			file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0)
			if err != nil {
				return 0, err
			}
			written, writeErr := file.Write(record[:len(record)/2])
			_ = file.Sync()
			_ = file.Close()
			if writeErr != nil {
				return int64(written), &ambiguousDispatchJournalError{err: writeErr}
			}
			return int64(written), &ambiguousDispatchJournalError{err: errors.New("short append")}
		}
		if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil || d.loadErr == nil {
			t.Fatalf("partial append error=%v load=%v", err, d.loadErr)
		}
		if restarted := newDedupRing(4, path, "", nil); restarted.loadErr == nil {
			t.Fatal("partial journal tail loaded after restart")
		}
	})
}

func TestDedupJournalCompactionPreservesStateAndBoundsAdmissions(t *testing.T) {
	t.Run("successful compaction replaces history with one checkpoint", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		d := newDedupRing(4, path, "", nil)
		reserveCompleteAndAcknowledge(t, d, "old", testDispatchDigest("old"), ActionResultMsg{EventID: "evt_old"})
		d.journalChanges = dispatchJournalCompactAfter
		calls := 0
		replaceFile := d.replaceFile
		d.replaceFile = func(path string, write func(io.Writer) error) error {
			calls++
			return replaceFile(path, write)
		}
		if decision, _, err := d.reserve("new", testDispatchDigest("new")); err != nil || decision != reservationNew {
			t.Fatalf("reserve after compaction: decision=%v err=%v", decision, err)
		}
		if calls != 1 {
			t.Fatalf("compaction calls = %d, want 1", calls)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if lines := bytes.Count(data, []byte{'\n'}); lines != 3 {
			t.Fatalf("compacted journal has %d lines, want header + old checkpoint + new reserve", lines)
		}
		restarted := newDedupRing(4, path, "", nil)
		if restarted.loadErr != nil || len(restarted.records) != 2 {
			t.Fatalf("restart: err=%v entries=%d", restarted.loadErr, len(restarted.records))
		}
	})

	t.Run("failed compaction latches uncertain persistence", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), dispatchLogFilename)
		d := newDedupRing(4, path, "", nil)
		if decision, _, err := d.reserve("active", testDispatchDigest("active")); err != nil || decision != reservationNew {
			t.Fatalf("reserve active: decision=%v err=%v", decision, err)
		}
		d.journalChanges = dispatchJournalCompactAfter
		replaceFile := d.replaceFile
		d.replaceFile = func(string, func(io.Writer) error) error {
			return errors.New("replace failed")
		}
		if _, _, err := d.reserve("blocked", testDispatchDigest("blocked")); err == nil {
			t.Fatal("new reservation ignored failed overdue compaction")
		}
		if d.loadErr == nil {
			t.Fatal("uncertain compaction failure did not latch journal")
		}
		if err := d.complete("active", testDispatchDigest("active"), testActionResult("active", ActionResultMsg{EventID: "evt"})); err == nil {
			t.Fatal("latched journal accepted a completion")
		}
		if _, _, err := d.reserve("another", testDispatchDigest("another")); err == nil {
			t.Fatal("latched journal accepted another reservation")
		}
		d.replaceFile = replaceFile
		if _, _, err := d.reserve("blocked", testDispatchDigest("blocked")); err == nil {
			t.Fatal("in-process repair bypassed the persistence latch")
		}
	})
}

func TestDedupJournalPersistsConfiguredMaxTrim(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(3, path, "", nil)
	for _, requestID := range []string{"a", "b", "c"} {
		reserveCompleteAndAcknowledge(t, d, requestID, testDispatchDigest(requestID), ActionResultMsg{
			EventID: "evt_" + requestID,
		})
	}

	trimmed := newDedupRing(2, path, "", nil)
	if trimmed.loadErr != nil {
		t.Fatalf("trim load: %v", trimmed.loadErr)
	}
	if _, exists := trimmed.records["a"]; exists || len(trimmed.records) != 2 {
		t.Fatalf("trimmed records = %#v", trimmed.records)
	}
	restarted := newDedupRing(2, path, "", nil)
	if restarted.loadErr != nil || len(restarted.records) != 2 {
		t.Fatalf("persisted trim restart: err=%v entries=%d", restarted.loadErr, len(restarted.records))
	}
	if _, exists := restarted.records["a"]; exists {
		t.Fatal("trimmed entry returned after restart")
	}
}

func TestDedupJournalLoweredCapacityPreservesActiveEntriesAndBlocksGrowth(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(2, path, "", nil)
	for _, requestID := range []string{"a", "b"} {
		if decision, _, err := d.reserve(requestID, testDispatchDigest(requestID)); err != nil || decision != reservationNew {
			t.Fatalf("reserve %s: decision=%v err=%v", requestID, decision, err)
		}
	}

	lowered := newDedupRing(1, path, "", nil)
	if lowered.loadErr != nil || len(lowered.records) != 2 {
		t.Fatalf("lowered-capacity load: err=%v entries=%d", lowered.loadErr, len(lowered.records))
	}
	if _, _, err := lowered.reserve("c", testDispatchDigest("c")); err == nil {
		t.Fatal("lowered capacity admitted a third active reservation")
	}
	if len(lowered.records) != 2 {
		t.Fatalf("failed reservation changed retained entries: %d", len(lowered.records))
	}
	for _, requestID := range []string{"a", "b"} {
		result := testActionResult(requestID, ActionResultMsg{EventID: "evt_" + requestID})
		if err := lowered.complete(requestID, testDispatchDigest(requestID), result); err != nil {
			t.Fatalf("complete %s: %v", requestID, err)
		}
		if err := lowered.acknowledge(requestID); err != nil {
			t.Fatalf("acknowledge %s: %v", requestID, err)
		}
	}
	if decision, _, err := lowered.reserve("c", testDispatchDigest("c")); err != nil || decision != reservationNew {
		t.Fatalf("reserve after acknowledgements: decision=%v err=%v", decision, err)
	}
	restarted := newDedupRing(1, path, "", nil)
	if restarted.loadErr != nil || len(restarted.records) != 1 || restarted.records["c"].State != dispatchReserved {
		t.Fatalf("restart after capacity recovery: err=%v records=%#v", restarted.loadErr, restarted.records)
	}
}

func TestDispatchJournalWriterRespectsReaderBounds(t *testing.T) {
	digest := testDispatchDigest("record-boundary")
	base := dedupEntry{DispatchSHA256: digest, State: dispatchReserved}
	baseJSON, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	base.RequestID = strings.Repeat("r", maxDispatchJournalRecordBytes-1-len(baseJSON))
	line, err := marshalDispatchJournalLine(base)
	if err != nil {
		t.Fatalf("marshal exact-boundary checkpoint: %v", err)
	}
	if len(line) != maxDispatchJournalRecordBytes {
		t.Fatalf("boundary line = %d bytes, want %d", len(line), maxDispatchJournalRecordBytes)
	}

	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	contents := append(journalTestBytes(t, dispatchJournalHeader{
		Format: dispatchJournalFormat, Version: dispatchJournalVersion,
	}), line...)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := readDispatchLog(path)
	if err != nil || len(loaded.entries) != 1 {
		t.Fatalf("reader rejected writer boundary: entries=%d err=%v", len(loaded.entries), err)
	}

	base.RequestID += "r"
	if _, err := marshalDispatchJournalLine(base); err == nil {
		t.Fatal("writer accepted a record beyond the reader limit")
	}
}

func TestDispatchJournalCompactsBeforeAppendWouldExceedAggregateBounds(t *testing.T) {
	path := filepath.Join(t.TempDir(), dispatchLogFilename)
	d := newDedupRing(4, path, "", nil)
	transition := dispatchJournalTransition{
		Op: dispatchJournalReserve, RequestID: "req", DispatchSHA256: testDispatchDigest("req"),
	}
	line, err := marshalDispatchJournalLine(transition)
	if err != nil {
		t.Fatal(err)
	}
	d.journalFileBytes = maxDispatchJournalFileBytes - int64(len(line)) + 1
	d.journalLines = maxDispatchJournalLines
	replacements := 0
	replaceFile := d.replaceFile
	d.replaceFile = func(path string, write func(io.Writer) error) error {
		replacements++
		return replaceFile(path, write)
	}
	if err := d.persistJournalTransitionLocked(transition); err != nil {
		t.Fatalf("compact before append: %v", err)
	}
	if replacements != 1 {
		t.Fatalf("replacement calls = %d, want 1", replacements)
	}
	d.applyJournalTransitionLocked(transition)
	if restarted := newDedupRing(4, path, "", nil); restarted.loadErr != nil {
		t.Fatalf("restart after capacity compaction: %v", restarted.loadErr)
	}
}

func journalTestBytes(t *testing.T, values ...any) []byte {
	t.Helper()
	var data []byte
	for _, value := range values {
		line, err := marshalDispatchJournalLine(value)
		if err != nil {
			t.Fatal(err)
		}
		data = append(data, line...)
	}
	return data
}
