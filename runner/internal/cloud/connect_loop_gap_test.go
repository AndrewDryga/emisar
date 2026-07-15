package cloud

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/audit"
)

// This file closes the PHASE-3 "gap" rows on the connect runtime loop that the
// existing fake-cloud harness (gate_test.go / client_test.go) can reach without
// any production-code change:
//
//   - Dispatch/ack routing edge cases (/T07/T08)
//   - Outbox/sender accounting (/T08/T10)
//   - Heartbeat defaults + load tracking (/T06)
//   - Reconnect/backoff + NewClient defaults (/T07/T08)
//
// The harness pieces reused here: newFakeConn, queuedDialer, buildClient,
// sendRunAction, waitForResult, waitUntil, backoffCapture (client_test.go).

// --- Dispatch / ack routing -------------------------------------------------

// A premature ack — one that arrives while the run is still in flight (not
// finished, or finished but its tail not yet drained) — must be ignored:
// ackRun logs cloud.premature_ack and returns WITHOUT evicting the run from the
// in-flight map, so the sender still gets to deliver the result. Dropping the
// run here would strand an in-flight action with no terminal message reaching
// the cloud.
func TestClient_AckRun_PrematureAckIgnored(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})

	t.Run("not finished", func(t *testing.T) {
		s := &runState{requestID: "req_unfinished", finished: false}
		cli.mu.Lock()
		cli.runs[s.requestID] = s
		cli.mu.Unlock()

		cli.ackRun("req_unfinished")

		cli.mu.Lock()
		_, stillPresent := cli.runs["req_unfinished"]
		cli.mu.Unlock()
		if !stillPresent {
			t.Fatal("premature ack of an unfinished run must not evict it from the in-flight map")
		}
	})

	t.Run("finished but tail still queued", func(t *testing.T) {
		s := &runState{
			requestID: "req_undrained",
			finished:  true,
			pending:   []any{ActionResultMsg{Status: "success"}}, // not yet sent
		}
		cli.mu.Lock()
		cli.runs[s.requestID] = s
		cli.mu.Unlock()

		cli.ackRun("req_undrained")

		cli.mu.Lock()
		_, stillPresent := cli.runs["req_undrained"]
		cli.mu.Unlock()
		if !stillPresent {
			t.Fatal("ack before the result drained must not evict the run (the result still needs sending)")
		}
	})
}

// An ack for a run that has ALREADY been evicted from the in-flight map (the
// legitimate reconnect dance: the result was delivered + acked, the run
// removed, then a duplicate ack lands) must still advance the audit cursor and
// never error/panic on the missing run. The event_id is recovered from the
// dedup ring (which outlives the in-flight state) and marked acked so a later
// prune pass knows it is safe to drop.
func TestClient_AckRun_EvictedRunStillAdvancesCursor(t *testing.T) {
	cursorPath := t.TempDir() + "/ack.json"
	cursor, err := audit.OpenCursor(cursorPath, 16)
	if err != nil {
		t.Fatal(err)
	}
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}}, func(o *Options) {
		o.Cursor = cursor
	})

	// The run is gone from c.runs (already removed after its result drained),
	// but its completed result — carrying the JSONL event_id — is still in the
	// dedup ring, exactly as it would be during a reconnect-driven re-ack.
	digest := testDispatchDigest("req_evicted")
	reserveAndComplete(t, cli.dedup, "req_evicted", digest, ActionResultMsg{EventID: "evt_evicted", Status: "success"})

	// Must not panic on the absent run, and must record the event on the cursor.
	cli.ackRun("req_evicted")

	contents, err := os.ReadFile(cursorPath)
	if err != nil {
		t.Fatal(err)
	}
	var persisted struct {
		AckedEventIDs []string `json:"acked_event_ids"`
	}
	if err := json.Unmarshal(contents, &persisted); err != nil {
		t.Fatal(err)
	}
	if len(persisted.AckedEventIDs) != 1 || persisted.AckedEventIDs[0] != "evt_evicted" {
		t.Fatal("ack of an evicted run must still mark its event_id on the cursor")
	}
}

func TestClient_ReconnectRequeuesCompletedResultUntilAcknowledged(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})
	result := ActionResultMsg{
		Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: "req_lost_ack"},
		EventID:  "evt_lost_ack",
		Status:   "success",
	}
	reserveAndComplete(t, cli.dedup, result.RequestID, testDispatchDigest(result.RequestID), result)

	if got := cli.requeueUnacknowledgedResults(); got != 1 {
		t.Fatalf("first reconnect requeued %d results, want 1", got)
	}
	if got := cli.requeueUnacknowledgedResults(); got != 0 {
		t.Fatalf("same session queued %d duplicate results", got)
	}

	cli.mu.Lock()
	state := cli.runs[result.RequestID]
	cli.mu.Unlock()
	if state == nil {
		t.Fatal("requeued result has no outbox")
	}
	state.mu.Lock()
	if len(state.pending) != 1 {
		t.Fatalf("pending results = %d, want 1", len(state.pending))
	}
	state.pending = nil // successful send before the ACK was lost
	state.mu.Unlock()
	cli.removeRun(result.RequestID)

	if got := cli.requeueUnacknowledgedResults(); got != 1 {
		t.Fatalf("next reconnect requeued %d results, want 1", got)
	}
	cli.mu.Lock()
	state = cli.runs[result.RequestID]
	cli.mu.Unlock()
	state.mu.Lock()
	state.pending = nil // the retried result reached the portal
	state.mu.Unlock()
	cli.ackRun(result.RequestID)
	if got := cli.requeueUnacknowledgedResults(); got != 0 {
		t.Fatalf("acknowledged result was requeued %d times", got)
	}
}

// An early cancel is remembered without consuming an execution slot. If its
// run_action follows, the runner returns cancelled without invoking the engine.
func TestClient_CancelBeforeRunActionPreventsExecution(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})

	before := cli.countInflight()
	cli.cancelRun("req_cancelled_early")
	if after := cli.countInflight(); after != before {
		t.Fatalf("early cancel changed the in-flight count: %d -> %d", before, after)
	}

	cli.startRun(context.Background(), RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "req_cancelled_early"},
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "must not execute"},
		Reason:   "test",
	})

	result, ok := cli.dedup.lookup("req_cancelled_early")
	if !ok {
		t.Fatal("early cancellation result was not persisted")
	}
	if result.Status != "cancelled" || result.Reason != "cancelled_before_start" {
		t.Fatalf("early cancellation result = %#v", result)
	}

	cli.cancelRun("req_cancelled_early")
	if _, exists := cli.preCanceled["req_cancelled_early"]; exists {
		t.Fatal("stale cancel for a completed request created a new tombstone")
	}
}

// --- Outbox / sender accounting ---------------------------------------------

// When the per-run outbox overflows with progress chunks (the disconnected
// case: the sender isn't draining, so progress piles up past MaxPendingPerRun),
// each overflow drops the oldest chunk and bumps s.dropped. The terminal result
// carries that count structurally so the portal can mark output incomplete
// without parsing human-readable failure text.
func TestClient_Outbox_ProgressDropCountIsStructured(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}}, func(o *Options) {
		o.MaxPendingPerRun = 4
	})

	s := &runState{requestID: "req_drops"}
	// Push well past capacity so the drop counter is unambiguously > 0.
	const pushed = 4 * 5
	for i := 0; i < pushed; i++ {
		cli.enqueue(s, ActionProgressMsg{
			Envelope: Envelope{Type: MsgActionProgress, ProtocolVersion: ProtocolVersion, RequestID: "req_drops"},
			Seq:      i,
			Stream:   "stdout",
			Chunk:    "x",
		}, dropOldestProgress)
	}

	s.mu.Lock()
	dropped := s.dropped
	s.mu.Unlock()
	if dropped == 0 {
		t.Fatal("expected progress chunks to be dropped once the outbox overflowed")
	}
	// The buffer never holds more than its cap — older chunks are evicted.
	s.mu.Lock()
	pending := len(s.pending)
	s.mu.Unlock()
	if pending > cli.opts.MaxPendingPerRun {
		t.Fatalf("pending outbox %d exceeded cap %d", pending, cli.opts.MaxPendingPerRun)
	}
	if want := pushed - cli.opts.MaxPendingPerRun; dropped != want {
		t.Fatalf("dropped=%d, want %d (pushed %d, cap %d)", dropped, want, pushed, cli.opts.MaxPendingPerRun)
	}

	result := ActionResultMsg{ProgressChunks: pushed, DroppedProgressChunks: dropped}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(encoded, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["progress_chunks"] != float64(pushed) || payload["dropped_progress_chunks"] != float64(dropped) {
		t.Fatalf("structured progress accounting = %s", encoded)
	}
}

// A send error mid-drain must requeue the unsent tail and stop, so the next
// session's sender resumes from exactly the same point rather than losing
// messages. drainOnce sends in order; the conn here accepts the first message
// then fails — the failing message plus everything after it must remain in the
// outbox afterward, in order.
func TestClient_DrainOnce_SendErrorMidDrainRequeues(t *testing.T) {
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{newFakeConn()}})

	conn := &failAfterNConn{fakeConn: newFakeConn(), failAt: 2}

	s := &runState{
		requestID: "req_requeue",
		pending: []any{
			ActionProgressMsg{Envelope: Envelope{Type: MsgActionProgress, RequestID: "req_requeue"}, Seq: 1},
			ActionProgressMsg{Envelope: Envelope{Type: MsgActionProgress, RequestID: "req_requeue"}, Seq: 2},
			ActionProgressMsg{Envelope: Envelope{Type: MsgActionProgress, RequestID: "req_requeue"}, Seq: 3},
		},
	}
	cli.mu.Lock()
	cli.runs[s.requestID] = s
	cli.mu.Unlock()

	err := cli.drainOnce(context.Background(), conn)
	if err == nil {
		t.Fatal("drainOnce should return the send error so senderLoop exits and reconnects")
	}

	// The first message went out; messages 2 and 3 (the failing one + its tail)
	// are requeued, in order, ready for the next session.
	conn.mu.Lock()
	sentCount := len(conn.sent)
	conn.mu.Unlock()
	if sentCount != 1 {
		t.Fatalf("expected exactly 1 message to have been sent before the failure, got %d", sentCount)
	}

	s.mu.Lock()
	requeued := append([]any(nil), s.pending...)
	s.mu.Unlock()
	if len(requeued) != 2 {
		t.Fatalf("expected 2 messages requeued (the failing one + its tail), got %d", len(requeued))
	}
	seqs := []int{requeued[0].(ActionProgressMsg).Seq, requeued[1].(ActionProgressMsg).Seq}
	if seqs[0] != 2 || seqs[1] != 3 {
		t.Fatalf("requeue lost ordering: got seqs %v, want [2 3]", seqs)
	}
}

// The terminal result envelope must NOT repeat stdout/stderr CONTENT — the
// cloud already has the bytes from the streamed progress chunks; the result
// carries only integrity metadata (sha256 + byte counts). Repeating output here
// would double the wire cost and risk shipping un-redacted bytes a second time.
// Driven end-to-end through the real engine so the assertion is about the wire
// shape the cloud actually receives.
func TestClient_Result_OmitsStdoutStderrContent(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	sendRunAction(t, conn, cli, "req_nocontent", "t.echo", map[string]any{"msg": "streamed-bytes"})
	res := waitForResult(t, conn, "req_nocontent", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}

	// The result must carry NO output-content field whatsoever — the bytes
	// travel only on the streamed progress chunks. (executed_command, which is
	// the command line, legitimately echoes the arg value and is NOT output
	// content, so this is a field-presence check, not a value scan.)
	for _, k := range []string{"stdout", "stderr", "output", "stdout_content", "stderr_content", "stdout_preview", "stderr_preview"} {
		if v, ok := res[k]; ok {
			t.Fatalf("result must omit output content, but carries %q=%v", k, v)
		}
	}
	raw, err := json.Marshal(res)
	if err != nil {
		t.Fatal(err)
	}
	// Emitted-output metadata is present instead. It describes the runner's
	// complete bounded stream; delivery completeness is a separate field.
	if _, ok := res["emitted_stdout_sha256"]; !ok {
		t.Fatalf("result should carry emitted_stdout_sha256: %s", raw)
	}
	if _, ok := res["emitted_stdout_bytes"]; !ok {
		t.Fatalf("result should carry emitted_stdout_bytes: %s", raw)
	}
	// And there is no field on the result type at all that could carry content:
	// guard against a future field named like one. (StdoutBytes proves bytes
	// were produced, so omission is a real choice, not an empty run.)
	if b, ok := res["emitted_stdout_bytes"].(float64); !ok || b == 0 {
		t.Fatalf("expected non-zero emitted_stdout_bytes so omission is meaningful: %v", res["emitted_stdout_bytes"])
	}
}

func TestClient_EmittedMetadataCoversNormalizedRedactedChunks(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	sendRunAction(t, conn, cli, "req_integrity", "t.truncated", map[string]any{})
	res := waitForResult(t, conn, "req_integrity", 3*time.Second)

	var stdout string
	for _, progress := range conn.sentByType(MsgActionProgress) {
		if progress["request_id"] == "req_integrity" && progress["stream"] == "stdout" {
			stdout += progress["chunk"].(string)
		}
	}
	wantHash := sha256.Sum256([]byte(stdout))
	if got := res["emitted_stdout_sha256"]; got != fmt.Sprintf("%x", wantHash) {
		t.Fatalf("emitted_stdout_sha256=%v, want digest of emitted chunks %x", got, wantHash)
	}
	if got := res["emitted_stdout_bytes"]; got != float64(len(stdout)) {
		t.Fatalf("emitted_stdout_bytes=%v, emitted chunk bytes=%d", got, len(stdout))
	}
	if got := res["progress_chunks"]; got != float64(len(conn.sentByType(MsgActionProgress))) {
		t.Fatalf("progress_chunks=%v, sent progress frames=%d", got, len(conn.sentByType(MsgActionProgress)))
	}
	if res["truncated_stdout"] != true {
		t.Fatalf("truncated_stdout=%v, want true", res["truncated_stdout"])
	}
}

// --- Heartbeat --------------------------------------------------------------

// Constructing a client with no heartbeat interval defaults it to 30s, so an
// operator who omits the knob still gets the fast dead-socket probe rather than
// a heartbeat that never fires (or a divide-by-zero ticker panic).
func TestClient_Heartbeat_DefaultIntervalWhenUnset(t *testing.T) {
	cli := NewClient(&queuedDialer{conns: []*fakeConn{newFakeConn()}}, Options{})
	if cli.opts.HeartbeatEvery != 30*time.Second {
		t.Fatalf("default heartbeat = %s, want 30s", cli.opts.HeartbeatEvery)
	}
}

// The heartbeat carries action_load = the live in-flight count, so the cloud's
// scheduler can avoid piling work onto a busy runner. With a long action in
// flight, at least one heartbeat must report action_load >= 1; the field tracks
// countInflight() rather than being hard-coded to zero.
func TestClient_Heartbeat_CarriesActionLoad(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}}, func(o *Options) {
		o.HeartbeatEvery = 25 * time.Millisecond // fire often during the test
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Start a long-running action so the in-flight count is non-zero while the
	// heartbeats fire.
	sendRunAction(t, conn, cli, "req_busy", "t.sleep", nil)
	waitUntil(t, 3*time.Second, func() bool { return cli.countInflight() >= 1 })

	// Some heartbeat sent while the run was in flight must report the load.
	sawLoad := false
	waitUntil(t, 3*time.Second, func() bool {
		for _, hb := range conn.sentByType(MsgHeartbeat) {
			if load, ok := hb["action_load"].(float64); ok && load >= 1 {
				sawLoad = true
				return true
			}
		}
		return false
	})
	if !sawLoad {
		t.Fatal("no heartbeat reported action_load >= 1 while a run was in flight")
	}
	// Cancel the in-flight sleep so the test shuts down promptly.
	raw, _ := json.Marshal(CancelMsg{Envelope: Envelope{Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: "req_busy"}})
	conn.in <- raw
}

// --- Reconnect / backoff / NewClient defaults -------------------------------

// A dial failure must NOT exit Run — the runner reconnects forever (the host
// runner has no other long-running mode). Run keeps looping over failed dials,
// backing off, and only returns when the PARENT context is cancelled. A bug
// here that treated a dial error as terminal would silently take the runner
// offline on the first network blip.
func TestClient_Run_DialFailureContinuesWithBackoff(t *testing.T) {
	d := &alwaysFailDialer{}
	cli := buildClient(t, d)
	rec := &backoffCapture{}
	cli.opts.Logger = slog.New(rec)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()

	// Several dials fail and the loop keeps going (it logs session_ended each
	// time) rather than returning.
	waitUntil(t, 3*time.Second, func() bool { return len(rec.backoffs()) >= 3 })
	select {
	case err := <-done:
		t.Fatalf("Run exited on dial failure instead of reconnecting: %v", err)
	default:
	}

	// Only the parent cancel ends it.
	cancel()
	select {
	case err := <-done:
		if err != context.Canceled {
			t.Fatalf("Run should return ctx.Err() on parent cancel, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after parent cancel")
	}
	if d.calls.Load() < 3 {
		t.Fatalf("expected repeated dial attempts, got %d", d.calls.Load())
	}
}

func TestClient_Run_UnauthorizedDialFailureIsPermanent(t *testing.T) {
	d := &unauthorizedDialer{}
	cli := buildClient(t, d)

	err := cli.Run(context.Background())
	if !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("Run error = %v, want ErrUnauthorized", err)
	}
	if got := d.calls.Load(); got != 1 {
		t.Fatalf("unauthorized dial attempts = %d, want 1", got)
	}
}

// A connected session that then fails its runner_state send returns
// connected=true, which RESETS the reconnect backoff to the floor — the dial
// succeeded, so any prior backoff escalation (from earlier failed dials) was a
// stale storm, not a continuation. Without the reset a runner that finally
// connects but trips on the very first send would inherit an inflated backoff
// and reconnect slowly. Distinguishes the connected=true (send-state) path from
// the connected=false (dial-fail) path.
func TestClient_Run_SendStateFailureResetsBackoff(t *testing.T) {
	// Two dials fail (backoff escalates), then a conn that fails its FIRST send
	// (the runner_state) — connected=true, so backoff must drop to the floor.
	stateFailing := &sendStateFailingConn{fakeConn: newFakeConn()}
	d := &failThenConnDialer{fails: 2, conn: stateFailing}
	cli := buildClient(t, d)
	cli.opts.ReconnectMin = 10 * time.Millisecond
	cli.opts.ReconnectMax = 10 * time.Second // headroom so escalation is visible
	rec := &backoffCapture{}
	cli.opts.Logger = slog.New(rec)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// got[0],got[1] = the two escalating dial failures (connected=false);
	// got[2] = session_ended after the connected session whose state send failed.
	waitUntil(t, 3*time.Second, func() bool { return len(rec.backoffs()) >= 3 })
	cancel()

	got := rec.backoffs()
	if !(got[1] > got[0]) {
		t.Fatalf("expected backoff to escalate across the two failed dials, got %v", got)
	}
	if got[2] != cli.opts.ReconnectMin {
		t.Fatalf("a connected session whose state-send failed must reset backoff to the floor: got[2]=%v want %v (full %v)",
			got[2], cli.opts.ReconnectMin, got)
	}
	if !stateFailing.stateFailed.Load() {
		t.Fatal("the state-failing conn never actually rejected a send")
	}
}

// NewClient fills every zero-valued knob with its documented default, so a
// caller can pass an almost-empty Options and still get a sane client: heartbeat
// 30s, reconnect 1s..60s, 8 concurrent runs, 2048 buffered per run, dedup ring
// 1024. (client.go:108-142.)
func TestClient_NewClient_ZeroIntervalDefaults(t *testing.T) {
	cli := NewClient(&queuedDialer{conns: []*fakeConn{newFakeConn()}}, Options{})

	if cli.opts.HeartbeatEvery != 30*time.Second {
		t.Errorf("HeartbeatEvery default = %s, want 30s", cli.opts.HeartbeatEvery)
	}
	if cli.opts.ReconnectMin != time.Second {
		t.Errorf("ReconnectMin default = %s, want 1s", cli.opts.ReconnectMin)
	}
	if cli.opts.ReconnectMax != 60*time.Second {
		t.Errorf("ReconnectMax default = %s, want 60s", cli.opts.ReconnectMax)
	}
	if cli.opts.MaxConcurrentRuns != 8 {
		t.Errorf("MaxConcurrentRuns default = %d, want 8", cli.opts.MaxConcurrentRuns)
	}
	if cli.opts.MaxPendingPerRun != 2048 {
		t.Errorf("MaxPendingPerRun default = %d, want 2048", cli.opts.MaxPendingPerRun)
	}
	if cli.opts.DedupRingSize != 1024 {
		t.Errorf("DedupRingSize default = %d, want 1024", cli.opts.DedupRingSize)
	}
	if cli.opts.Logger == nil {
		t.Error("Logger default must be non-nil (slog.Default())")
	}
	// The dedup ring is constructed with the resolved size.
	if cli.dedup == nil {
		t.Error("dedup ring must be constructed")
	}
}

// --- test-only Conn/Dialer helpers (no production change) -------------------

// failAfterNConn fails the Nth Send (1-indexed) and every send after it; the
// first N-1 succeed. Used to land a send error in the MIDDLE of a drain.
type failAfterNConn struct {
	*fakeConn
	failAt int
	count  int
}

func (c *failAfterNConn) Send(ctx context.Context, msg any) error {
	c.count++
	if c.count >= c.failAt {
		return io.ErrClosedPipe
	}
	return c.fakeConn.Send(ctx, msg)
}

// alwaysFailDialer never returns a conn — every Dial errors, simulating a
// portal that stays unreachable.
type alwaysFailDialer struct {
	calls atomic.Int64
}

type unauthorizedDialer struct {
	calls atomic.Int64
}

func (d *unauthorizedDialer) Dial(context.Context) (Conn, error) {
	d.calls.Add(1)
	return nil, ErrUnauthorized
}

func (d *alwaysFailDialer) Dial(context.Context) (Conn, error) {
	d.calls.Add(1)
	return nil, io.ErrUnexpectedEOF
}

// sendStateFailingConn rejects its FIRST Send (the runner_state advertised on
// connect) with an error; subsequent sends would succeed. It models a session
// that dials cleanly but dies on the very first write.
type sendStateFailingConn struct {
	*fakeConn
	stateFailed atomic.Bool
}

func (c *sendStateFailingConn) Send(ctx context.Context, msg any) error {
	if _, ok := msg.(RunnerStateMsg); ok && c.stateFailed.CompareAndSwap(false, true) {
		c.fakeConn.Close() // wake the receiver/heartbeat with EOF too
		return io.ErrClosedPipe
	}
	return c.fakeConn.Send(ctx, msg)
}

// failThenConnDialer fails `fails` dials, then hands out conn once, then errors
// forever — the same shape as dropAfterConnectDialer but lets the test supply a
// wrapper conn (e.g. one that fails its state send).
type failThenConnDialer struct {
	fails int
	conn  Conn
	done  bool
}

func (d *failThenConnDialer) Dial(context.Context) (Conn, error) {
	if d.fails > 0 {
		d.fails--
		return nil, io.ErrUnexpectedEOF
	}
	if !d.done {
		d.done = true
		return d.conn, nil
	}
	return nil, io.ErrUnexpectedEOF
}
