// Package cloud defines the wire protocol between the runner and the control
// plane plus the websocket client that carries it.
//
// All messages are JSON envelopes carried over a TLS websocket initiated by
// the runner (no inbound port on the host). The control plane is the only
// peer; there is no peer-to-peer runner traffic.
//
// Protocol versioning: every known message carries the exact protocol_version.
// Unknown message types are silently ignored so additive message families do
// not break an older peer. Schema additions inside a known message type are
// tolerated via "ignore unknown fields" JSON decoding.
package cloud

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"strings"
	"unicode/utf8"

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
// ExpectedPackHash is the content hash trusted by the control plane for every
// dispatch. PackRef additionally binds signed MCP calls to the immutable pack
// id/version/content hash selected by the client.
type RunActionMsg struct {
	Envelope
	ActionID         string          `json:"action_id"`
	ExpectedPackHash string          `json:"expected_pack_hash,omitempty"`
	PackRef          string          `json:"pack_ref,omitempty"`
	Args             map[string]any  `json:"-"`
	ArgsRaw          json.RawMessage `json:"-"`
	Opts             *RunOpts        `json:"opts,omitempty"`
	Reason           string          `json:"reason,omitempty"`
	OperationID      string          `json:"operation_id,omitempty"`
	// Attestation is the client signature an enforcing runner requires. The
	// cloud RELAYS it from the originating MCP call; it cannot forge or alter
	// it. Nil on portal-originated dispatch (operator/runbook), which an
	// enforcing runner refuses. See internal/signing.
	Attestation *Attestation `json:"attestation,omitempty"`
}

// Attestation is the shared signed envelope binding every execution-intent fact
// to a real user's MCP call. The control plane only relays it; it holds no leaf
// or CA private key and cannot forge or alter it. See internal/attest.
type Attestation = attest.Envelope

const (
	maxActionArgsBytes       = 32 << 10
	maxRunActionMessageBytes = 128 << 10
)

type runActionMsgWire struct {
	Envelope
	ActionID         string          `json:"action_id"`
	ExpectedPackHash string          `json:"expected_pack_hash,omitempty"`
	PackRef          string          `json:"pack_ref,omitempty"`
	Args             json.RawMessage `json:"args,omitempty"`
	Opts             *RunOpts        `json:"opts,omitempty"`
	Reason           string          `json:"reason,omitempty"`
	OperationID      string          `json:"operation_id,omitempty"`
	Attestation      *Attestation    `json:"attestation,omitempty"`
}

// UnmarshalJSON captures the exact args token before decoding it with UseNumber
// for the engine. The signature gate hashes ArgsRaw, never the decoded map.
func (m *RunActionMsg) UnmarshalJSON(data []byte) error {
	if len(data) > maxRunActionMessageBytes {
		return fmt.Errorf("cloud: run_action message exceeds %d bytes", maxRunActionMessageBytes)
	}
	if err := validateUniqueJSON(data); err != nil {
		return fmt.Errorf("cloud: invalid run_action JSON: %w", err)
	}
	if err := validateRunActionFieldNames(data); err != nil {
		return err
	}
	var wire runActionMsgWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	if len(wire.Args) == 0 {
		return fmt.Errorf("cloud: run_action args are required")
	}
	if strings.TrimSpace(wire.RequestID) == "" {
		return fmt.Errorf("cloud: run_action request_id is required")
	}
	args, err := decodeActionArgs(wire.Args)
	if err != nil {
		return err
	}
	*m = RunActionMsg{
		Envelope: wire.Envelope, ActionID: wire.ActionID,
		ExpectedPackHash: wire.ExpectedPackHash, PackRef: wire.PackRef,
		Args: args, ArgsRaw: append(json.RawMessage(nil), normalizedArgsRaw(wire.Args)...),
		Opts: wire.Opts, Reason: wire.Reason, OperationID: wire.OperationID,
		Attestation: wire.Attestation,
	}
	return nil
}

func validateRunActionFieldNames(data []byte) error {
	root, err := rawJSONObject(data, "run_action")
	if err != nil {
		return err
	}
	if err := rejectKnownAliases(root, "run_action", runActionFieldNames); err != nil {
		return err
	}
	if raw, ok := root["opts"]; ok && string(raw) != "null" {
		object, err := rawJSONObject(raw, "run_action opts")
		if err != nil {
			return err
		}
		if err := rejectKnownAliases(object, "run_action opts", runOptsFieldNames); err != nil {
			return err
		}
	}
	if raw, ok := root["attestation"]; ok && string(raw) != "null" {
		envelope, err := rawJSONObject(raw, "run_action attestation")
		if err != nil {
			return err
		}
		if err := rejectKnownAliases(envelope, "run_action attestation", attestationFieldNames); err != nil {
			return err
		}
		if raw, ok := envelope["cert"]; ok && string(raw) != "null" {
			cert, err := rawJSONObject(raw, "run_action certificate")
			if err != nil {
				return err
			}
			if err := rejectKnownAliases(cert, "run_action certificate", certFieldNames); err != nil {
				return err
			}
			if raw, ok := cert["scope"]; ok && string(raw) != "null" {
				scope, err := rawJSONObject(raw, "run_action certificate scope")
				if err != nil {
					return err
				}
				if err := rejectKnownAliases(scope, "run_action certificate scope", scopeFieldNames); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func rawJSONObject(raw []byte, label string) (map[string]json.RawMessage, error) {
	var object map[string]json.RawMessage
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, fmt.Errorf("cloud: %s must be a JSON object: %w", label, err)
	}
	if object == nil {
		return nil, fmt.Errorf("cloud: %s must be a JSON object", label)
	}
	return object, nil
}

var (
	runActionFieldNames   = canonicalJSONFieldNames(reflect.TypeOf(runActionMsgWire{}))
	runOptsFieldNames     = canonicalJSONFieldNames(reflect.TypeOf(RunOpts{}))
	attestationFieldNames = canonicalJSONFieldNames(reflect.TypeOf(attest.Envelope{}))
	certFieldNames        = canonicalJSONFieldNames(reflect.TypeOf(attest.Cert{}))
	scopeFieldNames       = canonicalJSONFieldNames(reflect.TypeOf(attest.Scope{}))
)

func canonicalJSONFieldNames(value reflect.Type) []string {
	fields := make([]string, 0, value.NumField())
	for i := 0; i < value.NumField(); i++ {
		field := value.Field(i)
		tag := field.Tag.Get("json")
		name, _, _ := strings.Cut(tag, ",")
		if name == "-" {
			continue
		}
		if field.Anonymous && name == "" && field.Type.Kind() == reflect.Struct {
			fields = append(fields, canonicalJSONFieldNames(field.Type)...)
			continue
		}
		if name == "" {
			name = field.Name
		}
		fields = append(fields, name)
	}
	return fields
}

func rejectKnownAliases(object map[string]json.RawMessage, label string, canonical []string) error {
	for field := range object {
		for _, want := range canonical {
			if field != want && strings.EqualFold(field, want) {
				return fmt.Errorf("cloud: %s field %q must use canonical name %q", label, field, want)
			}
		}
	}
	return nil
}

func normalizedArgsRaw(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage(`{}`)
	}
	return raw
}

func decodeActionArgs(raw json.RawMessage) (map[string]any, error) {
	raw = normalizedArgsRaw(raw)
	if len(raw) > maxActionArgsBytes {
		return nil, fmt.Errorf("cloud: run_action args exceed %d bytes", maxActionArgsBytes)
	}
	if err := validateUniqueJSON(raw); err != nil {
		return nil, fmt.Errorf("cloud: invalid run_action args: %w", err)
	}
	if trimmed := bytes.TrimSpace(raw); len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, fmt.Errorf("cloud: run_action args must be an object")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var args map[string]any
	if err := decoder.Decode(&args); err != nil {
		return nil, fmt.Errorf("cloud: decode run_action args: %w", err)
	}
	return args, nil
}

func validateUniqueJSON(raw []byte) error {
	if !utf8.Valid(raw) {
		return fmt.Errorf("JSON is not valid UTF-8")
	}
	if err := validateUnicodeSurrogates(raw); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if err := consumeUniqueJSONValue(decoder, 0); err != nil {
		return err
	}
	if token, err := decoder.Token(); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("unexpected trailing token %v", token)
	}
	return nil
}

func validateUnicodeSurrogates(raw []byte) error {
	inString := false
	for i := 0; i < len(raw); i++ {
		switch raw[i] {
		case '"':
			inString = !inString
		case '\\':
			if !inString || i+1 >= len(raw) {
				continue
			}
			if raw[i+1] != 'u' {
				i++
				continue
			}
			code, ok := decodeHex4(raw, i+2)
			if !ok {
				continue // encoding/json reports malformed escape syntax.
			}
			i += 5
			switch {
			case code >= 0xd800 && code <= 0xdbff:
				if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
					return fmt.Errorf("JSON string contains an unpaired high surrogate")
				}
				low, ok := decodeHex4(raw, i+3)
				if !ok || low < 0xdc00 || low > 0xdfff {
					return fmt.Errorf("JSON string contains an unpaired high surrogate")
				}
				i += 6
			case code >= 0xdc00 && code <= 0xdfff:
				return fmt.Errorf("JSON string contains an unpaired low surrogate")
			}
		}
	}
	return nil
}

func decodeHex4(raw []byte, start int) (uint16, bool) {
	if start+4 > len(raw) {
		return 0, false
	}
	var value uint16
	for _, char := range raw[start : start+4] {
		value <<= 4
		switch {
		case char >= '0' && char <= '9':
			value |= uint16(char - '0')
		case char >= 'a' && char <= 'f':
			value |= uint16(char-'a') + 10
		case char >= 'A' && char <= 'F':
			value |= uint16(char-'A') + 10
		default:
			return 0, false
		}
	}
	return value, true
}

func consumeUniqueJSONValue(decoder *json.Decoder, depth int) error {
	if depth > 64 {
		return fmt.Errorf("JSON nesting exceeds 64 levels")
	}
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]struct{}{}
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return err
			}
			key, ok := keyToken.(string)
			if !ok {
				return fmt.Errorf("object key is not a string")
			}
			if _, duplicate := seen[key]; duplicate {
				return fmt.Errorf("duplicate object key %q", key)
			}
			seen[key] = struct{}{}
			if err := consumeUniqueJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim('}') {
			return fmt.Errorf("object has invalid closing delimiter")
		}
	case '[':
		for decoder.More() {
			if err := consumeUniqueJSONValue(decoder, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil {
			return err
		}
		if closing != json.Delim(']') {
			return fmt.Errorf("array has invalid closing delimiter")
		}
	default:
		return fmt.Errorf("unexpected delimiter %q", delim)
	}
	return nil
}

// RunOpts is the per-call override envelope. Each field is clamped to the
// action's declared min/max bounds before use.
type RunOpts struct {
	Timeout        actionspec.Duration `json:"timeout,omitempty"`
	MaxStdoutBytes int                 `json:"max_stdout_bytes,omitempty"`
	MaxStderrBytes int                 `json:"max_stderr_bytes,omitempty"`
}

func (o *RunOpts) hasOverrides() bool {
	return o != nil && (o.Timeout != 0 || o.MaxStdoutBytes != 0 || o.MaxStderrBytes != 0)
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
	actionspec.ModelDescriptor
	PackID string           `json:"pack_id,omitempty"`
	Limits DescriptorLimits `json:"limits"`
	Output DescriptorOutput `json:"output"`
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
// content is not repeated here. Emitted-output hashes and byte counts cover
// every normalized, redacted byte admitted by the action's output caps; the
// progress counters let the portal distinguish those facts from the subset it
// durably received.
type ActionResultMsg struct {
	Envelope
	Status                string             `json:"status"`
	ExitCode              int                `json:"exit_code"`
	DurationMS            int64              `json:"duration_ms"`
	TimedOut              bool               `json:"timed_out,omitempty"`
	EmittedStdoutSHA256   string             `json:"emitted_stdout_sha256,omitempty"`
	EmittedStderrSHA256   string             `json:"emitted_stderr_sha256,omitempty"`
	EmittedStdoutBytes    int                `json:"emitted_stdout_bytes"`
	EmittedStderrBytes    int                `json:"emitted_stderr_bytes"`
	ProgressChunks        int                `json:"progress_chunks"`
	DroppedProgressChunks int                `json:"dropped_progress_chunks,omitempty"`
	TruncatedOut          bool               `json:"truncated_stdout,omitempty"`
	TruncatedErr          bool               `json:"truncated_stderr,omitempty"`
	Redactions            []RedactionSummary `json:"redactions,omitempty"`
	Reason                string             `json:"reason,omitempty"`
	Error                 string             `json:"error,omitempty"`
	EventID               string             `json:"event_id"`
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

// PeekEnvelope reads only the envelope needed to choose and validate a concrete
// message before its payload is decoded.
func PeekEnvelope(raw []byte) (Envelope, error) {
	var env Envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return Envelope{}, err
	}
	return env, nil
}
