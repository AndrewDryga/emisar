package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestClientRejectsInvalidControlRequestIDs(t *testing.T) {
	cli := buildClient(t, &queuedDialer{})
	requestID := "req_" + strings.Repeat("x", maxRunActionMessageBytes)

	cancelRaw, err := json.Marshal(CancelMsg{
		Envelope: Envelope{Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: requestID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := cli.dispatch(context.Background(), cancelRaw); err != nil {
		t.Fatal(err)
	}
	if len(cli.preCanceled) != 0 || len(cli.preCanceledOrder) != 0 {
		t.Fatal("invalid cancel request_id reached pre-cancel retention")
	}

	cli.runs[requestID] = &runState{requestID: requestID, finished: true}
	ackRaw, err := json.Marshal(AckResultMsg{
		Envelope: Envelope{Type: MsgAckResult, ProtocolVersion: ProtocolVersion, RequestID: requestID},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := cli.dispatch(context.Background(), ackRaw); err != nil {
		t.Fatal(err)
	}
	if _, exists := cli.runs[requestID]; !exists {
		t.Fatal("invalid ack_result request_id reached run state")
	}
}

func TestRunActionMsgPreservesExactArgumentBytes(t *testing.T) {
	wantArgs := "{\"job_id\":891234567890123456, \"ratio\":1e3, \"nested\":{\"ok\":true}}"
	wantHash := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	raw := []byte("{\"type\":\"run_action\",\"protocol_version\":1,\"request_id\":\"" + testRequestID("req_exact") + "\",\"action_id\":\"db.pause\",\"expected_pack_hash\":\"" + wantHash + "\",\"pack_ref\":\"db@1.0.0/" + wantHash + "\",\"args\":" + wantArgs + ",\"reason\":\"maintenance\",\"operation_id\":\"op_00000000000000000000000000\"}")

	var msg RunActionMsg
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if got := string(msg.ArgsRaw); got != wantArgs {
		t.Fatalf("ArgsRaw changed:\n got %s\nwant %s", got, wantArgs)
	}
	if got := msg.Args["job_id"].(json.Number).String(); got != "891234567890123456" {
		t.Fatalf("decoded large integer = %s", got)
	}
	if msg.ExpectedPackHash != wantHash {
		t.Fatalf("expected_pack_hash = %q, want %q", msg.ExpectedPackHash, wantHash)
	}
}

func TestRunActionMsgUsesIntegerMillisecondOptions(t *testing.T) {
	requestID := testRequestID("req_opts")
	valid := []byte("{\"type\":\"run_action\",\"request_id\":\"" + requestID + "\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"timeout_ms\":5000,\"max_stdout_bytes\":65536,\"max_stderr_bytes\":16384}}")

	var msg RunActionMsg
	if err := json.Unmarshal(valid, &msg); err != nil {
		t.Fatalf("Unmarshal integer options: %v", err)
	}
	if msg.Opts == nil || msg.Opts.TimeoutMS != 5_000 ||
		msg.Opts.MaxStdoutBytes != 65_536 || msg.Opts.MaxStderrBytes != 16_384 {
		t.Fatalf("decoded options = %+v", msg.Opts)
	}
	if got := msg.Opts.Timeout(); got != 5*time.Second {
		t.Errorf("Timeout() = %v, want 5s", got)
	}

	invalid := []byte("{\"type\":\"run_action\",\"request_id\":\"" + requestID + "\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"timeout_ms\":\"5s\"}}")
	if err := json.Unmarshal(invalid, &msg); err == nil {
		t.Fatal("string timeout_ms was accepted")
	}

	// The retired `timeout` spelling is now simply an unknown field, so it is
	// ignored rather than read as milliseconds. That is the safe direction: the
	// action falls back to its own authored timeout instead of running for a
	// number scaled a million-fold wrong.
	stale := []byte("{\"type\":\"run_action\",\"request_id\":\"" + requestID + "\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"timeout\":5000000000}}")
	var staleMsg RunActionMsg
	if err := json.Unmarshal(stale, &staleMsg); err != nil {
		t.Fatalf("Unmarshal retired timeout spelling: %v", err)
	}
	if staleMsg.Opts != nil && staleMsg.Opts.TimeoutMS != 0 {
		t.Errorf("retired `timeout` leaked into TimeoutMS = %d", staleMsg.Opts.TimeoutMS)
	}
}

func TestRunActionMsgRejectsNonPositiveOptions(t *testing.T) {
	requestID := testRequestID("req_bad_opts")
	for _, option := range []string{"timeout_ms", "max_stdout_bytes", "max_stderr_bytes"} {
		for _, value := range []int{-1, 0} {
			t.Run(fmt.Sprintf("%s_%d", option, value), func(t *testing.T) {
				raw := fmt.Sprintf(
					`{"type":"run_action","request_id":%q,"action_id":"a.b","args":{},"opts":{%q:%d}}`,
					requestID, option, value,
				)
				var msg RunActionMsg
				if err := json.Unmarshal([]byte(raw), &msg); err == nil || !strings.Contains(err.Error(), "must be positive") {
					t.Fatalf("Unmarshal(%s) error = %v", raw, err)
				}
			})
		}
	}

	var msg RunActionMsg
	raw := fmt.Sprintf(
		`{"type":"run_action","request_id":%q,"action_id":"a.b","args":{},"opts":{}}`,
		requestID,
	)
	if err := json.Unmarshal([]byte(raw), &msg); err != nil {
		t.Fatalf("empty opts rejected: %v", err)
	}
	if msg.Opts == nil || msg.Opts.hasOverrides() {
		t.Fatalf("empty opts decoded as %+v", msg.Opts)
	}
}

func TestRunActionMsgRejectsDuplicateKeysAtEveryDepth(t *testing.T) {
	for _, raw := range []string{
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"action_id\":\"a.c\",\"args\":{}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"x\":1,\"x\":2}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"nested\":{\"x\":1,\"x\":2}}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"version\":\"v\",\"version\":\"other\"}}",
	} {
		var msg RunActionMsg
		if err := json.Unmarshal([]byte(raw), &msg); err == nil || !strings.Contains(err.Error(), "duplicate object key") {
			t.Fatalf("Unmarshal(%s) error = %v, want duplicate-key refusal", raw, err)
		}
	}
}

func TestRunActionMsgRejectsNoncanonicalKnownFieldAliases(t *testing.T) {
	for _, raw := range []string{
		"{\"type\":\"run_action\",\"ACTION_ID\":\"a.b\",\"args\":{}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"ACTION_ID\":\"a.c\",\"args\":{}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"TIMEOUT_MS\":\"1s\"}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"ACTION_ID\":\"a.b\"}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"CERT_CHAIN\":[]}}",
	} {
		var msg RunActionMsg
		if err := json.Unmarshal([]byte(raw), &msg); err == nil || !strings.Contains(err.Error(), "canonical name") {
			t.Fatalf("Unmarshal(%s) error = %v, want noncanonical-field refusal", raw, err)
		}
	}
}

// The spec's "case aliases are rejected" covers EVERY inbound message, not just
// run_action. Go matches JSON field names case-insensitively, so
// {"TYPE":"ack_result","Request_ID":"…"} used to decode exactly like the
// canonical spelling — a TLS-authenticated portal gains nothing by it, but two
// implementations of a frozen protocol could then disagree about whether
// Request_Id is a request_id.
func TestRejectInboundAliasesCoversEveryInboundMessage(t *testing.T) {
	requestID := testRequestID("req_alias")
	tests := map[string]struct {
		messageType MessageType
		raw         string
	}{
		"cancel type":        {MsgCancel, `{"TYPE":"cancel","protocol_version":1,"request_id":"` + requestID + `"}`},
		"cancel request id":  {MsgCancel, `{"type":"cancel","protocol_version":1,"Request_ID":"` + requestID + `"}`},
		"ack_result version": {MsgAckResult, `{"type":"ack_result","Protocol_Version":1,"request_id":"` + requestID + `"}`},
		"shutdown reason":    {MsgShutdown, `{"type":"shutdown","protocol_version":1,"REASON":"runner_revoked"}`},
		"shutdown message":   {MsgShutdown, `{"type":"shutdown","protocol_version":1,"reason":"runner_revoked","MESSAGE":"x"}`},
		"error code":         {MsgError, `{"type":"error","protocol_version":1,"CODE":"finalize_failed"}`},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			err := rejectInboundAliases([]byte(tc.raw), tc.messageType)
			if err == nil || !strings.Contains(err.Error(), "canonical name") {
				t.Fatalf("rejectInboundAliases(%s) error = %v, want a canonical-name refusal", tc.raw, err)
			}
		})
	}

	// The canonical spelling and an additive future field both pass, and an
	// unknown message type stays ignorable.
	for name, tc := range map[string]struct {
		messageType MessageType
		raw         string
	}{
		"canonical cancel": {MsgCancel, `{"type":"cancel","protocol_version":1,"request_id":"` + requestID + `"}`},
		"additive field":   {MsgShutdown, `{"type":"shutdown","protocol_version":1,"reason":"cloud_shutdown","retry_after_ms":500}`},
		"unknown type":     {MessageType("future_family"), `{"type":"future_family","TYPE":"x"}`},
	} {
		t.Run(name, func(t *testing.T) {
			if err := rejectInboundAliases([]byte(tc.raw), tc.messageType); err != nil {
				t.Fatalf("rejectInboundAliases(%s) = %v, want nil", tc.raw, err)
			}
		})
	}
}

// The end-to-end path: an aliased control frame must not reach the handler that
// acts on it. A cancel with "Request_ID" would otherwise cancel a live run.
func TestClientDropsAliasedControlFrames(t *testing.T) {
	cli := buildClient(t, &queuedDialer{})
	requestID := testRequestID("req_alias_live")
	cli.runs[requestID] = &runState{requestID: requestID, finished: true}

	aliased := `{"type":"ack_result","protocol_version":1,"Request_ID":"` + requestID + `"}`
	if err := cli.dispatch(context.Background(), []byte(aliased)); err != nil {
		t.Fatal(err)
	}
	if _, exists := cli.runs[requestID]; !exists {
		t.Fatal("an aliased ack_result acknowledged the run")
	}

	canonical := `{"type":"ack_result","protocol_version":1,"request_id":"` + requestID + `"}`
	if err := cli.dispatch(context.Background(), []byte(canonical)); err != nil {
		t.Fatal(err)
	}
	if _, exists := cli.runs[requestID]; exists {
		t.Fatal("the canonical ack_result did not acknowledge the run")
	}
}

func TestRunActionMsgAllowsUnrelatedFutureFields(t *testing.T) {
	raw := []byte("{\"type\":\"run_action\",\"request_id\":\"" + testRequestID("req_future") + "\",\"action_id\":\"a.b\",\"args\":{},\"future_top\":1,\"opts\":{\"future_opt\":true},\"attestation\":{\"future_attestation\":true}}")
	var msg RunActionMsg
	if err := json.Unmarshal(raw, &msg); err != nil {
		t.Fatalf("Unmarshal additive fields: %v", err)
	}
}

func TestRunActionMsgRejectsLossyUnicodeInputs(t *testing.T) {
	for _, raw := range [][]byte{
		[]byte("{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"x\":\"\\uD800\"}}"),
		[]byte("{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"x\":\"\\uDC00\"}}"),
		[]byte("{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"x\":\"\\uD800\\u0041\"}}"),
		append([]byte("{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{\"x\":\""), append([]byte{0xff}, []byte("\"}}")...)...),
	} {
		var msg RunActionMsg
		if err := json.Unmarshal(raw, &msg); err == nil {
			t.Fatalf("Unmarshal(%q) accepted a lossy Unicode input", raw)
		}
	}

	validPair := []byte("{\"type\":\"run_action\",\"request_id\":\"" + testRequestID("req_unicode") + "\",\"action_id\":\"a.b\",\"args\":{\"x\":\"\\uD83D\\uDE80\"}}")
	var msg RunActionMsg
	if err := json.Unmarshal(validPair, &msg); err != nil {
		t.Fatalf("Unmarshal valid surrogate pair: %v", err)
	}
	if !bytes.Contains(msg.ArgsRaw, []byte("\\uD83D\\uDE80")) {
		t.Fatalf("valid surrogate pair bytes changed: %s", msg.ArgsRaw)
	}
}

func TestRunActionMsgRequiresRequestID(t *testing.T) {
	for _, raw := range []string{
		`{"type":"run_action","action_id":"a.b","args":{}}`,
		`{"type":"run_action","request_id":"","action_id":"a.b","args":{}}`,
		`{"type":"run_action","request_id":"  ","action_id":"a.b","args":{}}`,
	} {
		var msg RunActionMsg
		if err := json.Unmarshal([]byte(raw), &msg); err == nil || !strings.Contains(err.Error(), "request_id is required") {
			t.Fatalf("Unmarshal(%s) error = %v, want request_id refusal", raw, err)
		}
	}
}

func TestRunActionMsgRejectsInvalidRequestID(t *testing.T) {
	raw := []byte(`{"type":"run_action","request_id":"req invalid","action_id":"a.b","args":{}}`)
	var msg RunActionMsg
	if err := json.Unmarshal(raw, &msg); err == nil || !strings.Contains(err.Error(), "base64url") {
		t.Fatalf("Unmarshal error = %v, want invalid request_id refusal", err)
	}
}

func TestRequestIDIsOpaqueBoundedAndLogSafe(t *testing.T) {
	for _, requestID := range []string{
		"",
		"has space",
		"punctuation!",
		"unicode_é",
		strings.Repeat("x", maxRequestIDBytes+1),
	} {
		if err := validateRequestID(requestID); err == nil {
			t.Fatalf("validateRequestID(%q) accepted invalid id", requestID)
		}
	}
	for _, requestID := range []string{
		"r",
		"req_short",
		strings.Repeat("x", maxRequestIDBytes),
	} {
		if err := validateRequestID(requestID); err != nil {
			t.Fatalf("validateRequestID(%q) = %v", requestID, err)
		}
	}
}

func TestRunActionMsgRejectsInvalidArgumentShapeAndBudget(t *testing.T) {
	for _, raw := range []string{
		"{\"type\":\"run_action\",\"action_id\":\"a.b\"}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":null}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":[]}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":\"object\"}",
	} {
		var msg RunActionMsg
		if err := json.Unmarshal([]byte(raw), &msg); err == nil {
			t.Fatalf("Unmarshal(%s) accepted non-object args", raw)
		}
	}

	oversized := []byte("{\"type\":\"run_action\",\"request_id\":\"" + testRequestID("req_big") + "\",\"action_id\":\"a.b\",\"args\":{\"value\":\"" +
		strings.Repeat("x", maxActionArgsBytes) + "\"}}")
	var oversizedArgs RunActionMsg
	if err := json.Unmarshal(oversized, &oversizedArgs); err == nil || !strings.Contains(err.Error(), "exceed") {
		t.Fatalf("Unmarshal oversized args error = %v", err)
	}

	message := []byte("{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"future\":\"" +
		strings.Repeat("x", maxRunActionMessageBytes) + "\"}")
	var decoded RunActionMsg
	if err := json.Unmarshal(message, &decoded); err == nil || !strings.Contains(err.Error(), "message exceeds") {
		t.Fatalf("Unmarshal oversized message error = %v", err)
	}
}
