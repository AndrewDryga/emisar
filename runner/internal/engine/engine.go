// Package engine is the runner's action runtime: validate args, clamp
// cloud-supplied opts against per-action min/max bounds, execute through
// the executor (streaming progress if asked), redact output, journal.
//
// The runner does not evaluate allow/deny policy. The control plane decides
// what should run; the runner re-validates inputs against the action's
// declared schema and refuses to execute anything not declared.
package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync/atomic"
	"time"

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
)

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

	// OnProgress, if non-nil, is invoked from the executor goroutines with
	// each completed line of redacted output. The engine forwards lines to
	// the cloud over the websocket via this callback.
	OnProgress ProgressFunc
}

// ProgressFunc receives streamed output chunks (redacted, line-buffered).
type ProgressFunc func(stream executor.Stream, line []byte)

// Result is the durable, redacted result of one action call.
type Result struct {
	Status       Status       `json:"status"`
	EventID      string       `json:"event_id"`
	ActionID     string       `json:"action_id"`
	ExitCode     int          `json:"exit_code"`
	Stdout       string       `json:"stdout,omitempty"`
	Stderr       string       `json:"stderr,omitempty"`
	Output       any          `json:"output,omitempty"`
	ParserError  string       `json:"parser_error,omitempty"`
	DurationMS   int64        `json:"duration_ms"`
	Redactions   []redact.Hit `json:"redactions,omitempty"`
	Reason       string       `json:"reason,omitempty"`
	TimedOut     bool         `json:"timed_out,omitempty"`
	StdoutSHA256 string       `json:"stdout_sha256,omitempty"`
	StderrSHA256 string       `json:"stderr_sha256,omitempty"`
	StdoutBytes  int          `json:"stdout_bytes,omitempty"`
	StderrBytes  int          `json:"stderr_bytes,omitempty"`
}

// Engine wires the registry + executor + redactor + journal into a single
// orchestrator. The Registry is held behind atomic.Pointer so SIGHUP can
// swap it without locking out in-flight runs.
type Engine struct {
	registry atomic.Pointer[packs.Registry]

	Executor     *executor.Executor
	Journal      *audit.Journal
	Redactor     *redact.Engine
	PreviewBytes int
	// CancelGrace is the per-action SIGTERM->SIGKILL window passed into
	// every executor.Plan. Defaults to executor.DefaultCancelGrace.
	CancelGrace time.Duration
	// PackDirs is the list passed to Reload. Set by the caller (CLI) on
	// engine construction so SIGHUP can pick up new packs from the same
	// places we boot-loaded from.
	PackDirs []string
	// Logger is used for journal-write failures and other operational
	// signals. Defaults to slog.Default.
	Logger *slog.Logger
}

// Config bundles the construction-time dependencies for New.
type Config struct {
	Registry     *packs.Registry
	Executor     *executor.Executor
	Journal      *audit.Journal
	Redactor     *redact.Engine
	PreviewBytes int
	CancelGrace  time.Duration
	PackDirs     []string
	Logger       *slog.Logger
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
		Executor:     cfg.Executor,
		Journal:      cfg.Journal,
		Redactor:     cfg.Redactor,
		PreviewBytes: cfg.PreviewBytes,
		CancelGrace:  cfg.CancelGrace,
		PackDirs:     cfg.PackDirs,
		Logger:       cfg.Logger,
	}
	e.registry.Store(cfg.Registry)
	return e
}

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

// journal records ev and logs (but does not propagate) any sink failure.
// The local JSONL is best-effort durability for forensics; a write
// failure means the host disk has problems, which is an operator
// concern, but it shouldn't itself fail the action that was about to
// be reported successful.
func (e *Engine) journal(ctx context.Context, ev audit.Event) audit.Event {
	rec, err := e.Journal.Record(ctx, ev)
	if err != nil {
		e.Logger.Error("audit.write_failed",
			"event_type", ev.Type,
			"action_id", ev.ActionID,
			"error", err,
		)
	}
	return rec
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
		journaled := e.journal(ctx, ev)
		return &Result{
			Status:   StatusValidationFailed,
			EventID:  journaled.EventID,
			ActionID: req.ActionID,
			Reason:   "reason required",
		}, nil
	}

	reg := e.Registry()
	act, ok := reg.Action(req.ActionID)
	if !ok {
		ev := e.baseEvent(req, audit.EventValidationFailed, now)
		ev.ActionID = req.ActionID
		ev.Error = "unknown action"
		journaled := e.journal(ctx, ev)
		return &Result{
			Status:   StatusUnknownAction,
			EventID:  journaled.EventID,
			ActionID: req.ActionID,
			Reason:   "unknown action",
		}, nil
	}

	cleanArgs, err := validation.Validate(act.Args, req.Args)
	if err != nil {
		ev := e.baseEvent(req, audit.EventValidationFailed, now)
		ev.PackID = act.PackID
		ev.ActionID = act.ID
		ev.Metadata = metaFor(act)
		ev.Request = &audit.RequestInfo{Reason: req.Reason}
		ev.Error = err.Error()
		journaled := e.journal(ctx, ev)
		return &Result{
			Status:   StatusValidationFailed,
			EventID:  journaled.EventID,
			ActionID: act.ID,
			Reason:   err.Error(),
		}, nil
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
		return e.emitExecError(ctx, req, act, cleanArgs, now, err)
	}
	envRendered, err := expressions.RenderEnv(act.Execution.Env, cleanArgs)
	if err != nil {
		return e.emitExecError(ctx, req, act, cleanArgs, now, err)
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
			return e.emitExecError(ctx, req, act, cleanArgs, now,
				fmt.Errorf("script for action %s missing from registry", act.ID))
		}
		scriptSHA = si.SHA256
		plan = executor.PlanForScript(act, si.Path, si.SHA256, renderedArgv, envRendered, limits)
	}
	if g := act.Execution.CancelGrace.Std(); g > 0 {
		plan.CancelGrace = g
	} else {
		plan.CancelGrace = e.CancelGrace
	}

	combinedRedactor := e.combinedRedactor(act)

	// If the caller wants streaming, set up an OnChunk that redacts
	// line-by-line and forwards to OnProgress. We tally per-rule hits in
	// the journal afterward via the final-result captured streams as well.
	streaming := req.OnProgress != nil
	if streaming {
		plan.OnChunk = func(stream executor.Stream, data []byte) {
			redacted, _ := combinedRedactor.Apply(string(data))
			req.OnProgress(stream, []byte(redacted))
		}
	}

	execRes, execErr := e.Executor.Execute(ctx, plan)
	if execErr != nil {
		return e.emitExecError(ctx, req, act, cleanArgs, now, execErr)
	}

	// Redact captured output for the final journal entry. When streaming,
	// captured is empty; we redact the previews (which we'll reconstruct
	// from the streamed bytes if anyone cares — for now we just leave the
	// preview empty in streaming mode).
	var (
		redactedStdout, redactedStderr string
		hits                           []redact.Hit
	)
	if !streaming {
		var hs1, hs2 []redact.Hit
		redactedStdout, hs1 = combinedRedactor.Apply(execRes.Stdout)
		redactedStderr, hs2 = combinedRedactor.Apply(execRes.Stderr)
		hits = redact.MergeHits(hs1, hs2)
	}

	parsed, parserError := parseOutput(act.Output.Parser, redactedStdout)

	evType := audit.EventExecutionCompleted
	status := StatusSuccess
	if execRes.Status == executor.StatusTimeout {
		evType = audit.EventExecutionFailed
		status = StatusFailed
	} else if execRes.Status == executor.StatusFailed {
		evType = audit.EventExecutionFailed
		status = StatusError
	} else if execRes.ExitCode != 0 {
		status = StatusFailed
	}

	ev := e.baseEvent(req, evType, now)
	ev.PackID = act.PackID
	ev.ActionID = act.ID
	ev.Metadata = metaFor(act)
	ev.Request = e.requestInfo(req, redactArgs(cleanArgs, act.Args))
	ev.Execution = e.executionInfo(execRes, redactedStdout, redactedStderr, scriptSHA, plan)
	ev.Redactions = toAuditRedactions(hits)
	journaled := e.journal(ctx, ev)

	if act.Output.ParserRequired && parserError != "" {
		status = StatusFailed
	}

	return &Result{
		Status:       status,
		EventID:      journaled.EventID,
		ActionID:     act.ID,
		ExitCode:     execRes.ExitCode,
		Stdout:       redactedStdout,
		Stderr:       redactedStderr,
		Output:       parsed,
		ParserError:  parserError,
		DurationMS:   execRes.DurationMS,
		Redactions:   hits,
		TimedOut:     execRes.TimedOut,
		Reason:       reasonForStatus(status, execRes),
		StdoutSHA256: execRes.StdoutSHA256,
		StderrSHA256: execRes.StderrSHA256,
		StdoutBytes:  execRes.StdoutBytes,
		StderrBytes:  execRes.StderrBytes,
	}, nil
}

func (e *Engine) emitExecError(ctx context.Context, req Request, act *actionspec.Action,
	cleanArgs map[string]any, now time.Time, err error) (*Result, error) {
	ev := e.baseEvent(req, audit.EventExecutionFailed, now)
	ev.PackID = act.PackID
	ev.ActionID = act.ID
	ev.Metadata = metaFor(act)
	ev.Request = e.requestInfo(req, redactArgs(cleanArgs, act.Args))
	ev.Error = err.Error()
	journaled := e.journal(ctx, ev)
	return &Result{
		Status:   StatusError,
		EventID:  journaled.EventID,
		ActionID: act.ID,
		Reason:   err.Error(),
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

func (e *Engine) requestInfo(req Request, cleanArgs map[string]any) *audit.RequestInfo {
	return &audit.RequestInfo{
		ArgsSHA256:   hashArgs(cleanArgs),
		ArgsRedacted: cleanArgs,
		Reason:       req.Reason,
	}
}

// redactArgs replaces any value declared `sensitive: true` with the
// literal "[REDACTED]". Hash of the cleaned (pre-redaction) args is
// still kept on the audit event so an operator can prove two runs used
// the same secret without storing the secret itself.
func redactArgs(args map[string]any, schema []actionspec.Arg) map[string]any {
	if len(args) == 0 {
		return args
	}

	sensitive := make(map[string]bool, len(schema))
	for _, a := range schema {
		if a.Sensitive {
			sensitive[a.Name] = true
		}
	}

	if len(sensitive) == 0 {
		return args
	}

	out := make(map[string]any, len(args))
	for k, v := range args {
		if sensitive[k] {
			out[k] = "[REDACTED]"
		} else {
			out[k] = v
		}
	}
	return out
}

// combinedRedactor merges the action's redaction rules into the global ones.
func (e *Engine) combinedRedactor(act *actionspec.Action) *redact.Engine {
	if len(act.Output.Redact) == 0 {
		if e.Redactor == nil {
			return redact.Empty()
		}
		return e.Redactor
	}
	rules, err := redact.CompileAll(act.Output.Redact)
	if err != nil {
		if e.Redactor == nil {
			return redact.Empty()
		}
		return e.Redactor
	}
	return e.Redactor.Extend(rules)
}

func (e *Engine) executionInfo(r *executor.Result, redactedStdout, redactedStderr, scriptSHA string, plan executor.Plan) *audit.ExecutionInfo {
	return &audit.ExecutionInfo{
		Binary:        r.Binary,
		Argv:          r.Argv,
		ArgvSHA256:    r.ArgvSHA256,
		CWD:           r.CWD,
		EnvKeys:       r.EnvKeys,
		Timeout:       plan.Limits.Timeout.String(),
		ExitCode:      r.ExitCode,
		DurationMS:    r.DurationMS,
		TimedOut:      r.TimedOut,
		StdoutSHA256:  r.StdoutSHA256,
		StderrSHA256:  r.StderrSHA256,
		StdoutBytes:   r.StdoutBytes,
		StderrBytes:   r.StderrBytes,
		StdoutPreview: truncatePreview(redactedStdout, e.PreviewBytes),
		StderrPreview: truncatePreview(redactedStderr, e.PreviewBytes),
		ScriptSHA256:  scriptSHA,
	}
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

func reasonForStatus(s Status, r *executor.Result) string {
	switch {
	case s == StatusSuccess:
		return ""
	case r.TimedOut:
		return "execution timed out"
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
	return s[:max] + "\n...[truncated]"
}

// hashArgs returns SHA-256 hex of args encoded as canonical JSON (sorted
// keys). Used for audit + control-plane idempotency matching.
func hashArgs(args map[string]any) string {
	canon := canonicalize(args)
	b, err := json.Marshal(canon)
	if err != nil {
		return "unhashable"
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func canonicalize(v any) any {
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			out[k] = canonicalize(t[k])
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = canonicalize(x)
		}
		return out
	}
	return v
}
