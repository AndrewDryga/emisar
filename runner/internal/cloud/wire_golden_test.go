package cloud

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

var updateWireGolden = flag.Bool("update", false, "update the wire protocol golden")

// nonAdditiveChangeID names the one non-additive wire change currently allowed
// to keep ProtocolVersion. Set it to "" for ordinary work: the guard then
// refuses any non-additive regeneration, which is what it exists for.
const nonAdditiveChangeID = ""

// reviewedNonAdditiveChanges records non-additive wire changes that deliberately
// do NOT bump ProtocolVersion, with the reasoning that earned the exception.
//
// The version gates the WHOLE session, and operators upgrade runners on their
// own schedule ("you control runner, bridge, and pack upgrades") — so bumping it
// disconnects every fleet until each operator acts. That price is worth paying
// for a change to a field every dispatch carries; it is not worth paying for one
// only signed dispatch populates, where an un-upgraded runner already fails
// safe by refusing that single dispatch.
//
// Adding an entry here is a reviewed act. If the changed field is not optional,
// or an un-upgraded peer would MISREAD rather than refuse it, bump the version
// instead.
var reviewedNonAdditiveChanges = map[string]bool{
	// attestation.cert (a JSON object) -> attestation.cert_chain (base64 DER),
	// the X.509 certificate switch. The field is optional and only signed
	// dispatch sets it; an un-upgraded runner finds no certificate and refuses
	// that dispatch as signature_required rather than misreading one.
	"attestation-cert-chain-x509": true,
	// action_result.emitted_std{out,err}_sha256 fed two portal columns that
	// nothing ever read; the verifier they were for was decided against
	// (founder, 2026-08-28) and the columns are dropped. The host journal
	// keeps its own digests of the redacted output — that record is the
	// tamper-evidence story. Dropping fields the receiver no longer stores
	// cannot be misread by an un-upgraded peer in either direction.
	"action-result-drop-unverified-output-digests": true,
	// heartbeat.time was runner-stamped decoration the portal never read: it
	// stamps last_heartbeat_at server-side on receipt (the honest clock) and
	// consumes action_load alone. Dropping an unread, runner-supplied field
	// cannot be misread by an un-upgraded portal — decoding tolerates absence
	// and no consumer exists.
	"heartbeat-drop-unread-time": true,
	// action_result.redactions duplicated the local journal's per-rule hit
	// counts on the wire; the portal never persisted or read them, and the
	// owned contract keeps redaction detail on the host. Dropping a field the
	// receiver never read cannot be misread; the on-host dispatch log carries
	// a one-shot strip for old persisted lines.
	"action-result-drop-unread-redactions": true,
	// runner_state descriptor limits/output duplicated the engine's own
	// clamps on every advertised action (nine fields x the whole catalog per
	// connect against the 2 MiB frame cap); the portal never read them and
	// the trusted manifest owns execution semantics. `emisar state` stops
	// printing the advertisement copy; the enforced values remain in each
	// pack's YAML. Dropping receiver-unread fields cannot be misread.
	"runner-state-drop-unadvertised-limits": true,
	// opts.timeout (a raw Go nanosecond int64) -> opts.timeout_ms. The field is
	// optional and has NO producer: the console dispatches with opts: %{} and
	// the MCP surface never exposed run opts, so no deployed peer sends it. An
	// un-upgraded portal that started to would have its unknown `timeout`
	// ignored, leaving the action's own authored timeout — a fallback, not a
	// misread. The old name leaked Go's internal representation onto a frozen
	// wire while the portal validated it as a bare positive integer with no unit
	// knowledge, so `30` meaning seconds became 30 nanoseconds and clamped
	// silently.
	"run-opts-timeout-ms": true,
	// request_id removed from runner_state, heartbeat and shutdown. No builder
	// ever set it on those three — state.go and client.go construct their
	// envelope without it, and shutdown is portal->runner — so the golden was
	// publishing a field no implementation sends, which a third party writing a
	// runner from it would faithfully emit. Removing a key nobody sends cannot
	// be misread by any peer: the field was already absent on the wire.
	"drop-unsent-request-id": true,
}

type wireGolden struct {
	ProtocolVersion int                        `json:"protocol_version"`
	Frames          map[string]json.RawMessage `json:"frames"`
}

type wireFrameCase struct {
	name    string
	marshal func() ([]byte, error)
}

func TestWireFramesGolden(t *testing.T) {
	cases := canonicalWireFrames()
	got, err := marshalWireGolden(cases)
	if err != nil {
		t.Fatal(err)
	}

	path := filepath.Join("testdata", "wire_golden.json")
	want, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("read %s: %v", path, err)
	}

	if *updateWireGolden {
		if len(want) > 0 {
			var previous wireGolden
			if err := json.Unmarshal(want, &previous); err != nil {
				t.Fatalf("decode existing %s before update: %v", path, err)
			}
			var current wireGolden
			if err := json.Unmarshal(got, &current); err != nil {
				t.Fatalf("decode generated golden before update: %v", err)
			}
			if previous.ProtocolVersion == ProtocolVersion &&
				!wireGoldenChangeIsAdditive(previous, current) &&
				!reviewedNonAdditiveChanges[nonAdditiveChangeID] {
				t.Fatalf("wire frame shape changed — if this is non-additive, bump ProtocolVersion; regenerate with -update.\n-refusing to overwrite %s while protocol_version remains %d", path, ProtocolVersion)
			}
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
		want = got
	}

	if len(want) == 0 {
		t.Fatalf("wire frame golden is missing: run go test -run '^TestWireFramesGolden$' -update")
	}

	var captured wireGolden
	if err := json.Unmarshal(want, &captured); err != nil {
		t.Fatalf("decode %s: %v", path, err)
	}
	if captured.ProtocolVersion != ProtocolVersion {
		t.Fatalf("wire frame shape changed — if this is non-additive, bump ProtocolVersion; regenerate with -update.\nprotocol_version: current=%d, golden=%d", ProtocolVersion, captured.ProtocolVersion)
	}

	for _, frame := range cases {
		frame := frame
		t.Run(frame.name, func(t *testing.T) {
			raw, err := frame.marshal()
			if err != nil {
				t.Fatal(err)
			}
			formatted, err := json.MarshalIndent(json.RawMessage(raw), "", "  ")
			if err != nil {
				t.Fatalf("marshal %s: %v", frame.name, err)
			}
			wantFrame, ok := captured.Frames[frame.name]
			if !ok {
				t.Fatalf("frame is missing from golden; regenerate with -update")
			}
			gotCompact, err := compactWireJSON(formatted)
			if err != nil {
				t.Fatalf("compact %s: %v", frame.name, err)
			}
			wantCompact, err := compactWireJSON(wantFrame)
			if err != nil {
				t.Fatalf("decode golden %s: %v", frame.name, err)
			}
			if !bytes.Equal(gotCompact, wantCompact) {
				t.Fatalf("wire frame shape changed — if this is non-additive, bump ProtocolVersion; regenerate with -update.\nwant:\n%s\n\ngot:\n%s", wantFrame, formatted)
			}
		})
	}

	if len(captured.Frames) != len(cases) {
		t.Fatalf("golden has %d frames, want %d; regenerate with -update", len(captured.Frames), len(cases))
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("wire frame shape changed — if this is non-additive, bump ProtocolVersion; regenerate with -update.\ngolden %s differs", path)
	}
}

func canonicalWireFrames() []wireFrameCase {
	envelope := func(messageType MessageType, requestID string) Envelope {
		return Envelope{Type: messageType, ProtocolVersion: ProtocolVersion, RequestID: requestID}
	}
	// Frames that carry NO request_id, because no builder sets one. runner_state
	// (state.go) and heartbeat (client.go) construct their envelope without it,
	// and shutdown is portal->runner so the runner never builds one at all.
	// Stamping it here anyway published a field no implementation sends — a
	// third party writing a runner from this golden would emit it.
	unaddressed := func(messageType MessageType) Envelope {
		return Envelope{Type: messageType, ProtocolVersion: ProtocolVersion}
	}

	return []wireFrameCase{
		{
			name: string(MsgRunAction),
			marshal: func() ([]byte, error) {
				return marshalRunActionMsg(RunActionMsg{
					Envelope:         envelope(MsgRunAction, "req_wire_run_action"),
					ActionID:         "database.pause_job",
					ExpectedPackHash: "sha256:" + repeated("a", 64),
					PackRef:          "database@1.2.3/sha256:" + repeated("a", 64),
					Args:             map[string]any{"job_id": 891234567890123456, "mode": "graceful"},
					ArgsRaw:          json.RawMessage(`{"job_id":891234567890123456,"mode":"graceful"}`),
					Opts:             &RunOpts{TimeoutMS: 45_000, MaxStdoutBytes: 65536, MaxStderrBytes: 16384},
					Reason:           "planned maintenance",
					OperationID:      "op_wire_golden_0001",
					Attestation:      canonicalAttestation(),
				})
			},
		},
		{
			name: string(MsgCancel),
			marshal: func() ([]byte, error) {
				return json.Marshal(CancelMsg{Envelope: envelope(MsgCancel, "req_wire_cancel")})
			},
		},
		{
			name: string(MsgAckResult),
			marshal: func() ([]byte, error) {
				return json.Marshal(AckResultMsg{Envelope: envelope(MsgAckResult, "req_wire_ack")})
			},
		},
		{
			name: string(MsgShutdown),
			marshal: func() ([]byte, error) {
				return json.Marshal(ShutdownMsg{
					Envelope: unaddressed(MsgShutdown),
					Reason:   "cloud_shutdown",
					Message:  "The control plane is restarting; reconnect shortly.",
				})
			},
		},
		{
			name: string(MsgRunnerState),
			marshal: func() ([]byte, error) {
				return json.Marshal(RunnerStateMsg{
					Envelope:                 unaddressed(MsgRunnerState),
					Version:                  "0.12.0",
					Hostname:                 "runner-db-01",
					Group:                    "database",
					Labels:                   map[string]string{"datacenter": "dc1", "rack": "rack3"},
					Packs:                    map[string]PackInfo{"database": {Version: "1.2.3", Hash: "sha256:" + repeated("b", 64)}},
					Actions:                  []ActionDescriptor{canonicalActionDescriptor()},
					EnforceSignatures:        true,
					SigningCAIDs:             []string{"ca-production", "ca-staging"},
					MaxAttestationAgeSeconds: 86400,
					DegradedPacks: []DegradedPackState{
						{Pack: "cloud-init", Reason: "packs: parse pack.yaml: yaml: unmarshal errors"},
					},
				})
			},
		},
		{
			name: string(MsgActionStarted),
			marshal: func() ([]byte, error) {
				return json.Marshal(ActionStartedMsg{Envelope: envelope(MsgActionStarted, "req_wire_started")})
			},
		},
		{
			name: string(MsgActionProgress),
			marshal: func() ([]byte, error) {
				return json.Marshal(ActionProgressMsg{
					Envelope: envelope(MsgActionProgress, "req_wire_progress"),
					Seq:      7,
					Stream:   "stderr",
					Chunk:    "warning: replica lag is 12s\n",
				})
			},
		},
		{
			name: string(MsgActionResult),
			marshal: func() ([]byte, error) {
				return json.Marshal(ActionResultMsg{
					Envelope:                 envelope(MsgActionResult, "req_wire_result"),
					Status:                   "failed",
					ExitCode:                 23,
					DurationMS:               12875,
					TimedOut:                 true,
					EmittedStdoutBytes:       4096,
					EmittedStderrBytes:       512,
					ProgressChunks:           9,
					DroppedProgressChunks:    2,
					TruncatedOut:             true,
					TruncatedErr:             true,
					Reason:                   "command returned a non-zero exit status",
					Error:                    "replica is not ready",
					EventID:                  "evt_wire_result_0001",
					LocalAuditFailed:         true,
					ExecutedCommand:          "dbctl pause --job [REDACTED]",
					ExecutedCommandTruncated: true,
				})
			},
		},
		{
			name: "action_result_typed",
			marshal: func() ([]byte, error) {
				return json.Marshal(ActionResultMsg{
					Envelope:           envelope(MsgActionResult, "req_wire_typed_result"),
					Status:             "success",
					DurationMS:         42,
					StructuredOutput:   json.RawMessage(`{"count":9007199254740993,"status":"ok"}`),
					EventID:            "evt_wire_typed_result_0001",
					EmittedStdoutBytes: 41,
					ProgressChunks:     1,
				})
			},
		},
		{
			name: string(MsgHeartbeat),
			marshal: func() ([]byte, error) {
				return json.Marshal(HeartbeatMsg{
					Envelope:   unaddressed(MsgHeartbeat),
					ActionLoad: 4,
				})
			},
		},
		{
			name: string(MsgError),
			marshal: func() ([]byte, error) {
				return json.Marshal(ErrorMsg{
					Envelope: envelope(MsgError, "req_wire_error"),
					Code:     "concurrency_cap_reached",
					Message:  "the runner cannot retain another pending result",
				})
			},
		},
	}
}

func marshalWireGolden(cases []wireFrameCase) ([]byte, error) {
	frames := make(map[string]json.RawMessage, len(cases))
	for _, frame := range cases {
		raw, err := frame.marshal()
		if err != nil {
			return nil, fmt.Errorf("marshal %s: %w", frame.name, err)
		}
		formatted, err := json.MarshalIndent(json.RawMessage(raw), "", "  ")
		if err != nil {
			return nil, fmt.Errorf("indent %s: %w", frame.name, err)
		}
		frames[frame.name] = formatted
	}
	golden, err := json.MarshalIndent(wireGolden{ProtocolVersion: ProtocolVersion, Frames: frames}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal wire golden: %w", err)
	}
	return append(golden, '\n'), nil
}

func wireGoldenChangeIsAdditive(previous, current wireGolden) bool {
	for name, previousFrame := range previous.Frames {
		currentFrame, ok := current.Frames[name]
		if !ok {
			return false
		}
		var previousValue, currentValue any
		if err := decodeWireJSON(previousFrame, &previousValue); err != nil {
			return false
		}
		if err := decodeWireJSON(currentFrame, &currentValue); err != nil {
			return false
		}
		if !wireJSONShapeIsAdditive(previousValue, currentValue) {
			return false
		}
	}
	return true
}

func decodeWireJSON(raw json.RawMessage, value *any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	return decoder.Decode(value)
}

func compactWireJSON(raw []byte) ([]byte, error) {
	var compact bytes.Buffer
	if err := json.Compact(&compact, raw); err != nil {
		return nil, err
	}
	return compact.Bytes(), nil
}

func wireJSONShapeIsAdditive(previous, current any) bool {
	switch previous := previous.(type) {
	case map[string]any:
		current, ok := current.(map[string]any)
		if !ok {
			return false
		}
		for name, previousValue := range previous {
			currentValue, ok := current[name]
			if !ok || !wireJSONShapeIsAdditive(previousValue, currentValue) {
				return false
			}
		}
		return true
	case []any:
		current, ok := current.([]any)
		if !ok || len(current) < len(previous) {
			return false
		}
		for i, previousValue := range previous {
			if !wireJSONShapeIsAdditive(previousValue, current[i]) {
				return false
			}
		}
		return true
	case json.Number:
		_, ok := current.(json.Number)
		return ok
	case string:
		_, ok := current.(string)
		return ok
	case bool:
		_, ok := current.(bool)
		return ok
	case nil:
		return current == nil
	default:
		return false
	}
}

func canonicalAttestation() *Attestation {
	return &Attestation{
		Version:      attest.Version,
		Tool:         attest.Tool,
		PortalOrigin: "https://emisar.example",
		ActionID:     "database.pause_job",
		PackRef:      "database@1.2.3/sha256:" + repeated("a", 64),
		ArgsSHA256:   repeated("e", 64),
		RunnerRefs:   []string{"runner-db-01~aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "runner-db-02~bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
		Reason:       "planned maintenance",
		// Distinct, non-empty digests: two sha256("") values would let a swap
		// between the fields pass, and a blank one is not what the portal accepts.
		EvidenceSHA256: attest.TextSHA256("p99 write latency 40s since 12:10Z"),
		ExpectedSHA256: attest.TextSHA256("writes resume within 60s"),
		OperationID:    "op_wire_golden_0001",
		Signature:      repeated("f", 128),
		Nonce:          "nonce_wire_golden_0001",
		IssuedAt:       "2026-07-16T12:34:56Z",
		// cert -> cert_chain is a non-additive change to this OPTIONAL field, and
		// it deliberately does NOT bump ProtocolVersion: the version gates the
		// whole session, so bumping it would disconnect every runner in every
		// fleet over a field only signed dispatch populates. An older runner that
		// receives cert_chain simply finds no cert and refuses that ONE dispatch
		// as signature_required, which is the correct answer for a peer that
		// cannot verify the certificate it was sent; unsigned dispatch is
		// untouched.
		//
		// The chain travels as base64 DER; the golden test pins the wire SHAPE,
		// so a placeholder entry is enough here — attest's own vectors pin the
		// certificate bytes.
		CertChain: []string{base64.StdEncoding.EncodeToString([]byte("wire-golden-cert"))},
	}
}

func canonicalActionDescriptor() ActionDescriptor {
	min := 1.5
	max := 9.5
	maxItems := 3
	maxLength := 128
	minDuration := "5s"
	maxDuration := "30s"

	return ActionDescriptor{
		ModelDescriptor: actionspec.ModelDescriptor{
			ID:          "database.pause_job",
			Title:       "Pause database job",
			Summary:     "Pause one database job safely.",
			Description: "Pauses a database job and waits for the control plane to confirm the transition.",
			Kind:        "exec",
			Risk:        "high",
			SideEffects: []string{"pauses scheduled work", "changes database state"},
			Args: []actionspec.ModelArg{{
				Name:        "job_id",
				Type:        "integer",
				Required:    true,
				Sensitive:   true,
				Default:     42,
				Description: "The database job identifier.",
				Validation: &actionspec.ModelValidation{
					Enum:            []any{42, 43},
					Pattern:         `^[0-9]+$`,
					Min:             &min,
					Max:             &max,
					Allowed:         []any{"42", "43"},
					AllowedPaths:    []string{"/srv/jobs"},
					DeniedPaths:     []string{"/srv/jobs/private"},
					AllowedPrefixes: []string{"job-"},
					DeniedPrefixes:  []string{"tmp-"},
					MaxItems:        &maxItems,
					MaxLength:       &maxLength,
					MinDuration:     &minDuration,
					MaxDuration:     &maxDuration,
				},
			}},
			Examples:    []actionspec.ModelExample{{Title: "Pause nightly backup", Args: map[string]any{"job_id": 42}}},
			SearchTerms: []string{"pause", "database", "job"},
			OutputSchema: map[string]any{
				"type":                 "object",
				"required":             []string{"status"},
				"properties":           map[string]any{"status": map[string]any{"const": "ok"}},
				"additionalProperties": false,
			},
		},
		PackID:                     "database",
		PrimaryExecutableAvailable: true,
	}
}

func repeated(value string, count int) string {
	result := make([]byte, count)
	for i := range result {
		result[i] = value[0]
	}
	return string(result)
}
