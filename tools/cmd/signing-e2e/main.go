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
//  3. The SAME dispatch UNSIGNED is refused with
//     `runner_requires_attestation` (the portal won't relay an unsigned call
//     to an enforcing runner).
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

var refusalCodes = []string{
	"runner_requires_attestation",
	"signature_required",
	"cert_untrusted",
	"cert_expired",
	"cert_scope",
	"bad_signature",
}

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

// waitForEnforcingRunner polls the MCP runners list until the enforcing
// runner is connected, returning its name.
func waitForEnforcingRunner(portalURL, mcpKey, group string, deadline time.Time) string {
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
			status := strings.ToLower(fmt.Sprintf("%v", runner["status"]))
			if status == "<nil>" {
				status = ""
			}
			if strings.Contains(status, "connect") || status == "online" || status == "up" || status == "" {
				return name
			}
			last = fmt.Sprintf("runner %s present but status=%q", name, status)
		} else {
			last = fmt.Sprintf("no runner in group %s yet", group)
		}
		time.Sleep(2 * time.Second)
	}
	fail("timed out waiting for an enforcing runner in group %s (%s)", group, last)
	return ""
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

func dispatchFrame(runnerName, action string) string {
	frame := map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tools/call",
		"params": map[string]any{
			"name": action,
			"arguments": map[string]any{
				"runners": []string{runnerName},
				"reason":  "signed-dispatch e2e",
				"wait":    "30s",
			},
		},
	}
	data, err := json.Marshal(frame)
	if err != nil {
		fail("marshaling dispatch frame: %v", err)
	}
	return string(data) + "\n"
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

func refusalIn(text string) string {
	for _, code := range refusalCodes {
		if strings.Contains(text, code) {
			return code
		}
	}
	return ""
}

func main() {
	portalURL := envOr("PORTAL_URL", "http://localhost:4010")
	mcpKey := envOr("MCP_KEY", "emk-mcp-dev-fixed-bootstrap-DO-NOT-USE-IN-PROD")
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
	runnerName := waitForEnforcingRunner(portalURL, mcpKey, group, deadline)
	logf("enforcing runner connected: %s", runnerName)

	leaf, cert := readMaterial()
	logf("read leaf key + cert from the shared volume")

	frame := dispatchFrame(runnerName, action)

	// 1. SIGNED dispatch must RUN.
	logf("dispatching SIGNED %s -> %s", action, runnerName)
	signed := runBridge(frame, map[string]string{"EMISAR_SIGNING_KEY": leaf, "EMISAR_SIGNING_CERT": cert})
	if refusal := refusalIn(signed); refusal != "" {
		fail("a SIGNED dispatch was refused (%s):\n%s", refusal, head(signed, 600))
	}
	lines := strings.Split(signed, "\n")
	var parsed map[string]any
	if err := json.Unmarshal([]byte(lines[len(lines)-1]), &parsed); err != nil {
		fail("signed dispatch returned no JSON-RPC response:\n%s", head(signed, 600))
	}
	if _, ok := parsed["result"]; !ok {
		fail("signed dispatch returned no result:\n%s", head(signed, 600))
	}
	logf("signed dispatch ran (result returned, no refusal) ✓")

	// 2. The SAME dispatch UNSIGNED must be refused.
	logf("dispatching UNSIGNED %s -> %s (expect refusal)", action, runnerName)
	unsigned := runBridge(frame, nil)
	if !strings.Contains(unsigned, "runner_requires_attestation") {
		fail("an UNSIGNED dispatch to an enforcing runner was NOT refused with runner_requires_attestation:\n%s", head(unsigned, 600))
	}
	logf("unsigned dispatch refused with runner_requires_attestation ✓")

	logf("PASS — enforcing runner runs a signed dispatch and refuses an unsigned one")
}

func head(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
