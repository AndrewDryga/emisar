package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestDecodeBridgeResult(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name      string
		response  string
		wantError bool
		wantTool  bool
		wantText  string
	}{
		{
			name:     "terminal success",
			response: `{"jsonrpc":"2.0","id":"req","result":{"content":[{"type":"text","text":"status=success exit_code=0"}],"isError":false}}`,
			wantText: "status=success exit_code=0",
		},
		{
			name:     "tool error",
			response: `{"jsonrpc":"2.0","id":"req","result":{"content":[{"type":"text","text":"runner_requires_attestation"}],"isError":true}}`,
			wantTool: true,
			wantText: "runner_requires_attestation",
		},
		{
			name:      "JSON-RPC error",
			response:  `{"jsonrpc":"2.0","id":"req","error":{"code":-32603,"message":"upstream failed"}}`,
			wantError: true,
		},
		{
			name:      "missing isError",
			response:  `{"jsonrpc":"2.0","id":"req","result":{"content":[]}}`,
			wantError: true,
		},
		{
			name:      "non protocol output",
			response:  `<html>bad gateway</html>`,
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			got, err := decodeBridgeResult(tt.response)
			if (err != nil) != tt.wantError {
				t.Fatalf("decodeBridgeResult() error = %v, wantError %v", err, tt.wantError)
			}
			if err != nil {
				return
			}
			if got.isError != tt.wantTool {
				t.Errorf("isError = %v, want %v", got.isError, tt.wantTool)
			}
			if got.text != tt.wantText {
				t.Errorf("text = %q, want %q", got.text, tt.wantText)
			}
		})
	}
}

func TestDispatchFrameUsesDurableTargetAndUniqueRequestID(t *testing.T) {
	t.Parallel()

	frame := dispatchFrame("runner-01HQEXTERNAL", "linux.uptime", "signing-e2e-123-signed")

	var request struct {
		ID     string `json:"id"`
		Params struct {
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(frame), &request); err != nil {
		t.Fatalf("decode dispatch frame: %v", err)
	}
	if request.ID != "signing-e2e-123-signed" {
		t.Errorf("id = %q, want unique request id", request.ID)
	}
	targets, ok := request.Params.Arguments["runners"].([]any)
	if !ok || len(targets) != 1 || targets[0] != "runner-01HQEXTERNAL" {
		t.Errorf("runners = %#v, want durable external id", request.Params.Arguments["runners"])
	}
	reason, _ := request.Params.Arguments["reason"].(string)
	if !strings.Contains(reason, request.ID) {
		t.Errorf("reason = %q, want request id %q for audit correlation", reason, request.ID)
	}
}
