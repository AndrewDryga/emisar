package cloud

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func (d *dedupRing) lookup(requestID string) (ActionResultMsg, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	entry, ok := d.records[requestID]
	if !ok || entry.State != dispatchCompleted && entry.State != dispatchAcknowledged {
		return ActionResultMsg{}, false
	}
	return entry.Result, true
}

func testDispatchDigest(label string) string {
	digest := sha256.Sum256([]byte(label))
	return hex.EncodeToString(digest[:])
}

func reserveAndComplete(t *testing.T, d *dedupRing, requestID, digest string, result ActionResultMsg) {
	t.Helper()
	decision, _, err := d.reserve(requestID, digest)
	if err != nil || decision != reservationNew {
		t.Fatalf("reserve %s: decision=%v err=%v", requestID, decision, err)
	}
	if err := d.complete(requestID, digest, testActionResult(requestID, result)); err != nil {
		t.Fatalf("complete %s: %v", requestID, err)
	}
}

func testActionResult(requestID string, result ActionResultMsg) ActionResultMsg {
	result.Envelope = Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: requestID}
	if result.Status == "" {
		result.Status = "success"
	}
	return result
}

func reserveCompleteAndAcknowledge(t *testing.T, d *dedupRing, requestID, digest string, result ActionResultMsg) {
	t.Helper()
	reserveAndComplete(t, d, requestID, digest, result)
	if err := d.acknowledge(requestID); err != nil {
		t.Fatalf("acknowledge %s: %v", requestID, err)
	}
}

func dedupSize(d *dedupRing) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.keys)
}

func TestDedupRing_ReserveCompleteAndLookup(t *testing.T) {
	d := newDedupRing(4, "", "", nil)
	reserveAndComplete(t, d, "a", testDispatchDigest("a"), ActionResultMsg{EventID: "evt_a"})
	reserveAndComplete(t, d, "b", testDispatchDigest("b"), ActionResultMsg{EventID: "evt_b"})

	if r, ok := d.lookup("a"); !ok || r.EventID != "evt_a" {
		t.Fatalf("a not found: %+v", r)
	}
	if _, ok := d.lookup("missing"); ok {
		t.Fatal("missing should be absent")
	}
}

func TestValidActionResultBoundsStructuredOutput(t *testing.T) {
	base := testActionResult("typed", ActionResultMsg{
		Status:           "success",
		EventID:          "evt_typed",
		StructuredOutput: json.RawMessage(`{"count":9007199254740993}`),
	})
	if !validActionResult(base, "typed") {
		t.Fatal("valid structured output rejected")
	}

	for _, tc := range []struct {
		name   string
		mutate func(*ActionResultMsg)
	}{
		{"non-success", func(result *ActionResultMsg) { result.Status = "failed" }},
		{"non-object", func(result *ActionResultMsg) { result.StructuredOutput = json.RawMessage(`[]`) }},
		{"duplicate key", func(result *ActionResultMsg) { result.StructuredOutput = json.RawMessage(`{"a":1,"a":2}`) }},
		{"oversize", func(result *ActionResultMsg) {
			result.StructuredOutput = json.RawMessage(`{"value":"` + strings.Repeat("x", 8192) + `"}`)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := base
			tc.mutate(&result)
			if validActionResult(result, "typed") {
				t.Fatal("invalid structured output accepted")
			}
		})
	}
}

func TestDedupRing_EvictsOldest(t *testing.T) {
	d := newDedupRing(2, "", "", nil)
	for _, id := range []string{"a", "b", "c"} {
		reserveCompleteAndAcknowledge(t, d, id, testDispatchDigest(id), ActionResultMsg{EventID: "evt_" + id})
	}
	if _, ok := d.lookup("a"); ok {
		t.Fatal("a should have been evicted")
	}
	if _, ok := d.lookup("c"); !ok || dedupSize(d) != 2 {
		t.Fatalf("recent entries missing or wrong size: %d", dedupSize(d))
	}
}

func TestDedupRing_NeverEvictsAnActiveReservation(t *testing.T) {
	d := newDedupRing(1, "", "", nil)
	firstDigest := testDispatchDigest("first")
	if decision, _, err := d.reserve("first", firstDigest); err != nil || decision != reservationNew {
		t.Fatalf("first reserve: decision=%v err=%v", decision, err)
	}
	if _, _, err := d.reserve("second", testDispatchDigest("second")); err == nil {
		t.Fatal("second reservation unexpectedly evicted an active dispatch")
	}
	if decision, _, err := d.reserve("first", firstDigest); err != nil || decision != reservationPending {
		t.Fatalf("first reservation was not preserved: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_NeverEvictsAnUnacknowledgedCompletion(t *testing.T) {
	d := newDedupRing(1, "", "", nil)
	firstDigest := testDispatchDigest("first")
	reserveAndComplete(t, d, "first", firstDigest, ActionResultMsg{EventID: "evt_first"})

	if _, _, err := d.reserve("second", testDispatchDigest("second")); err == nil {
		t.Fatal("second reservation unexpectedly evicted an unacknowledged result")
	}
	if result, ok := d.lookup("first"); !ok || result.EventID != "evt_first" {
		t.Fatalf("unacknowledged result was not preserved: result=%+v ok=%t", result, ok)
	}

	if err := d.acknowledge("first"); err != nil {
		t.Fatal(err)
	}
	if decision, _, err := d.reserve("second", testDispatchDigest("second")); err != nil || decision != reservationNew {
		t.Fatalf("acknowledged result did not become evictable: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_ReplaysExactAndRefusesFactConflict(t *testing.T) {
	d := newDedupRing(4, "", "", nil)
	digest := testDispatchDigest("a")
	result := ActionResultMsg{EventID: "evt_first"}
	reserveAndComplete(t, d, "a", digest, result)

	decision, replay, err := d.reserve("a", digest)
	if err != nil || decision != reservationReplay || replay.EventID != "evt_first" {
		t.Fatalf("exact replay: decision=%v result=%+v err=%v", decision, replay, err)
	}
	decision, _, err = d.reserve("a", testDispatchDigest("other"))
	if err != nil || decision != reservationConflict {
		t.Fatalf("conflict: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_CompletedResultSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	digest := testDispatchDigest("one")
	d1 := newDedupRing(4, path, "", nil)
	reserveAndComplete(t, d1, "req-1", digest, ActionResultMsg{EventID: "evt_1", Status: "success"})

	d2 := newDedupRing(4, path, "", nil)
	decision, result, err := d2.reserve("req-1", digest)
	if err != nil || decision != reservationReplay || result.EventID != "evt_1" {
		t.Fatalf("result did not survive restart: decision=%v result=%+v err=%v", decision, result, err)
	}
}

func TestDedupRing_LocalAuditFailureSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	digest := testDispatchDigest("audit-failed")
	d1 := newDedupRing(4, path, "", nil)
	reserveAndComplete(t, d1, "req-audit-failed", digest, ActionResultMsg{
		LocalAuditFailed: true,
		Status:           "success",
	})

	d2 := newDedupRing(4, path, "", nil)
	decision, result, err := d2.reserve("req-audit-failed", digest)
	if err != nil || decision != reservationReplay || result.EventID != "" || !result.LocalAuditFailed {
		t.Fatalf("audit failure did not survive restart: decision=%v result=%+v err=%v", decision, result, err)
	}
}

func TestDedupRing_RejectsNoncurrentAndMalformedEntries(t *testing.T) {
	digest := testDispatchDigest("req")
	result := `{"type":"action_result","protocol_version":1,"request_id":"req","status":"success","exit_code":0,"duration_ms":0,"emitted_stdout_bytes":0,"emitted_stderr_bytes":0,"progress_chunks":0,"event_id":"evt"}`
	tests := map[string]string{
		"legacy without result":  `{"request_id":"req","other":true}`,
		"legacy bad result type": `{"request_id":"req","result":{"type":"error","request_id":"req","status":"success"}}`,
		"legacy without id":      `{"result":` + result + `}`,
		"unknown field":          `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"reserved","result":{},"extra":true}`,
		"duplicate key":          `{"request_id":"req","request_id":"other","dispatch_sha256":"` + digest + `","state":"reserved","result":{}}`,
		"duplicate record":       `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"reserved","result":{}}` + "\n" + `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"reserved","result":{}}`,
		"bad digest":             `{"request_id":"req","dispatch_sha256":"bad","state":"reserved","result":{}}`,
		"unknown state":          `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"other","result":{}}`,
		"reserved with result":   `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"reserved","result":` + result + `}`,
		"completed without type": `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"completed","result":{"protocol_version":1,"request_id":"req","status":"success"}}`,
		"wrong protocol":         `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"completed","result":{"type":"action_result","protocol_version":2,"request_id":"req","status":"success"}}`,
		"wrong result request":   `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"completed","result":{"type":"action_result","protocol_version":1,"request_id":"other","status":"success"}}`,
		"unknown result status":  `{"request_id":"req","dispatch_sha256":"` + digest + `","state":"completed","result":{"type":"action_result","protocol_version":1,"request_id":"req","status":"other"}}`,
	}

	for name, contents := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "dedup.jsonl")
			if err := os.WriteFile(path, []byte(contents+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			d := newDedupRing(2, path, "", nil)
			if d.loadErr == nil {
				t.Fatal("invalid dispatch record did not fail closed")
			}
			if _, _, err := d.reserve("new", testDispatchDigest("new")); err == nil {
				t.Fatal("invalid dispatch log allowed a new execution")
			}
		})
	}
}

// legacyDispatchLine is a pre-v0.10 dispatch log entry exactly as those
// runners persisted it: request_id + result, no state, no dispatch digest.
func legacyDispatchLine(requestID string) string {
	return `{"request_id":"` + requestID + `","result":{"type":"action_result","protocol_version":1,"request_id":"` + requestID + `","status":"success","exit_code":0,"event_id":"evt"}}`
}

// Deleting the v0.9 migration once bricked dispatch on every upgraded host
// that carried history (loadErr → every reserve refused). Legacy entries
// must load, normalize, and persist in the current format instead.
func TestDedupRing_MigratesLegacyEntriesInPlace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dispatches.jsonl")
	if err := os.WriteFile(path, []byte(legacyDispatchLine("req-legacy")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, path, "", nil)
	if d.loadErr != nil {
		t.Fatalf("legacy entry failed to load: %v", d.loadErr)
	}
	entry, ok := d.records["req-legacy"]
	if !ok {
		t.Fatal("legacy entry missing after load")
	}
	if entry.State != dispatchAcknowledged {
		t.Fatalf("legacy entry state = %q, want acknowledged (delivered long ago; never resent)", entry.State)
	}
	if entry.DispatchSHA256 != legacyDispatchDigest("req-legacy") {
		t.Fatalf("legacy entry digest = %q, want the deterministic sentinel", entry.DispatchSHA256)
	}
	// Envelope normalized to the current contract; the honest audit pairing
	// for a run with no durable event id.
	if entry.Result.ProtocolVersion != ProtocolVersion || entry.Result.EventID != "" || !entry.Result.LocalAuditFailed {
		t.Fatalf("legacy result not normalized: %+v", entry.Result)
	}

	// The migration persisted immediately: the rewritten file is pure current
	// format, so a restart loads it with zero legacy decoding.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte(`"dispatch_sha256"`)) {
		t.Fatalf("store not rewritten in current format: %s", data)
	}
	restarted := newDedupRing(4, path, "", nil)
	if restarted.loadErr != nil {
		t.Fatalf("migrated store failed to reload: %v", restarted.loadErr)
	}

	// A post-migration redelivery of the same request_id carries the REAL
	// dispatch digest, mismatches the sentinel, and is refused — fail-safe:
	// never a second execution under a recycled id.
	decision, _, err := restarted.reserve("req-legacy", testDispatchDigest("req-legacy"))
	if err != nil || decision != reservationConflict {
		t.Fatalf("redelivery after migration: decision=%v err=%v, want conflict", decision, err)
	}
}

// A host upgrading straight from ≤v0.11 has its dispatch log at the old
// dedup.jsonl location. First boot without a current log adopts it — state is
// migrated forward, never silently abandoned.
func TestDedupRing_AdoptsLegacyStorePath(t *testing.T) {
	dir := t.TempDir()
	storePath := filepath.Join(dir, "dispatches.jsonl")
	legacyPath := filepath.Join(dir, "dedup.jsonl")
	if err := os.WriteFile(legacyPath, []byte(legacyDispatchLine("req-old")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, storePath, legacyPath, nil)
	if d.loadErr != nil {
		t.Fatalf("legacy store adoption failed: %v", d.loadErr)
	}
	if _, ok := d.records["req-old"]; !ok {
		t.Fatal("adopted entry missing")
	}
	if _, err := os.Stat(storePath); err != nil {
		t.Fatalf("current store not written by adoption: %v", err)
	}
	if _, err := os.Stat(legacyPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy store still at old path after adoption: %v", err)
	}
	if _, err := os.Stat(legacyPath + ".migrated"); err != nil {
		t.Fatalf("legacy store not preserved as .migrated: %v", err)
	}

	// The next boot finds the current store and never re-reads the old path.
	restarted := newDedupRing(4, storePath, legacyPath, nil)
	if restarted.loadErr != nil || len(restarted.records) != 1 {
		t.Fatalf("post-adoption reload: err=%v records=%d", restarted.loadErr, len(restarted.records))
	}
}

// An unreadable legacy store starts clean (that is what ignoring it already
// did) but must never fail the boot — and must stay on disk for inspection.
func TestDedupRing_UnreadableLegacyStoreStartsClean(t *testing.T) {
	dir := t.TempDir()
	storePath := filepath.Join(dir, "dispatches.jsonl")
	legacyPath := filepath.Join(dir, "dedup.jsonl")
	if err := os.WriteFile(legacyPath, []byte("not-json\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, storePath, legacyPath, nil)
	if d.loadErr != nil {
		t.Fatalf("unreadable legacy store failed the boot: %v", d.loadErr)
	}
	if decision, _, err := d.reserve("req-new", testDispatchDigest("req-new")); err != nil || decision != reservationNew {
		t.Fatalf("clean start could not reserve: decision=%v err=%v", decision, err)
	}
	if _, err := os.Stat(legacyPath); err != nil {
		t.Fatalf("unreadable legacy store was moved or removed: %v", err)
	}
}

// A current store always wins: the legacy path is not even opened, so state
// that already migrated (or was quarantined by hand) cannot resurrect.
func TestDedupRing_CurrentStoreWinsOverLegacy(t *testing.T) {
	dir := t.TempDir()
	storePath := filepath.Join(dir, "dispatches.jsonl")
	legacyPath := filepath.Join(dir, "dedup.jsonl")

	seed := newDedupRing(4, storePath, "", nil)
	reserveCompleteAndAcknowledge(t, seed, "req-current", testDispatchDigest("req-current"), ActionResultMsg{EventID: "evt"})
	if err := os.WriteFile(legacyPath, []byte(legacyDispatchLine("req-stale")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := newDedupRing(4, storePath, legacyPath, nil)
	if d.loadErr != nil {
		t.Fatalf("load: %v", d.loadErr)
	}
	if _, ok := d.records["req-current"]; !ok {
		t.Fatal("current entry missing")
	}
	if _, ok := d.records["req-stale"]; ok {
		t.Fatal("legacy entry loaded despite a current store")
	}
	if _, err := os.Stat(legacyPath); err != nil {
		t.Fatalf("legacy store touched despite a current store: %v", err)
	}
}

func TestInspectDispatchLog(t *testing.T) {
	t.Run("absent", func(t *testing.T) {
		report := InspectDispatchLog(t.TempDir())
		if report.State != DispatchLogAbsent {
			t.Fatalf("state = %q, want absent", report.State)
		}
	})

	t.Run("ok", func(t *testing.T) {
		dir := t.TempDir()
		d := newDedupRing(4, DispatchLogPath(dir), "", nil)
		reserveCompleteAndAcknowledge(t, d, "req", testDispatchDigest("req"), ActionResultMsg{EventID: "evt"})

		report := InspectDispatchLog(dir)
		if report.State != DispatchLogOK || report.Entries != 1 {
			t.Fatalf("report = %+v, want ok with 1 entry", report)
		}
	})

	t.Run("legacy location", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(LegacyDispatchLogPath(dir), []byte(legacyDispatchLine("req")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		report := InspectDispatchLog(dir)
		if report.State != DispatchLogLegacy || report.Entries != 1 {
			t.Fatalf("report = %+v, want legacy with 1 entry", report)
		}
	})

	t.Run("legacy format at current location", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(DispatchLogPath(dir), []byte(legacyDispatchLine("req")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		report := InspectDispatchLog(dir)
		if report.State != DispatchLogLegacy {
			t.Fatalf("report = %+v, want legacy", report)
		}
	})

	t.Run("corrupt", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(DispatchLogPath(dir), []byte("not-json\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		report := InspectDispatchLog(dir)
		if report.State != DispatchLogCorrupt || report.Err == nil {
			t.Fatalf("report = %+v, want corrupt with error", report)
		}
	})

	t.Run("corrupt legacy", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(LegacyDispatchLogPath(dir), []byte("not-json\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		report := InspectDispatchLog(dir)
		if report.State != DispatchLogCorrupt || report.Err == nil {
			t.Fatalf("report = %+v, want corrupt with error", report)
		}
	})
}

func TestDedupRing_CompleteRejectsMalformedResultBeforePersistence(t *testing.T) {
	valid := testActionResult("req", ActionResultMsg{EventID: "evt"})
	tests := map[string]func(*ActionResultMsg){
		"wrong type":              func(result *ActionResultMsg) { result.Type = MsgError },
		"wrong protocol":          func(result *ActionResultMsg) { result.ProtocolVersion++ },
		"wrong request":           func(result *ActionResultMsg) { result.RequestID = "other" },
		"unknown status":          func(result *ActionResultMsg) { result.Status = "other" },
		"missing audit outcome":   func(result *ActionResultMsg) { result.EventID = "" },
		"conflicting audit state": func(result *ActionResultMsg) { result.LocalAuditFailed = true },
	}

	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "dedup.jsonl")
			digest := testDispatchDigest(name)
			d := newDedupRing(2, path, "", nil)
			if decision, _, err := d.reserve("req", digest); err != nil || decision != reservationNew {
				t.Fatalf("reserve: decision=%v err=%v", decision, err)
			}
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			result := valid
			mutate(&result)
			if err := d.complete("req", digest, result); err == nil {
				t.Fatal("malformed result completed a dispatch")
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(after, before) {
				t.Fatal("malformed completion changed the durable reservation")
			}
		})
	}
}

func TestDedupRing_CompletePersistenceFailureRestoresReservation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	digest := testDispatchDigest("req")
	d := newDedupRing(2, path, "", nil)
	if decision, _, err := d.reserve("req", digest); err != nil || decision != reservationNew {
		t.Fatalf("reserve: decision=%v err=%v", decision, err)
	}

	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.storePath = filepath.Join(blocker, "dedup.jsonl")
	if err := d.complete("req", digest, testActionResult("req", ActionResultMsg{EventID: "evt"})); err == nil {
		t.Fatal("completion unexpectedly persisted through an invalid path")
	}
	if decision, _, err := d.inspect("req", digest); err != nil || decision != reservationPending {
		t.Fatalf("failed completion did not restore reservation: decision=%v err=%v", decision, err)
	}

	restarted := newDedupRing(2, path, "", nil)
	if decision, _, err := restarted.inspect("req", digest); err != nil || decision != reservationPending {
		t.Fatalf("durable reservation changed after failed completion: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_AcknowledgementSurvivesRestartAndEnablesEviction(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	firstDigest := testDispatchDigest("first")
	d1 := newDedupRing(1, path, "", nil)
	reserveAndComplete(t, d1, "first", firstDigest, ActionResultMsg{EventID: "evt_first"})

	d2 := newDedupRing(1, path, "", nil)
	if _, _, err := d2.reserve("second", testDispatchDigest("second")); err == nil {
		t.Fatal("restart made an unacknowledged result evictable")
	}
	if err := d2.acknowledge("first"); err != nil {
		t.Fatal(err)
	}

	d3 := newDedupRing(1, path, "", nil)
	if decision, _, err := d3.reserve("second", testDispatchDigest("second")); err != nil || decision != reservationNew {
		t.Fatalf("persisted acknowledgement did not enable eviction: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_OnlyReturnsUnacknowledgedResultsForReconciliation(t *testing.T) {
	d := newDedupRing(3, "", "", nil)
	reserveAndComplete(t, d, "pending-ack", testDispatchDigest("pending-ack"), ActionResultMsg{
		Envelope: Envelope{RequestID: "pending-ack"}, EventID: "evt_pending",
	})
	reserveCompleteAndAcknowledge(t, d, "acked", testDispatchDigest("acked"), ActionResultMsg{
		Envelope: Envelope{RequestID: "acked"}, EventID: "evt_acked",
	})
	if decision, _, err := d.reserve("reserved", testDispatchDigest("reserved")); err != nil || decision != reservationNew {
		t.Fatalf("reserve: decision=%v err=%v", decision, err)
	}

	results := d.unacknowledgedResults()
	if len(results) != 1 || results[0].RequestID != "pending-ack" {
		t.Fatalf("unacknowledged results = %#v", results)
	}
}

func TestDedupRing_UnfinishedReservationSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	digest := testDispatchDigest("pending")
	d1 := newDedupRing(4, path, "", nil)
	decision, _, err := d1.reserve("req-pending", digest)
	if err != nil || decision != reservationNew {
		t.Fatalf("initial reserve: decision=%v err=%v", decision, err)
	}

	d2 := newDedupRing(4, path, "", nil)
	decision, _, err = d2.reserve("req-pending", digest)
	if err != nil || decision != reservationPending {
		t.Fatalf("restart reserve: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_PersistedRingStaysBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d1 := newDedupRing(2, path, "", nil)
	for _, id := range []string{"a", "b", "c"} {
		reserveCompleteAndAcknowledge(t, d1, id, testDispatchDigest(id), ActionResultMsg{EventID: "evt_" + id})
	}
	d2 := newDedupRing(2, path, "", nil)
	if _, ok := d2.lookup("a"); ok {
		t.Fatal("evicted entry should not persist")
	}
	if _, ok := d2.lookup("c"); !ok || dedupSize(d2) != 2 {
		t.Fatalf("reloaded ring is wrong: size=%d", dedupSize(d2))
	}
}

func TestDedupRing_CorruptStoreFailsClosed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	good, err := json.Marshal(dedupEntry{
		RequestID: "good", DispatchSHA256: testDispatchDigest("good"), State: dispatchCompleted,
		Result: testActionResult("good", ActionResultMsg{EventID: "evt_good"}),
	})
	if err != nil {
		t.Fatal(err)
	}
	contents := append(append(good, '\n'), []byte(`{"request_id":"torn","state"`)...)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	d := newDedupRing(4, path, "", nil)
	if _, _, err := d.reserve("new", testDispatchDigest("new")); err == nil {
		t.Fatal("corrupt dispatch log must refuse new execution")
	}
}

func TestDedupRing_ReservationPersistenceFailureRollsBack(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(parent, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d := newDedupRing(4, filepath.Join(parent, "dedup.jsonl"), "", nil)
	if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil {
		t.Fatal("reservation unexpectedly succeeded")
	}
	if dedupSize(d) != 0 {
		t.Fatalf("failed reservation remained in memory: size=%d", dedupSize(d))
	}
}

func TestDedupRing_ConcurrentReservations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d := newDedupRing(1000, path, "", nil)
	var wg sync.WaitGroup
	errs := make(chan error, 50)
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			id := fmt.Sprintf("req-%d", n)
			decision, _, err := d.reserve(id, testDispatchDigest(id))
			if err == nil && decision != reservationNew {
				err = fmt.Errorf("reserve %s decision=%v", id, decision)
			}
			if err == nil {
				err = d.complete(id, testDispatchDigest(id), testActionResult(id, ActionResultMsg{EventID: "evt"}))
			}
			errs <- err
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if dedupSize(d) != 50 {
		t.Fatalf("size=%d, want 50", dedupSize(d))
	}
}

func TestDispatchDigest_PreservesFactsAndLargeJSONNumbers(t *testing.T) {
	base := RunActionMsg{
		ActionID: "cockroach.pause_job", ExpectedPackHash: "sha256:abc", PackRef: "cockroach@1/sha256:abc",
		ArgsRaw: json.RawMessage(`{"job_id":9007199254740993}`),
		Reason:  "maintenance", OperationID: "op-1",
	}
	first, err := dispatchDigest(base)
	if err != nil {
		t.Fatal(err)
	}
	changed := base
	changed.ArgsRaw = json.RawMessage(`{"job_id":9007199254740992}`)
	second, err := dispatchDigest(changed)
	if err != nil {
		t.Fatal(err)
	}
	if first == second || len(first) != 64 || strings.Trim(first, "0123456789abcdef") != "" {
		t.Fatalf("bad dispatch digests: %q %q", first, second)
	}
	changed = base
	changed.ExpectedPackHash = "sha256:def"
	third, err := dispatchDigest(changed)
	if err != nil {
		t.Fatal(err)
	}
	if first == third {
		t.Fatal("expected_pack_hash must be part of the dispatch digest")
	}
}
