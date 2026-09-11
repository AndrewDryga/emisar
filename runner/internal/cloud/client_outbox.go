package cloud

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// The outbox and the background loops that drain it: bounded progress chunks,
// the drop policy that decides what a full queue sheds, the sender, heartbeat
// and re-advertise loops, and the cancel/ack paths that resolve a run.

// JSON escaping can expand one byte to six. A 32 KiB chunk leaves room for
// metadata below the portal's 256 KiB encoded event-payload limit, even when
// every byte needs escaping. Bound newly emitted chunks as well as merges.
const maxProgressChunkBytes = 32 * 1024

func (c *Client) enqueueProgress(s *runState, requestID, stream, chunk string) {
	for len(chunk) > maxProgressChunkBytes {
		end := maxProgressChunkBytes
		for !utf8.RuneStart(chunk[end]) {
			end--
		}
		c.enqueueProgressChunk(s, requestID, stream, chunk[:end])
		chunk = chunk[end:]
	}
	if chunk != "" {
		c.enqueueProgressChunk(s, requestID, stream, chunk)
	}
}

// enqueueProgressChunk queues one bounded chunk, merging it into the run's last
// pending progress message when that message is still waiting to go out.
//
// The cloud takes a row lock, inserts an event, and bumps the run's counters
// for every progress message it receives, so a line-at-a-time action turned
// each line into its own write transaction. A line can only merge while an
// earlier message is undrained — that is, while output is arriving faster than
// the socket ships it — so a runner keeping up still sends every line
// immediately and live output is unchanged.
//
// seq counts MESSAGES, not lines: it is the run's ProgressChunks, which the
// cloud compares against the events it stored to decide whether output went
// missing. Merging into a message therefore does not advance it.
func (c *Client) enqueueProgressChunk(s *runState, requestID, stream, chunk string) {
	s.mu.Lock()
	if last := len(s.pending) - 1; last >= s.attempted {
		if previous, ok := s.pending[last].(ActionProgressMsg); ok &&
			previous.Stream == stream &&
			len(previous.Chunk)+len(chunk) <= maxProgressChunkBytes {
			previous.Chunk += chunk
			s.pending[last] = previous
			s.mu.Unlock()
			c.signalSend()
			return
		}
	}
	s.progressSeq++
	msg := ActionProgressMsg{
		Envelope: Envelope{
			Type:            MsgActionProgress,
			ProtocolVersion: ProtocolVersion,
			RequestID:       requestID,
		},
		Seq:    s.progressSeq,
		Stream: stream,
		Chunk:  chunk,
	}
	s.mu.Unlock()

	c.enqueue(s, msg, dropOldestProgress)
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
		s.attempted = 0
		s.mu.Unlock()
		for i, msg := range msgs {
			if err := conn.Send(ctx, msg); err != nil {
				// Requeue everything we haven't yet sent so the next
				// session picks up where we left off. msgs[i] was already
				// handed to Send, so the cloud may hold it — mark the
				// requeued prefix untouchable, or a later line merging into
				// it would change the bytes behind a seq the cloud
				// deduplicates on and the difference would be dropped.
				s.mu.Lock()
				s.pending = append(msgs[i:], s.pending...)
				s.attempted = len(msgs) - i
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

func (c *Client) buildState() RunnerStateMsg {
	state := c.opts.StateBuilder.Build()
	_, state.CredentialRotationSupported = c.dialer.(credentialRotationRequester)
	return state
}

// readvertiseLoop watches for Readvertise() pings and primary-executable
// changes. SIGHUP refreshes immediately; the fixed poll keeps package installs
// and removals from leaving action readiness stale indefinitely.
func (c *Client) readvertiseLoop(
	ctx context.Context,
	sessionCancel context.CancelFunc,
	conn Conn,
	initial RunnerStateMsg,
) {
	defer sessionCancel()
	ticker := time.NewTicker(c.opts.AvailabilityRefreshEvery)
	defer ticker.Stop()
	lastAvailability := primaryExecutableAvailability(initial)

	sendState := func(state RunnerStateMsg) bool {
		if err := validateRunnerStateSize(state); err != nil {
			c.opts.Logger.Warn("cloud.readvertise_failed", "error", err)
			return false
		}
		if err := conn.Send(ctx, state); err != nil {
			c.opts.Logger.Warn("cloud.readvertise_failed", "error", err)
			return false
		}
		lastAvailability = primaryExecutableAvailability(state)
		c.opts.Logger.Info("cloud.readvertised",
			"actions", len(state.Actions),
			"packs", len(state.Packs),
		)
		c.updateRuntimeStatus(func(status *RuntimeStatus, _ time.Time) {
			setRuntimeCatalog(status, state)
		})
		return true
	}

	for {
		select {
		case <-ctx.Done():
			return
		case <-c.readvertise:
			state := c.buildState()
			if !sendState(state) {
				return
			}
		case <-ticker.C:
			state := c.buildState()
			availability := primaryExecutableAvailability(state)
			if availability == lastAvailability {
				continue
			}
			if !sendState(state) {
				return
			}
		}
	}
}

func primaryExecutableAvailability(state RunnerStateMsg) string {
	var b strings.Builder
	for _, action := range state.Actions {
		fmt.Fprintf(&b, "%s=%t:%s\n", action.ID, action.PrimaryExecutableAvailable, action.MissingExecutable)
	}
	return b.String()
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
			now := time.Now().UTC()
			if rotator, ok := c.dialer.(credentialRotator); ok && rotator.CredentialRotationDue(now) {
				// The dial is the only place the credential rotates, so the
				// session has to end for rotation to happen at all.
				c.opts.Logger.Info("cloud.credential_rotation_due",
					"detail", "ending the session so the reconnect can refresh the runner token")
				return
			}
			err := conn.Send(ctx, HeartbeatMsg{
				Envelope:   Envelope{Type: MsgHeartbeat, ProtocolVersion: ProtocolVersion},
				ActionLoad: load,
			})
			if err != nil {
				c.opts.Logger.Warn("cloud.heartbeat_failed", "error", err)
				return
			}
			c.updateRuntimeStatus(func(status *RuntimeStatus, _ time.Time) {
				status.LastHeartbeatSentAt = &now
			})
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
	c.mu.Lock()
	delete(c.finalizeRetries, requestID)
	c.mu.Unlock()
	if ok {
		c.removeRun(requestID)
	}
}

// retryFinalization requeues a durable terminal result after the portal says
// its first finalize attempt failed. The normal dedup replay remains the
// reconnect backstop; this once-per-request retry removes avoidable latency
// when the socket itself is healthy.
func (c *Client) retryFinalization(requestID string) {
	if requestID == "" {
		return
	}

	result, ok := c.dedup.unacknowledgedResult(requestID)
	if !ok {
		return
	}

	c.mu.Lock()
	if _, retried := c.finalizeRetries[requestID]; retried {
		c.mu.Unlock()
		return
	}
	if !c.enqueueTransientLocked(requestID, result) {
		c.mu.Unlock()
		return
	}
	c.finalizeRetries[requestID] = struct{}{}
	c.mu.Unlock()
	c.signalSend()
	c.opts.Logger.Warn("cloud.finalize_retry", "request_id", requestID)
}
