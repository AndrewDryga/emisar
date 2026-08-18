// Package installtest owns the repository's installer integration harness.
// Bash remains the artifact under test; setup, fakes, state inspection, and
// assertions live here so CI does not carry a second shell program.
package installtest

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
)

type harness struct {
	root string
	temp string
	out  io.Writer
}

func newHarness(root string, out io.Writer) (*harness, error) {
	temp, err := os.MkdirTemp("", "emisar-installtest-*")
	if err != nil {
		return nil, fmt.Errorf("creating temporary directory: %w", err)
	}
	return &harness{root: root, temp: temp, out: out}, nil
}

func (h *harness) close() {
	_ = os.RemoveAll(h.temp)
}

func (h *harness) path(parts ...string) string {
	return filepath.Join(append([]string{h.temp}, parts...)...)
}

func (h *harness) repoPath(path string) string {
	return filepath.Join(h.root, filepath.FromSlash(path))
}

func (h *harness) mkdir(paths ...string) error {
	for _, path := range paths {
		if err := os.MkdirAll(path, 0o755); err != nil {
			return fmt.Errorf("creating %s: %w", path, err)
		}
	}
	return nil
}

func writeFile(path, contents string, mode os.FileMode) error {
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		return fmt.Errorf("writing %s: %w", path, err)
	}
	return nil
}

func fileSHA(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", path, err)
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

func containsFile(path, text string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	if !bytes.Contains(data, []byte(text)) {
		return fmt.Errorf("%s does not contain %q", path, text)
	}
	return nil
}

func lacksFile(path, text string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	if bytes.Contains(data, []byte(text)) {
		return fmt.Errorf("%s still contains %q", path, text)
	}
	return nil
}

func exactFile(path, expected string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}
	if string(data) != expected {
		return fmt.Errorf("%s = %q, expected %q", path, data, expected)
	}
	return nil
}

func requireAbsent(path string) error {
	_, err := os.Lstat(path)
	if err == nil {
		return fmt.Errorf("%s still exists", path)
	}
	if !os.IsNotExist(err) {
		return fmt.Errorf("stating %s: %w", path, err)
	}
	return nil
}

func requireRegular(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("stating %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", path)
	}
	return nil
}

func environment(overrides map[string]string) []string {
	env := os.Environ()
	for key, value := range overrides {
		prefix := key + "="
		for index := len(env) - 1; index >= 0; index-- {
			if strings.HasPrefix(env[index], prefix) {
				env = append(env[:index], env[index+1:]...)
			}
		}
		env = append(env, prefix+value)
	}
	return env
}

// requireAttestationOutcome holds the installers to one of two stated outcomes
// for the release provenance check, so it can never pass by doing nothing.
//
// Which one is correct depends on the machine: with an authenticated gh the
// release must verify, and without one the installer must say why it skipped.
// A contributor's laptop usually takes the skip branch and CI takes the verify
// branch, so asserting only one of them would leave the other unguarded — and
// the skip branch is exactly where a broken signer pin hides, because a failure
// to check looks identical to nothing to check.
func (h *harness) requireAttestationOutcome(env map[string]string, output []byte) error {
	text := string(output)
	if h.attestationVerifierReady(env) {
		if !strings.Contains(text, "attestation verified") {
			return fmt.Errorf("an authenticated gh is available but the installer did not verify the release attestation:\n%s", text)
		}
		return nil
	}
	if !strings.Contains(text, "skipping release attestation check") &&
		!strings.Contains(text, "skipping provenance check") {
		return fmt.Errorf("the installer neither verified the release attestation nor explained skipping it:\n%s", text)
	}
	return nil
}

// attestationVerifierReady answers the installers' own gate — gh present AND
// authenticated — in the environment the installer will actually run in, not
// this process's. The MCP check hands the installer a throwaway HOME, so a gh
// that authenticates from the real user's config is unauthenticated there while
// one holding GH_TOKEN in the inherited environment, as CI does, is not.
// Asking on our own behalf gets the answer wrong in exactly that case.
func (h *harness) attestationVerifierReady(env map[string]string) bool {
	return h.command(h.root, env, "gh", "auth", "status").err == nil
}

type commandResult struct {
	output []byte
	err    error
}

func (h *harness) command(dir string, env map[string]string, name string, args ...string) commandResult {
	command := exec.Command(name, args...)
	command.Dir = dir
	command.Env = environment(env)
	output, err := command.CombinedOutput()
	return commandResult{output: output, err: err}
}

func exitCode(err error) int {
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return -1
}

func (h *harness) successful(dir string, env map[string]string, name string, args ...string) ([]byte, error) {
	result := h.command(dir, env, name, args...)
	if result.err != nil {
		return nil, fmt.Errorf("%s %s: %w\n%s", name, strings.Join(args, " "), result.err, result.output)
	}
	return result.output, nil
}

func shellFunction(file, name string) (string, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", file, err)
	}
	lines := strings.Split(string(data), "\n")
	signature := name + "() {"
	start := -1
	for index, line := range lines {
		if line == signature {
			start = index
			break
		}
	}
	if start < 0 {
		return "", fmt.Errorf("%s does not define %s", file, name)
	}
	for index := start + 1; index < len(lines); index++ {
		if lines[index] == "}" {
			return strings.Join(lines[start:index+1], "\n") + "\n", nil
		}
	}
	return "", fmt.Errorf("%s has an unterminated %s function", file, name)
}

func heredocBody(file, function, marker string) (string, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", file, err)
	}
	lines := strings.Split(string(data), "\n")
	inFunction := false
	copying := false
	var body []string
	for _, line := range lines {
		if line == function+"() {" {
			inFunction = true
			continue
		}
		if !inFunction {
			continue
		}
		if !copying && strings.Contains(line, "<<'"+marker+"'") {
			copying = true
			continue
		}
		if copying && line == marker {
			return strings.Join(body, "\n") + "\n", nil
		}
		if copying {
			body = append(body, line)
		}
	}
	return "", fmt.Errorf("%s does not contain %s heredoc in %s", file, marker, function)
}

func (h *harness) functions(file string, names []string, body string, env map[string]string) commandResult {
	var script strings.Builder
	script.WriteString("set -euo pipefail\n")
	for _, name := range names {
		function, err := shellFunction(file, name)
		if err != nil {
			return commandResult{err: err}
		}
		script.WriteString(function)
	}
	script.WriteString(body)

	command := exec.Command("bash")
	command.Dir = h.root
	command.Env = environment(env)
	// A session of its own, so the script has no controlling terminal:
	// /dev/tty stays unopenable even when the smoke test runs from an
	// interactive shell, keeping prompt-fallback paths deterministic.
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	command.Stdin = strings.NewReader(script.String())
	output, err := command.CombinedOutput()
	return commandResult{output: output, err: err}
}

func expectFailure(result commandResult, text string) error {
	if result.err == nil {
		return fmt.Errorf("command unexpectedly succeeded")
	}
	if text != "" && !bytes.Contains(result.output, []byte(text)) {
		return fmt.Errorf("failure output does not contain %q:\n%s", text, result.output)
	}
	return nil
}

func requireOutput(result commandResult) ([]byte, error) {
	if result.err != nil {
		return nil, fmt.Errorf("%w\n%s", result.err, result.output)
	}
	return result.output, nil
}

func fakeExecutable(path, body string) error {
	return writeFile(path, "#!/usr/bin/env bash\nset -euo pipefail\n"+body, 0o755)
}

func jsonFile(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}
	var value map[string]any
	if err := json.Unmarshal(data, &value); err != nil {
		return nil, fmt.Errorf("decoding %s: %w", path, err)
	}
	return value, nil
}

func nested(value map[string]any, keys ...string) (any, error) {
	var current any = value
	for _, key := range keys {
		object, ok := current.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s is not an object", strings.Join(keys, "."))
		}
		current, ok = object[key]
		if !ok {
			return nil, fmt.Errorf("%s is missing", strings.Join(keys, "."))
		}
	}
	return current, nil
}

func requireNestedString(value map[string]any, expected string, keys ...string) error {
	actual, err := nested(value, keys...)
	if err != nil {
		return err
	}
	if actual != expected {
		return fmt.Errorf("%s = %#v, expected %q", strings.Join(keys, "."), actual, expected)
	}
	return nil
}

func currentExecutable() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("locating installtest executable: %w", err)
	}
	return filepath.EvalSymlinks(path)
}

func maybeElevateRunner() (bool, error) {
	if os.Geteuid() == 0 || runtime.GOOS == "windows" {
		return true, nil
	}
	sudo, err := exec.LookPath("sudo")
	if err != nil {
		return false, nil
	}
	// Never let a canonical gate wait for a password prompt. If sudo is not
	// already available non-interactively, Runner executes its portable checks
	// and names the three privileged checks it could not prove.
	if err := exec.Command(sudo, "-n", "true").Run(); err != nil {
		return false, nil
	}
	executable, err := currentExecutable()
	if err != nil {
		return false, err
	}
	command := exec.Command(sudo, "-n", "-E", "--", executable, "runner")
	command.Dir, _ = os.Getwd()
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Run(); err != nil {
		return false, fmt.Errorf("re-running runner installer checks with passwordless sudo: %w", err)
	}
	os.Exit(0)
	return true, nil
}

var (
	runnerVersion = regexp.MustCompile(`^emisar version ([0-9]+\.[0-9]+\.[0-9]+)\n?$`)
	mcpVersion    = regexp.MustCompile(`^emisar-mcp ([0-9]+\.[0-9]+\.[0-9]+)\n?$`)
)

func matchedVersion(pattern *regexp.Regexp, output []byte) (string, error) {
	match := pattern.FindSubmatch(output)
	if match == nil {
		return "", fmt.Errorf("unexpected version output %q", output)
	}
	return string(match[1]), nil
}

func countLines(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0
	}
	return strings.Count(value, "\n") + 1
}

// githubTokenHygiene proves both installers' github_api sends the optional
// EMISAR_GITHUB_TOKEN as an Authorization header without exposing it on any
// argv: the TLS handler runs while curl is still blocked on the response,
// so /proc/*/cmdline scanned at that instant covers every live process in
// the pipeline. The no-token path must stay header-free under `set -u`.
func githubTokenHygiene(h *harness, script string) error {
	const token = "emisar-installtest-github-token"
	type probe struct {
		authorization string
		accept        string
		leaks         []string
	}
	var mu sync.Mutex
	probes := map[string]probe{}
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		mu.Lock()
		probes[request.URL.Path] = probe{
			authorization: request.Header.Get("Authorization"),
			accept:        request.Header.Get("Accept"),
			leaks:         argvHolders(token),
		}
		mu.Unlock()
		response.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(response, "{}")
	}))
	defer server.Close()
	caFile := h.path("github-api-ca.pem")
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
	if err := writeFile(caFile, string(certificate), 0o600); err != nil {
		return fmt.Errorf("writing test TLS certificate: %w", err)
	}

	result := h.functions(h.repoPath(script), []string{"github_api"}, `
github_api "$SERVER_URL/authenticated" >/dev/null
EMISAR_GITHUB_TOKEN="" github_api "$SERVER_URL/anonymous" >/dev/null
`, map[string]string{
		"CURL_CA_BUNDLE":      caFile,
		"EMISAR_GITHUB_TOKEN": token,
		"SERVER_URL":          server.URL,
	})
	if _, err := requireOutput(result); err != nil {
		return err
	}

	mu.Lock()
	defer mu.Unlock()
	authenticated, ok := probes["/authenticated"]
	if !ok {
		return fmt.Errorf("authenticated request never reached the server")
	}
	if authenticated.authorization != "Bearer "+token {
		return fmt.Errorf("authorization = %q, expected the bearer token", authenticated.authorization)
	}
	if len(authenticated.leaks) > 0 {
		return fmt.Errorf("token visible on argv of: %s", strings.Join(authenticated.leaks, ", "))
	}
	anonymous, ok := probes["/anonymous"]
	if !ok {
		return fmt.Errorf("anonymous request never reached the server")
	}
	if anonymous.authorization != "" {
		return fmt.Errorf("no-token call sent Authorization = %q", anonymous.authorization)
	}
	for _, received := range []probe{authenticated, anonymous} {
		if received.accept != "application/vnd.github+json" {
			return fmt.Errorf("accept = %q, expected the GitHub media type", received.accept)
		}
	}
	return nil
}

// argvHolders lists the /proc cmdline files carrying secret. Non-Linux
// hosts have no /proc — the glob matches nothing and the argv assertion
// passes vacuously (header delivery is still checked).
func argvHolders(secret string) []string {
	matches, _ := filepath.Glob("/proc/[0-9]*/cmdline")
	var holders []string
	for _, path := range matches {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if bytes.Contains(data, []byte(secret)) {
			holders = append(holders, path)
		}
	}
	return holders
}

// errorCode, when set, makes every token poll fail with HTTP 400 and that
// OAuth error code; "" serves the happy path: a code-less 502 blip, a 429
// rate limit, a malformed 400 error value, one pending, a proxy's 200 page,
// a 200 JSON body without client_keys, then success — every retryable
// response class the installer must survive without announcing approval.
type deviceServer struct {
	server    *httptest.Server
	polls     atomic.Int32
	errorCode string
}

func newDeviceServer(errorCode string) *deviceServer {
	device := &deviceServer{errorCode: errorCode}
	device.server = httptest.NewServer(http.HandlerFunc(device.handle))
	return device
}

func (d *deviceServer) close() {
	d.server.Close()
}

func (d *deviceServer) handle(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	switch request.URL.Path {
	case "/api/mcp/device_authorization":
		_, _ = io.WriteString(response,
			fmt.Sprintf(`{"device_code":"emdg-smoke","user_code":"FKZQ-2418",`+
				`"verification_uri":"%s/activate","verification_uri_complete":"%s/activate?code=FKZQ-2418",`+
				`"expires_in":60,"interval":0}`, d.server.URL, d.server.URL))
	case "/api/mcp/device_token":
		poll := d.polls.Add(1)
		if d.errorCode != "" {
			response.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(response, fmt.Sprintf(`{"error":%q}`, d.errorCode))
			return
		}
		switch poll {
		case 1: // a gateway blip with no OAuth error code must keep the poll alive
			response.WriteHeader(http.StatusBadGateway)
			_, _ = io.WriteString(response, "Bad Gateway")
			return
		case 2: // the portal's own rate limiter: token-shaped code, non-400 status
			response.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(response, `{"error":"rate_limited"}`)
			return
		case 3: // a 400 whose error value is outside the OAuth code charset
			response.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(response, `{"error":"upstream connect timeout"}`)
			return
		case 4:
			response.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(response, `{"error":"authorization_pending"}`)
			return
		case 5: // a proxy's 200 page carries no client_keys — not an approval
			response.Header().Set("Content-Type", "text/html")
			_, _ = io.WriteString(response, "<html><body>Signed in</body></html>")
			return
		case 6: // 200 JSON without the client_keys map is not an approval either
			_, _ = io.WriteString(response, `{"status":"ok"}`)
			return
		}
		_, _ = io.WriteString(response, `{"client_keys":{`+
			`"claude-code":"emk-cc","cursor":"emk-cur","codex":"emk-cod",`+
			`"openclaw":"emk-claw","opencode":"emk-oc","windsurf":"emk-ws",`+
			`"pi":"emk-pi","copilot-cli":"emk-cop","zed":"emk-zed",`+
			`"hermes":"emk-her","goose":"emk-goo"}}`)
	default:
		http.NotFound(response, request)
	}
}
