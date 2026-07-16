package cloud

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
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

func TestRunActionMsgUsesIntegerNanosecondOptions(t *testing.T) {
	requestID := testRequestID("req_opts")
	valid := []byte("{\"type\":\"run_action\",\"request_id\":\"" + requestID + "\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"timeout\":5000000000,\"max_stdout_bytes\":65536,\"max_stderr_bytes\":16384}}")

	var msg RunActionMsg
	if err := json.Unmarshal(valid, &msg); err != nil {
		t.Fatalf("Unmarshal integer options: %v", err)
	}
	if msg.Opts == nil || msg.Opts.Timeout != 5_000_000_000 ||
		msg.Opts.MaxStdoutBytes != 65_536 || msg.Opts.MaxStderrBytes != 16_384 {
		t.Fatalf("decoded options = %+v", msg.Opts)
	}

	invalid := []byte("{\"type\":\"run_action\",\"request_id\":\"" + requestID + "\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"timeout\":\"5s\"}}")
	if err := json.Unmarshal(invalid, &msg); err == nil {
		t.Fatal("string timeout was accepted")
	}
}

func TestRunActionMsgRejectsNonPositiveOptions(t *testing.T) {
	requestID := testRequestID("req_bad_opts")
	for _, option := range []string{"timeout", "max_stdout_bytes", "max_stderr_bytes"} {
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
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"opts\":{\"TIMEOUT\":\"1s\"}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"ACTION_ID\":\"a.b\"}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"cert\":{\"PUBLIC_KEY\":\"00\"}}}",
		"{\"type\":\"run_action\",\"action_id\":\"a.b\",\"args\":{},\"attestation\":{\"cert\":{\"scope\":{\"GROUP\":\"db\"}}}}",
	} {
		var msg RunActionMsg
		if err := json.Unmarshal([]byte(raw), &msg); err == nil || !strings.Contains(err.Error(), "canonical name") {
			t.Fatalf("Unmarshal(%s) error = %v, want noncanonical-field refusal", raw, err)
		}
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
