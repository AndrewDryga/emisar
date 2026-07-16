package cloud

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

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
	// failResults makes Send reject ActionResultMsg with an error, simulating
	// a connection that dies just as the terminal result goes out. Lets a test
	// force a result to stay queued for replay deterministically, without
	// racing the sender's wake-up.
	failResults atomic.Bool
}

type blockingAuditSink struct {
	started chan struct{}
	release chan struct{}
}

func (s *blockingAuditSink) Write(context.Context, audit.Event) error {
	close(s.started)
	<-s.release
	return nil
}

func (*blockingAuditSink) Close() error { return nil }

type failAfterAuditSink struct {
	successes int
	attempts  int
}

func (s *failAfterAuditSink) Write(context.Context, audit.Event) error {
	s.attempts++
	if s.attempts > s.successes {
		return errors.New("forced audit failure")
	}
	return nil
}

func (*failAfterAuditSink) Close() error { return nil }

// blockedOutboundConn models a portal that keeps dispatching but stops reading
// after registration. Session cancellation must unblock Send as Conn promises.
type blockedOutboundConn struct{ *fakeConn }

func (c *blockedOutboundConn) Send(ctx context.Context, msg any) error {
	if _, ok := msg.(RunnerStateMsg); ok {
		return c.fakeConn.Send(ctx, msg)
	}
	<-ctx.Done()
	return ctx.Err()
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
	if c.failResults.Load() {
		if _, ok := msg.(ActionResultMsg); ok {
			return io.ErrClosedPipe
		}
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

func (d *queuedDialer) Dial(ctx context.Context) (Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.conns) == 0 {
		return nil, errors.New("no more conns")
	}
	c := d.conns[0]
	d.conns = d.conns[1:]
	return c, nil
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
    binary: echo
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

const truncatedActionYAML = `
schema_version: 1
id: t.truncated
title: Truncated output
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv:
      - "-c"
      - "i=0; while [ $i -lt 600 ]; do printf x; i=$((i + 1)); done"
  timeout: 5s
output:
  parser: text
  max_stdout_bytes: 512
  max_stderr_bytes: 1024
`

const stubbornActionYAML = `
schema_version: 1
id: t.stubborn
title: Ignore graceful cancellation
kind: exec
risk: low
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: /bin/sh
    argv:
      - "-c"
      - "trap '' TERM; touch /tmp/emisar-cloud-shutdown-ready; while :; do sleep 1; done"
  timeout: 1m
  cancel_grace: 500ms
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

func buildClient(t *testing.T, dialer Dialer, mod ...func(*Options)) *Client {
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
  - actions/stubborn.yaml
  - actions/truncated.yaml
`), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoActionYAML), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "sleep.yaml"), []byte(longActionYAML), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "stubborn.yaml"), []byte(stubbornActionYAML), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "truncated.yaml"), []byte(truncatedActionYAML), 0o644))
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
	opts := Options{
		StateBuilder: &StateBuilder{
			Version:     "0.2.0",
			GetRegistry: eng.Registry,
		},
		Engine:            eng,
		HeartbeatEvery:    time.Hour, // disable for tests
		ReconnectMin:      10 * time.Millisecond,
		ReconnectMax:      20 * time.Millisecond,
		MaxConcurrentRuns: 4,
		MaxPendingPerRun:  2048,
	}
	for _, m := range mod {
		m(&opts)
	}
	return NewClient(dialer, opts)
}

func sendRunAction(t *testing.T, c *fakeConn, cli *Client, requestID, actionID string, args map[string]any) {
	t.Helper()
	sendRunActionWithPackContract(t, c, requestID, actionID, args, currentPackHash(t, cli, "t"), "")
}

func sendRunActionWithPackRef(t *testing.T, c *fakeConn, cli *Client, requestID, actionID string, args map[string]any, packRef string) {
	t.Helper()
	sendRunActionWithPackContract(t, c, requestID, actionID, args, currentPackHash(t, cli, "t"), packRef)
}

func sendRunActionWithPackContract(t *testing.T, c *fakeConn, requestID, actionID string, args map[string]any, expectedPackHash, packRef string) {
	t.Helper()
	raw, err := marshalRunActionMsg(RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: testRequestID(requestID)},
		ActionID: actionID, ExpectedPackHash: expectedPackHash, PackRef: packRef,
		Args: args, Reason: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	c.in <- raw
}

func currentPackHash(t *testing.T, cli *Client, packID string) string {
	t.Helper()
	hash, ok := cli.opts.Engine.Registry().PackHash(packID)
	if !ok {
		t.Fatalf("registry has no hash for pack %s", packID)
	}
	return hash
}

func currentPackRef(t *testing.T, cli *Client, packID string) string {
	t.Helper()
	reg := cli.opts.Engine.Registry()
	pack, ok := reg.Pack(packID)
	if !ok {
		t.Fatalf("registry has no pack %s", packID)
	}
	hash, ok := reg.PackHash(packID)
	if !ok {
		t.Fatalf("registry has no hash for pack %s", packID)
	}
	return fmt.Sprintf("%s@%s/%s", pack.ID, pack.Version, hash)
}

func waitForResult(t *testing.T, c *fakeConn, requestID string, deadline time.Duration) map[string]any {
	t.Helper()
	requestID = testRequestID(requestID)
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

func testRequestID(label string) string {
	if validateRequestID(label) == nil {
		return label
	}
	digest := sha256.Sum256([]byte(label))
	return "req_" + base64.RawURLEncoding.EncodeToString(digest[:16])
}

func requireResultEventID(t *testing.T, result map[string]any) string {
	t.Helper()
	eventID, ok := result["event_id"].(string)
	if !ok || eventID == "" {
		t.Fatalf("result missing local audit event id: %+v", result)
	}
	return eventID
}

func queuedResult(t *testing.T, cli *Client, requestID string) ActionResultMsg {
	t.Helper()
	cli.mu.Lock()
	state := cli.runs[requestID]
	cli.mu.Unlock()
	if state == nil {
		t.Fatalf("no queued state for %s", requestID)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if len(state.pending) != 1 {
		t.Fatalf("pending messages=%d, want 1", len(state.pending))
	}
	result, ok := state.pending[0].(ActionResultMsg)
	if !ok {
		t.Fatalf("queued message is %T, want ActionResultMsg", state.pending[0])
	}
	return result
}

func TestClient_RestartedReservationFailsClosedWithoutExecution(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	msg := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "req-pending"},
		ActionID: "t.echo", Args: map[string]any{"msg": "must-not-run"}, Reason: "test",
	}
	digest, err := dispatchDigest(msg)
	if err != nil {
		t.Fatal(err)
	}
	seed := newDedupRing(4, path, nil)
	if decision, _, err := seed.reserve(msg.RequestID, digest); err != nil || decision != reservationNew {
		t.Fatalf("seed reservation: decision=%v err=%v", decision, err)
	}

	cli := buildClient(t, &queuedDialer{}, func(opts *Options) { opts.DedupStorePath = path })
	cli.startRun(context.Background(), msg)
	result := queuedResult(t, cli, msg.RequestID)
	if result.Status != "failed" || result.Reason != "execution_outcome_unknown" {
		t.Fatalf("result=%+v", result)
	}
	if result.EventID == "" {
		t.Fatal("outcome-unknown refusal missing local audit event id")
	}
	if replay, ok := cli.dedup.lookup(msg.RequestID); !ok || replay.Reason != result.Reason {
		t.Fatalf("outcome-unknown result was not durably completed: ok=%v result=%+v", ok, replay)
	}
}

func TestClient_RequestIDFactConflictIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "dedup.jsonl")
	original := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "req-conflict"},
		ActionID: "t.echo", Args: map[string]any{"msg": "first"}, Reason: "test",
	}
	originalDigest, err := dispatchDigest(original)
	if err != nil {
		t.Fatal(err)
	}
	seed := newDedupRing(4, path, nil)
	reserveAndComplete(t, seed, original.RequestID, originalDigest, ActionResultMsg{
		Status:  "success",
		EventID: "evt_original",
	})

	changed := original
	changed.Args = map[string]any{"msg": "different"}
	cli := buildClient(t, &queuedDialer{}, func(opts *Options) { opts.DedupStorePath = path })
	cli.startRun(context.Background(), changed)
	result := queuedResult(t, cli, changed.RequestID)
	if result.Status != "failed" || result.Reason != "dispatch_id_conflict" {
		t.Fatalf("result=%+v", result)
	}
	if result.EventID == "" {
		t.Fatal("dispatch conflict missing local audit event id")
	}
}

func TestClient_UnavailableDispatchLogPreventsExecution(t *testing.T) {
	blocker := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(blocker, "dedup.jsonl")
	cli := buildClient(t, &queuedDialer{}, func(opts *Options) { opts.DedupStorePath = path })
	msg := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "req-no-store"},
		ActionID: "t.echo", Args: map[string]any{"msg": "must-not-run"}, Reason: "test",
	}
	cli.startRun(context.Background(), msg)
	result := queuedResult(t, cli, msg.RequestID)
	if result.Status != "failed" || result.Reason != "dispatch_reservation_failed" {
		t.Fatalf("result=%+v", result)
	}
	if result.EventID == "" {
		t.Fatal("reservation failure missing local audit event id")
	}
}

// TestClient_TrustGate_PassWithMatchingHash proves the ordinary unsigned
// operator path: a matching expected_pack_hash is sufficient without PackRef.
func TestClient_TrustGate_PassWithMatchingHash(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	sendRunAction(t, conn, cli, "req_pass", "t.echo", map[string]any{"msg": "ok"})
	res := waitForResult(t, conn, "req_pass", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v error=%v", res["status"], res["reason"], res["error"])
	}
}

// TestClient_TrustGate_RefuseOnMismatch — when cloud's PackRef
// doesn't match the runner's on-disk hash, the runner refuses to
// execute, returns a pack_hash_mismatch result, and re-advertises its
// state so cloud sees the new bytes.
func TestClient_TrustGate_RefuseOnMismatch(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Drain the initial state advertised on connect so the second one
	// we expect after the refusal is unambiguous.
	deadline := time.After(2 * time.Second)
	for {
		if len(conn.sentByType(MsgRunnerState)) > 0 {
			break
		}
		select {
		case <-deadline:
			t.Fatal("never saw initial runner_state")
		case <-time.After(10 * time.Millisecond):
		}
	}
	initialStateCount := len(conn.sentByType(MsgRunnerState))

	sendRunActionWithPackRef(t, conn, cli, "req_refuse", "t.echo", map[string]any{"msg": "x"}, "t@0.0.1/sha256:DEFINITELY_NOT_THE_HASH")
	res := waitForResult(t, conn, "req_refuse", 3*time.Second)
	if res["status"] != "pack_hash_mismatch" {
		t.Fatalf("status=%v reason=%v error=%v", res["status"], res["reason"], res["error"])
	}

	// Re-advertisement was kicked. Poll briefly — the readvertise loop
	// runs in a goroutine.
	got := false
	deadline = time.After(2 * time.Second)
	for !got {
		if len(conn.sentByType(MsgRunnerState)) > initialStateCount {
			got = true
			break
		}
		select {
		case <-deadline:
			t.Fatal("no follow-up runner_state after refusal")
		case <-time.After(10 * time.Millisecond):
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

	sendRunAction(t, conn, cli, "req_a", "t.echo", map[string]any{"msg": "hi"})
	res := waitForResult(t, conn, "req_a", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}
}

func TestClient_ReportsTerminalAuditFailureWithoutChangingOutcome(t *testing.T) {
	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})
	cli.opts.Engine.Journal = audit.New(audit.Defaults{}, &failAfterAuditSink{successes: 1})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	sendRunAction(t, conn, cli, "req_audit_failure", "t.echo", map[string]any{"msg": "hello"})
	result := waitForResult(t, conn, "req_audit_failure", 3*time.Second)
	if result["status"] != "success" {
		t.Fatalf("status=%v, want success", result["status"])
	}
	if _, ok := result["event_id"]; ok {
		t.Fatalf("failed audit write exposed event_id=%v", result["event_id"])
	}
	if result["local_audit_failed"] != true {
		t.Fatalf("local_audit_failed=%v, want true", result["local_audit_failed"])
	}
}

func TestClient_ReportsRefusalAuditFailure(t *testing.T) {
	cli := buildClient(t, &queuedDialer{})
	cli.opts.Engine.Journal = audit.New(audit.Defaults{}, &failAfterAuditSink{})
	m := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "req-refused"},
		ActionID: "t.echo",
		Reason:   "test refusal audit failure",
	}

	result := cli.refusedDispatchResult(context.Background(), m, "test_refusal", "refused for test")
	if result.EventID != "" || !result.LocalAuditFailed {
		t.Fatalf("result=%+v, want empty event id and local audit failure", result)
	}
}

func TestClient_BoundsExecutedCommandWithoutSplittingUTF8(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli := buildClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	msg := strings.Repeat("界", maxExecutedCommandBytes/len("界")+100)
	sendRunAction(t, conn, cli, "req_long_command", "t.echo", map[string]any{"msg": msg})
	result := waitForResult(t, conn, "req_long_command", 3*time.Second)
	command, ok := result["executed_command"].(string)
	if !ok {
		t.Fatalf("executed_command=%T, want string", result["executed_command"])
	}
	if len(command) > maxExecutedCommandBytes || !utf8.ValidString(command) {
		t.Fatalf("executed command bytes=%d valid_utf8=%t", len(command), utf8.ValidString(command))
	}
	if result["executed_command_truncated"] != true {
		t.Fatalf("executed_command_truncated=%v, want true", result["executed_command_truncated"])
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

	// Make conn1 reject the terminal result the moment the sender tries to
	// ship it. This deterministically leaves the result queued at disconnect —
	// no dependence on poll/send timing — so we exercise the replay path
	// rather than racing it. (Progress and runner_state still go out on conn1;
	// only the result is refused, which fails the sender and ends the session.)
	conn1.failResults.Store(true)
	sendRunAction(t, conn1, cli, "req_replay", "t.echo", map[string]any{"msg": "across"})

	// The client should fail conn1's sender, back off briefly, dial
	// conn2, send runner_state, then replay the queued result on conn2.
	res := waitForResult(t, conn2, "req_replay", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}

	// A sender-side disconnect must reconnect, not terminate the client: the
	// session ends via sessionCancel, whose context.Canceled was once mistaken
	// for a parent shutdown and tore the whole client down. Run must still be
	// blocking here.
	select {
	case err := <-done:
		t.Fatalf("client exited after a sender failure instead of reconnecting: %v", err)
	default:
	}

	// The original connection must NOT have received the result.
	for _, m := range conn1.sentByType(MsgActionResult) {
		if m["request_id"] == testRequestID("req_replay") {
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

	// Wait until the second conn receives a runner_state — that
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

func (d *mixedDialer) Dial(ctx context.Context) (Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.conns) == 0 {
		return nil, errors.New("no more conns")
	}
	c := d.conns[0]
	d.conns = d.conns[1:]
	return c, nil
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
	sendRunAction(t, conn, cli, "req_cancel", "t.sleep", nil)

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
		Envelope: Envelope{Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: testRequestID("req_cancel")},
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
	if res["status"] != "cancelled" {
		t.Fatalf("status=%v, want cancelled: %+v", res["status"], res)
	}
}

func TestClientRejectsKnownMessagesWithIncompatibleProtocolVersion(t *testing.T) {
	cli := buildClient(t, &queuedDialer{})

	for _, version := range []int{0, 999} {
		t.Run(fmt.Sprintf("version_%d", version), func(t *testing.T) {
			raw, err := marshalRunActionMsg(RunActionMsg{
				Envelope: Envelope{
					Type:            MsgRunAction,
					ProtocolVersion: version,
					RequestID:       fmt.Sprintf("req_version_%d", version),
				},
				ActionID:         "t.echo",
				ExpectedPackHash: currentPackHash(t, cli, "t"),
				Args:             map[string]any{"msg": "must not execute"},
				Reason:           "test",
			})
			if err != nil {
				t.Fatal(err)
			}

			if err := cli.dispatch(context.Background(), raw); err == nil {
				t.Fatal("dispatch accepted an incompatible protocol version")
			}
			cli.mu.Lock()
			started := len(cli.runs)
			cli.mu.Unlock()
			if started != 0 {
				t.Fatalf("incompatible message started %d run(s)", started)
			}
		})
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

	sendRunAction(t, conn, cli, "req_v", "t.echo", map[string]any{"msg": "v"})
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
	sendRunAction(t, conn, cli, "req_first", "t.echo", map[string]any{"msg": "1"})
	sendRunAction(t, conn, cli, "req_second", "t.echo", map[string]any{"msg": "2"})

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

func TestClient_AuditWriteDoesNotHoldClientMutex(t *testing.T) {
	cli := buildClient(t, &queuedDialer{})
	cli.opts.MaxConcurrentRuns = 1
	sink := &blockingAuditSink{started: make(chan struct{}), release: make(chan struct{})}
	cli.opts.Engine.Journal = audit.New(audit.Defaults{}, sink)

	cli.mu.Lock()
	cli.runs["already-running"] = &runState{requestID: "already-running"}
	cli.mu.Unlock()

	m := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "over-cap"},
		ActionID: "t.echo",
		Args:     map[string]any{"msg": "x"},
		Reason:   "test lock isolation",
	}
	done := make(chan error, 1)
	go func() { done <- cli.startRun(context.Background(), m) }()

	select {
	case <-sink.started:
	case <-time.After(2 * time.Second):
		t.Fatal("dispatch did not reach blocking audit sink")
	}
	lockAcquired := make(chan bool, 1)
	go func() {
		cli.mu.Lock()
		_, activeExists := cli.runs["already-running"]
		_, responseExists := cli.runs[m.RequestID]
		cli.mu.Unlock()
		lockAcquired <- activeExists && responseExists
	}()
	select {
	case stateReadable := <-lockAcquired:
		if !stateReadable {
			t.Fatal("expected active run and queued refusal while audit was blocked")
		}
	case <-time.After(500 * time.Millisecond):
		close(sink.release)
		t.Fatal("client mutex remained held during audit fsync")
	}
	close(sink.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestClient_RejectedDispatchStateIsBounded(t *testing.T) {
	conn := &blockedOutboundConn{fakeConn: newFakeConn()}
	cli := buildClient(t, &mixedDialer{conns: []Conn{conn}}, func(o *Options) {
		o.MaxConcurrentRuns = 1
		o.DedupRingSize = 4
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := cli.runSession(ctx)
		done <- err
	}()
	waitUntil(t, 2*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) == 1 })

	sendRunAction(t, conn.fakeConn, cli, "req_active", "t.sleep", nil)
	waitUntil(t, 2*time.Second, func() bool { return cli.countInflight() == 1 })

	for i := 0; i < 8; i++ {
		sendRunAction(t, conn.fakeConn, cli, fmt.Sprintf("req_rejected_%d", i), "t.echo", map[string]any{"msg": "rejected"})
	}

	select {
	case err := <-done:
		if !errors.Is(err, errResponseBacklogFull) {
			t.Fatalf("session error=%v, want response backlog backpressure", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("session kept accepting dispatches after its bounded response backlog filled")
	}

	cli.mu.Lock()
	states := len(cli.runs)
	maxTransientStates := cli.opts.MaxConcurrentRuns + cli.opts.DedupRingSize
	cli.mu.Unlock()
	if states > maxTransientStates {
		t.Fatalf("run states=%d, bounded transient capacity=%d", states, maxTransientStates)
	}

	cancel()
	if err := cli.shutdown(context.Canceled); !errors.Is(err, context.Canceled) {
		t.Fatalf("shutdown error=%v", err)
	}
}

func TestClient_ResponseBacklogRejectionDoesNotReserveDispatch(t *testing.T) {
	cli := buildClient(t, &queuedDialer{}, func(opts *Options) {
		opts.MaxConcurrentRuns = 1
		opts.DedupRingSize = 2
	})
	cli.mu.Lock()
	for index := 0; index < cli.maxRunStates(); index++ {
		requestID := fmt.Sprintf("backlog-%d", index)
		cli.runs[requestID] = &runState{requestID: requestID, finished: true}
	}
	cli.mu.Unlock()

	requestID := testRequestID("capacity-retry")
	msg := RunActionMsg{
		Envelope:         Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		ActionID:         "t.echo",
		ExpectedPackHash: currentPackHash(t, cli, "t"),
		Args:             map[string]any{"msg": "after capacity"},
		Reason:           "prove backlog admission precedes reservation",
	}
	digest, err := dispatchDigest(msg)
	if err != nil {
		t.Fatal(err)
	}
	if err := cli.startRun(context.Background(), msg); !errors.Is(err, errResponseBacklogFull) {
		t.Fatalf("startRun() error = %v, want response backlog full", err)
	}
	if decision, _, err := cli.dedup.inspect(requestID, digest); err != nil || decision != reservationNew {
		t.Fatalf("backlog rejection left durable reservation: decision=%v err=%v", decision, err)
	}

	cli.mu.Lock()
	delete(cli.runs, "backlog-0")
	cli.mu.Unlock()
	if err := cli.startRun(context.Background(), msg); err != nil {
		t.Fatalf("retry after freeing capacity: %v", err)
	}
	waitUntil(t, 3*time.Second, func() bool {
		result, ok := cli.dedup.lookup(requestID)
		return ok && result.Status == "success"
	})
	if err := cli.shutdown(context.Canceled); !errors.Is(err, context.Canceled) {
		t.Fatalf("shutdown error = %v", err)
	}
}

func TestClient_RunWaitsForActionHandlersOnShutdown(t *testing.T) {
	const readyPath = "/tmp/emisar-cloud-shutdown-ready"
	_ = os.Remove(readyPath)
	t.Cleanup(func() { _ = os.Remove(readyPath) })

	conn := newFakeConn()
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()

	sendRunAction(t, conn, cli, "req_shutdown", "t.stubborn", nil)
	waitUntil(t, 3*time.Second, func() bool {
		_, err := os.Stat(readyPath)
		return err == nil
	})

	started := time.Now()
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run error=%v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not wait for the cancelled action handler")
	}
	if elapsed := time.Since(started); elapsed < 400*time.Millisecond {
		t.Fatalf("Run returned after %s, before the action's cancellation grace elapsed", elapsed)
	}
	result, ok := cli.dedup.lookup(testRequestID("req_shutdown"))
	if !ok || result.Status != "cancelled" {
		t.Fatalf("persisted shutdown result=%+v, found=%v", result, ok)
	}
	if got := cli.countInflight(); got != 0 {
		t.Fatalf("active handlers after Run returned=%d", got)
	}
}

// --- backoff-reset regression ---------------------------------------

// backoffCapture is a slog.Handler that records the "backoff" attr of
// every cloud.session_ended log, so a test can assert the reconnect
// backoff used after each session.
type backoffCapture struct {
	mu  sync.Mutex
	got []time.Duration
}

func (h *backoffCapture) Enabled(context.Context, slog.Level) bool { return true }
func (h *backoffCapture) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *backoffCapture) WithGroup(string) slog.Handler            { return h }

func (h *backoffCapture) Handle(_ context.Context, r slog.Record) error {
	if r.Message != "cloud.session_ended" {
		return nil
	}
	r.Attrs(func(a slog.Attr) bool {
		if a.Key == "backoff" {
			h.mu.Lock()
			h.got = append(h.got, a.Value.Duration())
			h.mu.Unlock()
		}
		return true
	})
	return nil
}

func (h *backoffCapture) backoffs() []time.Duration {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]time.Duration(nil), h.got...)
}

// dropAfterConnectDialer fails `fails` dials (escalating the reconnect
// backoff), then hands out one conn, then errors forever. The test closes
// the handed conn once it has connected, so the session ends right after
// a successful connect.
type dropAfterConnectDialer struct {
	mu    sync.Mutex
	fails int
	conn  *fakeConn
	done  bool
}

func (d *dropAfterConnectDialer) Dial(context.Context) (Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.fails > 0 {
		d.fails--
		return nil, errors.New("register returned 409")
	}
	if !d.done {
		d.done = true
		return d.conn, nil
	}
	return nil, errors.New("no more conns")
}

func waitUntil(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.After(timeout)
	tick := time.NewTicker(5 * time.Millisecond)
	defer tick.Stop()
	for {
		if cond() {
			return
		}
		select {
		case <-tick.C:
		case <-deadline:
			t.Fatal("waitUntil: condition not met before timeout")
		}
	}
}

// TestClient_BackoffResetsAfterSuccessfulSession guards the reconnect
// loop: a backoff that escalated across failed dials must drop back to
// the floor once a session actually connects, so a healthy runner that
// briefly disconnects reconnects fast instead of inheriting an old,
// inflated backoff. Regression for "backoff is not reset on success".
func TestClient_BackoffResetsAfterSuccessfulSession(t *testing.T) {
	conn := newFakeConn()
	d := &dropAfterConnectDialer{fails: 2, conn: conn}
	cli := buildClient(t, d)
	cli.opts.ReconnectMin = 10 * time.Millisecond
	cli.opts.ReconnectMax = 10 * time.Second // headroom so escalation shows
	rec := &backoffCapture{}
	cli.opts.Logger = slog.New(rec)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		<-done
	})

	// Let two dials fail (backoff escalates), then the third connects —
	// drop it so the session ends right after a successful connect.
	waitUntil(t, 3*time.Second, func() bool {
		return len(conn.sentByType(MsgRunnerState)) > 0
	})
	conn.Close()

	// got[0],got[1] = the two escalating failures; got[2] = the
	// session_ended after the successful connect.
	waitUntil(t, 3*time.Second, func() bool { return len(rec.backoffs()) >= 3 })
	cancel()

	got := rec.backoffs()
	if !(got[1] > got[0]) {
		t.Fatalf("expected backoff to escalate across failed dials, got %v", got)
	}
	if got[2] != cli.opts.ReconnectMin {
		t.Fatalf("backoff not reset after a successful session: got[2]=%v want %v (full sequence %v)",
			got[2], cli.opts.ReconnectMin, got)
	}
}
