// Package engine is the runner's action runtime: validate args, clamp
// cloud-supplied opts against per-action min/max bounds, execute through
// the executor (streaming progress if asked), redact output, journal.
//
// The control plane decides what should run; the engine independently enforces
// runner-local admission, the installed action contract, and execution limits.
package engine

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/expressions"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// Status is the top-level outcome of a single action call.
type Status string

const (
	StatusSuccess          Status = "success"
	StatusFailed           Status = "failed"
	StatusError            Status = "error"
	StatusValidationFailed Status = "validation_failed"
	StatusUnknownAction    Status = "unknown_action"
	StatusTimedOut         Status = "timed_out"
	StatusCancelled        Status = "cancelled"
	// StatusBlockedByAdmission is returned when the runner's local
	// allow/deny config refuses the action. Distinct from
	// `unknown_action` (the cloud asked for something the registry
	// doesn't know) — admission is "I know what this is, and the host
	// operator has decided this runner will not execute it."
	StatusBlockedByAdmission Status = "blocked_by_admission"
)

var resultStatuses = [...]Status{
	StatusSuccess,
	StatusFailed,
	StatusError,
	StatusValidationFailed,
	StatusUnknownAction,
	StatusTimedOut,
	StatusCancelled,
	StatusBlockedByAdmission,
}

// ResultStatuses returns every terminal status the engine can put in a Result.
// Callers use the copy to keep transport contracts exhaustive without exposing
// the package's internal backing array.
func ResultStatuses() []Status {
	return append([]Status(nil), resultStatuses[:]...)
}

// Opts are the cloud-supplied per-call overrides. Each is clamped against
// the action's declared min/max before use.
type Opts struct {
	Timeout        time.Duration
	MaxStdoutBytes int
	MaxStderrBytes int
}

// Request is the public input to Run.
type Request struct {
	ControlPlaneRequestID string
	ActionID              string
	Args                  map[string]any
	Reason                string
	Opts                  Opts
	// RegistrySnapshot pins resolution and execution to the registry whose pack
	// bytes the cloud dispatch gate just verified. Nil is for local callers that
	// intentionally use the engine's current registry.
	RegistrySnapshot *packs.Registry

	// OnProgress, if non-nil, is invoked from the executor goroutines with
	// each completed line of redacted output. The engine forwards lines to
	// the cloud over the websocket via this callback.
	OnProgress ProgressFunc
}

// ProgressFunc receives streamed output chunks (redacted, line-buffered).
type ProgressFunc func(stream executor.Stream, line []byte)

// Result is the durable, redacted result of one action call.
type Result struct {
	Status           Status          `json:"status"`
	EventID          string          `json:"event_id"`
	LocalAuditFailed bool            `json:"local_audit_failed,omitempty"`
	ActionID         string          `json:"action_id"`
	ExitCode         int             `json:"exit_code"`
	Stdout           string          `json:"stdout,omitempty"`
	Stderr           string          `json:"stderr,omitempty"`
	Output           any             `json:"output,omitempty"`
	StructuredOutput json.RawMessage `json:"structured_output,omitempty"`
	ParserError      string          `json:"parser_error,omitempty"`
	DurationMS       int64           `json:"duration_ms"`
	Redactions       []redact.Hit    `json:"redactions,omitempty"`
	Reason           string          `json:"reason,omitempty"`
	Error            string          `json:"error,omitempty"`
	TimedOut         bool            `json:"timed_out,omitempty"`
	StdoutSHA256     string          `json:"stdout_sha256,omitempty"`
	StderrSHA256     string          `json:"stderr_sha256,omitempty"`
	StdoutBytes      int             `json:"stdout_bytes,omitempty"`
	StderrBytes      int             `json:"stderr_bytes,omitempty"`
	TruncatedOut     bool            `json:"truncated_stdout,omitempty"`
	TruncatedErr     bool            `json:"truncated_stderr,omitempty"`
	// ExecutedCommand is the exact command that ran, shell-quoted, with
	// sensitive arg values masked. The cloud transport bounds its remote copy;
	// the local audit keeps this complete value.
	ExecutedCommand string `json:"executed_command,omitempty"`
}

// Engine wires the registry + executor + redactor + journal into a single
// orchestrator. The Registry is held behind atomic.Pointer so SIGHUP can
// swap it without locking out in-flight runs.
type Engine struct {
	registry atomic.Pointer[packs.Registry]
	// Reloads replace the policy snapshots used by subsequent actions without
	// interrupting actions that already passed admission.
	admission atomic.Pointer[admission.Policy]
	redactor  atomic.Pointer[redact.Engine]

	Executor     *executor.Executor
	Journal      *audit.Journal
	PreviewBytes int
	// CancelGrace is the per-action SIGTERM->SIGKILL window passed into
	// every executor.Plan. Defaults to executor.DefaultCancelGrace.
	CancelGrace time.Duration
	// PackDirs is the list passed to Reload. Set by the caller (CLI) on
	// engine construction so SIGHUP can pick up new packs from the same
	// places we boot-loaded from.
	PackDirs []string
	// ProtectedPaths are the runner's own configuration and state roots.
	// No action argument may name a path inside them, whatever its pack
	// declared — they hold the enrollment key, the operator's pack
	// credentials, and this runner's bearer token.
	ProtectedPaths []string
	// Logger is used for journal-write failures and other operational
	// signals. Defaults to slog.Default.
	Logger *slog.Logger
}

// Config bundles the construction-time dependencies for New.
type Config struct {
	Registry       *packs.Registry
	Executor       *executor.Executor
	Journal        *audit.Journal
	Redactor       *redact.Engine
	PreviewBytes   int
	CancelGrace    time.Duration
	PackDirs       []string
	Admission      *admission.Policy
	ProtectedPaths []string
	Logger         *slog.Logger
}

// New returns an Engine. PreviewBytes defaults to 4 KiB; Logger defaults
// to slog.Default.
func New(cfg Config) *Engine {
	if cfg.PreviewBytes <= 0 {
		cfg.PreviewBytes = 4096
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	e := &Engine{
		Executor:       cfg.Executor,
		Journal:        cfg.Journal,
		PreviewBytes:   cfg.PreviewBytes,
		CancelGrace:    cfg.CancelGrace,
		PackDirs:       cfg.PackDirs,
		ProtectedPaths: cfg.ProtectedPaths,
		Logger:         cfg.Logger,
	}
	e.registry.Store(cfg.Registry)
	e.admission.Store(cfg.Admission)
	e.redactor.Store(cfg.Redactor)
	return e
}

// Admission returns the runner-local allow/deny policy. Defense-in-depth on
// top of cloud policy: every Run call passes through Admit before the registry
// lookup. Nil means "admit everything" (the default, and what a nil Policy's
// own methods answer).
func (e *Engine) Admission() *admission.Policy { return e.admission.Load() }

// SetAdmission replaces the local admission policy — a config reload applies
// an operator's edited allow/deny/max_risk without restarting the daemon and
// killing its in-flight runs. A run that already passed admission keeps
// running; every later one is judged by the new policy.
func (e *Engine) SetAdmission(policy *admission.Policy) { e.admission.Store(policy) }

// Redactor returns the global output redaction engine (nil = none configured).
func (e *Engine) Redactor() *redact.Engine { return e.redactor.Load() }

// SetRedactor replaces the global rules for subsequent actions. An in-flight
// action keeps one redactor snapshot for its complete output.
func (e *Engine) SetRedactor(r *redact.Engine) { e.redactor.Store(r) }

// Registry returns the current pack registry. Safe to call from any
// goroutine. The returned pointer is a snapshot; do not retain it past
// the immediate use if you care about post-reload correctness.
func (e *Engine) Registry() *packs.Registry {
	return e.registry.Load()
}

// Reload re-runs pack discovery and atomically swaps the active
// registry. In-flight runs keep the registry pointer they captured on
// startup, so reload is non-disruptive. New runs see the fresh registry.
func (e *Engine) Reload() error {
	newReg, err := packs.LoadAll(e.PackDirs, packs.LoadOptions{Logger: e.Logger})
	if err != nil {
		return err
	}
	e.registry.Store(newReg)
	e.Logger.Info("engine.reloaded",
		"packs", len(newReg.Packs()),
		"actions", len(newReg.Actions()),
	)
	return nil
}

// journal records refusal and terminal events without changing their outcome.
// The execution_started event takes the strict recordJournal path below and
// must be durable before the process is allowed to start.
func (e *Engine) journal(ctx context.Context, ev audit.Event) audit.Event {
	rec, err := e.recordJournal(ctx, ev)
	if err != nil {
		rec.EventID = ""
	}
	return rec
}

func (e *Engine) recordJournal(ctx context.Context, ev audit.Event) (audit.Event, error) {
	rec, err := e.Journal.Record(ctx, ev)
	if err != nil {
		e.Logger.Error("audit.write_failed",
			"event_type", ev.Type,
			"action_id", ev.ActionID,
			"error", err,
		)
	}
	return rec, err
}

// RecordDispatchRefusal records a cloud dispatch that was rejected before Run.
func (e *Engine) RecordDispatchRefusal(ctx context.Context, req Request, detail string) string {
	return e.recordPreExecutionEvent(ctx, req, audit.EventDispatchRefused, detail).EventID
}

// RecordDispatchCancellation records a dispatch cancelled before process start.
func (e *Engine) RecordDispatchCancellation(ctx context.Context, req Request, detail string) string {
	return e.recordPreExecutionEvent(ctx, req, audit.EventActionCancelled, detail).EventID
}

// RecordExecutionFailure records a recovered failure outside Run's terminal paths.
func (e *Engine) RecordExecutionFailure(ctx context.Context, req Request, detail string) string {
	return e.recordPreExecutionEvent(ctx, req, audit.EventExecutionFailed, detail).EventID
}

func (e *Engine) recordPreExecutionEvent(ctx context.Context, req Request, eventType audit.EventType, detail string) audit.Event {
	ev := e.baseEvent(req, eventType, time.Now().UTC())
	ev.ActionID = req.ActionID
	ev.Request = &audit.RequestInfo{Reason: req.Reason}
	ev.Error = detail

	reg := req.RegistrySnapshot
	if reg == nil {
		reg = e.Registry()
	}
	if reg != nil {
		if act, ok := reg.Action(req.ActionID); ok {
			ev.PackID = act.PackID
			ev.ActionID = act.ID
			ev.Metadata = metaFor(act)
		}
	}
	// These events precede schema validation or pack verification. Never persist
	// their untrusted argument values, even when the current registry knows the
	// action and could redact them.
	return e.journal(ctx, ev)
}

// refuse journals a prepared refusal event and turns it into the Result that
// ends the run. The event is built by the CALLER on purpose: the refusals
// raised before an action is resolved and validated deliberately carry no
// PackID, Metadata or Request, because their argument values are still
// untrusted and must never reach the journal. Folding that decision in here
// would quietly widen what gets persisted, so this helper owns only the part
// that is genuinely identical — the journal call and the shape of the Result.
func (e *Engine) refuse(
	ctx context.Context,
	ev audit.Event,
	status Status,
	actionID string,
	reason string,
) *Result {
	journaled := e.journal(ctx, ev)
	return &Result{
		Status:           status,
		EventID:          journaled.EventID,
		LocalAuditFailed: journaled.EventID == "",
		ActionID:         actionID,
		Reason:           reason,
	}
}

// Run executes one action call end to end.
func (e *Engine) Run(ctx context.Context, req Request) (*Result, error) {
	now := time.Now().UTC()

	// Reason is mandatory. Operators and LLMs alike must record *why*
	// an action ran; without it the audit trail is half-useless.
	if strings.TrimSpace(req.Reason) == "" {
		ev := e.baseEvent(req, audit.EventValidationFailed, now)
		ev.ActionID = req.ActionID
		ev.Error = "reason required"
		return e.refuse(ctx, ev, StatusValidationFailed, req.ActionID, "reason required"), nil
	}

	// Admission check — defense in depth. The control plane already
	// decided this action should run; the host operator's local
	// allow/deny config gets the final word. A reject here is recorded
	// in the JSONL journal so a compromised-portal attack leaves a
	// tamper-evident host-side trail.
	//
	// One snapshot for both gates below: a reload landing between them must
	// not judge the id against one policy and the risk against another.
	policy := e.Admission()
	if ok, reason := policy.Admit(req.ActionID); !ok {
		ev := e.baseEvent(req, audit.EventActionBlockedByAdmission, now)
		ev.ActionID = req.ActionID
		ev.Error = reason
		return e.refuse(ctx, ev, StatusBlockedByAdmission, req.ActionID, reason), nil
	}

	reg := req.RegistrySnapshot
	if reg == nil {
		reg = e.Registry()
	}
	act, ok := reg.Action(req.ActionID)
	if !ok {
		ev := e.baseEvent(req, audit.EventValidationFailed, now)
		ev.ActionID = req.ActionID
		ev.Error = "unknown action"
		return e.refuse(ctx, ev, StatusUnknownAction, req.ActionID, "unknown action"), nil
	}

	// Risk-ceiling admission — defense in depth on the advertised catalog
	// filter. A too-risky action is hidden from cloud, but a stale or
	// compromised portal that dispatches it anyway is refused here, with a
	// host-side journal entry, exactly like an allow/deny block.
	if ok, reason := policy.AdmitRisk(act.Risk); !ok {
		ev := e.baseEvent(req, audit.EventActionBlockedByAdmission, now)
		ev.PackID = act.PackID
		ev.ActionID = act.ID
		ev.Metadata = metaFor(act)
		ev.Request = &audit.RequestInfo{Reason: req.Reason}
		ev.Error = reason
		return e.refuse(ctx, ev, StatusBlockedByAdmission, act.ID, reason), nil
	}

	cleanArgs, err := validation.Validate(act.Args, req.Args, e.ProtectedPaths)
	if err != nil {
		detail := validationFailureDetail(err, req.Args, act.Args)
		ev := e.baseEvent(req, audit.EventValidationFailed, now)
		ev.PackID = act.PackID
		ev.ActionID = act.ID
		ev.Metadata = metaFor(act)
		ev.Request = &audit.RequestInfo{Reason: req.Reason}
		ev.Error = detail
		return e.refuse(ctx, ev, StatusValidationFailed, act.ID, detail), nil
	}

	// Render argv/env templates against validated args.
	var renderedArgv []string
	switch act.Kind {
	case actionspec.KindExec:
		renderedArgv, err = expressions.RenderArgv(act.Execution.Command.Argv, cleanArgs)
	case actionspec.KindScript:
		renderedArgv, err = expressions.RenderArgv(act.Execution.Argv, cleanArgs)
	}
	if err != nil {
		return e.emitExecError(ctx, req, act, cleanArgs, err)
	}
	envRendered, err := expressions.RenderEnv(act.Execution.Env, cleanArgs)
	if err != nil {
		return e.emitExecError(ctx, req, act, cleanArgs, err)
	}

	limits := clampLimits(act, req.Opts)
	var (
		plan      executor.Plan
		scriptSHA string
	)
	switch act.Kind {
	case actionspec.KindExec:
		plan = executor.PlanForExec(act, renderedArgv, envRendered, limits)
	case actionspec.KindScript:
		si, ok := reg.ScriptInfo(act.ID)
		if !ok {
			return e.emitExecError(ctx, req, act, cleanArgs,
				fmt.Errorf("script for action %s missing from registry", act.ID))
		}
		// Re-verify the script bytes against the hash the loader recorded when
		// the pack was loaded and trusted, as close to exec as we can get. The
		// pack hash is the unit of trust (cloud refuses untrusted packs); if the
		// file on disk changed since load — a TOCTOU swap by anything with write
		// access to the pack dir — the trusted hash no longer describes what
		// we'd run. Refuse rather than execute unreviewed bytes.
		if err := verifyScriptSHA(si); err != nil {
			return e.emitExecError(ctx, req, act, cleanArgs, err)
		}
		scriptSHA = si.SHA256
		plan = executor.PlanForScript(act, si.Path, si.SHA256, renderedArgv, envRendered, limits)
	}
	if g := act.Execution.CancelGrace.Std(); g > 0 {
		plan.CancelGrace = g
	} else {
		plan.CancelGrace = e.CancelGrace
	}

	combinedRedactor := e.combinedRedactor(act, cleanArgs)
	// Every action that declares JSON output takes the structure-preserving
	// path, not only the ones that also declare parser_required or a schema:
	// text redaction of a JSON document lets an assignment-style rule eat a
	// string's closing quote, and the caller then gets a parser error on
	// exactly the runs whose output held a credential. redactJSONOutput falls
	// back to whole-text redaction on ErrInvalidJSON, so an action that
	// mislabels its output behaves as before.
	structuredJSON := act.Output.Parser == actionspec.ParserJSON

	// When the caller wants streaming, redact text chunks before they leave the
	// runner and accumulate the redacted bytes locally so the post-run code
	// (parser, audit journal, run result) sees exactly what the cloud does.
	// Required structured JSON stdout is the exception: hold its bounded raw
	// document until exit, redact its decoded strings, re-encode it, and only
	// then emit the valid document. Redaction is stateful per text stream: a
	// StreamRedactor holds back a
	// bounded tail so multi-line rules (e.g. a PEM private-key block streamed
	// one line at a time) still match across chunk boundaries. This matters
	// for confidentiality, not just tidiness — the cloud reassembles stored
	// output from these chunks (the result message omits it), so a per-chunk
	// redaction miss would be a permanent leak into the run record.
	streaming := req.OnProgress != nil
	var (
		stdoutBuf  = boundedOutput{limit: plan.Limits.MaxStdoutBytes}
		stderrBuf  = boundedOutput{limit: plan.Limits.MaxStderrBytes}
		rawJSONBuf strings.Builder
		outRed     *redact.StreamRedactor
		errRed     *redact.StreamRedactor
	)

	if streaming {
		if !structuredJSON {
			outRed = combinedRedactor.StreamRedactor()
		}
		errRed = combinedRedactor.StreamRedactor()
		// stdout and stderr stream from separate goroutines; serialize so the
		// redactors' state and the shared progress sink stay consistent.
		var mu sync.Mutex
		plan.OnChunk = func(stream executor.Stream, data []byte) {
			mu.Lock()
			defer mu.Unlock()
			if stream == executor.StreamStdout && structuredJSON {
				rawJSONBuf.Write(data)
				return
			}
			var sr *redact.StreamRedactor
			var buf *boundedOutput
			switch stream {
			case executor.StreamStdout:
				sr, buf = outRed, &stdoutBuf
			case executor.StreamStderr:
				sr, buf = errRed, &stderrBuf
			default:
				return
			}
			if emitted := sr.Write(data); len(emitted) > 0 {
				emitted = normalizeUTF8Bytes(emitted)
				if emitted = buf.take(emitted); len(emitted) > 0 {
					req.OnProgress(stream, emitted)
				}
			}
		}
	}

	started := e.baseEvent(req, audit.EventExecutionStarted, time.Now().UTC())
	started.PackID = act.PackID
	started.ActionID = act.ID
	started.Metadata = metaFor(act)
	started.Request = e.requestInfo(req, redactArgs(combinedRedactor, cleanArgs, act.Args))
	startArgv, startCommand := redactedInvocation(combinedRedactor, plan.Binary, plan.Argv, cleanArgs, act.Args)
	started.Execution = executionStartInfo(plan, scriptSHA, startArgv)
	started.Execution.ExecutedCommand = startCommand
	if _, err := e.recordJournal(ctx, started); err != nil {
		return &Result{
			Status:           StatusError,
			LocalAuditFailed: true,
			ActionID:         act.ID,
			Reason:           "local audit unavailable; action was not executed",
		}, nil
	}

	execRes, execErr := e.Executor.Execute(ctx, plan)
	if execErr != nil {
		return e.emitExecError(ctx, req, act, cleanArgs, execErr)
	}

	var (
		redactedStdout, redactedStderr string
		hits                           []redact.Hit
		jsonRedactionFailed            bool
		redactionOverflow              bool
	)

	if streaming {
		// Execute has returned, so both stream goroutines are done and no
		// further OnChunk can run — draining the held-back tails needs no lock.
		if structuredJSON {
			redactedStdout, hits, jsonRedactionFailed, redactionOverflow =
				redactJSONOutput(combinedRedactor, rawJSONBuf.String(), &stdoutBuf, execRes.Truncated.Stdout)
			if redactedStdout != "" {
				req.OnProgress(executor.StreamStdout, []byte(redactedStdout))
			}
		} else {
			if tail := outRed.Flush(execRes.Truncated.Stdout); len(tail) > 0 {
				tail = normalizeUTF8Bytes(tail)
				if tail = stdoutBuf.take(tail); len(tail) > 0 {
					req.OnProgress(executor.StreamStdout, tail)
				}
			}
			redactedStdout = stdoutBuf.String()
			hits = outRed.Hits()
		}
		if tail := errRed.Flush(execRes.Truncated.Stderr); len(tail) > 0 {
			tail = normalizeUTF8Bytes(tail)
			if tail = stderrBuf.take(tail); len(tail) > 0 {
				req.OnProgress(executor.StreamStderr, tail)
			}
		}
		redactedStderr = stderrBuf.String()
		hits = redact.MergeHits(hits, errRed.Hits())
	} else {
		var hs1, hs2 []redact.Hit
		if structuredJSON {
			redactedStdout, hs1, jsonRedactionFailed, redactionOverflow =
				redactJSONOutput(combinedRedactor, execRes.Stdout, &stdoutBuf, execRes.Truncated.Stdout)
		} else {
			redactedStdout, hs1 = combinedRedactor.ApplyOutput(execRes.Stdout, execRes.Truncated.Stdout)
			redactedStdout = normalizeUTF8String(redactedStdout)
			redactedStdout = string(stdoutBuf.take([]byte(redactedStdout)))
		}
		redactedStderr, hs2 = combinedRedactor.ApplyOutput(execRes.Stderr, execRes.Truncated.Stderr)
		redactedStderr = normalizeUTF8String(redactedStderr)
		redactedStderr = string(stderrBuf.take([]byte(redactedStderr)))
		hits = redact.MergeHits(hs1, hs2)
	}

	evType := audit.EventExecutionCompleted
	status := StatusSuccess
	if execRes.Status == executor.StatusTimeout {
		evType = audit.EventExecutionFailed
		status = StatusTimedOut
	} else if execRes.Status == executor.StatusCancelled {
		evType = audit.EventActionCancelled
		status = StatusCancelled
	} else if execRes.Status == executor.StatusFailed {
		evType = audit.EventExecutionFailed
		status = StatusError
	} else if execRes.ExitCode != 0 && !successExit(execRes.ExitCode, act.Execution.SuccessExitCodes) {
		status = StatusFailed
	}

	var (
		parsed           any
		structuredOutput json.RawMessage
		parserError      string
		resultError      string
		reason           = reasonForStatus(status, execRes)
	)
	if status == StatusSuccess && jsonRedactionFailed {
		status = StatusValidationFailed
		reason = "output_redaction_invalid_json"
		resultError = "output redaction could not preserve the JSON document"
		parserError = resultError
	} else if status == StatusSuccess && redactionOverflow {
		status = StatusValidationFailed
		reason = "output_redaction_exceeded_limit"
		resultError = "redacted structured output exceeded its byte limit"
		parserError = resultError
	} else if status == StatusSuccess && act.Output.HasSchema() {
		if execRes.Truncated.Stdout {
			status = StatusValidationFailed
			reason = "output_truncated"
			resultError = "structured output was truncated before validation"
			parserError = resultError
		} else {
			validator, ok := reg.OutputSchema(act.ID)
			if !ok {
				status = StatusValidationFailed
				reason = "output_schema_unavailable"
				resultError = "structured output schema is unavailable"
				parserError = resultError
			} else if value, raw, validationError := validator.Validate([]byte(redactedStdout)); validationError != nil {
				status = StatusValidationFailed
				reason = validationError.Code
				resultError = validationError.Message
				parserError = validationError.Message
			} else {
				parsed = value
				structuredOutput = raw
			}
		}
	} else if !act.Output.HasSchema() {
		parsed, parserError = parseOutput(act.Output.Parser, redactedStdout)
		if status == StatusSuccess && act.Output.ParserRequired && parserError != "" {
			status = StatusValidationFailed
			reason = "output_invalid_json"
			resultError = "required output is not valid JSON"
		}
	}
	if status == StatusValidationFailed {
		evType = audit.EventValidationFailed
	}

	// The exact command that ran, with sensitive arg values masked for every
	// durable or remote representation. Raw argv exists only inside the live
	// executor result and is discarded after this method returns.
	auditArgv, executedCommand := redactedInvocation(combinedRedactor, execRes.Binary, execRes.Argv, cleanArgs, act.Args)

	ev := e.baseEvent(req, evType, time.Now().UTC())
	ev.PackID = act.PackID
	ev.ActionID = act.ID
	ev.Metadata = metaFor(act)
	ev.Request = e.requestInfo(req, redactArgs(combinedRedactor, cleanArgs, act.Args))
	ev.Execution = e.executionInfo(execRes, redactedStdout, redactedStderr, scriptSHA, plan, auditArgv)
	ev.Execution.ExecutedCommand = executedCommand
	ev.Redactions = toAuditRedactions(hits)
	ev.Error = resultError
	journaled := e.journal(ctx, ev)

	return &Result{
		Status:           status,
		EventID:          journaled.EventID,
		LocalAuditFailed: journaled.EventID == "",
		ActionID:         act.ID,
		ExitCode:         execRes.ExitCode,
		Stdout:           redactedStdout,
		Stderr:           redactedStderr,
		Output:           parsed,
		StructuredOutput: structuredOutput,
		ParserError:      parserError,
		DurationMS:       execRes.DurationMS,
		Redactions:       hits,
		TimedOut:         execRes.TimedOut,
		Reason:           reason,
		Error:            resultError,
		StdoutSHA256:     hashOutput(redactedStdout),
		StderrSHA256:     hashOutput(redactedStderr),
		StdoutBytes:      len(redactedStdout),
		StderrBytes:      len(redactedStderr),
		TruncatedOut:     execRes.Truncated.Stdout || redactionOverflow || stdoutBuf.truncated,
		TruncatedErr:     execRes.Truncated.Stderr || stderrBuf.truncated,
		ExecutedCommand:  executedCommand,
	}, nil
}

// boundedOutput accumulates redacted output up to the action's declared byte
// limit and returns exactly what it kept, so the caller emits no more than
// that. The visible cap lives HERE rather than in the executor because a cap
// applied to raw bytes can cut a sensitive value in half: the literal rule
// synthesized for it then matches nothing and the prefix leaves the host
// unmasked. The redactor masks known literal prefixes when raw input was cut;
// this is where streamPipe's bounded line overshoot is taken back off.
type boundedOutput struct {
	limit     int
	buf       strings.Builder
	truncated bool
}

func (b *boundedOutput) take(data []byte) []byte {
	if b.truncated {
		return nil
	}
	room := b.limit - b.buf.Len()
	if room <= 0 {
		b.truncated = b.truncated || len(data) > 0
		return nil
	}
	if len(data) > room {
		for room > 0 && !utf8.RuneStart(data[room]) {
			room--
		}
		data = data[:room]
		b.truncated = true
	}
	b.buf.Write(data)
	return data
}

func (b *boundedOutput) String() string { return b.buf.String() }

// redactJSONOutput redacts stdout for an action declaring JSON output and
// applies its byte cap to the RESULT. A document that no longer fits is
// dropped rather than trimmed — half a JSON document is not a document, and
// the caller turns the overflow into a validation failure — while text from
// the invalid-JSON fallback is simply cut like any other text stream.
func redactJSONOutput(redactor *redact.Engine, raw string, output *boundedOutput, truncated bool) (string, []redact.Hit, bool, bool) {
	if truncated {
		// A truncated prefix may itself be valid JSON while ending inside a
		// known secret. Use prefix-aware text redaction; schema validation
		// independently refuses the executor's truncated output below.
		text, hits := redactor.ApplyOutput(raw, true)
		return string(output.take([]byte(normalizeUTF8String(text)))), hits, false, false
	}
	redacted, hits, err := redactor.ApplyJSON([]byte(raw))
	switch {
	case err == nil:
		if len(redacted) > output.limit {
			return "", hits, false, true
		}
		return string(redacted), hits, false, false
	case errors.Is(err, redact.ErrInvalidJSON):
		text, textHits := redactor.ApplyOutput(raw, truncated)
		return string(output.take([]byte(normalizeUTF8String(text)))), textHits, false, false
	default:
		return string(redacted), hits, true, false
	}
}

func normalizeUTF8Bytes(data []byte) []byte {
	if utf8.Valid(data) {
		return data
	}
	return bytes.ToValidUTF8(data, []byte("\uFFFD"))
}

func normalizeUTF8String(value string) string {
	if utf8.ValidString(value) {
		return value
	}
	return strings.ToValidUTF8(value, "\uFFFD")
}

func (e *Engine) emitExecError(ctx context.Context, req Request, act *actionspec.Action,
	cleanArgs map[string]any, err error) (*Result, error) {
	combinedRedactor := e.combinedRedactor(act, cleanArgs)
	detail := redactInvocationValue(combinedRedactor, err.Error(), cleanArgs, act.Args)
	ev := e.baseEvent(req, audit.EventExecutionFailed, time.Now().UTC())
	ev.PackID = act.PackID
	ev.ActionID = act.ID
	ev.Metadata = metaFor(act)
	ev.Request = e.requestInfo(req, redactArgs(combinedRedactor, cleanArgs, act.Args))
	ev.Error = detail
	journaled := e.journal(ctx, ev)
	return &Result{
		Status:           StatusError,
		EventID:          journaled.EventID,
		LocalAuditFailed: journaled.EventID == "",
		ActionID:         act.ID,
		Reason:           detail,
	}, nil
}

func (e *Engine) baseEvent(req Request, t audit.EventType, now time.Time) audit.Event {
	return audit.Event{
		Type: t,
		Time: now,
		Caller: audit.CallerRef{
			ControlPlaneRequestID: req.ControlPlaneRequestID,
		},
	}
}

func (e *Engine) requestInfo(req Request, redactedArgs map[string]any) *audit.RequestInfo {
	return &audit.RequestInfo{
		ArgsSHA256:   hashArgs(redactedArgs),
		ArgsRedacted: redactedArgs,
		Reason:       req.Reason,
	}
}

// redactArgs replaces any value declared `sensitive: true` with the
// literal "[REDACTED]". The audit event's args_sha256 is computed over
// this redacted map (see requestInfo), NOT the raw args — deliberately:
// writing a hash of a raw secret into the on-disk journal would let
// anyone who reads the file brute-force a low-entropy secret offline.
// The trade-off is that two runs with different secret values but
// otherwise-identical args share an args_sha256; that's the safe
// direction for a local audit log.
// redactArgs masks the arguments recorded in the journal and shipped to the
// cloud. Like redactedInvocation, it runs both the schema pass and the default
// rule net, so a credential in an unflagged arg is not stored verbatim — for
// every value shape the net can read, not just scalar strings. A string_array
// element goes into argv exactly like a scalar does, so masking one and not
// the other wrote the same bytes to the journal masked and in the clear.
func redactArgs(redactor *redact.Engine, args map[string]any, schema []actionspec.Arg) map[string]any {
	if len(args) == 0 {
		return args
	}

	sensitive := make(map[string]bool, len(schema))
	for _, a := range schema {
		if a.Sensitive {
			sensitive[a.Name] = true
		}
	}

	out := make(map[string]any, len(args))
	for k, v := range args {
		switch {
		case sensitive[k]:
			out[k] = "[REDACTED]"
		case redactor != nil:
			out[k] = redactArgValue(redactor, v)
		default:
			out[k] = v
		}
	}
	return out
}

func redactArgValue(redactor *redact.Engine, v any) any {
	switch typed := v.(type) {
	case string:
		masked, _ := redactor.Apply(typed)
		return masked
	case []string:
		masked := make([]string, len(typed))
		for i, s := range typed {
			masked[i], _ = redactor.Apply(s)
		}
		return masked
	case []any:
		masked := make([]any, len(typed))
		for i, item := range typed {
			masked[i] = redactArgValue(redactor, item)
		}
		return masked
	}
	return v
}

// redactedInvocation masks the command line for every durable or remote
// representation. Two passes, because they catch different things: the schema
// pass replaces the exact values of args declared `sensitive: true`, and the
// rule pass is the same default net that guards stdout (bearer tokens,
// GitHub tokens, `password=` assignments). Without the second pass a credential
// passed through an arg the author forgot to flag was written verbatim into
// the local journal AND the permanent cloud run record — while the identical
// bytes in the command's OUTPUT would have been masked.
func redactedInvocation(redactor *redact.Engine, binary string, argv []string, cleanArgs map[string]any, schema []actionspec.Arg) ([]string, string) {
	redactedArgv := make([]string, len(argv))
	parts := make([]string, 0, len(argv)+1)
	parts = append(parts, shellQuote(redactInvocationValue(redactor, binary, cleanArgs, schema)))
	for i, arg := range argv {
		redactedArgv[i] = redactInvocationValue(redactor, arg, cleanArgs, schema)
		parts = append(parts, shellQuote(redactedArgv[i]))
	}
	return redactedArgv, strings.Join(parts, " ")
}

// `redactor` is the action's combined redactor, which ALREADY carries the
// sensitive-argument set (combinedRedactor synthesizes it from the same args and
// schema). Masking those values here first as well was not belt-and-braces but a
// second pass over text the first had already masked: a value that is a
// substring of the marker ("ED" in "[REDACTED]") matched inside the marker the
// first pass wrote and rewrote it to "[R[REDACTED]ACT[REDACTED]]". So mask once,
// through the redactor, and fall back to the values alone only when there is no
// redactor to carry them.
func redactInvocationValue(redactor *redact.Engine, value string, args map[string]any, schema []actionspec.Arg) string {
	if redactor == nil {
		return redactSensitiveValues(value, args, schema)
	}
	masked, _ := redactor.Apply(value)
	return masked
}

// The one rule name for the whole sensitive-argument set. A pack may legally
// declare a rule with this name; the two sets are compiled separately so it is
// never deduped away.
const sensitiveArgsRule = "sensitive-args"

// Masks through the same single-pass set the output path uses, so the recorded
// command and the command's output hide a value identically — and so a secret
// that is a substring of the marker ("ED" in "[REDACTED]") cannot rewrite a
// marker an earlier secret left behind. This is also what the cloud's
// CommandPreview does for the same line.
func redactSensitiveValues(value string, args map[string]any, schema []actionspec.Arg) string {
	secrets := sensitiveValues(args, schema)
	if len(secrets) == 0 {
		return value
	}
	rule := redact.LiteralSet(sensitiveArgsRule, secrets, "[REDACTED]")
	masked, _ := redact.New([]redact.Rule{rule}).Apply(value)
	return masked
}

func validationFailureDetail(err error, args map[string]any, schema []actionspec.Arg) string {
	if validationErr, ok := err.(*validation.Error); ok {
		for _, arg := range schema {
			_, provided := args[arg.Name]
			if arg.Name == validationErr.Arg && arg.Sensitive && provided {
				return fmt.Sprintf("argument %s: rejected sensitive value (%s)", validationErr.Arg, validationErr.Code)
			}
		}
	}
	return redactSensitiveValues(err.Error(), args, schema)
}

// sensitiveValues returns the string forms of every arg the schema marks
// `sensitive: true`, so they can be masked out of the recorded command. A
// list-typed sensitive arg expands into separate argv tokens (RenderArgv), so
// each element is its own secret — the bracketed "%v" whole form never appears
// as a token on its own, and masking only that would leave the raw elements in
// executed_command. We add both: the per-element tokens (via ArgStrings, which
// mirrors the exact rendering) and the whole "%v" form as defense-in-depth for
// any context that stringifies the value as one blob.
func sensitiveValues(args map[string]any, schema []actionspec.Arg) []string {
	var out []string
	seen := make(map[string]struct{})
	add := func(s string) {
		if s == "" {
			return
		}
		if _, ok := seen[s]; ok {
			return
		}
		seen[s] = struct{}{}
		out = append(out, s)
	}
	for _, a := range schema {
		if !a.Sensitive {
			continue
		}
		v, ok := args[a.Name]
		if !ok {
			continue
		}
		for _, s := range expressions.ArgStrings(v) {
			add(s)
		}
		add(fmt.Sprintf("%v", v))
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

// shellQuote makes an argv element safe + readable to paste into a shell:
// bare when it's plain, single-quoted (with embedded quotes escaped) otherwise.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}

	bare := strings.IndexFunc(s, func(r rune) bool {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return false
		case r == '-' || r == '_' || r == '.' || r == '/' || r == ':' || r == '=' || r == '@' || r == ',' || r == '+':
			return false
		default:
			return true
		}
	}) == -1

	if bare {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// verifyScriptSHA re-hashes the on-disk script and compares it to the hash the
// pack loader recorded at trust time, closing the gap between "the bytes we
// trust" and "the bytes we execute". A mismatch means the file changed after
// the pack was loaded. An empty recorded hash means checksums were disabled at
// load (an explicit operator opt-out), so there is nothing to verify against.
//
// This shrinks the TOCTOU window from load-to-exec down to hash-to-exec; a
// truly atomic guarantee would need fexecve of an already-open fd, which Go
// does not expose portably.
func verifyScriptSHA(si packs.ScriptInfo) error {
	if si.SHA256 == "" {
		return nil
	}
	data, err := os.ReadFile(si.Path)
	if err != nil {
		return fmt.Errorf("re-read script for integrity check: %w", err)
	}
	sum := sha256.Sum256(data)
	if got := hex.EncodeToString(sum[:]); got != si.SHA256 {
		return fmt.Errorf("script %s changed on disk since the pack was trusted "+
			"(sha256 %s != trusted %s); refusing to execute", si.Path, got, si.SHA256)
	}
	return nil
}

// combinedRedactor masks validated sensitive argument values before applying
// the action and global rules. Sensitive values may be echoed by a child
// process, so argv masking alone is not a complete confidentiality boundary.
func (e *Engine) combinedRedactor(act *actionspec.Action, cleanArgs map[string]any) *redact.Engine {
	// One snapshot of the global rules for this action's whole output.
	global := e.Redactor()
	if global == nil {
		global = redact.Empty()
	}
	secrets := sensitiveValues(cleanArgs, act.Args)
	if len(secrets) == 0 && len(act.Output.Redact) == 0 {
		return global
	}

	// ONE rule for the whole sensitive set, masking in a single pass. As one
	// literal rule per value they ran in sequence, so a value that is a substring
	// of the marker rewrote the marker an earlier value left behind —
	// "[R[REDACTED]ACT[REDACTED]]" in the journal and in what the portal shows.
	// A pack may declare a rule named the same thing, and CompileAll drops later
	// duplicates by name (how an author overrides a rule deliberately), so the
	// authored set is compiled separately and appended; the two have no override
	// relationship and both must apply.
	var rules []redact.Rule
	if len(secrets) > 0 {
		rules = append(rules, redact.LiteralSet(sensitiveArgsRule, secrets, "[REDACTED]"))
	}

	// Authored rules compile at pack load (actionspec.RedactionRule.Validate),
	// so a loaded action cannot fail here; a rule that somehow did not compile
	// is dropped rather than taking the sensitive set down with it.
	authored, _ := redact.CompileAll(act.Output.Redact)
	return global.Extend(append(rules, authored...))
}

func (e *Engine) executionInfo(r *executor.Result, redactedStdout, redactedStderr, scriptSHA string, plan executor.Plan, auditArgv []string) *audit.ExecutionInfo {
	return &audit.ExecutionInfo{
		Binary:        r.Binary,
		Argv:          append([]string(nil), auditArgv...),
		ArgvSHA256:    argvSHA256(r.Binary, auditArgv),
		CWD:           r.CWD,
		EnvKeys:       r.EnvKeys,
		Timeout:       plan.Limits.Timeout.String(),
		ExitCode:      r.ExitCode,
		DurationMS:    r.DurationMS,
		TimedOut:      r.TimedOut,
		StdoutSHA256:  hashOutput(redactedStdout),
		StderrSHA256:  hashOutput(redactedStderr),
		StdoutBytes:   len(redactedStdout),
		StderrBytes:   len(redactedStderr),
		StdoutPreview: truncatePreview(redactedStdout, e.PreviewBytes),
		StderrPreview: truncatePreview(redactedStderr, e.PreviewBytes),
		ScriptSHA256:  scriptSHA,
	}
}

func executionStartInfo(plan executor.Plan, scriptSHA string, auditArgv []string) *audit.ExecutionInfo {
	envKeys := make([]string, 0, len(plan.Env))
	for key := range plan.Env {
		envKeys = append(envKeys, key)
	}
	sort.Strings(envKeys)
	return &audit.ExecutionInfo{
		Binary:       plan.Binary,
		Argv:         append([]string(nil), auditArgv...),
		ArgvSHA256:   argvSHA256(plan.Binary, auditArgv),
		CWD:          plan.CWD,
		EnvKeys:      envKeys,
		Timeout:      plan.Limits.Timeout.String(),
		ScriptSHA256: scriptSHA,
	}
}

func argvSHA256(binary string, argv []string) string {
	joined := strings.Join(append([]string{binary}, argv...), "\x00")
	digest := sha256.Sum256([]byte(joined))
	return hex.EncodeToString(digest[:])
}

// clampLimits resolves the actual per-call limits. For each field the
// action declares a default plus optional min/max; opts overrides clamp
// inside that envelope. Unset min/max means the override isn't allowed
// (the default wins).
func clampLimits(act *actionspec.Action, opts Opts) executor.Limits {
	limits := executor.Limits{
		Timeout:        act.Execution.Timeout.Std(),
		MaxStdoutBytes: act.Output.MaxStdoutBytes,
		MaxStderrBytes: act.Output.MaxStderrBytes,
	}
	if opts.Timeout > 0 {
		lo := act.Execution.TimeoutMin.Std()
		if lo == 0 {
			lo = limits.Timeout
		}
		hi := act.Execution.TimeoutMax.Std()
		if hi == 0 {
			hi = limits.Timeout
		}
		limits.Timeout = clampDur(opts.Timeout, lo, hi)
	}
	if opts.MaxStdoutBytes > 0 {
		limits.MaxStdoutBytes = clampInt(opts.MaxStdoutBytes,
			fallbackInt(act.Output.MaxStdoutBytesMin, limits.MaxStdoutBytes),
			fallbackInt(act.Output.MaxStdoutBytesMax, limits.MaxStdoutBytes))
	}
	if opts.MaxStderrBytes > 0 {
		limits.MaxStderrBytes = clampInt(opts.MaxStderrBytes,
			fallbackInt(act.Output.MaxStderrBytesMin, limits.MaxStderrBytes),
			fallbackInt(act.Output.MaxStderrBytesMax, limits.MaxStderrBytes))
	}
	return limits
}

func clampDur(v, lo, hi time.Duration) time.Duration {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func fallbackInt(v, fallback int) int {
	if v <= 0 {
		return fallback
	}
	return v
}

func metaFor(a *actionspec.Action) *audit.MetadataInfo {
	return &audit.MetadataInfo{
		Kind: string(a.Kind),
		Risk: string(a.Risk),
	}
}

func toAuditRedactions(hits []redact.Hit) []audit.RedactionSummary {
	out := make([]audit.RedactionSummary, 0, len(hits))
	for _, h := range hits {
		out = append(out, audit.RedactionSummary{Name: h.Name, Type: h.Type, Count: h.Count})
	}
	return out
}

func parseOutput(parser actionspec.Parser, stdout string) (any, string) {
	if parser != actionspec.ParserJSON {
		return nil, ""
	}
	var v any
	if err := json.Unmarshal([]byte(stdout), &v); err != nil {
		return nil, err.Error()
	}
	return v, ""
}

// successExit reports whether a non-zero exit code was declared benign for
// this action via execution.success_exit_codes (e.g. iscsiadm's 21 for "no
// active sessions"). The list is an exact allowlist — an undeclared non-zero
// code still fails, so this never relaxes the executor to "any non-zero is
// success".
func successExit(code int, allow []int) bool {
	for _, c := range allow {
		if c == code {
			return true
		}
	}
	return false
}

func reasonForStatus(s Status, r *executor.Result) string {
	switch {
	case s == StatusSuccess:
		return ""
	case s == StatusTimedOut:
		return "execution timed out"
	case s == StatusCancelled:
		return "execution cancelled"
	case r.Status == executor.StatusFailed:
		return r.StartError
	case r.ExitCode != 0:
		return fmt.Sprintf("process exited with code %d", r.ExitCode)
	}
	return ""
}

func truncatePreview(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	for max > 0 && !utf8.RuneStart(s[max]) {
		max--
	}
	return s[:max] + "\n...[truncated]"
}

// hashArgs returns SHA-256 hex of args encoded as canonical JSON (sorted
// keys) for the local audit event.
func hashArgs(args map[string]any) string {
	b, err := json.Marshal(args)
	if err != nil {
		return "unhashable"
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func hashOutput(output string) string {
	h := sha256.Sum256([]byte(output))
	return hex.EncodeToString(h[:])
}
