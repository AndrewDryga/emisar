// Command signing-e2e is the signed-dispatch end-to-end check for the
// docker-compose stack (driven by dev/signing/e2e/run.sh).
//
// Proves the CA-issued-certificate feature works through the WHOLE topology
// (portal + runner + the real MCP bridge), not just in unit tests:
//
//  1. runner-signed enforces signing — it trusts a CA `signing-init` minted
//     at stack-up (generate-at-startup; no key material is committed).
//  2. A dispatch SIGNED by the MCP bridge (using the matching leaf key +
//     cert) to that runner RUNS.
//  3. The SAME dispatch UNSIGNED is refused with `signature_required` before
//     the portal creates a run.
//
// Signing is exercised through the actual `emisar-mcp` bridge — the bridge is
// what builds the canonical claim and signs it — so this tests the real
// signer↔verifier contract end to end, not a reimplementation. Stdlib only;
// exit 0 = pass. Lives in the never-shipped tools module (see
// tools/cmd/depgate/main.go for the module rule).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

func logf(format string, args ...any) {
	fmt.Printf("[signed-dispatch-e2e] "+format+"\n", args...)
}

func fail(format string, args ...any) {
	logf("FAIL: "+format, args...)
	os.Exit(1)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// compose runs `docker compose <args>` from the repo root and returns
// (stdout, stderr, exit code).
func compose(stdin string, args ...string) (string, string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", append([]string{"compose"}, args...)...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out, errBuf strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errBuf
	err := cmd.Run()
	code := 0
	if err != nil {
		code = 1
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			code = exit.ExitCode()
		}
	}
	return out.String(), errBuf.String(), code
}

// findRunner recursively finds a connected-runner object in the given group
// anywhere in the decoded JSON.
func findRunner(v any, group string) map[string]any {
	switch node := v.(type) {
	case map[string]any:
		if node["group"] == group {
			if name, _ := node["name"].(string); name != "" {
				return node
			}
		}
		for _, child := range node {
			if found := findRunner(child, group); found != nil {
				return found
			}
		}
	case []any:
		for _, child := range node {
			if found := findRunner(child, group); found != nil {
				return found
			}
		}
	}
	return nil
}

type runnerTarget struct {
	name       string
	externalID string
	runnerRef  string
	packRef    string
}

// waitForEnforcingRunner polls the MCP runners list until the enforcing
// runner is connected, returning both its display name and durable identity.
func waitForEnforcingRunner(portalURL, mcpKey, group string, deadline time.Time) runnerTarget {
	client := &http.Client{Timeout: 10 * time.Second}
	last := ""
	for time.Now().Before(deadline) {
		req, err := http.NewRequest(http.MethodGet, portalURL+"/api/mcp/runners", nil)
		if err != nil {
			fail("building runners request: %v", err)
		}
		req.Header.Set("Authorization", "Bearer "+mcpKey)
		resp, err := client.Do(req)
		if err != nil {
			last = fmt.Sprintf("runners query error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		raw, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			last = fmt.Sprintf("runners read error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		var body any
		if err := json.Unmarshal(raw, &body); err != nil {
			last = fmt.Sprintf("runners decode error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}
		if runner := findRunner(body, group); runner != nil {
			name, _ := runner["name"].(string)
			externalID, _ := runner["id"].(string)
			status := strings.ToLower(fmt.Sprintf("%v", runner["status"]))
			if status == "<nil>" {
				status = ""
			}
			if name == "" || externalID == "" {
				last = fmt.Sprintf("runner in group %s has no name or durable id", group)
			} else if strings.Contains(status, "connect") || status == "online" || status == "up" || status == "" {
				return runnerTarget{name: name, externalID: externalID}
			} else {
				last = fmt.Sprintf("runner %s present but status=%q", name, status)
			}
		} else {
			last = fmt.Sprintf("no runner in group %s yet", group)
		}
		time.Sleep(2 * time.Second)
	}
	fail("timed out waiting for an enforcing runner in group %s (%s)", group, last)
	return runnerTarget{}
}

// readMaterial reads the freshly-minted leaf key + cert from the shared volume.
func readMaterial() (leaf, cert string) {
	leaf, errOut, code := compose("", "run", "--rm", "--no-deps", "-T", "--entrypoint", "cat", "signing-init", "/signing/leaf_key")
	leaf = strings.TrimSpace(leaf)
	if code != 0 || leaf == "" {
		fail("could not read /signing/leaf_key (rc=%d): %s", code, strings.TrimSpace(errOut))
	}
	cert, errOut, code = compose("", "run", "--rm", "--no-deps", "-T", "--entrypoint", "cat", "signing-init", "/signing/cert.json")
	cert = strings.TrimSpace(cert)
	if code != 0 || cert == "" {
		fail("could not read /signing/cert.json (rc=%d): %s", code, strings.TrimSpace(errOut))
	}
	return leaf, cert
}

func toolFrame(tool string, arguments map[string]any, requestID string) string {
	frame := map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  "tools/call",
		"params": map[string]any{
			"name":      tool,
			"arguments": arguments,
		},
	}
	data, err := json.Marshal(frame)
	if err != nil {
		fail("marshaling dispatch frame: %v", err)
	}
	return string(data) + "\n"
}

func dispatchFrame(runnerRef, action, packRef, requestID string) string {
	return toolFrame(
		"run_action",
		map[string]any{
			"action_id":   action,
			"pack_ref":    packRef,
			"runner_refs": []string{runnerRef},
			"args":        map[string]any{},
			"reason":      "signed-dispatch e2e " + requestID,
			"wait":        "30s",
		},
		requestID,
	)
}

// runBridge drives the real emisar-mcp bridge with the frame on stdin and
// returns its stdout.
func runBridge(frame string, signingEnv map[string]string) string {
	args := []string{"run", "--rm", "-T"}
	for k, v := range signingEnv {
		args = append(args, "-e", k+"="+v)
	}
	args = append(args, "mcp")
	out, errOut, code := compose(frame, args...)
	out = strings.TrimSpace(out)
	if code != 0 && out == "" {
		fail("bridge run failed (rc=%d): %s", code, strings.TrimSpace(errOut))
	}
	return out
}

type bridgeResult struct {
	isError    bool
	text       string
	structured json.RawMessage
}

func decodeBridgeResult(output string) (bridgeResult, error) {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) == 0 || lines[len(lines)-1] == "" {
		return bridgeResult{}, errors.New("empty bridge response")
	}

	var response struct {
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
		Result *struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			IsError    *bool           `json:"isError"`
			Structured json.RawMessage `json:"structuredContent"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &response); err != nil {
		return bridgeResult{}, fmt.Errorf("decode JSON-RPC response: %w", err)
	}
	if response.Error != nil {
		return bridgeResult{}, fmt.Errorf("JSON-RPC error %d: %s", response.Error.Code, response.Error.Message)
	}
	if response.Result == nil || response.Result.IsError == nil {
		return bridgeResult{}, errors.New("response has no MCP tool result with isError")
	}

	texts := make([]string, 0, len(response.Result.Content))
	for _, block := range response.Result.Content {
		if block.Type == "text" && block.Text != "" {
			texts = append(texts, block.Text)
		}
	}
	return bridgeResult{
		isError:    *response.Result.IsError,
		text:       strings.Join(texts, "\n"),
		structured: response.Result.Structured,
	}, nil
}

func callBridgeTool(tool string, arguments map[string]any, requestID string, signingEnv map[string]string) bridgeResult {
	output := runBridge(toolFrame(tool, arguments, requestID), signingEnv)
	result, err := decodeBridgeResult(output)
	if err != nil {
		fail("%s returned an invalid response: %v\n%s", tool, err, head(output, 600))
	}
	return result
}

func discoverFixedContract(runner runnerTarget, action string) runnerTarget {
	listed := callBridgeTool(
		"list_runners",
		map[string]any{"query": runner.name, "statuses": []string{"connected"}, "limit": 15},
		"discover-runner",
		nil,
	)
	if listed.isError {
		fail("list_runners returned a tool error:\n%s", head(listed.text, 600))
	}

	var runnerList struct {
		Runners []struct {
			Name      string `json:"name"`
			Group     string `json:"group"`
			Status    string `json:"status"`
			RunnerRef string `json:"runner_ref"`
		} `json:"runners"`
	}
	if err := json.Unmarshal(listed.structured, &runnerList); err != nil {
		fail("decode list_runners structuredContent: %v", err)
	}
	for _, candidate := range runnerList.Runners {
		if candidate.Name == runner.name && candidate.Status == "connected" {
			runner.runnerRef = candidate.RunnerRef
			break
		}
	}
	if runner.runnerRef == "" {
		fail("list_runners did not return connected runner %s", runner.name)
	}

	found := callBridgeTool(
		"find_actions",
		map[string]any{"action_id": action, "runner_refs": []string{runner.runnerRef}, "limit": 15},
		"discover-action",
		nil,
	)
	if found.isError {
		fail("find_actions returned a tool error:\n%s", head(found.text, 600))
	}

	var actionList struct {
		Candidates []struct {
			ActionID string `json:"action_id"`
			PackRef  string `json:"pack_ref"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(found.structured, &actionList); err != nil {
		fail("decode find_actions structuredContent: %v", err)
	}
	for _, candidate := range actionList.Candidates {
		if candidate.ActionID == action {
			runner.packRef = candidate.PackRef
			break
		}
	}
	if runner.packRef == "" {
		fail("find_actions did not return %s for runner %s", action, runner.name)
	}
	return runner
}

func successfulDispatch(result bridgeResult) bool {
	var body struct {
		Runs []struct {
			Status   string `json:"status"`
			ExitCode *int   `json:"exit_code"`
		} `json:"runs"`
	}
	if err := json.Unmarshal(result.structured, &body); err != nil || len(body.Runs) != 1 {
		return false
	}
	return body.Runs[0].Status == "success" && body.Runs[0].ExitCode != nil && *body.Runs[0].ExitCode == 0
}

func structuredErrorCode(result bridgeResult) string {
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(result.structured, &body); err != nil {
		return ""
	}
	return body.Error.Code
}

func main() {
	portalURL := envOr("PORTAL_URL", "http://localhost:4010")
	mcpKey := envOr("MCP_KEY", "emk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	group := envOr("SIGNED_GROUP", "signed-iad")
	action := envOr("SIGNED_ACTION", "linux.uptime")
	timeout := 120 * time.Second
	if v := os.Getenv("E2E_TIMEOUT"); v != "" {
		if d, err := time.ParseDuration(v + "s"); err == nil {
			timeout = d
		}
	}
	deadline := time.Now().Add(timeout)

	logf("waiting for an enforcing runner in group %s...", group)
	runner := waitForEnforcingRunner(portalURL, mcpKey, group, deadline)
	logf("enforcing runner connected: %s (%s)", runner.name, runner.externalID)
	runner = discoverFixedContract(runner, action)
	logf("fixed contract discovered: runner_ref=%s pack_ref=%s", runner.runnerRef, runner.packRef)

	leaf, cert := readMaterial()
	logf("read leaf key + cert from the shared volume")

	requestBase := fmt.Sprintf("signing-e2e-%d", time.Now().UnixNano())
	signedFrame := dispatchFrame(runner.runnerRef, action, runner.packRef, requestBase+"-signed")

	// 1. SIGNED dispatch must RUN.
	logf("dispatching SIGNED %s -> %s", action, runner.name)
	signed := runBridge(signedFrame, map[string]string{"EMISAR_SIGNING_KEY": leaf, "EMISAR_SIGNING_CERT": cert})
	signedResult, err := decodeBridgeResult(signed)
	if err != nil {
		fail("signed dispatch returned an invalid response: %v\n%s", err, head(signed, 600))
	}
	if signedResult.isError {
		fail("signed dispatch returned a tool error:\n%s", head(signed, 600))
	}
	if !successfulDispatch(signedResult) {
		fail("signed dispatch did not reach terminal success:\n%s", head(signed, 600))
	}
	logf("signed dispatch reached status=success with exit_code=0")

	// 2. The SAME dispatch UNSIGNED must be refused.
	logf("dispatching UNSIGNED %s -> %s (expect refusal)", action, runner.name)
	unsigned := runBridge(
		dispatchFrame(runner.runnerRef, action, runner.packRef, requestBase+"-unsigned"),
		nil,
	)
	unsignedResult, err := decodeBridgeResult(unsigned)
	if err != nil {
		fail("unsigned dispatch returned an invalid response: %v\n%s", err, head(unsigned, 600))
	}
	if !unsignedResult.isError || structuredErrorCode(unsignedResult) != "signature_required" {
		fail("an UNSIGNED dispatch to an enforcing runner was NOT refused with signature_required:\n%s", head(unsigned, 600))
	}
	logf("unsigned dispatch refused with signature_required")

	logf("PASS — enforcing runner runs a signed dispatch and refuses an unsigned one")
}

func head(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
