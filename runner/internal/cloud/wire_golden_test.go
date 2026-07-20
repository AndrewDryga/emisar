package cloud

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

var updateWireGolden = flag.Bool("update", false, "update the wire protocol golden")

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
			if previous.ProtocolVersion == ProtocolVersion && !wireGoldenChangeIsAdditive(previous, current) {
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
					Opts:             &RunOpts{Timeout: actionspec.Duration(45 * time.Second), MaxStdoutBytes: 65536, MaxStderrBytes: 16384},
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
					Envelope: envelope(MsgShutdown, "req_wire_shutdown"),
					Reason:   "cloud_shutdown",
					Message:  "The control plane is restarting; reconnect shortly.",
				})
			},
		},
		{
			name: string(MsgRunnerState),
			marshal: func() ([]byte, error) {
				return json.Marshal(RunnerStateMsg{
					Envelope:                 envelope(MsgRunnerState, "req_wire_state"),
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
					EmittedStdoutSHA256:      repeated("c", 64),
					EmittedStderrSHA256:      repeated("d", 64),
					EmittedStdoutBytes:       4096,
					EmittedStderrBytes:       512,
					ProgressChunks:           9,
					DroppedProgressChunks:    2,
					TruncatedOut:             true,
					TruncatedErr:             true,
					Redactions:               []RedactionSummary{{Name: "database-password", Type: "named", Count: 3}},
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
					Envelope:   envelope(MsgHeartbeat, "req_wire_heartbeat"),
					Time:       "2026-07-16T12:34:56Z",
					ActionLoad: 4,
				})
			},
		},
		{
			name: string(MsgError),
			marshal: func() ([]byte, error) {
				return json.Marshal(ErrorMsg{
					Envelope: envelope(MsgError, "req_wire_error"),
					Code:     "dispatch_backlog_full",
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
		OperationID:  "op_wire_golden_0001",
		Signature:    repeated("f", 128),
		Nonce:        "nonce_wire_golden_0001",
		IssuedAt:     "2026-07-16T12:34:56Z",
		Cert: &attest.Cert{
			CAID:       "ca-production",
			KeyID:      "key-runner-db",
			PublicKey:  repeated("1", 64),
			ValidFrom:  "2026-01-01T00:00:00Z",
			ValidUntil: "2027-01-01T00:00:00Z",
			Scope:      attest.Scope{Group: "database", Labels: map[string]string{"datacenter": "dc1"}},
			Serial:     "01JZWIREGOLDEN000000000000",
			Sig:        repeated("2", 128),
		},
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
		Limits: DescriptorLimits{
			DefaultTimeout: actionspec.Duration(15 * time.Second),
			TimeoutMin:     actionspec.Duration(5 * time.Second),
			TimeoutMax:     actionspec.Duration(2 * time.Minute),
		},
		Output: DescriptorOutput{
			Parser:            actionspec.ParserJSON,
			ParserRequired:    true,
			MaxStdoutBytes:    65536,
			MaxStdoutBytesMin: 1024,
			MaxStdoutBytesMax: 131072,
			MaxStderrBytes:    16384,
			MaxStderrBytesMin: 512,
			MaxStderrBytesMax: 32768,
		},
	}
}

func repeated(value string, count int) string {
	result := make([]byte, count)
	for i := range result {
		result[i] = value[0]
	}
	return string(result)
}
