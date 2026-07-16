package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

var errResponseBacklogFull = errors.New("response backlog full")

var errTerminalShutdown = errors.New("cloud: terminal shutdown")

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

// Dialer establishes a Conn authenticated as the runner configured on it.
type Dialer interface {
	Dial(ctx context.Context) (Conn, error)
}

// Options configure the Client behaviour.
type Options struct {
	StateBuilder   *StateBuilder
	Engine         *engine.Engine
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

	// TerminalShutdownPath persists terminal cloud rejections so a later
	// `emisar doctor` can explain why this runner stopped. Empty disables the
	// optional diagnostic state, which is useful for in-memory test clients.
	TerminalShutdownPath string

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
	// handlerWG additions happen under mu and stop once closing is set, so
	// shutdown can cancel every handler and wait without racing a late Add.
	handlerWG sync.WaitGroup
	closing   bool

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
	pending  []any            // queued outbound messages
	terminal *ActionResultMsg // result waiting for durable dedup completion
	dropped  int              // progress chunks discarded because pending was full
	started  bool             // signature and pack gates passed; Engine.Run entered
	finished bool             // terminal outcome has been produced
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
	if c.dedup.loadErr != nil {
		return fmt.Errorf("load durable dispatch state: %w", c.dedup.loadErr)
	}

	backoff := c.opts.ReconnectMin
	for {
		if err := ctx.Err(); err != nil {
			return c.shutdown(err)
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
			return c.shutdown(ctx.Err())
		}
		// A portal shutdown for a revoked or unsupported runner is terminal for
		// this process. Return context.Canceled so the connect command exits
		// cleanly instead of its supervisor immediately restarting into the same
		// rejection. Planned cloud shutdowns continue through the normal
		// reconnect path below.
		if errors.Is(err, errTerminalShutdown) {
			return c.shutdown(context.Canceled)
		}
		if errors.Is(err, ErrUnauthorized) {
			return c.shutdown(err)
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
			return c.shutdown(ctx.Err())
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
	conn, err := c.dialer.Dial(parent)
	if err != nil {
		return false, fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	// sessionCtx is cancelled when any of: parent dies, recv errors,
	// heartbeat errors, sender errors. It's the lifetime of the websocket.
	sessionCtx, sessionCancel := context.WithCancel(parent)
	var sessionWG sync.WaitGroup
	defer sessionWG.Wait()
	defer sessionCancel()

	state := c.opts.StateBuilder.Build()
	if err := validateRunnerStateSize(state); err != nil {
		return true, err
	}
	if err := conn.Send(sessionCtx, state); err != nil {
		return true, fmt.Errorf("send state: %w", err)
	}
	if err := ClearTerminalShutdown(c.opts.TerminalShutdownPath); err != nil {
		c.opts.Logger.Warn("cloud.shutdown_state_clear_failed", "error", err)
	}
	requeuedResults := c.requeueUnacknowledgedResults()
	requeuedStarts := c.requeueActiveStarts()
	c.opts.Logger.Info("cloud.connected",
		"actions", len(state.Actions),
		"packs", len(state.Packs),
		"inflight_runs", c.countInflight(),
		"requeued_starts", requeuedStarts,
		"requeued_results", requeuedResults,
	)

	// Drain any queued messages from runs that survived a previous
	// disconnect. The sender loop does this on its tick, but kick a
	// drain right away so cloud sees a fast catch-up.
	startSessionLoop := func(loop func()) {
		sessionWG.Add(1)
		go func() {
			defer sessionWG.Done()
			loop()
		}()
	}
	startSessionLoop(func() { c.senderLoop(sessionCtx, sessionCancel, conn) })
	startSessionLoop(func() { c.heartbeatLoop(sessionCtx, sessionCancel, conn) })
	startSessionLoop(func() { c.readvertiseLoop(sessionCtx, sessionCancel, conn) })

	// Recv loop runs inline. Any error here terminates the session.
	for {
		raw, err := conn.Recv(sessionCtx)
		if err != nil {
			sessionCancel()
			return true, fmt.Errorf("recv: %w", err)
		}
		if err := c.dispatch(parent, raw); err != nil {
			sessionCancel()
			return true, fmt.Errorf("dispatch: %w", err)
		}
	}
}

// requeueActiveStarts makes the current session aware of every action that
// entered Engine.Run and survived a prior socket. It prepends at most one frame
// per active run so lifecycle recovery precedes buffered progress.
func (c *Client) requeueActiveStarts() int {
	c.mu.Lock()
	defer c.mu.Unlock()

	requeued := 0
	for _, state := range c.runs {
		state.mu.Lock()
		if !state.started || state.finished || hasActionStarted(state.pending, state.requestID) {
			state.mu.Unlock()
			continue
		}
		started := ActionStartedMsg{Envelope: Envelope{
			Type:            MsgActionStarted,
			ProtocolVersion: ProtocolVersion,
			RequestID:       state.requestID,
		}}
		state.pending = append([]any{started}, state.pending...)
		state.mu.Unlock()
		requeued++
	}
	return requeued
}

func hasActionStarted(messages []any, requestID string) bool {
	for _, message := range messages {
		started, ok := message.(ActionStartedMsg)
		if ok && started.RequestID == requestID {
			return true
		}
	}
	return false
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
func (c *Client) dispatch(parent context.Context, raw []byte) error {
	envelope, err := PeekEnvelope(raw)
	if err != nil {
		c.opts.Logger.Warn("cloud.bad_envelope", "error", err)
		return nil
	}
	switch envelope.Type {
	case MsgRunAction:
		if err := requireProtocolVersion(envelope); err != nil {
			return err
		}
		var m RunActionMsg
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		if err := decoder.Decode(&m); err != nil {
			c.opts.Logger.Warn("cloud.bad_run_action", "error", err)
			return nil
		}
		return c.startRun(parent, m)
	case MsgCancel:
		if err := requireProtocolVersion(envelope); err != nil {
			return err
		}
		if err := validateRequestID(envelope.RequestID); err != nil {
			c.opts.Logger.Warn("cloud.bad_cancel", "error", err)
			return nil
		}
		c.cancelRun(envelope.RequestID)
	case MsgAckResult:
		if err := requireProtocolVersion(envelope); err != nil {
			return err
		}
		if err := validateRequestID(envelope.RequestID); err != nil {
			c.opts.Logger.Warn("cloud.bad_ack_result", "error", err)
			return nil
		}
		c.ackRun(envelope.RequestID)
	case MsgShutdown:
		if err := requireProtocolVersion(envelope); err != nil {
			return err
		}
		var m ShutdownMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			c.opts.Logger.Warn("cloud.bad_shutdown", "error", err)
			return nil
		}
		c.opts.Logger.Warn("cloud.shutdown", "reason", m.Reason, "message", m.Message)
		if terminalShutdownReason(m.Reason) {
			if c.opts.TerminalShutdownPath != "" {
				if err := WriteTerminalShutdown(c.opts.TerminalShutdownPath, m.Reason, m.Message); err != nil {
					c.opts.Logger.Error("cloud.shutdown_state_write_failed", "reason", m.Reason, "error", err)
				}
			}
			return fmt.Errorf("%w: reason=%s", errTerminalShutdown, m.Reason)
		}
	default:
		c.opts.Logger.Debug("cloud.unknown_message", "type", envelope.Type)
	}
	return nil
}

func terminalShutdownReason(reason string) bool {
	switch reason {
	case "runner_revoked", "runner_version_unsupported":
		return true
	default:
		return false
	}
}

func requireProtocolVersion(envelope Envelope) error {
	if envelope.ProtocolVersion != ProtocolVersion {
		return fmt.Errorf(
			"cloud: %s protocol_version %d does not match supported version %d",
			envelope.Type,
			envelope.ProtocolVersion,
			ProtocolVersion,
		)
	}
	return nil
}

// startRun spawns a handler for one run_action, subject to the
// concurrency cap. The handler outlives the current connection.
//
// Idempotency: if request_id matches a cached completed result, the
// cached result is enqueued for re-send without re-executing.
func (c *Client) startRun(parent context.Context, m RunActionMsg) error {
	digest, err := dispatchDigest(m)
	if err != nil {
		if !c.enqueueTransient(m.RequestID, c.refusedDispatchResult(parent, m, "dispatch_invalid", err.Error())) {
			return errResponseBacklogFull
		}
		return nil
	}
	c.mu.Lock()
	if c.closing {
		c.mu.Unlock()
		return context.Canceled
	}
	if existing, exists := c.runs[m.RequestID]; exists {
		c.mu.Unlock()
		if existing.dispatchDigest != digest {
			// The first intent may already be executing and cannot safely be
			// replaced or failed under the same correlation id. Keep it authoritative.
			c.opts.Logger.Error("cloud.duplicate_in_flight_conflict", "request_id", m.RequestID)
		} else {
			c.opts.Logger.Warn("cloud.duplicate_in_flight", "request_id", m.RequestID)
		}
		return nil
	}
	decision, cached, err := c.dedup.inspect(m.RequestID, digest)
	if err != nil {
		c.mu.Unlock()
		if !c.dispatchReservationFailed(parent, m, err) {
			return errResponseBacklogFull
		}
		return nil
	}
	if decision != reservationNew {
		c.mu.Unlock()
		if !c.handleReservationDecision(parent, m, digest, decision, cached) {
			return errResponseBacklogFull
		}
		return nil
	}
	preCanceled := c.consumePreCancelLocked(m.RequestID)
	if !preCanceled && c.countActiveRunsLocked() >= c.opts.MaxConcurrentRuns {
		c.opts.Logger.Warn("cloud.concurrency_cap_reached",
			"request_id", m.RequestID,
			"cap", c.opts.MaxConcurrentRuns,
		)
		enqueued := c.enqueueTransientLocked(m.RequestID, ErrorMsg{
			Envelope: Envelope{Type: MsgError, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Code:     "concurrency_cap_reached",
			Message:  fmt.Sprintf("runner at concurrency cap (%d in flight)", c.opts.MaxConcurrentRuns),
		})
		c.mu.Unlock()
		c.opts.Engine.RecordDispatchRefusal(context.WithoutCancel(parent), requestForDispatch(m, nil, nil), "concurrency cap reached")
		if !enqueued {
			return errResponseBacklogFull
		}
		c.signalSend()
		return nil
	}
	if !preCanceled && len(c.runs) >= c.maxRunStates() {
		c.mu.Unlock()
		c.opts.Engine.RecordDispatchRefusal(context.WithoutCancel(parent), requestForDispatch(m, nil, nil), "response backlog full")
		return errResponseBacklogFull
	}
	decision, cached, err = c.dedup.reserve(m.RequestID, digest)
	if err != nil {
		c.mu.Unlock()
		if !c.dispatchReservationFailed(parent, m, err) {
			return errResponseBacklogFull
		}
		return nil
	}
	if decision != reservationNew {
		c.mu.Unlock()
		if !c.handleReservationDecision(parent, m, digest, decision, cached) {
			return errResponseBacklogFull
		}
		return nil
	}
	if preCanceled {
		s := &runState{requestID: m.RequestID, dispatchDigest: digest}
		c.runs[m.RequestID] = s
		c.mu.Unlock()
		result := withLocalAudit(ActionResultMsg{
			Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Status:   "cancelled",
			ExitCode: -1,
			Reason:   "cancelled_before_start",
		}, c.opts.Engine.RecordDispatchCancellation(
			context.WithoutCancel(parent), requestForDispatch(m, nil, nil), "cancelled before process start",
		))
		c.finishRun(s, result)
		return nil
	}
	runCtx, cancel := context.WithCancel(parent)
	s := &runState{requestID: m.RequestID, cancel: cancel, dispatchDigest: digest}
	c.runs[m.RequestID] = s
	c.handlerWG.Add(1)
	c.mu.Unlock()

	go func() {
		defer c.handlerWG.Done()
		c.handleRun(runCtx, s, m)
	}()
	return nil
}

func (c *Client) handleReservationDecision(
	ctx context.Context,
	m RunActionMsg,
	digest string,
	decision reservationDecision,
	cached ActionResultMsg,
) bool {
	switch decision {
	case reservationReplay:
		c.opts.Logger.Info("cloud.dedup_replay", "request_id", m.RequestID)
		return c.enqueueTransient(m.RequestID, cached)
	case reservationPending:
		result := c.refusedDispatchResult(
			ctx,
			m,
			"execution_outcome_unknown",
			"runner restarted after reserving this dispatch; it was not re-executed because prior side effects are unknown",
		)
		return c.enqueueDurableResult(m.RequestID, digest, result)
	case reservationConflict:
		c.opts.Logger.Warn("cloud.dispatch_id_conflict", "request_id", m.RequestID)
		return c.enqueueTransient(m.RequestID, c.refusedDispatchResult(
			ctx,
			m,
			"dispatch_id_conflict",
			"request_id was already bound to different execution facts; action was not executed",
		))
	default:
		return false
	}
}

// enqueueDurableResult installs response state before attempting completion so
// a transient filesystem failure cannot lose the only terminal result.
func (c *Client) enqueueDurableResult(requestID, digest string, result ActionResultMsg) bool {
	c.mu.Lock()
	if c.closing || len(c.runs) >= c.maxRunStates() {
		c.mu.Unlock()
		return false
	}
	if _, exists := c.runs[requestID]; exists {
		c.mu.Unlock()
		return false
	}
	state := &runState{requestID: requestID, dispatchDigest: digest}
	c.runs[requestID] = state
	c.mu.Unlock()
	c.finishRun(state, result)
	return true
}

func (c *Client) dispatchReservationFailed(ctx context.Context, m RunActionMsg, err error) bool {
	c.opts.Logger.Error("cloud.dispatch_reservation_failed", "request_id", m.RequestID, "error", err)
	return c.enqueueTransient(m.RequestID, c.refusedDispatchResult(
		ctx,
		m,
		"dispatch_reservation_failed",
		"runner could not durably reserve this dispatch; action was not executed",
	))
}

func (c *Client) refusedDispatchResult(ctx context.Context, m RunActionMsg, reason, detail string) ActionResultMsg {
	result := failedDispatchResult(m.RequestID, reason, detail)
	return withLocalAudit(result, c.opts.Engine.RecordDispatchRefusal(
		context.WithoutCancel(ctx), requestForDispatch(m, nil, nil), detail,
	))
}

func failedDispatchResult(requestID, reason, detail string) ActionResultMsg {
	return ActionResultMsg{
		Envelope: Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		Status:   "failed", ExitCode: -1, Reason: reason, Error: detail,
	}
}

func withLocalAudit(result ActionResultMsg, eventID string) ActionResultMsg {
	result.EventID = eventID
	result.LocalAuditFailed = eventID == ""
	return result
}

// enqueueTransient creates a finished runState containing exactly one
// message (a cached result or a synthetic error). The sender picks it
// up on its next tick.
func (c *Client) enqueueTransient(requestID string, msg any) bool {
	c.mu.Lock()
	enqueued := c.enqueueTransientLocked(requestID, msg)
	c.mu.Unlock()
	if enqueued {
		c.signalSend()
	}
	return enqueued
}

// enqueueTransientLocked appends one terminal response while c.mu is held.
// Reservation classification runs under that same lock, so it uses this form
// to avoid releasing the execution-cap decision before the response is queued.
func (c *Client) enqueueTransientLocked(requestID string, msg any) bool {
	if c.closing {
		return false
	}
	// If a runState already exists (e.g., second dedup hit while the
	// first replay is still queued), append rather than overwrite.
	if existing, ok := c.runs[requestID]; ok {
		existing.mu.Lock()
		if len(existing.pending) >= c.opts.MaxPendingPerRun {
			existing.mu.Unlock()
			return false
		}
		existing.pending = append(existing.pending, msg)
		existing.mu.Unlock()
		return true
	}
	// Reserve one dedup-ring-sized tranche for replaying durable unacknowledged
	// results after reconnect. Transient responses cannot consume that space.
	if len(c.runs) >= c.opts.MaxConcurrentRuns+c.opts.DedupRingSize {
		return false
	}
	c.runs[requestID] = &runState{requestID: requestID, finished: true, pending: []any{msg}}
	return true
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
				result := failedDispatchResult(
					m.RequestID,
					"engine_panic",
					"the runner hit an internal error handling this action",
				)
				result = withLocalAudit(result, c.opts.Engine.RecordExecutionFailure(
					context.WithoutCancel(ctx), requestForDispatch(m, nil, nil), "runner recovered an internal dispatch panic",
				))
				c.finishRun(s, result)
			}
		}
	}()

	c.opts.Logger.Info("cloud.run_started",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
	)

	// Authenticity first (did a real user sign this dispatch?), then pack
	// integrity (do the on-disk bytes still match what was trusted?).
	if !c.passesSignatureGate(ctx, s, m) {
		return
	}

	registry, trusted := c.passesTrustGate(ctx, s, m)
	if !trusted {
		return
	}
	c.markRunStarted(s)

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

	req := requestForDispatch(m, registry, progress)
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
		result := failedDispatchResult(m.RequestID, "engine_error", err.Error())
		result = withLocalAudit(result, c.opts.Engine.RecordExecutionFailure(
			context.WithoutCancel(ctx), req, "engine returned an internal error: "+err.Error(),
		))
		c.finishRun(s, result)
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

		executedCommand, executedCommandTruncated := boundExecutedCommand(res.ExecutedCommand)
		result := ActionResultMsg{
			Envelope:                 Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
			Status:                   string(res.Status),
			ExitCode:                 res.ExitCode,
			DurationMS:               res.DurationMS,
			TimedOut:                 res.TimedOut,
			EmittedStdoutSHA256:      res.StdoutSHA256,
			EmittedStderrSHA256:      res.StderrSHA256,
			EmittedStdoutBytes:       res.StdoutBytes,
			EmittedStderrBytes:       res.StderrBytes,
			ProgressChunks:           seq,
			DroppedProgressChunks:    dropped,
			TruncatedOut:             res.TruncatedOut,
			TruncatedErr:             res.TruncatedErr,
			Redactions:               toProtocolRedactions(res.Redactions),
			Reason:                   res.Reason,
			EventID:                  res.EventID,
			LocalAuditFailed:         res.LocalAuditFailed,
			ExecutedCommand:          executedCommand,
			ExecutedCommandTruncated: executedCommandTruncated,
		}
		c.finishRun(s, result)
	}
}

func (c *Client) markRunStarted(s *runState) {
	s.mu.Lock()
	s.started = true
	s.pending = append(s.pending, ActionStartedMsg{Envelope: Envelope{
		Type:            MsgActionStarted,
		ProtocolVersion: ProtocolVersion,
		RequestID:       s.requestID,
	}})
	s.mu.Unlock()
	c.signalSend()
}

func (c *Client) finishRun(s *runState, result ActionResultMsg) {
	s.mu.Lock()
	s.finished = true
	if err := c.dedup.complete(s.requestID, s.dispatchDigest, result); err != nil {
		// Keep the terminal result in memory and let the sender backstop retry.
		// The durable reservation also prevents re-execution after a restart.
		s.terminal = &result
		s.mu.Unlock()
		c.opts.Logger.Error("cloud.dedup_persist_failed", "request_id", s.requestID, "error", err)
		c.signalSend()
		return
	}
	s.pending = append(s.pending, result)
	s.mu.Unlock()
	c.signalSend()
}

// passesSignatureGate verifies the client attestation when the operator turned
// on enforcement. A nil (or non-enforcing) verifier always passes. On refusal
// it logs the reason and
// enqueues a terminal `signature_invalid` result the cloud records as a refused
// run; it deliberately does NOT re-advertise (unlike a pack mismatch, a bad
// signature says nothing about this runner's catalog).
func (c *Client) passesSignatureGate(ctx context.Context, s *runState, m RunActionMsg) bool {
	verifier := c.verifier.Load()
	if verifier == nil {
		return true
	}

	var att *signing.Attestation
	if m.Attestation != nil {
		att = m.Attestation
	}
	if att != nil && m.Opts.hasOverrides() {
		return c.refuseSignature(ctx, s, m, signing.Decision{
			Code:   "intent_mismatch",
			Detail: "signed MCP dispatches cannot override action execution limits",
		})
	}

	dec := verifier.Check(signing.Dispatch{
		ActionID: m.ActionID, PackRef: m.PackRef, ArgsRaw: m.ArgsRaw,
		Reason: m.Reason, OperationID: m.OperationID,
	}, att)
	if dec.Allowed {
		return true
	}
	return c.refuseSignature(ctx, s, m, dec)
}

func (c *Client) refuseSignature(ctx context.Context, s *runState, m RunActionMsg, dec signing.Decision) bool {
	c.opts.Logger.Warn("cloud.signature_refused",
		"request_id", m.RequestID,
		"action_id", m.ActionID,
		"code", dec.Code,
	)
	result := withLocalAudit(ActionResultMsg{
		Envelope:   Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
		Status:     "signature_invalid",
		ExitCode:   -1,
		DurationMS: 0,
		Error:      "refused: " + dec.Detail,
		Reason:     dec.Code,
	}, c.opts.Engine.RecordDispatchRefusal(
		context.WithoutCancel(ctx), requestForDispatch(m, nil, nil), "signature refused: "+dec.Code,
	))
	c.finishRun(s, result)
	return false
}

// passesTrustGate re-hashes the action's pack from disk and compares it to the
// control plane's trusted hash. Signed calls also carry PackRef, which must
// describe the same local pack. On success it returns the exact registry
// snapshot that Engine.Run retains through execution.
func (c *Client) passesTrustGate(ctx context.Context, s *runState, m RunActionMsg) (*packs.Registry, bool) {
	reg := c.opts.Engine.Registry()
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
		c.emitPackMismatch(ctx, s, m, action.PackID, m.ExpectedPackHash, "rehash_failed:"+err.Error())
		return nil, false
	}

	if hash != m.ExpectedPackHash {
		expected := m.ExpectedPackHash
		if strings.TrimSpace(expected) == "" {
			expected = "<missing>"
		}
		c.opts.Logger.Warn("cloud.pack_hash_mismatch",
			"request_id", m.RequestID,
			"action_id", m.ActionID,
			"pack_id", action.PackID,
			"expected", expected,
			"got", hash,
		)
		c.emitPackMismatch(ctx, s, m, action.PackID, expected, hash)
		c.Readvertise()
		return nil, false
	}

	gotRef := fmt.Sprintf("%s@%s/%s", pack.ID, pack.Version, hash)
	if m.PackRef != "" && gotRef != m.PackRef {
		c.opts.Logger.Warn("cloud.pack_ref_mismatch",
			"request_id", m.RequestID,
			"action_id", m.ActionID,
			"pack_id", action.PackID,
			"expected", m.PackRef,
			"got", gotRef,
		)
		c.emitPackMismatch(ctx, s, m, action.PackID, m.PackRef, gotRef)
		c.Readvertise()
		return nil, false
	}

	return reg, true
}

// emitPackMismatch enqueues the terminal ActionResultMsg the cloud
// receives when the runner refuses a dispatch on trust mismatch. Cloud
// surfaces this as a run with status="pack_hash_mismatch" — the UI
// renders it as a tamper alert, and the pending_trust card shows up on
// /app/packs as soon as the runner's re-broadcast lands.
func (c *Client) emitPackMismatch(ctx context.Context, s *runState, m RunActionMsg, packID, expected, got string) {
	detail := fmt.Sprintf(
		"pack %q does not match the dispatch trust contract (expected %s, got %s); refused — operator must review the drift in /app/packs",
		packID, expected, got,
	)
	result := withLocalAudit(ActionResultMsg{
		Envelope:   Envelope{Type: MsgActionResult, ProtocolVersion: ProtocolVersion, RequestID: m.RequestID},
		Status:     "pack_hash_mismatch",
		ExitCode:   -1,
		DurationMS: 0,
		Error:      detail,
		Reason:     "pack_hash_mismatch",
	}, c.opts.Engine.RecordDispatchRefusal(
		context.WithoutCancel(ctx), requestForDispatch(m, nil, nil), detail,
	))
	c.finishRun(s, result)
}

func requestForDispatch(m RunActionMsg, registry *packs.Registry, progress engine.ProgressFunc) engine.Request {
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
	return req
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
		progress := -1
		for i, pending := range s.pending {
			if _, ok := pending.(ActionProgressMsg); ok {
				progress = i
				break
			}
		}
		s.dropped++
		if progress < 0 {
			s.mu.Unlock()
			return
		}
		s.pending = append(s.pending[:progress], s.pending[progress+1:]...)
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
		if recovered, err := c.retryTerminalPersistence(s); err == nil && recovered {
			c.opts.Logger.Info("cloud.dedup_persist_recovered", "request_id", s.requestID)
		}
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
		if s.finished && s.terminal == nil && len(s.pending) == 0 {
			s.mu.Unlock()
			c.removeRun(s.requestID)
			continue
		}
		s.mu.Unlock()
	}
	return nil
}

// retryTerminalPersistence promotes a held terminal result into the send queue
// only after the completed dedup record is durable. Failure is deliberately not
// a transport error: the sender backstop retries without reconnecting.
func (c *Client) retryTerminalPersistence(s *runState) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.terminal == nil {
		return false, nil
	}
	if err := c.dedup.complete(s.requestID, s.dispatchDigest, *s.terminal); err != nil {
		return false, err
	}
	s.pending = append(s.pending, *s.terminal)
	s.terminal = nil
	return true, nil
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
			if err := validateRunnerStateSize(state); err != nil {
				c.opts.Logger.Warn("cloud.readvertise_failed", "error", err)
				return
			}
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
// The cached result stays in the dedup ring in the acknowledged state, in case
// cloud retries the request_id. Only acknowledged entries may roll out later.
func (c *Client) ackRun(requestID string) {
	c.mu.Lock()
	s, ok := c.runs[requestID]
	c.mu.Unlock()
	if ok {
		s.mu.Lock()
		finished := s.finished
		empty := len(s.pending) == 0 && s.terminal == nil
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
	if err := c.dedup.acknowledge(requestID); err != nil {
		c.opts.Logger.Error("cloud.dedup_ack_failed", "request_id", requestID, "error", err)
		return
	}
	if ok {
		c.removeRun(requestID)
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
	return c.countActiveRunsLocked()
}

func (c *Client) countActiveRunsLocked() int {
	active := 0
	for _, s := range c.runs {
		s.mu.Lock()
		if !s.finished {
			active++
		}
		s.mu.Unlock()
	}
	return active
}

func (c *Client) maxRunStates() int {
	return c.opts.MaxConcurrentRuns + 2*c.opts.DedupRingSize
}

// shutdown stops admission before waiting, so no handler can race a WaitGroup
// Add with Wait. Each executor receives cancellation and persists its terminal
// dedup result before Run returns to the process shutdown path.
func (c *Client) shutdown(reason error) error {
	c.mu.Lock()
	c.closing = true
	cancels := make([]context.CancelFunc, 0, len(c.runs))
	for _, s := range c.runs {
		if s.cancel != nil {
			cancels = append(cancels, s.cancel)
		}
	}
	c.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
	c.handlerWG.Wait()
	return reason
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
