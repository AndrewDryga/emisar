package main

import (
	"bytes"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
)

// The bridge's main() — the flag loop, the required-env fatalln, the
// scheme-check-fatal path, and the endpoint composition — all call os.Exit and
// so can't be exercised in-process. We re-exec the test binary with a sentinel
// env var so it runs main() as a child; the parent then asserts on the child's
// stdout / stderr / exit code. This is the stdlib pattern (see os/exec's own
// TestHelperProcess) and the only way to automate the startup glue the test
// plan records as a gap.

const runMainSentinel = "EMISAR_MCP_RUN_MAIN"

// TestMain dispatches into main() when the sentinel is set; otherwise it runs
// the package's tests normally.
func TestMain(m *testing.M) {
	if os.Getenv(runMainSentinel) == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

// runMain re-execs this test binary so the child runs main() with the given
// args + env. It returns stdout, stderr, and the process exit code. stdin is fed
// from stdinData (so a started bridge sees EOF and exits cleanly).
func runMain(t *testing.T, stdinData string, args []string, env map[string]string) (stdout, stderr string, exitCode int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	// A minimal, controlled environment — start from the sentinel only so a
	// stray EMISAR_* in the developer's shell can't perturb the assertions.
	cmd.Env = []string{
		runMainSentinel + "=1",
		// Under CI's -coverprofile the re-exec'd child is coverage-instrumented
		// and warns "GOCOVERDIR not set" on stderr, breaking the stderr-empty
		// assertions. Point it at a scratch dir (the child's coverage is
		// discarded on purpose — the parent's profile is the one that counts).
		"GOCOVERDIR=" + t.TempDir(),
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Stdin = strings.NewReader(stdinData)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	err := cmd.Run()
	exitCode = 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exitCode = ee.ExitCode()
		} else {
			t.Fatalf("running child: %v", err)
		}
	}
	return outBuf.String(), errBuf.String(), exitCode
}

// `--version` / `-v` print `emisar-mcp <Version>` and exit 0. The
// build is not ldflag-stamped here, so Version is its "dev" default.
func TestMain_VersionFlagPrintsVersionExitsZero(t *testing.T) {
	for _, flag := range []string{"--version", "-v"} {
		stdout, stderr, code := runMain(t, "", []string{flag}, nil)
		if code != 0 {
			t.Errorf("%s: exit code = %d, want 0", flag, code)
		}
		if strings.TrimSpace(stdout) != bridgeName+" "+Version {
			t.Errorf("%s: stdout = %q, want %q", flag, stdout, bridgeName+" "+Version)
		}
		// Version flag short-circuits before any env is read — no fatalln noise.
		if stderr != "" {
			t.Errorf("%s: unexpected stderr %q", flag, stderr)
		}
	}
}

// Version defaults to "dev" when not stamped via
// `-ldflags -X main.Version=...`. The test binary is built without that flag, so
// the version line must read exactly "emisar-mcp dev".
func TestMain_VersionDefaultsToDev(t *testing.T) {
	if Version != "dev" {
		t.Skipf("Version is stamped (%q) in this build; the default-dev case can't be observed", Version)
	}
	stdout, _, code := runMain(t, "", []string{"--version"}, nil)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if got := strings.TrimSpace(stdout); got != "emisar-mcp dev" {
		t.Errorf("unstamped --version = %q, want %q", got, "emisar-mcp dev")
	}
}

// `--help` / `-h` print the help text and exit 0. We assert the
// exact helpText so the documented env-var contract (what the bridge actually
// reads) can't silently drift from the help.
func TestMain_HelpFlagPrintsHelpExitsZero(t *testing.T) {
	for _, flag := range []string{"--help", "-h"} {
		stdout, stderr, code := runMain(t, "", []string{flag}, nil)
		if code != 0 {
			t.Errorf("%s: exit code = %d, want 0", flag, code)
		}
		if stdout != helpText {
			t.Errorf("%s: stdout did not match helpText verbatim", flag)
		}
		if stderr != "" {
			t.Errorf("%s: unexpected stderr %q", flag, stderr)
		}
	}
}

// an unknown flag is rejected: stderr names the argument and the
// process exits 2 (distinct from the env-fatal exit 1). The bridge takes no
// positional args or unknown flags.
func TestMain_UnknownFlagExitsTwo(t *testing.T) {
	stdout, stderr, code := runMain(t, "", []string{"--bogus"}, nil)
	if code != 2 {
		t.Errorf("exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr, "unknown argument") || !strings.Contains(stderr, "--bogus") {
		t.Errorf("stderr should name the unknown argument, got %q", stderr)
	}
	if stdout != "" {
		t.Errorf("unknown flag should print nothing to stdout, got %q", stdout)
	}
}

// / / — a missing EMISAR_URL or
// EMISAR_API_KEY (or both) is fatal: fatalln to stderr, exit 1. The check is
// "both must be set", so url-only and key-only both fail the same way.
func TestMain_MissingRequiredEnvIsFatal(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
	}{
		{"neither set", nil},
		{"url only", map[string]string{"EMISAR_URL": "https://emisar.dev"}},
		{"key only", map[string]string{"EMISAR_API_KEY": "emk-x"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, code := runMain(t, "", nil, c.env)
			if code != 1 {
				t.Errorf("exit code = %d, want 1 (fatalln)", code)
			}
			if !strings.Contains(stderr, "EMISAR_URL and EMISAR_API_KEY must both be set") {
				t.Errorf("stderr should explain the missing env, got %q", stderr)
			}
			if stdout != "" {
				t.Errorf("a fatal startup should write nothing to stdout, got %q", stdout)
			}
		})
	}
}

// a failed endpoint-scheme check is fatal at startup: a cleartext
// http:// URL to a public host (no EMISAR_ALLOW_INSECURE override) makes main()
// fatalln and exit 1. The bridge never silently downgrades to shipping the
// Bearer key over plaintext. (The pure checkEndpointScheme logic is covered by
// TestCheckEndpointScheme; this pins that main wires the failure to a fatal.)
func TestMain_CleartextPublicEndpointIsFatal(t *testing.T) {
	stdout, stderr, code := runMain(t, "", nil, map[string]string{
		"EMISAR_URL":     "http://emisar.dev",
		"EMISAR_API_KEY": "emk-x",
	})
	if code != 1 {
		t.Errorf("exit code = %d, want 1 (fatalln)", code)
	}
	if !strings.Contains(stderr, "cleartext http") {
		t.Errorf("stderr should explain the cleartext refusal, got %q", stderr)
	}
	if stdout != "" {
		t.Errorf("a fatal scheme check should write nothing to stdout, got %q", stdout)
	}
}

// (override half) — the EMISAR_ALLOW_INSECURE=1 opt-in lets the same
// cleartext public endpoint through: main() proceeds past the scheme check, the
// bridge serves, and an empty stdin yields a clean (exit 0) shutdown — no fatal.
func TestMain_CleartextPublicEndpointAllowedWithOverride(t *testing.T) {
	stdout, stderr, code := runMain(t, "", nil, map[string]string{
		"EMISAR_URL":            "http://emisar.dev",
		"EMISAR_API_KEY":        "emk-x",
		"EMISAR_ALLOW_INSECURE": "1",
	})
	if code != 0 {
		t.Errorf("exit code = %d, want 0 (override lets it serve, EOF exits clean); stderr=%q", code, stderr)
	}
	if stdout != "" {
		t.Errorf("no frames in → no stdout, got %q", stdout)
	}
}

// /T11 wired to startup — a malformed signing-key configuration
// (only one of the pair, or a non-hex / wrong-length seed) is fatal at startup:
// newSigner's error is surfaced via fatalln, exit 1. (newSigner's pure cases are
// covered by TestNewSigner; this pins that main treats the error as fatal.)
func TestMain_BadSigningKeyConfigIsFatal(t *testing.T) {
	// (the signing-key branch of the startup glue)
	base := map[string]string{"EMISAR_URL": "https://emisar.dev", "EMISAR_API_KEY": "emk-x"}
	cert := certJSONFor(t, testSeedHex)
	cases := []struct {
		name string
		key  string
		cert string
		want string
	}{
		{"key without cert", testSeedHex, "", "both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT"},
		{"cert without key", "", cert, "both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT"},
		{"non-hex seed", "zz", cert, "not valid hex"},
		{"wrong-length seed", "00", cert, "Ed25519 seed"},
		{"unparseable cert", testSeedHex, "{nope", "not valid JSON"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := map[string]string{"EMISAR_SIGNING_KEY": c.key, "EMISAR_SIGNING_CERT": c.cert}
			for k, v := range base {
				env[k] = v
			}
			stdout, stderr, code := runMain(t, "", nil, env)
			if code != 1 {
				t.Errorf("exit code = %d, want 1 (fatalln)", code)
			}
			if !strings.Contains(stderr, c.want) {
				t.Errorf("stderr = %q, want it to contain %q", stderr, c.want)
			}
			if stdout != "" {
				t.Errorf("a fatal startup should write nothing to stdout, got %q", stdout)
			}
		})
	}
}

// Invalid EMISAR_CLIENT_METADATA is fatal at startup — the operator gets a clear
// local error and nothing partial ever reaches the control plane.
func TestMain_BadClientMetadataIsFatal(t *testing.T) {
	base := map[string]string{"EMISAR_URL": "https://emisar.dev", "EMISAR_API_KEY": "emk-x"}
	cases := []struct {
		name     string
		metadata string
		want     string
	}{
		{"not json", "nope", "must be a JSON object"},
		{"array", `["x"]`, "must be a JSON object"},
		{"too many keys", `{"a":"1","b":"2","c":"3","d":"4","e":"5","f":"6","g":"7","h":"8","i":"9","j":"10","k":"11"}`, "the maximum is 10"},
		{"bool value", `{"managed":true}`, "must be a string or number"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := map[string]string{"EMISAR_CLIENT_METADATA": c.metadata}
			for k, v := range base {
				env[k] = v
			}
			stdout, stderr, code := runMain(t, "", nil, env)
			if code != 1 {
				t.Errorf("exit code = %d, want 1 (fatalln)", code)
			}
			if !strings.Contains(stderr, c.want) {
				t.Errorf("stderr = %q, want it to contain %q", stderr, c.want)
			}
			if stdout != "" {
				t.Errorf("a fatal startup should write nothing to stdout, got %q", stdout)
			}
		})
	}
}

// Valid EMISAR_CLIENT_METADATA is forwarded (canonical) in the request header on
// every frame the started bridge sends.
func TestMain_ClientMetadataForwardedOnRequest(t *testing.T) {
	var mu sync.Mutex
	var gotMetadata string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gotMetadata = r.Header.Get("Emisar-Client-Metadata")
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted) // notification → bridge writes nothing
	}))
	defer srv.Close()

	frame := `{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n"
	_, stderr, code := runMain(t, frame, nil, map[string]string{
		"EMISAR_URL":             srv.URL,
		"EMISAR_API_KEY":         "emk-x",
		"EMISAR_CLIENT_METADATA": `{"b":"2","asset_tag":"LT-4417"}`,
	})
	if code != 0 {
		t.Fatalf("exit code = %d, want 0; stderr=%q", code, stderr)
	}
	mu.Lock()
	defer mu.Unlock()
	if gotMetadata != `{"asset_tag":"LT-4417","b":"2"}` {
		t.Errorf("forwarded metadata = %q, want the canonical sorted form", gotMetadata)
	}
}

// / — the endpoint is composed as `base + /api/mcp/rpc`,
// and a trailing slash on EMISAR_URL is trimmed first (so `https://x/` and
// `https://x` produce the same endpoint). We point a started bridge at a real
// capture server, feed one notification frame, and assert the POST landed on
// exactly `/api/mcp/rpc`. The server answers 202 so the bridge writes nothing
// and exits clean on EOF.
func TestMain_EndpointComposedAndTrailingSlashTrimmed(t *testing.T) {
	for _, urlSuffix := range []string{"", "/"} {
		name := "no trailing slash"
		if urlSuffix == "/" {
			name = "trailing slash trimmed"
		}
		t.Run(name, func(t *testing.T) {
			var mu sync.Mutex
			var gotPath string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				gotPath = r.URL.Path
				mu.Unlock()
				w.WriteHeader(http.StatusAccepted) // notification → bridge writes nothing
			}))
			defer srv.Close()

			frame := `{"jsonrpc":"2.0","method":"notifications/initialized"}` + "\n"
			stdout, stderr, code := runMain(t, frame, nil, map[string]string{
				"EMISAR_URL":     srv.URL + urlSuffix,
				"EMISAR_API_KEY": "emk-x",
			})
			if code != 0 {
				t.Fatalf("exit code = %d, want 0; stderr=%q", code, stderr)
			}
			if stdout != "" {
				t.Errorf("a 202 notification should produce no stdout, got %q", stdout)
			}
			mu.Lock()
			defer mu.Unlock()
			if gotPath != "/api/mcp/rpc" {
				t.Errorf("POST path = %q, want %q (endpoint = trimmed base + /api/mcp/rpc)", gotPath, "/api/mcp/rpc")
			}
		})
	}
}

// the API key value is NOT format-checked by the bridge: any
// non-empty string is accepted at startup (the portal enforces key validity
// server-side). An arbitrary "not-a-real-key" still lets main() start and serve,
// exiting clean on EOF.
func TestMain_APIKeyNotFormatChecked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()

	_, stderr, code := runMain(t, "", nil, map[string]string{
		"EMISAR_URL":     srv.URL,
		"EMISAR_API_KEY": "this-is-not-an-emk-or-emo-prefixed-key",
	})
	if code != 0 {
		t.Errorf("an arbitrary non-empty API key should start cleanly; exit=%d stderr=%q", code, stderr)
	}
}

// secrets arrive via env, never as a CLI flag/argv. There is no
// `--api-key` / `--signing-key` flag: passing one is rejected as an unknown
// argument (exit 2), so a credential can't land in a process's visible arg list.
func TestMain_SecretsNotAcceptedAsFlags(t *testing.T) {
	for _, arg := range []string{"--api-key=emk-secret", "--signing-key=deadbeef", "--token", "emk-secret"} {
		stdout, stderr, code := runMain(t, "", []string{arg}, map[string]string{
			"EMISAR_URL":     "https://emisar.dev",
			"EMISAR_API_KEY": "emk-x",
		})
		if code != 2 {
			t.Errorf("%q: exit code = %d, want 2 (no secret-bearing flags exist)", arg, code)
		}
		if !strings.Contains(stderr, "unknown argument") {
			t.Errorf("%q: stderr should reject the unknown flag, got %q", arg, stderr)
		}
		if stdout != "" {
			t.Errorf("%q: nothing should reach stdout, got %q", arg, stdout)
		}
	}
}

// / (transport-error half) — on a transport failure
// (connection refused), the client-facing JSON-RPC frame on STDOUT is the
// generic `-32603 upstream transport error`, while the detailed error (including
// the resolved host:port) lands on STDERR only. The API key never appears on
// either stream, and the loop survives (clean exit on the subsequent EOF). This
// is the transport-path twin of the in-process 5xx test
// (TestServe_5xxBodyAndKeyNeverReachClientFrame), exercised end-to-end through
// main()'s real os.Stdout / os.Stderr split.
func TestMain_TransportErrorDetailOnStderrNotClientFrame(t *testing.T) {
	// A server we start then immediately close, so the bridge's connect is
	// refused — a loopback host, so it passes the scheme check and reaches the
	// transport-error path (not a startup fatal).
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	closedURL := srv.URL
	srv.Close() // subsequent connects to closedURL are refused

	const secretKey = "emk-super-secret-DO-NOT-LEAK"
	frame := `{"jsonrpc":"2.0","id":1,"method":"tools/call"}` + "\n"
	stdout, stderr, code := runMain(t, frame, nil, map[string]string{
		"EMISAR_URL":     closedURL,
		"EMISAR_API_KEY": secretKey,
	})
	if code != 0 {
		t.Fatalf("a transport error must not kill the process; exit=%d", code)
	}

	// STDOUT: only the generic synthetic error frame.
	if !strings.Contains(stdout, "-32603") || !strings.Contains(stdout, "upstream transport error") {
		t.Errorf("client frame should be the generic -32603, got %q", stdout)
	}
	// The detail (host:port of the refused dial) is on STDERR, not the client frame.
	host := strings.TrimPrefix(closedURL, "http://")
	if !strings.Contains(stderr, "forward error") {
		t.Errorf("stderr should carry the forward-error detail, got %q", stderr)
	}
	if strings.Contains(stdout, host) {
		t.Errorf("the resolved host leaked into the client frame: %q", stdout)
	}
	// The API key must not appear on EITHER stream.
	if strings.Contains(stdout, secretKey) || strings.Contains(stderr, secretKey) {
		t.Errorf("the API key leaked (stdout=%q stderr=%q)", stdout, stderr)
	}
}

// Sanity for the harness itself: prevent a regression where the sentinel stops
// dispatching into main() and every subprocess test silently runs the suite
// instead. A child with the sentinel and no usable env must hit the required-env
// fatal (exit 1), proving it really ran main(), not m.Run().
func TestMain_SentinelDispatchesIntoMain(t *testing.T) {
	stdout, stderr, code := runMain(t, "", nil, nil)
	if code != 1 {
		t.Fatalf("child did not run main() (exit=%d); the TestMain sentinel is broken", code)
	}
	if !strings.Contains(stderr, "EMISAR_URL and EMISAR_API_KEY") {
		t.Errorf("child stderr = %q, want the required-env fatal (proves main() ran)", stderr)
	}
	// A child running the test suite would print test output; main() prints none here.
	if strings.Contains(stdout, "PASS") || strings.Contains(stdout, "RUN") {
		t.Errorf("child appears to have run the test suite, not main(): %q", stdout)
	}
}
