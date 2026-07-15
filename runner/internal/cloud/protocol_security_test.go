package cloud

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestRunActionMsgPreservesExactArgumentBytes(t *testing.T) {
	wantArgs := "{\"job_id\":891234567890123456, \"ratio\":1e3, \"nested\":{\"ok\":true}}"
	wantHash := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	raw := []byte("{\"type\":\"run_action\",\"protocol_version\":1,\"request_id\":\"req_exact\",\"action_id\":\"db.pause\",\"expected_pack_hash\":\"" + wantHash + "\",\"pack_ref\":\"db@1.0.0/" + wantHash + "\",\"args\":" + wantArgs + ",\"reason\":\"maintenance\",\"operation_id\":\"op_00000000000000000000000000\"}")

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
	raw := []byte("{\"type\":\"run_action\",\"request_id\":\"req_future\",\"action_id\":\"a.b\",\"args\":{},\"future_top\":1,\"opts\":{\"future_opt\":true},\"attestation\":{\"future_attestation\":true}}")
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

	validPair := []byte("{\"type\":\"run_action\",\"request_id\":\"req_unicode\",\"action_id\":\"a.b\",\"args\":{\"x\":\"\\uD83D\\uDE80\"}}")
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

	oversized := []byte("{\"type\":\"run_action\",\"request_id\":\"req_big\",\"action_id\":\"a.b\",\"args\":{\"value\":\"" +
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
