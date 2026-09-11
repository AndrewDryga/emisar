package cloud

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

// The per-run gates a dispatch passes before the engine sees it — the signed
// dispatch decision and pack trust — and the run's own lifecycle either side of
// them. These already had their own test files (signature_test.go,
// trust_gate_test.go, gate_test.go); the source now has the same seam.

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

	// Authenticity first (did a customer-authorized bridge sign this dispatch?),
	// then pack integrity (do the on-disk bytes still match what was trusted?).
	if !c.passesSignatureGate(ctx, s, m) {
		return
	}

	registry, trusted := c.passesTrustGate(ctx, s, m)
	if !trusted {
		return
	}
	c.markRunStarted(s)

	progress := func(stream executor.Stream, line []byte) {
		c.enqueueProgress(s, m.RequestID, string(stream), string(line))
	}

	req := requestForDispatch(m, registry, progress)
	res, err := c.opts.Engine.Run(ctx, req)

	s.mu.Lock()
	dropped := s.dropped
	progressChunks := s.progressSeq
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
			EmittedStdoutBytes:       res.StdoutBytes,
			EmittedStderrBytes:       res.StderrBytes,
			ProgressChunks:           progressChunks,
			DroppedProgressChunks:    dropped,
			TruncatedOut:             res.TruncatedOut,
			TruncatedErr:             res.TruncatedErr,
			Reason:                   res.Reason,
			Error:                    res.Error,
			StructuredOutput:         res.StructuredOutput,
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
	c.updateRuntimeStatus(func(_ *RuntimeStatus, _ time.Time) {})
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
		c.updateRuntimeStatus(func(_ *RuntimeStatus, _ time.Time) {})
		c.opts.Logger.Error("cloud.dedup_persist_failed", "request_id", s.requestID, "error", err)
		c.signalSend()
		return
	}
	s.pending = append(s.pending, result)
	s.mu.Unlock()
	c.updateRuntimeStatus(func(_ *RuntimeStatus, _ time.Time) {})
	c.signalSend()
}

// passesSignatureGate verifies the bridge attestation when the operator turned
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
		Status:     resultStatusSignatureInvalid,
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
		c.emitPackMismatch(ctx, s, m, action.PackID, m.ExpectedPackHash, "pack_missing")
		return nil, false
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
		Status:     resultStatusPackHashMismatch,
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
			Timeout:        m.Opts.Timeout(),
			MaxStdoutBytes: m.Opts.MaxStdoutBytes,
			MaxStderrBytes: m.Opts.MaxStderrBytes,
		}
	}
	return req
}
