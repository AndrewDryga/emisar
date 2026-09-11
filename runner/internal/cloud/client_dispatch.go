package cloud

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/engine"
)

// Admission for an incoming frame: decode it, check the protocol version, take
// or refuse a reservation for a run, and put a refusal on the wire as a real
// result rather than silence. Split out of client.go, which had grown to 1,736
// lines across four concerns that share only the Client struct.

// dispatch routes one inbound message. parent (not sessionCtx) is the
// outer context so that started runs outlive the connection.
func (c *Client) dispatch(parent context.Context, raw []byte) error {
	envelope, err := PeekEnvelope(raw)
	if err != nil {
		c.opts.Logger.Warn("cloud.bad_envelope", "error", err)
		c.refuseUndecodableDispatch(parent, "")
		return nil
	}
	// Every KNOWN message must carry the exact protocol version; an unknown
	// type stays ignorable so an additive message family cannot break a peer.
	switch envelope.Type {
	case MsgRunAction, MsgCancel, MsgAckResult, MsgError, MsgShutdown, MsgRefreshCredentials:
		if err := c.requireProtocolVersion(envelope); err != nil {
			return err
		}
	}
	// The spec freezes the exact lowercase field names for EVERY inbound
	// message, not just run_action, which owns its own (deeper) check inside
	// UnmarshalJSON. A dropped frame matches how each of these types already
	// handles a malformed body: warn and ignore, never act on it.
	if err := rejectInboundAliases(raw, envelope.Type); err != nil {
		c.opts.Logger.Warn("cloud.field_name_alias", "type", envelope.Type, "error", err)
		return nil
	}
	switch envelope.Type {
	case MsgRunAction:
		var m RunActionMsg
		// RunActionMsg.UnmarshalJSON owns the size, uniqueness, alias and
		// request_id checks, and captures the exact args token itself — a
		// decoder option here would never reach the args.
		if err := json.Unmarshal(raw, &m); err != nil {
			c.opts.Logger.Warn("cloud.bad_run_action", "error", err)
			c.refuseUndecodableDispatch(parent, envelope.RequestID)
			return nil
		}
		return c.startRun(parent, m)
	case MsgCancel:
		if err := validateRequestID(envelope.RequestID); err != nil {
			c.opts.Logger.Warn("cloud.bad_cancel", "error", err)
			return nil
		}
		c.cancelRun(envelope.RequestID)
	case MsgAckResult:
		if err := validateRequestID(envelope.RequestID); err != nil {
			c.opts.Logger.Warn("cloud.bad_ack_result", "error", err)
			return nil
		}
		c.ackRun(envelope.RequestID)
	case MsgError:
		if envelope.RequestID != "" {
			if err := validateRequestID(envelope.RequestID); err != nil {
				c.opts.Logger.Warn("cloud.bad_error", "error", err)
				return nil
			}
		}
		var m ErrorMsg
		if err := json.Unmarshal(raw, &m); err != nil {
			c.opts.Logger.Warn("cloud.bad_error", "error", err)
			return nil
		}
		c.opts.Logger.Warn("cloud.error_envelope",
			"code", m.Code,
			"message", "details withheld; inspect portal logs",
			"request_id", envelope.RequestID)
		if m.Code == "finalize_failed" {
			c.retryFinalization(envelope.RequestID)
		}
	case MsgRefreshCredentials:
		var m RefreshCredentialsMsg
		if err := validateUniqueJSON(raw); err != nil {
			c.opts.Logger.Warn("cloud.bad_credential_rotation")
			return nil
		}
		if err := json.Unmarshal(raw, &m); err != nil {
			c.opts.Logger.Warn("cloud.bad_credential_rotation")
			return nil
		}
		if rotator, ok := c.dialer.(credentialRotationRequester); ok {
			requested, err := rotator.RequestCredentialRotation(m.TokenPrefix, time.Now().UTC())
			if err != nil {
				// The bearer secret and transport are unchanged. Do not echo input
				// or filesystem errors from the credential boundary into logs.
				c.opts.Logger.Warn("cloud.credential_rotation_not_persisted",
					"detail", "keeping the current connection; the portal can retry")
				return nil
			}
			if requested {
				c.opts.Logger.Info("cloud.credential_rotation_requested")
				return errCredentialRotationRequested
			}
		}
	case MsgShutdown:
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

// requireProtocolVersion ends the session when a known message carries a
// version this build does not implement, and records that as a PERMANENT local
// condition: the peer speaks a wire protocol we cannot read, so every
// reconnect meets the same message. Persisting it lets doctor explain the loop
// instead of leaving the operator with a reconnect log.
func (c *Client) requireProtocolVersion(envelope Envelope) error {
	if envelope.ProtocolVersion == ProtocolVersion {
		return nil
	}
	message := fmt.Sprintf(
		"the control plane sent %s at protocol_version %d; this runner implements version %d",
		envelope.Type, envelope.ProtocolVersion, ProtocolVersion,
	)
	if c.opts.TerminalShutdownPath != "" {
		if err := WriteTerminalShutdown(
			c.opts.TerminalShutdownPath, ReasonProtocolVersionUnsupported, message,
		); err != nil {
			c.opts.Logger.Error("cloud.shutdown_state_write_failed",
				"reason", ReasonProtocolVersionUnsupported, "error", err)
		}
	}
	return fmt.Errorf("%w: %s", errProtocolVersionUnsupported, message)
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

const (
	dispatchUndecodableReason = "dispatch_undecodable"
	// The code leads the detail so a journal line names the classification on
	// its own, without the payload that produced it.
	dispatchUndecodableDetail = dispatchUndecodableReason +
		": message did not decode as a valid run_action; nothing was executed"
)

// refuseUndecodableDispatch journals — and, when the message carries a usable
// correlation id, answers — a dispatch rejected before it could become a
// RunActionMsg: an unreadable envelope, an oversized frame, duplicate or
// aliased keys, an invalid request_id. Those rejections never reach startRun,
// so no other path records them, and this is precisely the class a compromised
// control plane produces: without an entry the tamper-evident journal says the
// attempt never happened, and the portal sees only a dispatch timeout with no
// cause.
//
// Only the fixed rejection code is journaled and returned. The payload that
// failed to decode is untrusted and is never persisted — the same rule
// recordPreExecutionEvent applies to arguments that failed validation.
func (c *Client) refuseUndecodableDispatch(parent context.Context, requestID string) {
	ctx := context.WithoutCancel(parent)
	if err := validateRequestID(requestID); err != nil {
		// No correlation id to attribute a result to, so the journal entry is
		// the only durable record this attempt can leave.
		c.opts.Engine.RecordDispatchRefusal(ctx, engine.Request{}, dispatchUndecodableDetail)
		return
	}
	eventID := c.opts.Engine.RecordDispatchRefusal(
		ctx, engine.Request{ControlPlaneRequestID: requestID}, dispatchUndecodableDetail)

	c.mu.Lock()
	if _, exists := c.runs[requestID]; exists {
		c.mu.Unlock()
		// A live run already owns this correlation id. Its own terminal result
		// is authoritative and must not be pre-empted by a malformed re-send.
		c.opts.Logger.Warn("cloud.undecodable_dispatch_duplicate_id", "request_id", requestID)
		return
	}
	enqueued := c.enqueueTransientLocked(requestID, withLocalAudit(
		failedDispatchResult(requestID, dispatchUndecodableReason, dispatchUndecodableDetail),
		eventID,
	))
	c.mu.Unlock()
	if !enqueued {
		c.opts.Logger.Warn("cloud.undecodable_dispatch_not_queued", "request_id", requestID)
		return
	}
	c.signalSend()
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
