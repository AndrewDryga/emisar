package cloud

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
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
	d := newDedupRing(4, "", nil)
	reserveAndComplete(t, d, "a", testDispatchDigest("a"), ActionResultMsg{EventID: "evt_a"})
	reserveAndComplete(t, d, "b", testDispatchDigest("b"), ActionResultMsg{EventID: "evt_b"})

	if r, ok := d.lookup("a"); !ok || r.EventID != "evt_a" {
		t.Fatalf("a not found: %+v", r)
	}
	if _, ok := d.lookup("missing"); ok {
		t.Fatal("missing should be absent")
	}
}

func TestDedupRing_EvictsOldest(t *testing.T) {
	d := newDedupRing(2, "", nil)
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
	d := newDedupRing(1, "", nil)
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
	d := newDedupRing(1, "", nil)
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
	d := newDedupRing(4, "", nil)
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
	d1 := newDedupRing(4, path, nil)
	reserveAndComplete(t, d1, "req-1", digest, ActionResultMsg{EventID: "evt_1", Status: "success"})

	d2 := newDedupRing(4, path, nil)
	decision, result, err := d2.reserve("req-1", digest)
	if err != nil || decision != reservationReplay || result.EventID != "evt_1" {
		t.Fatalf("result did not survive restart: decision=%v result=%+v err=%v", decision, result, err)
	}
}

func TestDedupRing_LocalAuditFailureSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	digest := testDispatchDigest("audit-failed")
	d1 := newDedupRing(4, path, nil)
	reserveAndComplete(t, d1, "req-audit-failed", digest, ActionResultMsg{
		LocalAuditFailed: true,
		Status:           "success",
	})

	d2 := newDedupRing(4, path, nil)
	decision, result, err := d2.reserve("req-audit-failed", digest)
	if err != nil || decision != reservationReplay || result.EventID != "" || !result.LocalAuditFailed {
		t.Fatalf("audit failure did not survive restart: decision=%v result=%+v err=%v", decision, result, err)
	}
}

func TestDedupRing_RejectsNoncurrentAndMalformedEntries(t *testing.T) {
	digest := testDispatchDigest("req")
	result := `{"type":"action_result","protocol_version":1,"request_id":"req","status":"success","exit_code":0,"duration_ms":0,"emitted_stdout_bytes":0,"emitted_stderr_bytes":0,"progress_chunks":0,"event_id":"evt"}`
	tests := map[string]string{
		"legacy shape":           `{"request_id":"req","result":` + result + `}`,
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
			d := newDedupRing(2, path, nil)
			if d.loadErr == nil {
				t.Fatal("invalid dispatch record did not fail closed")
			}
			if _, _, err := d.reserve("new", testDispatchDigest("new")); err == nil {
				t.Fatal("invalid dispatch log allowed a new execution")
			}
		})
	}
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
			d := newDedupRing(2, path, nil)
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
	d := newDedupRing(2, path, nil)
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

	restarted := newDedupRing(2, path, nil)
	if decision, _, err := restarted.inspect("req", digest); err != nil || decision != reservationPending {
		t.Fatalf("durable reservation changed after failed completion: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_AcknowledgementSurvivesRestartAndEnablesEviction(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	firstDigest := testDispatchDigest("first")
	d1 := newDedupRing(1, path, nil)
	reserveAndComplete(t, d1, "first", firstDigest, ActionResultMsg{EventID: "evt_first"})

	d2 := newDedupRing(1, path, nil)
	if _, _, err := d2.reserve("second", testDispatchDigest("second")); err == nil {
		t.Fatal("restart made an unacknowledged result evictable")
	}
	if err := d2.acknowledge("first"); err != nil {
		t.Fatal(err)
	}

	d3 := newDedupRing(1, path, nil)
	if decision, _, err := d3.reserve("second", testDispatchDigest("second")); err != nil || decision != reservationNew {
		t.Fatalf("persisted acknowledgement did not enable eviction: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_OnlyReturnsUnacknowledgedResultsForReconciliation(t *testing.T) {
	d := newDedupRing(3, "", nil)
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
	d1 := newDedupRing(4, path, nil)
	decision, _, err := d1.reserve("req-pending", digest)
	if err != nil || decision != reservationNew {
		t.Fatalf("initial reserve: decision=%v err=%v", decision, err)
	}

	d2 := newDedupRing(4, path, nil)
	decision, _, err = d2.reserve("req-pending", digest)
	if err != nil || decision != reservationPending {
		t.Fatalf("restart reserve: decision=%v err=%v", decision, err)
	}
}

func TestDedupRing_PersistedRingStaysBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d1 := newDedupRing(2, path, nil)
	for _, id := range []string{"a", "b", "c"} {
		reserveCompleteAndAcknowledge(t, d1, id, testDispatchDigest(id), ActionResultMsg{EventID: "evt_" + id})
	}
	d2 := newDedupRing(2, path, nil)
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
	d := newDedupRing(4, path, nil)
	if _, _, err := d.reserve("new", testDispatchDigest("new")); err == nil {
		t.Fatal("corrupt dispatch log must refuse new execution")
	}
}

func TestDedupRing_ReservationPersistenceFailureRollsBack(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(parent, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	d := newDedupRing(4, filepath.Join(parent, "dedup.jsonl"), nil)
	if _, _, err := d.reserve("req", testDispatchDigest("req")); err == nil {
		t.Fatal("reservation unexpectedly succeeded")
	}
	if dedupSize(d) != 0 {
		t.Fatalf("failed reservation remained in memory: size=%d", dedupSize(d))
	}
}

func TestDedupRing_ConcurrentReservations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	d := newDedupRing(1000, path, nil)
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
