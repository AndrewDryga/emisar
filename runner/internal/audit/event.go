// Package audit implements the local JSONL security log. Every action attempt
// produces one terminal event; attempts that reach the process boundary first
// produce an execution_started event so a crash cannot erase evidence that
// execution began. The cloud control plane is the system of record for fleet
// audit; this log exists for on-host forensics.
package audit

import (
	"time"

	"github.com/oklog/ulid/v2"
)

// EventType is the set of event types written to the journal.
type EventType string

const (
	EventValidationFailed   EventType = "validation_failed"
	EventDispatchRefused    EventType = "dispatch_refused"
	EventExecutionStarted   EventType = "execution_started"
	EventExecutionCompleted EventType = "execution_completed"
	EventExecutionFailed    EventType = "execution_failed"
	EventActionCancelled    EventType = "action_cancelled"
	// EventActionBlockedByAdmission fires when the runner's local
	// allow/deny config refuses an action the cloud asked to run.
	// Separate event type so SIEM rules can alert on it directly —
	// every such row is either a misconfiguration or a portal-compromise
	// attempt.
	EventActionBlockedByAdmission EventType = "action_blocked_by_admission"
)

// CallerRef identifies who/what requested the action. For v0.1 this is the
// cloud control plane's request envelope.
type CallerRef struct {
	ControlPlaneRequestID string `json:"control_plane_request_id,omitempty"`
}

// RequestInfo captures the inputs supplied with the request.
type RequestInfo struct {
	ArgsSHA256   string         `json:"args_sha256,omitempty"`
	ArgsRedacted map[string]any `json:"args_redacted,omitempty"`
	Reason       string         `json:"reason,omitempty"`
}

// MetadataInfo is the static metadata snapshotted at the moment of execution.
type MetadataInfo struct {
	Kind string `json:"kind,omitempty"`
	Risk string `json:"risk,omitempty"`
}

// ExecutionInfo captures everything the runner knows about the process
// invocation. Stdout/stderr previews are bounded; hashes and byte counts cover
// the complete redacted output, never the pre-redaction secret-bearing bytes.
type ExecutionInfo struct {
	Binary        string   `json:"binary,omitempty"`
	Argv          []string `json:"argv,omitempty"`
	ArgvSHA256    string   `json:"argv_sha256,omitempty"`
	CWD           string   `json:"cwd,omitempty"`
	EnvKeys       []string `json:"env_keys,omitempty"`
	Timeout       string   `json:"timeout,omitempty"`
	ExitCode      int      `json:"exit_code"`
	DurationMS    int64    `json:"duration_ms"`
	TimedOut      bool     `json:"timed_out"`
	StdoutSHA256  string   `json:"stdout_sha256,omitempty"`
	StderrSHA256  string   `json:"stderr_sha256,omitempty"`
	StdoutPreview string   `json:"stdout_preview,omitempty"`
	StderrPreview string   `json:"stderr_preview,omitempty"`
	StdoutBytes   int      `json:"stdout_bytes"`
	StderrBytes   int      `json:"stderr_bytes"`
	ScriptSHA256  string   `json:"script_sha256,omitempty"`
	// ExecutedCommand is argv rendered as a shell-quoted string with
	// sensitive arg values masked. Argv and its digest use the same redacted
	// values; raw sensitive arguments are never durable audit data.
	ExecutedCommand string `json:"executed_command,omitempty"`
}

// RedactionSummary is the per-rule redaction count on this event.
type RedactionSummary struct {
	Name  string `json:"name"`
	Type  string `json:"type,omitempty"`
	Count int    `json:"count"`
}

// Event is one journal entry. The schema is deliberately flat — JSONL is
// for grep/jq/sed, not for indexed queries.
//
// PrevHash is the SHA-256 (hex) of the entire previous serialized line
// — minus the trailing newline. Together with the JSONL sink's restart
// logic, this makes the file a tamper-evident hash chain: cutting,
// reordering, or mutating any line invalidates every entry after it,
// which `emisar audit verify` will surface.
type Event struct {
	PrevHash   string             `json:"prev_hash,omitempty"`
	EventID    string             `json:"event_id"`
	Time       time.Time          `json:"time"`
	Type       EventType          `json:"event_type"`
	Group      string             `json:"group,omitempty"`
	AgentID    string             `json:"runner_id,omitempty"`
	Caller     CallerRef          `json:"caller,omitempty"`
	PackID     string             `json:"pack_id,omitempty"`
	ActionID   string             `json:"action_id,omitempty"`
	Request    *RequestInfo       `json:"request,omitempty"`
	Metadata   *MetadataInfo      `json:"metadata,omitempty"`
	Execution  *ExecutionInfo     `json:"execution,omitempty"`
	Redactions []RedactionSummary `json:"redactions,omitempty"`
	Error      string             `json:"error,omitempty"`
}

// NewID returns a fresh prefixed ULID for the given prefix.
func NewID(prefix string) string {
	id := ulid.Make().String()
	if prefix == "" {
		return id
	}
	return prefix + "_" + id
}
