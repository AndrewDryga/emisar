// Package cloud defines the wire protocol between the runner and the control
// plane plus the websocket client that carries it.
//
// All messages are JSON envelopes carried over a TLS websocket initiated by
// the runner (no inbound port on the host). The control plane is the only
// peer; there is no peer-to-peer runner traffic.
//
// Protocol versioning: every message carries protocol_version. Unknown
// message types are silently ignored (so an old runner can tolerate a newer
// cloud that learned new messages). Schema additions inside a known message
// type are tolerated via "ignore unknown fields" JSON decoding.
package cloud

import (
	"encoding/json"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// ProtocolVersion is the current wire-protocol revision.
const ProtocolVersion = 1

// MessageType is the discriminant on every envelope.
type MessageType string

const (
	// Cloud -> Runner
	MsgRunAction MessageType = "run_action"
	MsgCancel    MessageType = "cancel"
	MsgAckResult MessageType = "ack_result"

	// Runner -> Cloud
	MsgRunnerState    MessageType = "runner_state"
	MsgActionProgress MessageType = "action_progress"
	MsgActionResult   MessageType = "action_result"
	MsgHeartbeat      MessageType = "heartbeat"
	MsgError          MessageType = "error"
)

// Envelope is the common header on every wire message.
type Envelope struct {
	Type            MessageType `json:"type"`
	ProtocolVersion int         `json:"protocol_version"`
	// RequestID correlates request/response pairs for action calls. It also
	// identifies which action a Cancel or AckResult message refers to.
	RequestID string `json:"request_id,omitempty"`
}

// RunActionMsg asks the runner to execute an action. Cloud has already
// evaluated its policy; the runner re-validates args against the action's
// declared schema and refuses if anything is off.
//
// ExpectedPackHash is the trust-pinned pack hash the cloud last accepted
// for this action's pack/version. The runner re-hashes its on-disk pack
// and refuses the dispatch if the value doesn't match — that closes the
// TOCTOU window between the last RunnerStateMsg broadcast and execution
// (someone edited files on disk after the runner advertised its hash).
// Empty when the cloud has no trusted hash on file (e.g. very early
// observation, or the runner hasn't sent a state yet); runner skips the
// check in that case.
type RunActionMsg struct {
	Envelope
	ActionID         string         `json:"action_id"`
	Args             map[string]any `json:"args,omitempty"`
	Opts             *RunOpts       `json:"opts,omitempty"`
	Reason           string         `json:"reason,omitempty"`
	ExpectedPackHash string         `json:"expected_pack_hash,omitempty"`
	// Attestation is the client signature an enforcing runner requires. The
	// cloud RELAYS it from the originating MCP call; it cannot forge or alter
	// it. Nil on portal-originated dispatch (operator/runbook), which an
	// enforcing runner refuses. See internal/signing.
	Attestation *Attestation `json:"attestation,omitempty"`
}

// Attestation is the signed envelope binding a dispatch to a real user's MCP
// call. The runner reconstructs the signed claim from the run_action's
// action_id + args plus these nonce/issued_at fields and verifies Signature
// against the leaf key the CA-signed Cert vouches for. The control plane only
// relays this — it holds no key and cannot forge or alter it. See internal/attest
// for the canonical encoding shared with the mcp signer.
type Attestation struct {
	Signature string       `json:"sig"`
	Nonce     string       `json:"nonce"`
	IssuedAt  string       `json:"issued_at"`
	Cert      *attest.Cert `json:"cert,omitempty"`
}

// RunOpts is the per-call override envelope. Each field is clamped to the
// action's declared min/max bounds before use.
type RunOpts struct {
	Timeout        actionspec.Duration `json:"timeout,omitempty"`
	MaxStdoutBytes int                 `json:"max_stdout_bytes,omitempty"`
	MaxStderrBytes int                 `json:"max_stderr_bytes,omitempty"`
}

// CancelMsg asks the runner to terminate a running action. The runner
// SIGTERMs, then SIGKILLs after a grace window; a final ActionResultMsg
// still goes out with status="cancelled".
type CancelMsg struct {
	Envelope
}

// AckResultMsg confirms cloud received an ActionResultMsg. The runner flips
// the corresponding JSONL event's upload status to "acked" and can prune
// it from its outbox replay window.
type AckResultMsg struct {
	Envelope
}

// RunnerStateMsg is the self-description sent on connect and on pack reload.
// Actions are the primary surface; pack metadata is a side index for cloud
// UI grouping.
//
// Group is the cloud's primary auto-grouping key — every runner in the
// same Group is displayed together in the cloud UI without operator
// configuration. Labels are free-form additional tags.
type RunnerStateMsg struct {
	Envelope
	AgentID  string              `json:"runner_id"`
	Version  string              `json:"version"`
	Hostname string              `json:"hostname,omitempty"`
	Group    string              `json:"group"`
	Labels   map[string]string   `json:"labels,omitempty"`
	Packs    map[string]PackInfo `json:"packs,omitempty"`
	Actions  []ActionDescriptor  `json:"actions"`
	// EnforceSignatures advertises that this runner verifies a client signature
	// on every dispatch and refuses unsigned ones. The cloud responds by
	// disabling its own (operator/runbook) dispatch to this runner.
	EnforceSignatures bool `json:"enforce_signatures,omitempty"`
	// SigningCAIDs + MaxAttestationAgeSeconds ride along only when enforcing:
	// the CA ids this runner trusts (so an operator can confirm setup — the
	// public-key bytes never leave the host) and the freshness window in seconds
	// (so the cloud can warn before dispatching a run that would be refused as
	// stale, e.g. a slow approval).
	SigningCAIDs             []string `json:"signing_ca_ids,omitempty"`
	MaxAttestationAgeSeconds int      `json:"max_attestation_age_seconds,omitempty"`
}

// PackInfo is the side-index entry for a pack.
type PackInfo struct {
	Version string `json:"version,omitempty"`
	Hash    string `json:"hash,omitempty"`
}

// ActionDescriptor is the runner's self-described view of a single action.
// Cloud uses this for runbook authoring + LLM tool advertising.
type ActionDescriptor struct {
	ID          string               `json:"id"`
	PackID      string               `json:"pack_id,omitempty"`
	Title       string               `json:"title"`
	Kind        string               `json:"kind"`
	Risk        string               `json:"risk"`
	Description string               `json:"description"`
	SideEffects []string             `json:"side_effects,omitempty"`
	Args        []actionspec.Arg     `json:"args,omitempty"`
	Limits      DescriptorLimits     `json:"limits"`
	Output      DescriptorOutput     `json:"output"`
	Examples    []actionspec.Example `json:"examples,omitempty"`
}

// DescriptorLimits is the timeout envelope cloud sees.
type DescriptorLimits struct {
	DefaultTimeout actionspec.Duration `json:"default_timeout"`
	TimeoutMin     actionspec.Duration `json:"timeout_min,omitempty"`
	TimeoutMax     actionspec.Duration `json:"timeout_max,omitempty"`
}

// DescriptorOutput is the output-shape cloud sees.
type DescriptorOutput struct {
	Parser            actionspec.Parser `json:"parser,omitempty"`
	MaxStdoutBytes    int               `json:"max_stdout_bytes"`
	MaxStdoutBytesMin int               `json:"max_stdout_bytes_min,omitempty"`
	MaxStdoutBytesMax int               `json:"max_stdout_bytes_max,omitempty"`
	MaxStderrBytes    int               `json:"max_stderr_bytes"`
	MaxStderrBytesMin int               `json:"max_stderr_bytes_min,omitempty"`
	MaxStderrBytesMax int               `json:"max_stderr_bytes_max,omitempty"`
}

// ActionProgressMsg streams a line of action output. seq increases
// monotonically per request_id so cloud can detect drops.
type ActionProgressMsg struct {
	Envelope
	Seq    int    `json:"seq"`
	Stream string `json:"stream"`
	Chunk  string `json:"chunk"`
}

// ActionResultMsg is the terminal message for an action call. Stdout/stderr
// content is *not* repeated here when streaming was used — cloud already
// has the chunks. SHA-256s + byte counts let cloud verify integrity.
type ActionResultMsg struct {
	Envelope
	Status       string             `json:"status"`
	ExitCode     int                `json:"exit_code"`
	DurationMS   int64              `json:"duration_ms"`
	TimedOut     bool               `json:"timed_out,omitempty"`
	StdoutSHA256 string             `json:"stdout_sha256,omitempty"`
	StderrSHA256 string             `json:"stderr_sha256,omitempty"`
	StdoutBytes  int                `json:"stdout_bytes"`
	StderrBytes  int                `json:"stderr_bytes"`
	TruncatedOut bool               `json:"truncated_stdout,omitempty"`
	TruncatedErr bool               `json:"truncated_stderr,omitempty"`
	Redactions   []RedactionSummary `json:"redactions,omitempty"`
	Reason       string             `json:"reason,omitempty"`
	Error        string             `json:"error,omitempty"`
	EventID      string             `json:"event_id"`
	// ExecutedCommand is the exact command the runner ran, shell-quoted,
	// with sensitive arg values masked runner-side.
	ExecutedCommand string `json:"executed_command,omitempty"`
}

// RedactionSummary is the per-rule hit count on this action call.
type RedactionSummary struct {
	Name  string `json:"name"`
	Type  string `json:"type,omitempty"`
	Count int    `json:"count"`
}

// HeartbeatMsg lets cloud detect stuck runners. Sent every cloud.heartbeat_every.
type HeartbeatMsg struct {
	Envelope
	Time       string `json:"time"`
	ActionLoad int    `json:"action_load"`
}

// ErrorMsg is a generic runner-to-cloud error. It does not abort the session.
type ErrorMsg struct {
	Envelope
	Code    string `json:"code"`
	Message string `json:"message"`
}

// PeekType reads only the envelope to learn which concrete type to unmarshal.
func PeekType(raw []byte) (MessageType, error) {
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return "", err
	}
	return env.Type, nil
}
