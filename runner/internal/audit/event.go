// Package audit implements the local JSONL security log. Every action attempt
// produces one terminal event; attempts that reach the process boundary first
// produce an execution_started event so a crash cannot erase evidence that
// execution began. The cloud control plane is the system of record for fleet
// audit; this log exists for on-host forensics.
package audit

import (
	"crypto/rand"
	"math/big"
	"time"
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

// CallerRef identifies the control-plane request that asked for the action.
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
// logic, this makes the retained file a tamper-evident hash chain: reordering,
// mutating, or deleting an interior line invalidates every entry after it.
// Tail truncation and a consistent whole-file replacement need an external
// anchor to detect.
type Event struct {
	PrevHash   string             `json:"prev_hash,omitempty"`
	EventID    string             `json:"event_id"`
	Time       time.Time          `json:"time"`
	Type       EventType          `json:"event_type"`
	Group      string             `json:"group,omitempty"`
	RunnerID   string             `json:"runner_id,omitempty"`
	Caller     CallerRef          `json:"caller,omitempty"`
	PackID     string             `json:"pack_id,omitempty"`
	ActionID   string             `json:"action_id,omitempty"`
	Request    *RequestInfo       `json:"request,omitempty"`
	Metadata   *MetadataInfo      `json:"metadata,omitempty"`
	Execution  *ExecutionInfo     `json:"execution,omitempty"`
	Redactions []RedactionSummary `json:"redactions,omitempty"`
	Error      string             `json:"error,omitempty"`
}

// crockford is ULID's alphabet: base32 without I, L, O or U, so a
// transcribed id cannot be confused with 1, 0 or V.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewID returns a fresh prefixed, lexicographically sortable id.
//
// This is ULID's layout — 48-bit big-endian millisecond timestamp then 80 bits
// of randomness, Crockford base32, 26 characters — implemented here rather than
// pulled from a dependency. It was the runner module's only use of
// github.com/oklog/ulid/v2, for one expression, and this module is
// CLIENT-SHIPPED: self-hosters build it and audit its go.sum, so a dependency
// carried for one line is their supply-chain surface, not just ours.
//
// The layout is kept rather than simplified to random bytes: the sort order is
// free here, and a journal id that sorts by creation time is worth having even
// though nothing in the runner currently relies on it.
func NewID(prefix string) string {
	var raw [16]byte
	millis := uint64(time.Now().UnixMilli())
	raw[0] = byte(millis >> 40)
	raw[1] = byte(millis >> 32)
	raw[2] = byte(millis >> 24)
	raw[3] = byte(millis >> 16)
	raw[4] = byte(millis >> 8)
	raw[5] = byte(millis)
	// crypto/rand, not math/rand: these land in an append-only security
	// journal, and a predictable suffix would let a forged line be addressed
	// before it is written. Read never fails per its contract.
	if _, err := rand.Read(raw[6:]); err != nil {
		panic("audit: entropy source unavailable: " + err.Error())
	}

	// 128 bits into 26 base32 characters: the first holds the top 2 bits, the
	// remaining 25 take 5 each.
	id := make([]byte, 26)
	id[0] = crockford[(raw[0]&224)>>5]
	bits := new(big.Int).SetBytes(raw[:])
	mask := big.NewInt(31)
	for i := 25; i >= 1; i-- {
		id[i] = crockford[new(big.Int).And(bits, mask).Int64()]
		bits.Rsh(bits, 5)
	}

	if prefix == "" {
		return string(id)
	}
	return prefix + "_" + string(id)
}
