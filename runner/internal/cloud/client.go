package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
	"github.com/andrewdryga/emisar/runner/internal/signing"
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

	// DedupRingSize bounds the persistent dispatch log. Active and completed
	// but unacknowledged entries are never evicted. Defaults to 1024.
	DedupRingSize int

	// DedupStorePath persists the dedup ring so it survives a runner
	// restart (empty = in-memory only). Without it, a re-dispatch landing
	// after a restart finds an empty ring and re-executes a completed
	// action — double-running a mutating action.
	DedupStorePath string

	// Verifier is the INITIAL signature verifier gating dispatches; SIGHUP
	// swaps it live via Client.SetVerifier. Nil (or a non-enforcing verifier)
	// means client-signature enforcement is disabled.
	Verifier *signing.Verifier
}

// Client runs the outbound websocket loop. It owns the in-flight runs
// across reconnects: action goroutines outlive the connection and queue
// their messages in a per-request outbox; a connection-scoped sender
// drains the outbox while the connection is up.
type Client struct {
	dialer Dialer
	opts   Options

	// verifier gates dispatches; held behind an atomic pointer so a SIGHUP
	// (SetVerifier) can rotate or revoke a trusted key live, while in-flight
	// runs keep the verifier they read at the gate. Mirrors the engine's
	// atomic registry. A nil load means client-signature enforcement is disabled.
	verifier atomic.Pointer[signing.Verifier]

	mu    sync.Mutex
	runs  map[string]*runState // request_id -> in-flight state
	dedup *dedupRing           // bounded cache of completed results

	// A cancel can race just ahead of its run_action on the websocket. Remember
	// unknown request ids briefly so that wire reordering cannot turn an operator
	// cancellation into execution. The ring is bounded with the dedup capacity.
	preCanceled      map[string]struct{}
	preCanceledOrder []string

	// readvertise is a coalescing wake-up: Readvertise() does a
	// non-blocking send and readvertiseLoop drains it. Buffered size 1,
	// so many calls between drains collapse into a single extra send.
	readvertise chan struct{}

	// wake is the same coalescing-signal pattern for the sender: enqueue
	// pokes it so senderLoop drains immediately instead of waking on a
	// fixed poll. Buffered size 1 — many enqueues between drains collapse
	// into one wake, and senderLoop drains every run's outbox per wake.
	wake chan struct{}
}

// runState is the per-request outbox. handleRun appends to it; the
// sender goroutine drains it; both live independently of the current
// websocket connection.
type runState struct {
	requestID      string
	dispatchDigest string
	cancel         context.CancelFunc

	mu       sync.Mutex
	pending  []any // queued outbound messages
	dropped  int   // progress chunks discarded because pending was full
	finished bool  // ActionResultMsg has been enqueued
}

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
	c := &Client{
		dialer:      d,
		opts:        opts,
		runs:        map[string]*runState{},
		dedup:       newDedupRing(opts.DedupRingSize, opts.DedupStorePath, opts.Logger),
		preCanceled: map[string]struct{}{},
		readvertise: make(chan struct{}, 1),
		wake:        make(chan struct{}, 1),
	}
	c.verifier.Store(opts.Verifier)
	return c
}

// Verifier returns the signature verifier currently gating dispatches (nil =
// signature enforcement disabled). The StateBuilder reads it through this getter so the advertised
// key set tracks live swaps, the same way it reads the engine's registry.
func (c *Client) Verifier() *signing.Verifier { return c.verifier.Load() }

// SetVerifier swaps the gate's verifier — call it on SIGHUP after rebuilding
// from the reloaded config so a rotated or revoked key takes effect without a
// restart. Atomic: in-flight runs keep the verifier they read at the gate.
func (c *Client) SetVerifier(v *signing.Verifier) { c.verifier.Store(v) }

// signalSend pokes the sender loop after a message is enqueued. Non-blocking
// and coalesced: if a wake is already pending, this is a no-op (the sender
// drains all outboxes per wake, so one signal covers any number of enqueues).
func (c *Client) signalSend() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// Readvertise asks the client to re-send runner_state on the current
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
		connected, err := c.runSession(ctx)
		// Only a cancelled PARENT context means "shut the client down". A
		// session that ended on its own — sender or heartbeat hit a write
		// error and tripped sessionCancel, which surfaces as the receiver's
		// Recv returning context.Canceled — must reconnect, not terminate.
		// Keying off errors.Is(err, context.Canceled) conflated the two and
		// made a writer-side disconnect kill the whole runner (and all its
		// in-flight runs) instead of reconnecting; which path won was a race
		// between the reader and writer noticing the drop first.
		if ctx.Err() != nil {
			c.cancelAllRuns()
			return ctx.Err()
		}
		// A session that actually connected clears the backoff: the drop
		// that ended it is a fresh failure, not a continuation of the
		// reconnect storm. Without this the backoff ratchets up across
		// unrelated disconnects and never recovers on success.
		if connected {
			backoff = c.opts.ReconnectMin
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
// receiver until any of them errors, then returns. The bool reports
// whether the dial+register handshake succeeded (i.e. we actually
// connected), so the caller can reset its reconnect backoff on success.
func (c *Client) runSession(parent context.Context) (bool, error) {
	conn, _, err := c.dialer.Dial(parent)
	if err != nil {
		return false, fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	// sessionCtx is cancelled when any of: parent dies, recv errors,
	// heartbeat errors, sender errors. It's the lifetime of the websocket.
	sessionCtx, sessionCancel := context.WithCancel(parent)
	defer sessionCancel()

	state := c.opts.StateBuilder.Build()
	if err := conn.Send(sessionCtx, state); err != nil {
		return true, fmt.Errorf("send state: %w", err)
	}
	requeuedResults := c.requeueUnacknowledgedResults()
	c.opts.Logger.Info("cloud.connected",
		"actions", len(state.Actions),
		"packs", len(state.Packs),
		"inflight_runs", c.countInflight(),
		"requeued_results", requeuedResults,
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
			return true, fmt.Errorf("recv: %w", err)
		}
		c.dispatch(parent, raw)
	}
}

// requeueUnacknowledgedResults reconciles the durable result log with the
// connection-scoped outbox. A successful WebSocket Send is not an application
// acknowledgement: if the portal committed the result but its ack was lost,
// the next session must send that result again so the record can become
// evictable. At most one copy is queued per request for this session.
func (c *Client) requeueUnacknowledgedResults() int {
	results := c.dedup.unacknowledgedResults()
	if len(results) == 0 {
		return 0
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	requeued := 0
	for _, result := range results {
		requestID := result.RequestID
		if requestID == "" {
			c.opts.Logger.Error("cloud.dedup_result_missing_request_id")
			continue
		}
		if state, ok := c.runs[requestID]; ok {
			state.mu.Lock()
			if len(state.pending) == 0 {
				state.pending = append(state.pending, result)
				state.finished = true
				requeued++
			}
			state.mu.Unlock()
			continue
		}
		c.runs[requestID] = &runState{
			requestID: requestID,
			finished:  true,
			pending:   []any{result},
		}
		requeued++
	}
	return requeued
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
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		if err := decoder.Decode(&m); err != nil {
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
	digest, err := dispatchDigest(m)
	if err != nil {
		c.enqueueTransient(m.RequestID, failedDispatchResult(m.RequestID, "dispatch_invalid", err.Error()))
		return
	}
	c.mu.Lock()
	if existing, exists := c.runs[m.RequestID]; exists {
		c.mu.Unlock()
		if existing.dispatchDigest != digest {
			// The first intent may already be executing and cannot safely be
			// replaced or failed under the same correlation id. Keep it authoritative.
			c.opts.Logger.Error("cloud.duplicate_in_flight_conflict", "request_id", m.RequestID)
		} else {
			c.opts.Logger.Warn("cloud.duplicate_in_flight", "request_id", m.RequestID)
		}
		return
	}
	decision, cached, err := c.dedup.inspect(m.RequestID, digest)
	if err != nil {
		c.mu.Unlock()
		c.dispatchReservationFailed(m.RequestID, err)
		return
	}
	if c.handleReservationDecision(m.RequestID, digest, decision, cached) {
		c.mu.Unlock()
		c.signalSend()
		return
	}
	preCanceled := c.consumePreCancelLocked(m.RequestID)
	if !preCanceled && len(c.runs) >= c.opts.MaxConcurrentRuns {
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
	decision, cached, err = c.dedup.reserve(m.RequestID, digest)
	if err != nil {
		c.mu.Unlock()
		c.dispatchReservationFailed(m.RequestID, err)
		return
	}
	if c.handleReservationDecision(m.RequestID, digest, decision, cached) {
		c.mu.Unlock()
		c.signalSend()
		return
	}
	if preCanceled {
		result := ActionResultMsg{
			Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Status:   "cancelled",
			ExitCode: -1,
			Reason:   "cancelled_before_start",
		}
		if err := c.dedup.complete(m.RequestID, digest, result); err != nil {
			c.mu.Unlock()
			c.dispatchReservationFailed(m.RequestID, err)
			return
		}
		c.enqueueTransientLocked(m.RequestID, result)
		c.mu.Unlock()
		c.signalSend()
		return
	}

	runCtx, cancel := context.WithCancel(parent)
	s := &runState{requestID: m.RequestID, cancel: cancel, dispatchDigest: digest}
	c.runs[m.RequestID] = s
	c.mu.Unlock()

	go c.handleRun(runCtx, s, m)
}

func (c *Client) handleReservationDecision(
	requestID, digest string,
	decision reservationDecision,
	cached ActionResultMsg,
) bool {
	switch decision {
	case reservationReplay:
		c.opts.Logger.Info("cloud.dedup_replay", "request_id", requestID)
		c.enqueueTransientLocked(requestID, cached)
		return true
	case reservationPending:
		result := failedDispatchResult(
			requestID,
			"execution_outcome_unknown",
			"runner restarted after reserving this dispatch; it was not re-executed because prior side effects are unknown",
		)
		if err := c.dedup.complete(requestID, digest, result); err != nil {
			c.opts.Logger.Error("cloud.dedup_persist_failed", "request_id", requestID, "error", err)
		}
		c.enqueueTransientLocked(requestID, result)
		return true
	case reservationConflict:
		c.opts.Logger.Warn("cloud.dispatch_id_conflict", "request_id", requestID)
		c.enqueueTransientLocked(requestID, failedDispatchResult(
			requestID,
			"dispatch_id_conflict",
			"request_id was already bound to different execution facts; action was not executed",
		))
		return true
	default:
		return false
	}
}

func (c *Client) dispatchReservationFailed(requestID string, err error) {
	c.opts.Logger.Error("cloud.dispatch_reservation_failed", "request_id", requestID, "error", err)
	c.enqueueTransient(requestID, failedDispatchResult(
		requestID,
		"dispatch_reservation_failed",
		"runner could not durably reserve this dispatch; action was not executed",
	))
}

func failedDispatchResult(requestID, reason, detail string) ActionResultMsg {
	return ActionResultMsg{
		Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		Status:   "failed", ExitCode: -1, Reason: reason, Error: detail,
	}
}

// enqueueTransient creates a finished runState containing exactly one
// message (a cached result or a synthetic error). The sender picks it
// up on its next tick.
func (c *Client) enqueueTransient(requestID string, msg any) {
	c.mu.Lock()
	c.enqueueTransientLocked(requestID, msg)
	c.mu.Unlock()
	c.signalSend()
}

// enqueueTransientLocked appends one terminal response while c.mu is held.
// Reservation classification runs under that same lock, so it uses this form
// to avoid releasing the execution-cap decision before the response is queued.
func (c *Client) enqueueTransientLocked(requestID string, msg any) {
	// If a runState already exists (e.g., second dedup hit while the
	// first replay is still queued), append rather than overwrite.
	if existing, ok := c.runs[requestID]; ok {
		existing.mu.Lock()
		existing.pending = append(existing.pending, msg)
		existing.mu.Unlock()
		return
	}
	c.runs[requestID] = &runState{requestID: requestID, finished: true, pending: []any{msg}}
}

// handleRun executes the action and enqueues progress + result messages
// onto the runState. It does NOT call conn.Send directly; the sender
// loop is responsible for delivery.
//
// Trust gate: if the cloud supplied PackRef, re-hash the action's pack from disk
// and refuse to execute on a different immutable ref. Also
// signal a re-advertisement so cloud sees the new hash and flips the
// pack to pending in the trust UI.
func (c *Client) handleRun(ctx context.Context, s *runState, m RunActionMsg) {
	// A panic in one dispatch must not crash the runner — that would kill every
	// other in-flight action and the session. Recover, log it, and degrade to a
	// single failed result so the cloud still sees an outcome and the run never
	// hangs. The panic value is logged locally but never sent to the cloud.
	defer func() {
		if r := recover(); r != nil {
			c.opts.Logger.Error("cloud.run_panic",
				"request_id", m.RequestID,
				"action_id", m.ActionID,
				"panic", fmt.Sprintf("%v", r),
			)
			s.mu.Lock()
			already := s.finished
			s.mu.Unlock()
			if !already {
				c.finishRun(s, m, failedDispatchResult(
					m.RequestID,
					"engine_panic",
					"the runner hit an internal error handling this action",
				))
			}
		}
	}()

	c.opts.Logger.Info("cloud.run_started",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
	)

	// Authenticity first (did a real user sign this dispatch?), then pack
	// integrity (do the on-disk bytes still match what was trusted?).
	if !c.passesSignatureGate(s, m) {
		return
	}

	registry, trusted := c.passesTrustGate(s, m)
	if !trusted {
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
		RegistrySnapshot:      registry,
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
		c.finishRun(s, m, failedDispatchResult(m.RequestID, "engine_error", err.Error()))
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
			Envelope:        Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Status:          string(res.Status),
			ExitCode:        res.ExitCode,
			DurationMS:      res.DurationMS,
			TimedOut:        res.TimedOut,
			StdoutSHA256:    res.StdoutSHA256,
			StderrSHA256:    res.StderrSHA256,
			StdoutBytes:     res.StdoutBytes,
			StderrBytes:     res.StderrBytes,
			Redactions:      toProtocolRedactions(res.Redactions),
			Reason:          buildReasonWithDrops(res.Reason, dropped),
			EventID:         res.EventID,
			ExecutedCommand: res.ExecutedCommand,
		}
		c.finishRun(s, m, result)
	}
}

func (c *Client) finishRun(s *runState, m RunActionMsg, result ActionResultMsg) {
	if err := c.dedup.complete(m.RequestID, s.dispatchDigest, result); err != nil {
		// The durable reservation remains on disk if completion cannot be
		// persisted, so a restart still refuses to execute the action again.
		c.opts.Logger.Error("cloud.dedup_persist_failed", "request_id", m.RequestID, "error", err)
	}
	s.mu.Lock()
	s.finished = true
	s.mu.Unlock()
	c.enqueue(s, result, never)
}

// passesSignatureGate verifies the client attestation when the operator turned
// on enforcement. A nil (or non-enforcing) verifier always passes. On refusal
// it logs the reason and
// enqueues a terminal `signature_invalid` result the cloud records as a refused
// run; it deliberately does NOT re-advertise (unlike a pack mismatch, a bad
// signature says nothing about this runner's catalog).
func (c *Client) passesSignatureGate(s *runState, m RunActionMsg) bool {
	verifier := c.verifier.Load()
	if verifier == nil {
		return true
	}

	var att *signing.Attestation
	if m.Attestation != nil {
		att = m.Attestation
	}

	dec := verifier.Check(signing.Dispatch{
		ActionID: m.ActionID, PackRef: m.PackRef, ArgsRaw: m.ArgsRaw,
		Reason: m.Reason, OperationID: m.OperationID,
	}, att)
	if dec.Allowed {
		return true
	}

	c.opts.Logger.Warn("cloud.signature_refused",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
		"code", dec.Code,
	)
	result := ActionResultMsg{
		Envelope:   Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
		Status:     "signature_invalid",
		ExitCode:   -1,
		DurationMS: 0,
		Error:      "refused: " + dec.Detail,
		Reason:     dec.Code,
	}
	c.finishRun(s, m, result)
	return false
}

// passesTrustGate re-hashes the action's pack from disk and compares it to the
// cloud-supplied PackRef. On success it returns the exact registry snapshot that
// was checked, which Engine.Run must retain through execution. On mismatch it
// enqueues a pack_hash_mismatch result and requests a catalog re-advertisement.
func (c *Client) passesTrustGate(s *runState, m RunActionMsg) (*packs.Registry, bool) {
	reg := c.opts.Engine.Registry()
	expected := m.PackRef
	if expected == "" {
		// Signature-enforcing runners reject a missing signed PackRef before this
		// point. With enforcement off, an absent ref skips only the hash check.
		return reg, true
	}

	action, ok := reg.Action(m.ActionID)
	if !ok || action.PackID == "" {
		// Action vanished or has no pack. Let the engine produce its
		// own unknown_action result; nothing to gate.
		return reg, true
	}

	pack, ok := reg.Pack(action.PackID)
	if !ok {
		return reg, true
	}
	hash, err := reg.RecomputePackHash(action.PackID)
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
		return nil, false
	}

	got := fmt.Sprintf("%s@%s/%s", pack.ID, pack.Version, hash)
	if got == expected {
		return reg, true
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
	return nil, false
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
	c.finishRun(s, m, result)
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
	if len(s.pending) >= c.opts.MaxPendingPerRun && policy == dropOldestProgress {
		s.pending = s.pending[1:]
		s.dropped++
	}
	s.pending = append(s.pending, msg)
	s.mu.Unlock()
	c.signalSend()
}

// senderLoop runs for the duration of one websocket session. It drains
// in-flight runs' outboxes onto the connection. On send error, it
// requeues unsent messages and exits — runSession will reconnect and
// spawn a fresh senderLoop that resumes from the same state.
func (c *Client) senderLoop(ctx context.Context, sessionCancel context.CancelFunc, conn Conn) {
	defer sessionCancel()
	// Drain on each enqueue signal rather than polling at a fixed rate: at
	// idle this parks instead of waking 40×/s, and an outbound message (a
	// streamed progress chunk, a result) goes out immediately instead of
	// waiting up to a poll interval. The backstop ticker is a safety net —
	// liveness never depends on a signal arriving, so a missed wake only ever
	// adds at most one backstop interval of latency, never wedges the queue.
	const backstop = time.Second
	t := time.NewTicker(backstop)
	defer t.Stop()
	for {
		if err := c.drainOnce(ctx, conn); err != nil {
			c.opts.Logger.Warn("cloud.sender_failed", "error", err)
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-c.wake:
		case <-t.C:
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
// runner_state on the current connection. SIGHUP-driven pack reload
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

// cancelRun cancels the per-request context. If run_action has not arrived yet,
// it records a bounded tombstone so a cancel/action ordering race fails closed.
func (c *Client) cancelRun(requestID string) {
	c.mu.Lock()
	s, ok := c.runs[requestID]
	if !ok && !c.dedup.contains(requestID) {
		c.rememberPreCancelLocked(requestID)
	}
	c.mu.Unlock()
	if !ok {
		return
	}
	if s.cancel != nil {
		s.cancel()
	}
}

func (c *Client) rememberPreCancelLocked(requestID string) {
	if requestID == "" {
		return
	}
	if _, exists := c.preCanceled[requestID]; exists {
		return
	}
	if len(c.preCanceledOrder) >= c.opts.DedupRingSize {
		oldest := c.preCanceledOrder[0]
		c.preCanceledOrder = c.preCanceledOrder[1:]
		delete(c.preCanceled, oldest)
	}
	c.preCanceled[requestID] = struct{}{}
	c.preCanceledOrder = append(c.preCanceledOrder, requestID)
}

func (c *Client) consumePreCancelLocked(requestID string) bool {
	if _, exists := c.preCanceled[requestID]; !exists {
		return false
	}
	delete(c.preCanceled, requestID)
	for i, key := range c.preCanceledOrder {
		if key == requestID {
			c.preCanceledOrder = append(c.preCanceledOrder[:i], c.preCanceledOrder[i+1:]...)
			break
		}
	}
	return true
}

// ackRun is called when cloud confirms receipt of an action_result.
// Two effects:
//
//  1. If the runState is still finished+drained, remove it from
//     the in-flight map.
//  2. Record the underlying JSONL event_id in the cursor file so a
//     future cleanup pass can prune up to that point.
//
// The cached result stays in the dedup ring in the acknowledged state, in case
// cloud retries the request_id. Only acknowledged entries may roll out later.
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
	}
	cached, cachedOK := c.dedup.lookup(requestID)
	if err := c.dedup.acknowledge(requestID); err != nil {
		c.opts.Logger.Error("cloud.dedup_ack_failed", "request_id", requestID, "error", err)
		return
	}
	if ok {
		c.removeRun(requestID)
	}
	// Record on the cursor regardless of whether the in-flight state was
	// still around — cloud might be acking something we already evicted
	// from runs (legitimate during reconnect dances).
	if c.opts.Cursor != nil {
		if cachedOK && cached.EventID != "" {
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
// the reason when the per-run outbox lost progress messages during a
// disconnect, so the dropped count survives in the final result.
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
