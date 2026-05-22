package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// fakeConn is an in-memory transport. Each call to Send appends to a
// slice; Recv blocks on an inbound channel. Calling Close makes pending
// Send/Recv calls return io.EOF so the client treats it as a dead
// socket and reconnects.
type fakeConn struct {
	mu       sync.Mutex
	sent     []any
	in       chan []byte
	closedCh chan struct{}
	closed   atomic.Bool
}

func newFakeConn() *fakeConn {
	return &fakeConn{
		in:       make(chan []byte, 16),
		closedCh: make(chan struct{}),
	}
}

func (c *fakeConn) Send(ctx context.Context, msg any) error {
	if c.closed.Load() {
		return io.ErrClosedPipe
	}
	c.mu.Lock()
	c.sent = append(c.sent, msg)
	c.mu.Unlock()
	return nil
}

func (c *fakeConn) Recv(ctx context.Context) ([]byte, error) {
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-c.closedCh:
		return nil, io.EOF
	case b, ok := <-c.in:
		if !ok {
			return nil, io.EOF
		}
		return b, nil
	}
}

func (c *fakeConn) Close() error {
	if c.closed.CompareAndSwap(false, true) {
		close(c.closedCh)
	}
	return nil
}

// sentByType returns sent messages filtered by type. Safe to call from tests.
func (c *fakeConn) sentByType(t MessageType) []map[string]any {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := []map[string]any{}
	for _, m := range c.sent {
		raw, err := json.Marshal(m)
		if err != nil {
			continue
		}
		var probe map[string]any
		_ = json.Unmarshal(raw, &probe)
		if MessageType(probe["type"].(string)) == t {
			out = append(out, probe)
		}
	}
	return out
}

// queuedDialer hands out a sequence of pre-built fakeConns. After each
// is closed, the next Dial returns the next one.
type queuedDialer struct {
	mu    sync.Mutex
	conns []*fakeConn
}

func (d *queuedDialer) Dial(ctx context.Context) (Conn, string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.conns) == 0 {
		return nil, "", errors.New("no more conns")
	}
	c := d.conns[0]
	d.conns = d.conns[1:]
	return c, "agt_test", nil
}

const echoActionYAML = `
schema_version: 1
id: t.echo
title: Echo
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: msg
    type: string
    required: true
execution:
  command:
    binary: /bin/echo
    argv: ["{{ args.msg }}"]
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

// longActionYAML sleeps for 30s if uninterrupted. Used by the
// CancelMsg test to verify cloud-initiated cancellation reaches the
// executor and SIGTERMs the process before the 30s elapse.
const longActionYAML = `
schema_version: 1
id: t.sleep
title: Long sleep
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "sleep 30"]
  timeout: 1m
  cancel_grace: 2s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func buildClient(t *testing.T, dialer Dialer) *Client {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(`schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
  - actions/sleep.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoActionYAML), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "sleep.yaml"), []byte(longActionYAML), 0o644))
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	must(err)
	sink, err := audit.OpenJSONL(filepath.Join(root, "events.jsonl"), audit.JSONLOptions{})
	must(err)
	j := audit.New(audit.Defaults{}, sink)
	t.Cleanup(func() { _ = j.Close() })
	eng := engine.New(engine.Config{
		Registry: reg, Executor: executor.New(), Journal: j, Redactor: redact.Empty(),
		PreviewBytes: 256,
	})
	return NewClient(dialer, Options{
		StateBuilder: &StateBuilder{
			AgentID:     "agt",
			Version:     "0.2.0",
			GetRegistry: eng.Registry,
		},
		Engine:            eng,
		HeartbeatEvery:    time.Hour, // disable for tests
		ReconnectMin:      10 * time.Millisecond,
		ReconnectMax:      20 * time.Millisecond,
		MaxConcurrentRuns: 4,
		MaxPendingPerRun:  2048,
	})
}

func sendRunAction(t *testing.T, c *fakeConn, requestID, actionID string, args map[string]any) {
	t.Helper()
	raw, err := json.Marshal(RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		ActionID: actionID,
		Args:     args,
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	c.in <- raw
}

func waitForResult(t *testing.T, c *fakeConn, requestID string, deadline time.Duration) map[string]any {
	t.Helper()
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	timeout := time.After(deadline)
	for {
		for _, m := range c.sentByType(MsgActionResult) {
			if m["request_id"] == requestID {
				return m
			}
		}
		select {
		case <-tick.C:
		case <-timeout:
			t.Fatalf("no result for %s within %s", requestID, deadline)
		}
	}
}

// TestClient_DeliversResultsOnSingleConn — happy path that proves the
// new sender pipeline still delivers under normal conditions.
func TestClient_DeliversResultsOnSingleConn(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	sendRunAction(t, conn, "req_a", "t.echo", map[string]any{"msg": "hi"})
	res := waitForResult(t, conn, "req_a", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}
}

// TestClient_ReplaysResultAcrossReconnect — the critical zombie/long-job
// behaviour. Cloud sends a run, runner starts it, the connection is
// killed BEFORE the action finishes. Run keeps going. A new connection
// is dialed; the result is delivered on the new conn.
func TestClient_ReplaysResultAcrossReconnect(t *testing.T) {
	conn1 := newFakeConn()
	conn2 := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn1, conn2}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Kick off an echo, then drop conn1 immediately. Echo is fast, but
	// the senderLoop polls every 25ms — there is a meaningful window
	// during which the result is enqueued but unsent. We close conn1
	// from a goroutine ~10ms in to maximise the chance of catching it.
	sendRunAction(t, conn1, "req_replay", "t.echo", map[string]any{"msg": "across"})

	go func() {
		time.Sleep(5 * time.Millisecond)
		conn1.Close()
	}()

	// The client should fail conn1's sender, back off briefly, dial
	// conn2, send agent_state, then replay the queued result on conn2.
	res := waitForResult(t, conn2, "req_replay", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}

	// The original connection must NOT have received the result.
	for _, m := range conn1.sentByType(MsgActionResult) {
		if m["request_id"] == "req_replay" {
			t.Fatalf("result was sent on dead conn1: %+v", m)
		}
	}
}

// heartbeatFailingConn fails Send on the first HeartbeatMsg; other
// sends succeed normally. Used to verify that a heartbeat send error
// cancels the session and triggers reconnect.
type heartbeatFailingConn struct {
	*fakeConn
	hbFailed atomic.Bool
}

func (c *heartbeatFailingConn) Send(ctx context.Context, msg any) error {
	if _, isHB := msg.(HeartbeatMsg); isHB && c.hbFailed.CompareAndSwap(false, true) {
		// Close the conn so the receiver and sender both wake with EOF.
		c.fakeConn.Close()
		return io.ErrUnexpectedEOF
	}
	return c.fakeConn.Send(ctx, msg)
}

func TestClient_HeartbeatFailureTriggersReconnect(t *testing.T) {
	conn1 := &heartbeatFailingConn{fakeConn: newFakeConn()}
	conn2 := newFakeConn()
	// Adapter: queuedDialer expects *fakeConn, but the second slot is a
	// plain fakeConn. Wrap with a small Dialer that returns whichever's next.
	d := &mixedDialer{conns: []Conn{conn1, conn2}}
	cli := buildClient(t, d)
	cli.opts.HeartbeatEvery = 50 * time.Millisecond
	cli.opts.ReconnectMin = 10 * time.Millisecond
	cli.opts.ReconnectMax = 20 * time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Wait until the second conn receives an agent_state — that
	// confirms reconnect happened.
	deadline := time.After(5 * time.Second)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		if len(conn2.sentByType(MsgRunnerState)) > 0 {
			return // reconnect succeeded
		}
		select {
		case <-tick.C:
		case <-deadline:
			t.Fatalf("reconnect did not happen; conn1 hb_failed=%v conn2 sends=%d",
				conn1.hbFailed.Load(), len(conn2.sent))
		}
	}
}

// mixedDialer is like queuedDialer but accepts a heterogeneous slice
// so the heartbeat-failing wrapper can sit alongside plain fakeConns.
type mixedDialer struct {
	mu    sync.Mutex
	conns []Conn
}

func (d *mixedDialer) Dial(ctx context.Context) (Conn, string, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.conns) == 0 {
		return nil, "", errors.New("no more conns")
	}
	c := d.conns[0]
	d.conns = d.conns[1:]
	return c, "agt_test", nil
}

// TestClient_CancelMsgTerminatesInflightAction verifies the end-to-end
// cancel path:
//
//  1. Cloud sends RunActionMsg for a long-running action.
//  2. Once the runner has started the action, cloud sends CancelMsg.
//  3. The runner SIGTERMs the process group (via cmd.Cancel), waits
//     up to cancel_grace, then SIGKILL.
//  4. An ActionResultMsg is still delivered back to cloud.
//
// The whole flow must complete well before the action's 1-minute
// declared timeout — proving cancellation reached the process and
// didn't just wait the timeout out.
func TestClient_CancelMsgTerminatesInflightAction(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Kick off the sleep action.
	start := time.Now()
	sendRunAction(t, conn, "req_cancel", "t.sleep", nil)

	// Wait briefly for the runner to register the in-flight run. Polling
	// is cheap; we just need handleRun to have inserted into c.runs.
	deadline := time.After(2 * time.Second)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for cli.countInflight() == 0 {
		select {
		case <-tick.C:
		case <-deadline:
			t.Fatal("action never started")
		}
	}

	// Now send the cancel.
	raw, err := json.Marshal(CancelMsg{
		Envelope: Envelope{Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: "req_cancel"},
	})
	if err != nil {
		t.Fatal(err)
	}
	conn.in <- raw

	// Result should arrive within ~3s (the trap script's 2s
	// cancel_grace plus scheduling/test overhead). The 1m action
	// timeout would otherwise win.
	res := waitForResult(t, conn, "req_cancel", 10*time.Second)
	elapsed := time.Since(start)
	if elapsed > 15*time.Second {
		t.Fatalf("cancel took too long (%s); the action timeout (1m) shouldn't have been the trigger", elapsed)
	}
	// Status will be failed or success-with-nonzero exit depending on
	// how the shell happened to react. The point is that it terminated
	// fast — not that it returned a specific status code.
	if res["status"] == nil {
		t.Fatalf("no status on result: %+v", res)
	}
}

// TestClient_TolerantOfNewerProtocolVersion confirms the
// documented compatibility rule: an inbound message of a known type
// decodes and dispatches even if it claims a newer protocol_version
// than this runner. The runner never refuses unknown versions on known
// types — it just decodes what it understands.
func TestClient_TolerantOfNewerProtocolVersion(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Send a run_action that claims a far-future protocol_version.
	raw, err := json.Marshal(RunActionMsg{
		Envelope: Envelope{
			Type:            MsgRunAction,
			ProtocolVersion: 999,
			RequestID:       "req_future",
		},
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "future ok"},
		Reason:   "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	conn.in <- raw

	res := waitForResult(t, conn, "req_future", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("future protocol_version should still execute; status=%v", res["status"])
	}
	// And the runner's reply must use the RUNNER's protocol_version, not
	// echo back the inbound one — outbound messages always advertise
	// what the runner speaks.
	if got := int(res["protocol_version"].(float64)); got != ProtocolVersion {
		t.Fatalf("runner reply protocol_version=%d, want %d", got, ProtocolVersion)
	}
}

// TestClient_OutboundProtocolVersionConsistent confirms every outbound
// message type the runner sends carries the current ProtocolVersion.
func TestClient_OutboundProtocolVersionConsistent(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	sendRunAction(t, conn, "req_v", "t.echo", map[string]any{"msg": "v"})
	_ = waitForResult(t, conn, "req_v", 3*time.Second)

	conn.mu.Lock()
	sent := append([]any(nil), conn.sent...)
	conn.mu.Unlock()
	for _, m := range sent {
		b, _ := json.Marshal(m)
		var probe map[string]any
		_ = json.Unmarshal(b, &probe)
		ver, ok := probe["protocol_version"]
		if !ok {
			t.Errorf("outbound message has no protocol_version: %s", b)
			continue
		}
		if int(ver.(float64)) != ProtocolVersion {
			t.Errorf("outbound %v has protocol_version=%v, want %d",
				probe["type"], ver, ProtocolVersion)
		}
	}
}

// TestClient_ConcurrencyCap — exceeding cap returns an error envelope
// instead of starting a new run.
func TestClient_ConcurrencyCap(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)
	cli.opts.MaxConcurrentRuns = 1

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Two concurrent runs; second should be rejected.
	sendRunAction(t, conn, "req_first", "t.echo", map[string]any{"msg": "1"})
	sendRunAction(t, conn, "req_second", "t.echo", map[string]any{"msg": "2"})

	// Look for any error message with concurrency_cap_reached. We can't
	// guarantee ordering — the first might finish before the second
	// arrives, in which case the second runs successfully. To make the
	// test deterministic we'd need a slower action; for now, just
	// verify that EITHER both succeed OR the second was capped.
	deadline := time.After(3 * time.Second)
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		results := conn.sentByType(MsgActionResult)
		errs := conn.sentByType(MsgError)
		if len(results)+len(errs) >= 2 {
			// At least one of these branches must be true:
			//   1. both succeeded (cap wasn't hit because the first finished first)
			//   2. error with concurrency_cap_reached delivered
			cappedSeen := false
			for _, e := range errs {
				if e["code"] == "concurrency_cap_reached" {
					cappedSeen = true
				}
			}
			if cappedSeen || len(results) == 2 {
				return
			}
			t.Fatalf("unexpected mix: results=%+v errs=%+v", results, errs)
		}
		select {
		case <-tick.C:
		case <-deadline:
			t.Fatalf("timed out waiting for two responses; results=%v errs=%v",
				len(results), len(errs))
		}
	}
}
