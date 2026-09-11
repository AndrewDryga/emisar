package cloud

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

var errResponseBacklogFull = errors.New("response backlog full")

var errTerminalShutdown = errors.New("cloud: terminal shutdown")

// errProtocolVersionUnsupported marks a wire-protocol mismatch. Unlike a
// dropped socket it is local, deterministic, and unchanged by retrying, so the
// session that hit it must NOT count as connected (see runSession).
var errProtocolVersionUnsupported = errors.New("cloud: unsupported protocol version")

const (
	resultStatusSignatureInvalid = "signature_invalid"
	resultStatusPackHashMismatch = "pack_hash_mismatch"
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

// Dialer establishes a Conn authenticated as the runner configured on it.
type Dialer interface {
	Dial(ctx context.Context) (Conn, error)
}

// credentialRotator is the optional capability the real dialer has: it knows
// when the credential this session dialed with becomes eligible for rotation.
//
// A token refreshes only at dial time, so a session that never ends never
// refreshes. The portal expires a runner token 30 days after it becomes
// refreshable, so a runner on a stable link against a rarely-redeployed control
// plane eventually presents an expired token, gets 401, drops its cache, and
// needs an enrollment key its operator was told they could unset. Ending the
// session is the whole fix — Run redials and the existing refresh path runs. A
// dialer without this capability (every in-memory test transport) simply keeps
// its session.
type credentialRotator interface {
	CredentialRotationDue(now time.Time) bool
}

type credentialRotationRequester interface {
	RequestCredentialRotation(prefix string, now time.Time) (bool, error)
}

var errCredentialRotationRequested = errors.New("cloud: credential rotation requested")

// Options configure the Client behaviour.
type Options struct {
	StateBuilder   *StateBuilder
	Engine         *engine.Engine
	Logger         *slog.Logger
	HeartbeatEvery time.Duration
	// AvailabilityRefreshEvery is an internal polling interval for primary
	// executable changes. It is not user configuration; tests shorten it.
	AvailabilityRefreshEvery time.Duration
	ReconnectMin             time.Duration
	ReconnectMax             time.Duration

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

	// DedupLegacyStorePath is the pre-v0.12 dispatch log location. When
	// DedupStorePath does not exist yet, readable state found here is
	// migrated forward on boot instead of being silently abandoned.
	DedupLegacyStorePath string

	// TerminalShutdownPath persists terminal cloud rejections so a later
	// `emisar doctor` can explain why this runner stopped. Empty disables the
	// optional diagnostic state, which is useful for in-memory test clients.
	TerminalShutdownPath string

	// RuntimeStatusPath receives the daemon's local operational snapshot.
	// Empty disables it for in-memory clients and tests.
	RuntimeStatusPath string

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

	// finalizeRetries bounds the transient-finalize replay to one attempt
	// per request for the client's lifetime (entries clear only on ack, so a
	// retry consumed in one session is not granted again after a reconnect).
	// Completed, unacknowledged results are already retained by the dedup
	// ring for reconnect recovery; this map only covers the extra retry
	// requested by a transient portal persistence error.
	finalizeRetries map[string]struct{}

	// readvertise is a coalescing wake-up: Readvertise() does a
	// non-blocking send and readvertiseLoop drains it. Buffered size 1,
	// so many calls between drains collapse into a single extra send.
	readvertise chan struct{}

	// wake is the same coalescing-signal pattern for the sender: enqueue
	// pokes it so senderLoop drains immediately instead of waking on a
	// fixed poll. Buffered size 1 — many enqueues between drains collapse
	// into one wake, and senderLoop drains every run's outbox per wake.
	wake chan struct{}

	statusMu      sync.Mutex
	runtimeStatus RuntimeStatus
	runtimeWriter *runtimeStatusWriter
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
	// progressSeq is the number of progress MESSAGES minted for this run, and
	// the seq carried by the last one. Output lines merge into that message
	// while it is still queued, so this is also the count the cloud should
	// have stored — it reports it as ProgressChunks, and the cloud compares
	// that against its own event count to judge whether output was omitted.
	progressSeq int
	// attempted counts leading pending messages already handed to a failed
	// Send. The cloud may hold them and deduplicates on (request_id, seq), so
	// their bytes must never change; merging never touches this prefix.
	attempted int
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
	if opts.AvailabilityRefreshEvery <= 0 {
		opts.AvailabilityRefreshEvery = 30 * time.Second
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
		dialer: d,
		opts:   opts,
		runs:   map[string]*runState{},
		dedup: newDedupRing(
			opts.DedupRingSize, opts.DedupStorePath, opts.DedupLegacyStorePath, opts.Logger),
		preCanceled:     map[string]struct{}{},
		finalizeRetries: map[string]struct{}{},
		readvertise:     make(chan struct{}, 1),
		wake:            make(chan struct{}, 1),
		runtimeStatus: RuntimeStatus{
			SchemaVersion:         1,
			PID:                   os.Getpid(),
			State:                 RuntimeStateConnecting,
			StartedAt:             time.Now().UTC(),
			HeartbeatEverySeconds: int64((opts.HeartbeatEvery + time.Second - 1) / time.Second),
		},
	}
	c.runtimeStatus.UpdatedAt = c.runtimeStatus.StartedAt
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
	c.updateRuntimeStatus(func(status *RuntimeStatus, _ time.Time) {
		status.AdvertisementPending = true
	})
	select {
	case c.readvertise <- struct{}{}:
	default:
	}
}

// Run blocks until ctx is done, reconnecting indefinitely on failure.
// In-flight actions survive reconnects; their queued messages replay
// once the new session is established.
func (c *Client) Run(ctx context.Context) error {
	c.startRuntimeStatus()
	defer c.stopRuntimeStatus()

	if c.dedup.loadErr != nil {
		return c.dedup.startupRefusal()
	}

	backoff := c.opts.ReconnectMin
	for {
		if err := ctx.Err(); err != nil {
			return c.shutdown(err)
		}
		c.updateRuntimeStatus(func(status *RuntimeStatus, _ time.Time) {
			status.ConnectionAttempts++
		})
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
		c.updateRuntimeStatus(func(status *RuntimeStatus, _ time.Time) {
			status.State = RuntimeStateReconnecting
		})
		// A session that actually connected clears the backoff: the drop
		// that ended it is a fresh failure, not a continuation of the
		// reconnect storm. Without this the backoff ratchets up across
		// unrelated disconnects and never recovers on success.
		if connected {
			backoff = c.opts.ReconnectMin
		}
		wait := jitterBackoff(backoff)
		c.opts.Logger.Warn("cloud.session_ended", "error", err, "backoff", wait)
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return c.shutdown(ctx.Err())
		}
		backoff *= 2
		if backoff > c.opts.ReconnectMax {
			backoff = c.opts.ReconnectMax
		}
	}
}

// jitterBackoff spreads one reconnect delay uniformly over [d/2, d).
//
// A portal deploy drops the whole fleet in the same instant. Without this every
// runner waits the identical 1s, 2s, 4s … and the just-booting control plane
// takes N TLS handshakes plus N runner_state frames inside one millisecond,
// wave after wave — and the successful-connect backoff reset keeps the herd
// tight. The doubling and the cap are unchanged; only the sleep is randomised.
func jitterBackoff(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	return d/2 + time.Duration(rand.Int64N(int64(d-d/2)))
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

	state := c.buildState()
	if err := validateRunnerStateSize(state); err != nil {
		// Local, deterministic, and unchanged by retrying: the state we built is
		// too large to advertise. Report it as NOT connected so the caller keeps
		// backing off — reporting a successful dial here reset the backoff on
		// every pass and turned a permanent condition (enough installed packs to
		// exceed the cap) into a 1 Hz reconnect storm against the portal.
		return false, err
	}
	if err := conn.Send(sessionCtx, state); err != nil {
		return true, fmt.Errorf("send state: %w", err)
	}
	c.updateRuntimeStatus(func(status *RuntimeStatus, now time.Time) {
		status.State = RuntimeStateConnected
		status.ConnectedAt = &now
		status.LastHeartbeatSentAt = nil
		setRuntimeCatalog(status, state)
	})
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
	startSessionLoop(func() { c.readvertiseLoop(sessionCtx, sessionCancel, conn, state) })

	// Recv loop runs inline. Any error here terminates the session.
	for {
		raw, err := conn.Recv(sessionCtx)
		if err != nil {
			sessionCancel()
			return true, fmt.Errorf("recv: %w", err)
		}
		if err := c.dispatch(parent, raw); err != nil {
			sessionCancel()
			if errors.Is(err, errProtocolVersionUnsupported) {
				// Local, deterministic, and unchanged by retrying, exactly like
				// the runner_state size check above: the next session receives
				// the same message from the same peer. Reporting a successful
				// connect here would reset the backoff on every pass and turn a
				// permanent condition into a 1 Hz reconnect storm against the
				// portal — the shape the package's additive-safety promise
				// exists to avoid.
				return false, fmt.Errorf("dispatch: %w", err)
			}
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

func runnerResultStatuses() []string {
	statuses := make([]string, 0, len(engine.ResultStatuses())+2)
	for _, status := range engine.ResultStatuses() {
		statuses = append(statuses, string(status))
	}
	return append(statuses, resultStatusSignatureInvalid, resultStatusPackHashMismatch)
}

func validActionResultStatus(status string) bool {
	for _, allowed := range runnerResultStatuses() {
		if status == allowed {
			return true
		}
	}
	return false
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
