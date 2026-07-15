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
			response: `{"jsonrpc":"2.0","id":"req","result":{"content":[{"type":"text","text":"signature_required"}],"isError":true}}`,
			wantTool: true,
			wantText: "signature_required",
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

	frame := dispatchFrame(
		"signed-iad-01~0123456789abcdef0123456789abcdef",
		"linux.uptime",
		"linux-core@1.0.0/sha256:"+strings.Repeat("a", 64),
		"signing-e2e-123-signed",
	)

	var request struct {
		ID     string `json:"id"`
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal([]byte(frame), &request); err != nil {
		t.Fatalf("decode dispatch frame: %v", err)
	}
	if request.ID != "signing-e2e-123-signed" {
		t.Errorf("id = %q, want unique request id", request.ID)
	}
	if request.Params.Name != "run_action" {
		t.Errorf("name = %q, want run_action", request.Params.Name)
	}
	targets, ok := request.Params.Arguments["runner_refs"].([]any)
	if !ok || len(targets) != 1 || targets[0] != "signed-iad-01~0123456789abcdef0123456789abcdef" {
		t.Errorf("runner_refs = %#v, want generation-bound runner ref", request.Params.Arguments["runner_refs"])
	}
	if request.Params.Arguments["action_id"] != "linux.uptime" {
		t.Errorf("action_id = %#v", request.Params.Arguments["action_id"])
	}
	if request.Params.Arguments["pack_ref"] != "linux-core@1.0.0/sha256:"+strings.Repeat("a", 64) {
		t.Errorf("pack_ref = %#v", request.Params.Arguments["pack_ref"])
	}
	reason, _ := request.Params.Arguments["reason"].(string)
	if !strings.Contains(reason, request.ID) {
		t.Errorf("reason = %q, want request id %q for audit correlation", reason, request.ID)
	}
}

func TestSelectConnectedRunnerRequiresExactGroupAndStatus(t *testing.T) {
	t.Parallel()

	structured := []byte(`{"runners":[` +
		`{"name":"wrong-group","group":"signed-iad-extra","status":"connected","runner_ref":"wrong-group~00000000000000000000000000000000"},` +
		`{"name":"offline","group":"signed-iad","status":"disconnected","runner_ref":"offline~11111111111111111111111111111111"},` +
		`{"name":"signed-iad-01","group":"signed-iad","status":"connected","runner_ref":"signed-iad-01~22222222222222222222222222222222"}` +
		`]}`)

	got, err := selectConnectedRunner(structured, "signed-iad")
	if err != nil {
		t.Fatalf("selectConnectedRunner() error = %v", err)
	}
	if got.name != "signed-iad-01" {
		t.Errorf("name = %q, want signed-iad-01", got.name)
	}
	if got.runnerRef != "signed-iad-01~22222222222222222222222222222222" {
		t.Errorf("runnerRef = %q", got.runnerRef)
	}
}
