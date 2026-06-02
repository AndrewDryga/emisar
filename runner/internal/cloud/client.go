package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// Conn is the transport-level interface the Client uses. A real
// implementation wraps a websocket; tests can use an in-memory pair.
//
// Send/Recv block; ctx cancellation must terminate them. Close releases
// resources; concurrent calls to Close are safe.
type Conn interface {
	Send(ctx context.Context, msg any) error
	Recv(ctx context.Context) ([]byte, error)
	Close() error
}

// Dialer establishes a Conn. Returns the assigned runner_id alongside the
// connection so callers can update their identity from the auth response.
type Dialer interface {
	Dial(ctx context.Context) (conn Conn, agentID string, err error)
}

// Options configure the Client behaviour.
type Options struct {
	StateBuilder   *StateBuilder
	Engine         *engine.Engine
	Cursor         *audit.Cursor // optional; ack_result marks event IDs here
	Logger         *slog.Logger
	HeartbeatEvery time.Duration
	ReconnectMin   time.Duration
	ReconnectMax   time.Duration

	// MaxConcurrentRuns caps the number of in-flight actions. Additional
	// run_action messages get an immediate error reply. Defaults to 8.
	MaxConcurrentRuns int

	// MaxPendingPerRun bounds the per-request outbox. If full, the oldest
	// progress chunk is dropped (the final result is preserved). The drop
	// count is reported on the eventual ActionResultMsg.
	MaxPendingPerRun int

	// DedupRingSize bounds the count of completed results we keep cached
	// for idempotent replay. Defaults to 1024.
	DedupRingSize int
}

// Client runs the outbound websocket loop. It owns the in-flight runs
// across reconnects: action goroutines outlive the connection and queue
// their messages in a per-request outbox; a connection-scoped sender
// drains the outbox while the connection is up.
type Client struct {
	dialer Dialer
	opts   Options

	mu    sync.Mutex
	runs  map[string]*runState // request_id -> in-flight state
	dedup *dedupRing           // bounded cache of completed results

	// readvertise is closed-and-replaced when state should be re-sent.
	// Buffered channel of struct{} — at most one pending wake-up.
	readvertiseMu sync.Mutex
	readvertise   chan struct{}
}

// runState is the per-request outbox. handleRun appends to it; the
// sender goroutine drains it; both live independently of the current
// websocket connection.
type runState struct {
	requestID string
	cancel    context.CancelFunc

	mu       sync.Mutex
	pending  []any // queued outbound messages
	dropped  int   // progress chunks discarded because pending was full
	finished bool  // ActionResultMsg has been enqueued
}

// outboundMsg is the type sent over the wire. Using any keeps the queue
// uniform across heartbeats, progress, results, and errors.
type outboundMsg = any

// NewClient constructs a Client. Defaults: heartbeat 30s, reconnect 1-60s,
// 8 concurrent runs, 2048 messages buffered per run.
func NewClient(d Dialer, opts Options) *Client {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.HeartbeatEvery <= 0 {
		opts.HeartbeatEvery = 30 * time.Second
	}
	if opts.ReconnectMin <= 0 {
		opts.ReconnectMin = time.Second
	}
	if opts.ReconnectMax <= 0 {
		opts.ReconnectMax = 60 * time.Second
	}
	if opts.MaxConcurrentRuns <= 0 {
		opts.MaxConcurrentRuns = 8
	}
	if opts.MaxPendingPerRun <= 0 {
		opts.MaxPendingPerRun = 2048
	}
	if opts.DedupRingSize <= 0 {
		opts.DedupRingSize = 1024
	}
	return &Client{
		dialer:      d,
		opts:        opts,
		runs:        map[string]*runState{},
		dedup:       newDedupRing(opts.DedupRingSize),
		readvertise: make(chan struct{}, 1),
	}
}

// Readvertise asks the client to re-send agent_state on the current
// connection (e.g., after SIGHUP-driven pack reload). Calls are
// coalesced — multiple Readvertise() invocations between sends produce
// exactly one extra send.
func (c *Client) Readvertise() {
	select {
	case c.readvertise <- struct{}{}:
	default:
	}
}

// Run blocks until ctx is done, reconnecting indefinitely on failure.
// In-flight actions survive reconnects; their queued messages replay
// once the new session is established.
func (c *Client) Run(ctx context.Context) error {
	backoff := c.opts.ReconnectMin
	for {
		if err := ctx.Err(); err != nil {
			c.cancelAllRuns()
			return err
		}
		err := c.runSession(ctx)
		if errors.Is(err, context.Canceled) || ctx.Err() != nil {
			c.cancelAllRuns()
			return ctx.Err()
		}
		c.opts.Logger.Warn("cloud.session_ended", "error", err, "backoff", backoff)
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			c.cancelAllRuns()
			return ctx.Err()
		}
		backoff *= 2
		if backoff > c.opts.ReconnectMax {
			backoff = c.opts.ReconnectMax
		}
	}
}

// runSession dials, advertises state, runs the sender + heartbeat +
// receiver until any of them errors, then returns.
func (c *Client) runSession(parent context.Context) error {
	conn, _, err := c.dialer.Dial(parent)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	// sessionCtx is cancelled when any of: parent dies, recv errors,
	// heartbeat errors, sender errors. It's the lifetime of the websocket.
	sessionCtx, sessionCancel := context.WithCancel(parent)
	defer sessionCancel()

	state := c.opts.StateBuilder.Build()
	if err := conn.Send(sessionCtx, state); err != nil {
		return fmt.Errorf("send state: %w", err)
	}
	c.opts.Logger.Info("cloud.connected",
		"actions", len(state.Actions),
		"packs", len(state.Packs),
		"inflight_runs", c.countInflight(),
	)

	// Drain any queued messages from runs that survived a previous
	// disconnect. The sender loop does this on its tick, but kick a
	// drain right away so cloud sees a fast catch-up.
	go c.senderLoop(sessionCtx, sessionCancel, conn)
	go c.heartbeatLoop(sessionCtx, sessionCancel, conn)
	go c.readvertiseLoop(sessionCtx, sessionCancel, conn)

	// Recv loop runs inline. Any error here terminates the session.
	for {
		raw, err := conn.Recv(sessionCtx)
		if err != nil {
			sessionCancel()
			return fmt.Errorf("recv: %w", err)
		}
		c.dispatch(parent, raw)
	}
}

// dispatch routes one inbound message. parent (not sessionCtx) is the
// outer context so that started runs outlive the connection.
func (c *Client) dispatch(parent context.Context, raw []byte) {
	mt, err := PeekType(raw)
	if err != nil {
		c.opts.Logger.Warn("cloud.bad_envelope", "error", err)
		return
	}
	switch mt {
	case MsgRunAction:
		var m RunActionMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			c.opts.Logger.Warn("cloud.bad_run_action", "error", err)
			return
		}
		c.startRun(parent, m)
	case MsgCancel:
		var m CancelMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			return
		}
		c.cancelRun(m.RequestID)
	case MsgAckResult:
		var m AckResultMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			return
		}
		c.ackRun(m.RequestID)
	default:
		c.opts.Logger.Debug("cloud.unknown_message", "type", mt)
	}
}

// startRun spawns a handler for one run_action, subject to the
// concurrency cap. The handler outlives the current connection.
//
// Idempotency: if request_id matches a cached completed result, the
// cached result is enqueued for re-send without re-executing.
func (c *Client) startRun(parent context.Context, m RunActionMsg) {
	if cached, ok := c.dedup.lookup(m.RequestID); ok {
		c.opts.Logger.Info("cloud.dedup_replay", "request_id", m.RequestID)
		c.enqueueTransient(m.RequestID, cached)
		return
	}

	c.mu.Lock()
	if _, exists := c.runs[m.RequestID]; exists {
		c.mu.Unlock()
		// Still in flight — sender will eventually deliver the result.
		c.opts.Logger.Warn("cloud.duplicate_in_flight", "request_id", m.RequestID)
		return
	}
	if len(c.runs) >= c.opts.MaxConcurrentRuns {
		c.mu.Unlock()
		c.opts.Logger.Warn("cloud.concurrency_cap_reached",
			"request_id", m.RequestID,
			"cap", c.opts.MaxConcurrentRuns,
		)
		c.enqueueTransient(m.RequestID, ErrorMsg{
			Envelope: Envelope{Type: MsgError, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Code:     "concurrency_cap_reached",
			Message:  fmt.Sprintf("runner at concurrency cap (%d in flight)", c.opts.MaxConcurrentRuns),
		})
		return
	}

	runCtx, cancel := context.WithCancel(parent)
	s := &runState{requestID: m.RequestID, cancel: cancel}
	c.runs[m.RequestID] = s
	c.mu.Unlock()

	go c.handleRun(runCtx, s, m)
}

// enqueueTransient creates a finished runState containing exactly one
// message (a cached result or a synthetic error). The sender picks it
// up on its next tick.
func (c *Client) enqueueTransient(requestID string, msg any) {
	s := &runState{requestID: requestID, finished: true, pending: []any{msg}}
	c.mu.Lock()
	// If a runState already exists (e.g., second dedup hit while the
	// first replay is still queued), append rather than overwrite.
	if existing, ok := c.runs[requestID]; ok {
		c.mu.Unlock()
		existing.mu.Lock()
		existing.pending = append(existing.pending, msg)
		existing.mu.Unlock()
		return
	}
	c.runs[requestID] = s
	c.mu.Unlock()
}

// handleRun executes the action and enqueues progress + result messages
// onto the runState. It does NOT call conn.Send directly; the sender
// loop is responsible for delivery.
//
// Trust gate: if the cloud supplied ExpectedPackHash, re-hash the
// action's pack from disk and refuse to execute on mismatch. Also
// signal a re-advertisement so cloud sees the new hash and flips the
// pack to pending in the trust UI.
func (c *Client) handleRun(ctx context.Context, s *runState, m RunActionMsg) {
	c.opts.Logger.Info("cloud.run_started",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
	)

	if !c.passesTrustGate(s, m) {
		s.mu.Lock()
		s.finished = true
		s.mu.Unlock()
		return
	}

	seq := 0
	progress := func(stream executor.Stream, line []byte) {
		seq++
		c.enqueue(s, ActionProgressMsg{
			Envelope: Envelope{
				Type:            MsgActionProgress,
				ProtocolVersion: ProtocolVersion,
				RequestID:       m.RequestID,
			},
			Seq:    seq,
			Stream: string(stream),
			Chunk:  string(line),
		}, dropOldestProgress)
	}

	req := engine.Request{
		ControlPlaneRequestID: m.RequestID,
		ActionID:              m.ActionID,
		Args:                  m.Args,
		Reason:                m.Reason,
		OnProgress:            progress,
	}
	if m.Opts != nil {
		req.Opts = engine.Opts{
			Timeout:        m.Opts.Timeout.Std(),
			MaxStdoutBytes: m.Opts.MaxStdoutBytes,
			MaxStderrBytes: m.Opts.MaxStderrBytes,
		}
	}
	res, err := c.opts.Engine.Run(ctx, req)

	s.mu.Lock()
	dropped := s.dropped
	s.mu.Unlock()

	if err != nil {
		c.opts.Logger.Warn("cloud.run_engine_error",
			"request_id", m.RequestID,
			"action_id", m.ActionID,
			"error", err.Error(),
		)
		c.enqueue(s, ErrorMsg{
			Envelope: Envelope{Type: MsgError, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Code:     "engine_error",
			Message:  err.Error(),
		}, never)
	} else {
		// One log line per completed run. Non-success statuses get Warn
		// so they stand out in operator logs; success is Info.
		level := slog.LevelInfo
		if res.Status != engine.StatusSuccess {
			level = slog.LevelWarn
		}
		c.opts.Logger.Log(ctx, level, "cloud.run_finished",
			"request_id", m.RequestID,
			"action_id", m.ActionID,
			"status", string(res.Status),
			"exit_code", res.ExitCode,
			"duration_ms", res.DurationMS,
			"reason", res.Reason,
		)

		result := ActionResultMsg{
			Envelope:     Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Status:       string(res.Status),
			ExitCode:     res.ExitCode,
			DurationMS:   res.DurationMS,
			TimedOut:     res.TimedOut,
			StdoutSHA256: res.StdoutSHA256,
			StderrSHA256: res.StderrSHA256,
			StdoutBytes:  res.StdoutBytes,
			StderrBytes:  res.StderrBytes,
			Redactions:   toProtocolRedactions(res.Redactions),
			Reason:       buildReasonWithDrops(res.Reason, dropped),
			EventID:      res.EventID,
		}
		c.enqueue(s, result, never)
		c.dedup.remember(m.RequestID, result)
	}
	s.mu.Lock()
	s.finished = true
	s.mu.Unlock()
}

// passesTrustGate re-hashes the action's pack from disk and compares it
// to the cloud-supplied ExpectedPackHash. Returns true (proceed) when
// the cloud didn't supply a hash, the action is unknown, or the
// computed hash matches. Returns false (refuse) on mismatch — in that
// case it enqueues a `pack_hash_mismatch` ActionResultMsg and asks the
// state loop to re-broadcast so the cloud's catalog sees the new bytes
// and flips the (pack, version) to pending_trust.
func (c *Client) passesTrustGate(s *runState, m RunActionMsg) bool {
	expected := m.ExpectedPackHash
	if expected == "" {
		// Cloud has no trusted hash on file yet (very early observation
		// or runner pre-dates Phase 2). Skip the gate.
		return true
	}

	reg := c.opts.Engine.Registry()
	action, ok := reg.Action(m.ActionID)
	if !ok || action.PackID == "" {
		// Action vanished or has no pack. Let the engine produce its
		// own unknown_action result; nothing to gate.
		return true
	}

	got, err := reg.RecomputePackHash(action.PackID)
	if err != nil {
		c.opts.Logger.Warn("cloud.pack_rehash_failed",
			"request_id", m.RequestID,
			"action_id", m.ActionID,
			"pack_id", action.PackID,
			"error", err.Error(),
		)
		// Fail-closed when we can't even read the pack — the most likely
		// cause is the operator deleted files between load and dispatch,
		// and we shouldn't run a half-existing pack on the assumption it
		// matched.
		c.emitPackMismatch(s, m, action.PackID, expected, "rehash_failed:"+err.Error())
		return false
	}

	if got == expected {
		return true
	}

	c.opts.Logger.Warn("cloud.pack_hash_mismatch",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
		"pack_id", action.PackID,
		"expected", expected,
		"got", got,
	)
	c.emitPackMismatch(s, m, action.PackID, expected, got)
	// Kick a state re-advertisement so cloud sees the new hash and
	// flips the pack to pending_trust in the UI.
	c.Readvertise()
	return false
}

// emitPackMismatch enqueues the terminal ActionResultMsg the cloud
// receives when the runner refuses a dispatch on trust mismatch. Cloud
// surfaces this as a run with status="pack_hash_mismatch" — the UI
// renders it as a tamper alert, and the pending_trust card shows up on
// /app/packs as soon as the runner's re-broadcast lands.
func (c *Client) emitPackMismatch(s *runState, m RunActionMsg, packID, expected, got string) {
	result := ActionResultMsg{
		Envelope:   Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
		Status:     "pack_hash_mismatch",
		ExitCode:   -1,
		DurationMS: 0,
		Error: fmt.Sprintf(
			"pack %q hash on disk (%s) does not match cloud-pinned trusted hash (%s); refused — operator must review the drift in /app/packs",
			packID, got, expected,
		),
		Reason: "pack_hash_mismatch",
	}
	c.enqueue(s, result, never)
	c.dedup.remember(m.RequestID, result)
}

// dropPolicy controls what happens when the per-run buffer is full.
type dropPolicy int

const (
	dropOldestProgress dropPolicy = iota
	never                         // result/error messages are never dropped
)

// enqueue appends msg to a run's outbox. If full and policy is
// dropOldestProgress, the oldest progress chunk in the buffer is
// removed and dropped count is incremented. Final results/errors are
// never dropped — they push out older progress chunks if needed.
func (c *Client) enqueue(s *runState, msg any, policy dropPolicy) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.pending) >= c.opts.MaxPendingPerRun && policy == dropOldestProgress {
		s.pending = s.pending[1:]
		s.dropped++
	}
	s.pending = append(s.pending, msg)
}

// senderLoop runs for the duration of one websocket session. It drains
// in-flight runs' outboxes onto the connection. On send error, it
// requeues unsent messages and exits — runSession will reconnect and
// spawn a fresh senderLoop that resumes from the same state.
func (c *Client) senderLoop(ctx context.Context, sessionCancel context.CancelFunc, conn Conn) {
	defer sessionCancel()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		if err := c.drainOnce(ctx, conn); err != nil {
			c.opts.Logger.Warn("cloud.sender_failed", "error", err)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (c *Client) drainOnce(ctx context.Context, conn Conn) error {
	c.mu.Lock()
	snapshot := make([]*runState, 0, len(c.runs))
	for _, s := range c.runs {
		snapshot = append(snapshot, s)
	}
	c.mu.Unlock()

	for _, s := range snapshot {
		s.mu.Lock()
		msgs := s.pending
		s.pending = nil
		s.mu.Unlock()
		for i, msg := range msgs {
			if err := conn.Send(ctx, msg); err != nil {
				// Requeue everything we haven't yet sent so the next
				// session picks up where we left off.
				s.mu.Lock()
				s.pending = append(msgs[i:], s.pending...)
				s.mu.Unlock()
				return err
			}
		}
		// If this run is finished and we just sent its tail, remove it.
		s.mu.Lock()
		if s.finished && len(s.pending) == 0 {
			s.mu.Unlock()
			c.removeRun(s.requestID)
			continue
		}
		s.mu.Unlock()
	}
	return nil
}

// readvertiseLoop watches for Readvertise() pings and sends a fresh
// agent_state on the current connection. SIGHUP-driven pack reload
// uses this to inform cloud of the new pack inventory.
func (c *Client) readvertiseLoop(ctx context.Context, sessionCancel context.CancelFunc, conn Conn) {
	defer sessionCancel()
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.readvertise:
			state := c.opts.StateBuilder.Build()
			if err := conn.Send(ctx, state); err != nil {
				c.opts.Logger.Warn("cloud.readvertise_failed", "error", err)
				return
			}
			c.opts.Logger.Info("cloud.readvertised",
				"actions", len(state.Actions),
				"packs", len(state.Packs),
			)
		}
	}
}

// heartbeatLoop sends a heartbeat every HeartbeatEvery. Any send error
// cancels the session so reconnect logic engages immediately, rather
// than waiting for TCP keepalive (default ~2h on Linux).
func (c *Client) heartbeatLoop(ctx context.Context, sessionCancel context.CancelFunc, conn Conn) {
	defer sessionCancel()
	t := time.NewTicker(c.opts.HeartbeatEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			load := c.countInflight()
			err := conn.Send(ctx, HeartbeatMsg{
				Envelope:   Envelope{Type: MsgHeartbeat, ProtocolVersion: ProtocolVersion},
				Time:       time.Now().UTC().Format(time.RFC3339),
				ActionLoad: load,
			})
			if err != nil {
				c.opts.Logger.Warn("cloud.heartbeat_failed", "error", err)
				return
			}
		}
	}
}

// cancelRun cancels the per-request context.
func (c *Client) cancelRun(requestID string) {
	c.mu.Lock()
	s, ok := c.runs[requestID]
	c.mu.Unlock()
	if !ok {
		return
	}
	if s.cancel != nil {
		s.cancel()
	}
}

// ackRun is called when cloud confirms receipt of an action_result.
// Two effects:
//
//  1. If the runState is still finished+drained, remove it from
//     the in-flight map.
//  2. Record the underlying JSONL event_id in the cursor file so a
//     future cleanup pass can prune up to that point.
//
// The cached result stays in the dedup ring regardless, in case cloud
// retries the request_id (which would happen if the ack itself was
// lost in flight). The dedup ring is bounded so old entries roll out.
func (c *Client) ackRun(requestID string) {
	c.mu.Lock()
	s, ok := c.runs[requestID]
	c.mu.Unlock()
	if ok {
		s.mu.Lock()
		finished := s.finished
		empty := len(s.pending) == 0
		s.mu.Unlock()
		if !finished || !empty {
			c.opts.Logger.Warn("cloud.premature_ack",
				"request_id", requestID,
				"finished", finished,
				"pending", !empty,
			)
			return
		}
		c.removeRun(requestID)
	}
	// Record on the cursor regardless of whether the in-flight state was
	// still around — cloud might be acking something we already evicted
	// from runs (legitimate during reconnect dances).
	if c.opts.Cursor != nil {
		if cached, ok := c.dedup.lookup(requestID); ok && cached.EventID != "" {
			if err := c.opts.Cursor.MarkAcked(cached.EventID); err != nil {
				c.opts.Logger.Warn("cloud.cursor_write_failed",
					"event_id", cached.EventID,
					"error", err,
				)
			}
		}
	}
}

func (c *Client) removeRun(requestID string) {
	c.mu.Lock()
	delete(c.runs, requestID)
	c.mu.Unlock()
}

func (c *Client) countInflight() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.runs)
}

// cancelAllRuns is called on runner shutdown to cancel every in-flight
// run. The engine then cancels each executor, which SIGTERMs the child
// process group, gives it the grace window, and SIGKILLs.
func (c *Client) cancelAllRuns() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, s := range c.runs {
		if s.cancel != nil {
			s.cancel()
		}
	}
}

// buildReasonWithDrops appends a "(N progress chunks dropped)" suffix to
// the reason when the per-run outbox lost messages. The exact count
// also lives on the JSONL event via the engine's redaction summary
// (well, future change — for now the suffix is the only signal).
func buildReasonWithDrops(reason string, dropped int) string {
	if dropped <= 0 {
		return reason
	}
	suffix := fmt.Sprintf("(%d progress chunks dropped during disconnect)", dropped)
	if reason == "" {
		return suffix
	}
	return reason + " " + suffix
}

func toProtocolRedactions(hits []redact.Hit) []RedactionSummary {
	if len(hits) == 0 {
		return nil
	}
	out := make([]RedactionSummary, 0, len(hits))
	for _, h := range hits {
		out = append(out, RedactionSummary{Name: h.Name, Type: h.Type, Count: h.Count})
	}
	return out
}

// LoggedDialer is a placeholder Dialer that logs the dial intent and
// returns ErrNotConfigured. It exists so `emisar connect` can be invoked
// end-to-end while the real cloud is being built. Replace with a
// websocket-backed Dialer once the control plane URL is real.
type LoggedDialer struct {
	URL    string
	Logger *slog.Logger
}

// ErrNotConfigured is returned by LoggedDialer.Dial.
var ErrNotConfigured = errors.New("cloud transport not configured (build a real Dialer)")

// Dial logs and returns ErrNotConfigured.
func (d LoggedDialer) Dial(ctx context.Context) (Conn, string, error) {
	log := d.Logger
	if log == nil {
		log = slog.Default()
	}
	log.Info("cloud.dial_skipped",
		"url", d.URL,
		"reason", "no websocket transport wired yet",
	)
	return nil, "", ErrNotConfigured
}
