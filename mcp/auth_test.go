package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

type stubRoundTripper struct{ err error }

func (rt stubRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, rt.err
}

func TestFilterBrowserEnvironment(t *testing.T) {
	environ := []string{
		"EMISAR_API_KEY=upper",
		"Emisar_Signing_Key=mixed",
		"emisar_url=lower",
		"EMISAR_=empty-name",
		"EMISARISH=value",
		"PATH=/usr/bin",
		`=C:=C:\workspace`,
		"NO_EQUALS",
	}
	want := []string{
		"EMISARISH=value",
		"PATH=/usr/bin",
		`=C:=C:\workspace`,
		"NO_EQUALS",
	}

	if got := filterBrowserEnvironment(environ); !slices.Equal(got, want) {
		t.Fatalf("filterBrowserEnvironment() = %q, want %q", got, want)
	}
}

// A TLS/certificate failure must stop the poll immediately with the real cause,
// never keep polling to the deadline and report the misleading "code expired".
func TestDevicePollSurfacesTLSErrorButRetriesTransient(t *testing.T) {
	fatal := deviceAuthenticator{client: &http.Client{Transport: stubRoundTripper{err: x509.UnknownAuthorityError{}}}}
	_, pending, err := fatal.poll(context.Background(), "https://emisar.test", "emdg-0123456789abcdef")
	if pending || err == nil || !strings.Contains(err.Error(), "cannot securely reach") {
		t.Fatalf("TLS poll: pending=%v err=%v", pending, err)
	}

	transient := deviceAuthenticator{client: &http.Client{Transport: stubRoundTripper{err: errors.New("connection refused")}}}
	_, pending, err = transient.poll(context.Background(), "https://emisar.test", "emdg-0123456789abcdef")
	if !pending || err == nil {
		t.Fatalf("transient poll: pending=%v err=%v", pending, err)
	}
}

func TestIsSecurityConnectionError(t *testing.T) {
	for name, tc := range map[string]struct {
		err  error
		want bool
	}{
		"unknown authority":        {&url.Error{Op: "Post", Err: x509.UnknownAuthorityError{}}, true},
		"hostname mismatch":        {&url.Error{Op: "Post", Err: x509.HostnameError{Host: "x"}}, true},
		"certificate verification": {&url.Error{Op: "Post", Err: &tls.CertificateVerificationError{}}, true},
		"connection refused":       {errors.New("connection refused"), false},
		"nil":                      {nil, false},
	} {
		t.Run(name, func(t *testing.T) {
			if got := isSecurityConnectionError(tc.err); got != tc.want {
				t.Fatalf("isSecurityConnectionError = %v, want %v", got, tc.want)
			}
		})
	}
}

const (
	blitzAccountID     = "018f0000-0000-7000-8000-000000000001"
	immersiveAccountID = "018f0000-0000-7000-8000-000000000002"
)

func TestBrowserAuthOpensApprovalAndStoresAccountCredential(t *testing.T) {
	configDir, _ := useTestUserConfigDir(t)
	key := testAPIKey(89)
	const deviceCode = "emdg-0123456789abcdef"
	var polls int
	var opened string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "" {
			t.Error("device flow sent an Authorization header")
		}
		switch r.URL.Path {
		case "/api/mcp/device_authorization":
			origin := "http://" + r.Host
			var request struct {
				RequestedClients []string `json:"requested_clients"`
			}
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Errorf("decode authorization request: %v", err)
			}
			if !slices.Equal(request.RequestedClients, []string{deviceAuthClientID}) {
				t.Errorf("requested clients = %#v", request.RequestedClients)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_code":               deviceCode,
				"user_code":                 "ABCD-2345",
				"verification_uri":          origin + "/activate",
				"verification_uri_complete": origin + "/activate?code=ABCD-2345",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/mcp/device_token":
			polls++
			if polls == 1 {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"authorization_pending"}`)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"account_id":   blitzAccountID,
				"account_slug": "blitz",
				"account_name": "Blitz\x1b Operations",
				"client_keys":  map[string]string{deviceAuthClientID: key},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	authenticator := deviceAuthenticator{
		client: server.Client(),
		openBrowser: func(rawURL string) bool {
			opened = rawURL
			return true
		},
		stdoutIsTTY: func(io.Writer) bool { return true },
		now:         time.Now,
		wait:        func(context.Context, time.Duration) error { return nil },
	}
	var stdout, stderr bytes.Buffer
	code := runAuthCommandWithDeviceAuth(
		"",
		[]string{"login", server.URL},
		&stdout,
		&stderr,
		authenticator,
	)
	if code != 0 || stderr.Len() != 0 {
		t.Fatalf("login exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if opened != server.URL+"/activate?code=ABCD-2345" ||
		!strings.Contains(stdout.String(), "Approve Emisar CLI in your browser\n\n  "+server.URL) ||
		!strings.Contains(stdout.String(), "If prompted, enter this code: ABCD-2345") ||
		!strings.Contains(stdout.String(), "Sent the link to your default browser") ||
		strings.Contains(stdout.String(), "Approved.") ||
		!strings.Contains(stdout.String(), "Waiting for approval (Ctrl-C to cancel)…\n\n✓ Authenticated") ||
		!strings.Contains(stdout.String(), "Blitz Operations (blitz)") {
		t.Fatalf("opened=%q stdout=%q", opened, stdout.String())
	}
	if strings.Contains(stdout.String(), key) || strings.Contains(stderr.String(), key) ||
		strings.Contains(stdout.String(), deviceCode) || strings.Contains(stdout.String(), "\x1b[") {
		t.Fatal("browser authentication disclosed a secret or styled captured output")
	}
	store := newCLIAccountCredentialStoreAt(configDir, blitzAccountID, server.URL, keyPrefix(key))
	state, err := store.load("")
	if err != nil {
		t.Fatal(err)
	}
	if state.Current != key || state.AccountID != blitzAccountID ||
		state.AccountSlug != "blitz" || state.AccountName != "Blitz Operations" || state.Pending != "" {
		t.Fatalf("stored state = %#v", state)
	}
	selection, err := readAccountSelection()
	if err != nil || selection.AccountID != blitzAccountID || selection.EndpointOrigin != server.URL {
		t.Fatalf("selection = %#v, err=%v", selection, err)
	}
	if runtime.GOOS != "windows" {
		assertMode(t, store.path, 0o600)
		assertMode(t, filepath.Dir(store.path), 0o700)
		assertMode(t, filepath.Join(filepath.Dir(store.path), accountSelectionFilename), 0o600)
	}
}

func TestMainBrowserAuthEndToEnd(t *testing.T) {
	_, configEnv := useTestUserConfigDir(t)
	configEnv["EMISAR_URL"] = "https://override.example"
	key := testAPIKey(90)
	server := newBrowserAuthServer(t, immersiveAccountID, "immersive", "Immersive", key)
	defer server.Close()

	stdout, stderr, code := runMain(t, "", []string{"auth", "login", server.URL}, configEnv)
	if code != 0 || !strings.Contains(stderr, "Authentication environment is incomplete") ||
		!strings.Contains(stderr, "EMISAR_API_KEY is not") ||
		!strings.Contains(stdout, "Open the link above") ||
		!strings.Contains(stdout, "✓ Authenticated as Immersive (immersive)") ||
		strings.Contains(stdout, "Approved.") || strings.Contains(stdout, "\x1b[") {
		t.Fatalf("login exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stdout, key) || strings.Contains(stderr, key) {
		t.Fatal("process-level browser authentication disclosed the API key")
	}
	_, state, err := loadCLICredential("")
	if err != nil {
		t.Fatal(err)
	}
	if state.Current != key || state.AccountID != immersiveAccountID || state.AccountSlug != "immersive" {
		t.Fatalf("stored state = %#v", state)
	}
}

func TestBrowserAuthDenialAndHostileURLStoreNothing(t *testing.T) {
	tests := []struct {
		name             string
		verificationURL  func(string) string
		pollError        string
		want             string
		wantApprovalPage bool
	}{
		{
			name:             "denied",
			verificationURL:  func(origin string) string { return origin + "/activate?code=ABCD-2345" },
			pollError:        "access_denied",
			want:             "Browser sign-in was denied",
			wantApprovalPage: true,
		},
		{
			name:             "cross-origin verification URL",
			verificationURL:  func(string) string { return "https://attacker.example/activate?code=ABCD-2345" },
			want:             "invalid complete verification URL",
			wantApprovalPage: false,
		},
		{
			name:             "terminal-hostile verification URL",
			verificationURL:  func(origin string) string { return origin + "/activate?code=ABCD-\u202e1234" },
			want:             "invalid complete verification URL",
			wantApprovalPage: false,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			useTestUserConfigDir(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch r.URL.Path {
				case "/api/mcp/device_authorization":
					origin := "http://" + r.Host
					_ = json.NewEncoder(w).Encode(map[string]any{
						"device_code":               "emdg-0123456789abcdef",
						"user_code":                 "ABCD-2345",
						"verification_uri":          origin + "/activate",
						"verification_uri_complete": test.verificationURL(origin),
						"expires_in":                60,
						"interval":                  1,
					})
				case "/api/mcp/device_token":
					w.WriteHeader(http.StatusBadRequest)
					_ = json.NewEncoder(w).Encode(map[string]string{"error": test.pollError})
				}
			}))
			defer server.Close()

			opened := false
			authenticator := deviceAuthenticator{
				client:      server.Client(),
				openBrowser: func(string) bool { opened = true; return true },
				stdoutIsTTY: func(io.Writer) bool { return true },
				now:         time.Now,
				wait:        func(context.Context, time.Duration) error { return nil },
			}
			var stdout, stderr bytes.Buffer
			code := runAuthCommandWithDeviceAuth(
				"",
				[]string{"login", server.URL},
				&stdout,
				&stderr,
				authenticator,
			)
			if code != 1 || !strings.Contains(stderr.String(), test.want) {
				t.Fatalf("login exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			if opened != test.wantApprovalPage {
				t.Fatalf("browser opened=%t, want %t", opened, test.wantApprovalPage)
			}
			accounts, skipped, err := loadStoredCLIAccounts()
			if err != nil || len(accounts) != 0 || len(skipped) != 0 {
				t.Fatalf("denied login stored accounts: %#v, skipped %#v, %v", accounts, skipped, err)
			}
		})
	}
}

func TestMainBrowserAuthUnsupportedExplainsHowToRecover(t *testing.T) {
	for _, status := range []int{http.StatusBadRequest, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			_, configEnv := useTestUserConfigDir(t)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
				if request.URL.Path != "/api/mcp/device_authorization" {
					t.Fatalf("path = %q", request.URL.Path)
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(status)
				if status == http.StatusBadRequest {
					_, _ = io.WriteString(w, `{"error":"invalid_request"}`)
				}
			}))
			defer server.Close()

			stdout, stderr, code := runMain(t, "", []string{"auth", "login", server.URL}, configEnv)
			if code != 1 || stdout != "" ||
				!strings.Contains(stderr, "Error: Browser sign-in is not available") ||
				!strings.Contains(stderr, "The server at "+server.URL) ||
				!strings.Contains(stderr, "/api/mcp/device_authorization") ||
				!strings.Contains(stderr, "EMISAR_URL and EMISAR_API_KEY together") {
				t.Fatalf("login exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
			if strings.Contains(stderr, "emisar-mcp:") || strings.Contains(stderr, "\x1b[") {
				t.Fatalf("captured diagnostic contains a prefix or terminal color: %q", stderr)
			}
		})
	}
}

func TestBrowserAuthRejectsSecretBearingEndpointWithoutEcho(t *testing.T) {
	useTestUserConfigDir(t)
	for _, endpoint := range []string{
		"https://review-user:review-secret@example.com",
		"https://example.com?token=review-secret",
		"https://example.com#review-secret",
		"https://example.com/review-secret",
		"https://example.com/%zz-review-secret",
	} {
		var stdout, stderr bytes.Buffer
		code := runAuthCommandWithDeviceAuth(
			"",
			[]string{"login", endpoint},
			&stdout,
			&stderr,
			deviceAuthenticator{},
		)
		if code != 1 || stdout.Len() != 0 || stderr.Len() == 0 {
			t.Fatalf("endpoint rejection exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
		if strings.Contains(stderr.String(), "review-secret") || strings.Contains(stderr.String(), endpoint) {
			t.Fatalf("endpoint rejection disclosed input: %q", stderr.String())
		}
	}
}

// stubApproval is the identity a stubbed device-authorization flow approves
// with; newLoginStub's handler reads it at poll time so one server can approve
// different credentials across sequential logins.
type stubApproval struct {
	accountID, slug, name, key string
}

func newLoginStub(t *testing.T, approval *stubApproval) (*httptest.Server, deviceAuthenticator) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/mcp/device_authorization":
			origin := "http://" + r.Host
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_code":               "emdg-0123456789abcdef",
				"user_code":                 "ABCD-2345",
				"verification_uri":          origin + "/activate",
				"verification_uri_complete": origin + "/activate?code=ABCD-2345",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/mcp/device_token":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"account_id":   approval.accountID,
				"account_slug": approval.slug,
				"account_name": approval.name,
				"client_keys":  map[string]string{deviceAuthClientID: approval.key},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	authenticator := deviceAuthenticator{
		client:      server.Client(),
		openBrowser: func(string) bool { return true },
		stdoutIsTTY: func(io.Writer) bool { return true },
		now:         time.Now,
		wait:        func(context.Context, time.Duration) error { return nil },
	}
	return server, authenticator
}

func TestLoginWarnsWhenEnvironmentOverridesSelection(t *testing.T) {
	useTestUserConfigDir(t)
	t.Setenv("EMISAR_URL", "https://override.example")
	t.Setenv("EMISAR_API_KEY", testAPIKey(92))
	key := testAPIKey(91)
	server, authenticator := newLoginStub(t, &stubApproval{blitzAccountID, "blitz", "Blitz", key})
	var stdout, stderr bytes.Buffer
	code := runAuthCommandWithDeviceAuth("", []string{"login", server.URL}, &stdout, &stderr, authenticator)
	if code != 0 || !strings.Contains(stdout.String(), "Authenticated") ||
		!strings.Contains(stderr.String(), "overrides stored accounts") {
		t.Fatalf("login exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if strings.Contains(stdout.String(), key) || strings.Contains(stderr.String(), key) {
		t.Fatal("login disclosed the API key")
	}
}

func TestLoginWarnsOnlyWhenReplacingSameAccountCredential(t *testing.T) {
	useTestUserConfigDir(t)
	oldKey := testAPIKey(81)
	newKey := testAPIKey(82)
	approval := &stubApproval{blitzAccountID, "blitz", "Blitz", oldKey}
	server, authenticator := newLoginStub(t, approval)
	var stdout, stderr bytes.Buffer
	if code := runAuthCommandWithDeviceAuth("", []string{"login", server.URL}, &stdout, &stderr, authenticator); code != 0 || stderr.Len() != 0 {
		t.Fatalf("first login exit=%d stderr=%q", code, stderr.String())
	}

	stdout.Reset()
	stderr.Reset()
	*approval = stubApproval{blitzAccountID, "blitz-renamed", "Blitz Renamed", newKey}
	if code := runAuthCommandWithDeviceAuth("", []string{"login", server.URL}, &stdout, &stderr, authenticator); code != 0 {
		t.Fatalf("replacement exit=%d stderr=%q", code, stderr.String())
	}
	wantWarning := "Warning: Previous credential replaced. The old key was not revoked automatically. " +
		"Revoke it at " + server.URL + "/app/agents if it is still listed.\n\n"
	if stderr.String() != wantWarning {
		t.Fatalf("replacement warning = %q", stderr.String())
	}
	for _, secret := range []string{oldKey, newKey} {
		if strings.Contains(stdout.String(), secret) || strings.Contains(stderr.String(), secret) {
			t.Fatal("replacement disclosed an API key")
		}
	}
	_, state, err := loadCLICredential("blitz-renamed")
	if err != nil || state.AccountName != "Blitz Renamed" {
		t.Fatalf("renamed account state = %#v, %v", state, err)
	}
}

func TestLoginRejectsUnsafeCredentialPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlink creation requires privileges on Windows")
	}
	configDir, _ := useTestUserConfigDir(t)
	dir := filepath.Join(configDir, "emisar", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key := testAPIKey(72)
	approval := &stubApproval{blitzAccountID, "blitz", "Blitz", key}
	server, authenticator := newLoginStub(t, approval)
	store := newCLIAccountCredentialStoreAt(configDir, blitzAccountID, server.URL, keyPrefix(key))
	target := filepath.Join(t.TempDir(), "target")
	if err := os.WriteFile(target, []byte("leave me\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, store.path); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	code := runAuthCommandWithDeviceAuth("", []string{"login", server.URL}, &stdout, &stderr, authenticator)
	if code != 1 || !strings.Contains(stderr.String(), "not a regular file") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "leave me\n" {
		t.Fatalf("symlink target changed: data=%q err=%v", data, err)
	}
}

// One unreadable stored-account file must not take down every other account:
// loadStoredCLIAccounts skips it, and the good accounts stay listable and
// usable while the skipped entry is reported.
func TestStoredAccountsSkipOneCorruptFileWithoutLosingTheRest(t *testing.T) {
	_, configEnv := useTestUserConfigDir(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()

	for _, credential := range []deviceCredential{
		{AccountID: blitzAccountID, AccountSlug: "blitz", AccountName: "Blitz", APIKey: testAPIKey(83)},
		{AccountID: immersiveAccountID, AccountSlug: "immersive", AccountName: "Immersive", APIKey: testAPIKey(84)},
	} {
		var stdout, stderr bytes.Buffer
		if code := storeCLIAccountCredential(srv.URL, credential, &stdout, &stderr); code != 0 {
			t.Fatalf("store credential: exit=%d stderr=%q", code, stderr.String())
		}
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	corruptName := cliAccountFilePrefix + strings.Repeat("ab", 32) + ".json"
	corrupt := filepath.Join(configDir, "emisar", "credentials", corruptName)
	if err := os.WriteFile(corrupt, []byte("{ not valid json"), 0o600); err != nil {
		t.Fatal(err)
	}

	accounts, skipped, err := loadStoredCLIAccounts()
	if err != nil {
		t.Fatalf("load stored accounts: %v", err)
	}
	if len(accounts) != 2 || len(skipped) != 1 || skipped[0].name != corruptName {
		t.Fatalf("accounts=%d skipped=%#v", len(accounts), skipped)
	}

	stdout, stderr, code := runMain(t, "", []string{"accounts", "list"}, configEnv)
	if code != 0 || !strings.Contains(stdout, "Blitz") || !strings.Contains(stdout, "Immersive") ||
		!strings.Contains(stderr, "could not be read") {
		t.Fatalf("accounts list: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "use", "blitz"}, configEnv)
	if code != 0 || !strings.Contains(stdout, "Blitz") {
		t.Fatalf("accounts use blitz: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestAccountsListUseAndOneCommandSelectionEndToEnd(t *testing.T) {
	_, configEnv := useTestUserConfigDir(t)
	blitzKey := testAPIKey(83)
	immersiveKey := testAPIKey(84)
	authorizations := make(chan string, 3)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorizations <- r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()

	for _, credential := range []deviceCredential{
		{AccountID: blitzAccountID, AccountSlug: "blitz", AccountName: "Blitz", APIKey: blitzKey},
		{AccountID: immersiveAccountID, AccountSlug: "immersive", AccountName: "Immersive", APIKey: immersiveKey},
	} {
		var stdout, stderr bytes.Buffer
		if code := storeCLIAccountCredential(srv.URL, credential, &stdout, &stderr); code != 0 {
			t.Fatalf("store credential: exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	}

	stdout, stderr, code := runMain(t, "", []string{"accounts", "list"}, configEnv)
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	if code != 0 || stderr != "" || len(lines) != 3 ||
		!strings.Contains(lines[0], "CURRENT") || !strings.Contains(lines[1], "Blitz") ||
		!slices.Equal(strings.Fields(lines[2]), []string{"*", "Immersive", "immersive", srv.URL}) {
		t.Fatalf("accounts list: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	for _, key := range []string{blitzKey, immersiveKey} {
		if strings.Contains(stdout, key) || strings.Contains(stderr, key) {
			t.Fatal("accounts list disclosed an API key")
		}
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "list", "--json"}, configEnv)
	var listed []accountListEntry
	if code != 0 || stderr != "" || json.Unmarshal([]byte(stdout), &listed) != nil ||
		len(listed) != 2 || listed[0].Current || !listed[1].Current {
		t.Fatalf("accounts list JSON: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "use", "blitz"}, configEnv)
	if code != 0 || stderr != "" || !strings.Contains(stdout, "Using Blitz (blitz)") {
		t.Fatalf("accounts use: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	stdout, stderr, code = runMain(t, "", []string{"list_tools", "--json"}, configEnv)
	if code != 0 || stderr != "" || strings.TrimSpace(stdout) != "[]" || <-authorizations != "Bearer "+blitzKey {
		t.Fatalf("current account call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"--account", "immersive", "list_tools", "--json"}, configEnv)
	if code != 0 || stderr != "" || strings.TrimSpace(stdout) != "[]" || <-authorizations != "Bearer "+immersiveKey {
		t.Fatalf("one-command account call: exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	_, state, err := loadCLICredential("")
	if err != nil || state.AccountID != blitzAccountID {
		t.Fatalf("one-command selection changed current account: %#v, %v", state, err)
	}
}

func TestAccountSlugAmbiguityFailsClosed(t *testing.T) {
	configDir, _ := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, "https://one.example", blitzAccountID, "shared", "One", testAPIKey(1), false)
	storeTestCLIAccount(t, configDir, "https://two.example", immersiveAccountID, "shared", "Two", testAPIKey(2), false)

	var stdout, stderr bytes.Buffer
	code := runAccountsCommand([]string{"use", "shared"}, &stdout, &stderr)
	if code != 1 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "multiple endpoints") {
		t.Fatalf("ambiguous use exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	stdout.Reset()
	stderr.Reset()
	code = runAccountsCommand([]string{"use", blitzAccountID}, &stdout, &stderr)
	if code != 0 || stderr.Len() != 0 || !strings.Contains(stdout.String(), "Using One (shared)") {
		t.Fatalf("ID use exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestAccountSelectorsAreValidatedBeforeConfiguration(t *testing.T) {
	for _, account := range []string{"../blitz", "Blitz", "-blitz", "ab", strings.Repeat("a", 65)} {
		stdout, stderr, code := runMain(t, "", []string{"--account", account, "auth", "status"}, nil)
		if code != 2 || stdout != "" ||
			(!strings.Contains(stderr, "Account must be") && !strings.Contains(stderr, "--account <slug-or-id>")) {
			t.Errorf("account %q: exit=%d stdout=%q stderr=%q", account, code, stdout, stderr)
		}
	}

	var stdout, stderr bytes.Buffer
	code := runAccountsCommand([]string{"use", "../blitz"}, &stdout, &stderr)
	if code != 2 || stdout.Len() != 0 || !strings.Contains(stderr.String(), "Account must be") {
		t.Fatalf("accounts use: exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestAccountFlagOnlySelectsStoredCommandsAndAuthStatus(t *testing.T) {
	useTestUserConfigDir(t)
	for _, args := range [][]string{
		{"--account", "blitz", "auth"},
		{"--account", "blitz", "auth", "login"},
		{"--account", "blitz", "auth", "import", testEndpointOrigin},
	} {
		stdout, stderr, code := runMain(t, "", args, nil)
		if code != 2 || stdout != "" ||
			!strings.Contains(stderr, "Error: --account only works with auth status") ||
			!strings.Contains(stderr, "Usage:\n  emisar-mcp auth") {
			t.Errorf("%v: exit=%d stdout=%q stderr=%q", args, code, stdout, stderr)
		}
	}
}

func TestInteractiveNoCommandPrintsHelpWithoutConfiguration(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := runProgramMode(nil, strings.NewReader(""), &stdout, &stderr, true)
	if code != 0 || stdout.String() != helpText || stderr.Len() != 0 {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestAuthStatusExplainsHowToAuthenticateOrChooseAnAccount(t *testing.T) {
	useTestUserConfigDir(t)
	var stdout, stderr bytes.Buffer
	code := runAuthCommand("", []string{"status"}, &stdout, &stderr)
	if code != 1 || stdout.Len() != 0 ||
		!strings.Contains(stderr.String(), "Error: No account is selected") ||
		!strings.Contains(stderr.String(), "Run `emisar-mcp auth`") ||
		!strings.Contains(stderr.String(), "Run `emisar-mcp accounts list`") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestAuthHelpAndUsageDoNotRequireConfiguration(t *testing.T) {
	stdout, stderr, code := runMain(t, "", []string{"auth", "--help"}, nil)
	if code != 0 || stdout != authHelpText || stderr != "" {
		t.Fatalf("help exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	secret := testAPIKey(78)
	stdout, stderr, code = runMain(t, "", []string{"auth", "import", testEndpointOrigin, secret}, nil)
	if code != 2 || stdout != "" ||
		!strings.Contains(stderr, "Error: Invalid auth command") ||
		!strings.Contains(stderr, "Usage:\n  emisar-mcp auth") {
		t.Fatalf("usage exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if strings.Contains(stderr, secret) {
		t.Fatal("invalid auth invocation echoed an argv secret")
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "--help"}, nil)
	if code != 0 || stdout != accountsHelpText || stderr != "" {
		t.Fatalf("accounts help exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	for _, args := range [][]string{
		{"auth", "login", "--help"},
		{"auth", "status", "--help"},
	} {
		stdout, stderr, code = runMain(t, "", args, nil)
		if code != 0 || stdout != authHelpText || stderr != "" {
			t.Errorf("%v: exit=%d stdout=%q stderr=%q", args, code, stdout, stderr)
		}
	}
	for _, args := range [][]string{
		{"accounts", "list", "--help"},
		{"accounts", "use", "--help"},
	} {
		stdout, stderr, code = runMain(t, "", args, nil)
		if code != 0 || stdout != accountsHelpText || stderr != "" {
			t.Errorf("%v: exit=%d stdout=%q stderr=%q", args, code, stdout, stderr)
		}
	}
}

func TestDeviceCredentialRequiresCompleteSafeAccountIdentity(t *testing.T) {
	key := testAPIKey(1)
	valid := deviceTokenResponse{
		AccountID:   blitzAccountID,
		AccountSlug: "blitz",
		AccountName: "Blitz",
		ClientKeys:  map[string]string{deviceAuthClientID: key},
	}
	for name, mutate := range map[string]func(*deviceTokenResponse){
		"missing ID":   func(response *deviceTokenResponse) { response.AccountID = "" },
		"invalid slug": func(response *deviceTokenResponse) { response.AccountSlug = "Blitz" },
		"empty name":   func(response *deviceTokenResponse) { response.AccountName = "\x1b\u202e" },
		"invalid key":  func(response *deviceTokenResponse) { response.ClientKeys[deviceAuthClientID] = "emk-short" },
	} {
		t.Run(name, func(t *testing.T) {
			response := valid
			response.ClientKeys = map[string]string{deviceAuthClientID: key}
			mutate(&response)
			if _, err := response.cliCredential(); err == nil {
				t.Fatal("unsafe approval identity was accepted")
			}
		})
	}
}

// An unsafe or corrupt stored-account file is skipped and reported, never
// silently dropped and never trusted: listing no longer takes down the whole
// directory, but the account it names stays unusable so the credential still
// fails closed.
func TestStoredCLIAccountUnsafeStateIsSkippedButUnusable(t *testing.T) {
	tests := []struct {
		name    string
		content string
		mode    os.FileMode
		want    string
	}{
		{"malformed JSON", "{nope\n", 0o600, "decode credential state"},
		{"multiple values", "{} {}\n", 0o600, "decode credential state"},
		{"oversized", strings.Repeat("x", maxCredentialStateBytes+1), 0o600, "limit is"},
		{"unsafe mode", "{}\n", 0o644, "want owner-only"},
		{
			"terminal-empty account name",
			fmt.Sprintf(
				`{"version":1,"endpoint_origin":%q,"account_id":%q,"account_slug":"blitz","account_name":"\u001b\u202e","bootstrap_prefix":"emk-prefix","current":%q}`,
				testEndpointOrigin,
				blitzAccountID,
				testAPIKey(1),
			),
			0o600,
			"invalid account name",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if runtime.GOOS == "windows" && test.name == "unsafe mode" {
				t.Skip("Windows does not expose Unix permission bits")
			}
			configDir, _ := useTestUserConfigDir(t)
			store := newCLIAccountCredentialStoreAt(configDir, blitzAccountID, testEndpointOrigin, "emk-prefix")
			if err := os.MkdirAll(filepath.Dir(store.path), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(store.path, []byte(test.content), test.mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(store.path, test.mode); err != nil {
				t.Fatal(err)
			}

			// Listing skips the broken file and reports it, rather than failing
			// the whole command; no hostile account bytes reach stdout.
			var stdout, stderr bytes.Buffer
			code := runAccountsCommand([]string{"list"}, &stdout, &stderr)
			if code != 0 || strings.Contains(stdout.String(), "\x1b") ||
				!strings.Contains(stderr.String(), test.want) || !strings.Contains(stderr.String(), "could not be read") {
				t.Fatalf("list exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}

			// The account is still not usable: selecting its credential fails
			// closed and surfaces the cause, so a broken file is never trusted.
			if _, _, err := loadCLICredential(blitzAccountID); err == nil ||
				!strings.Contains(err.Error(), test.want) {
				t.Fatalf("loadCLICredential must fail closed on the broken account: %v", err)
			}
		})
	}
}

func TestDirectCLIUsesStoredAccountButStdioDoesNot(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	key := testAPIKey(73)
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()
	storeTestCLIAccount(t, configDir, srv.URL, blitzAccountID, "blitz", "Blitz", key, true)

	stdout, stderr, code := runMain(t, "", []string{"list_tools", "--json"}, configEnv)
	if code != 0 || strings.TrimSpace(stdout) != "[]" || stderr != "" {
		t.Fatalf("direct CLI exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if authorization != "Bearer "+key {
		t.Fatalf("Authorization = %q", authorization)
	}

	stdout, stderr, code = runMain(t, "", nil, configEnv)
	if code != 1 || stdout != "" || !strings.Contains(stderr, "EMISAR_URL and EMISAR_API_KEY must both be set") {
		t.Fatalf("stdio exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestDirectCLIExplicitEnvironmentOverridesStoredAccount(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)

	explicitKey := "explicit-bearer"
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		writeCLIResult(t, w, r, `{"tools":[]}`)
	}))
	defer srv.Close()
	configEnv["EMISAR_URL"] = srv.URL
	configEnv["EMISAR_API_KEY"] = explicitKey

	_, stderr, code := runMain(t, "", []string{"list_tools"}, configEnv)
	if code != 0 || stderr != "" {
		t.Fatalf("exit=%d stderr=%q", code, stderr)
	}
	if authorization != "Bearer "+explicitKey {
		t.Fatalf("Authorization = %q, stored credential overrode explicit env", authorization)
	}
}

func TestDirectCLIRejectsAccountFlagWithExplicitEnvironment(t *testing.T) {
	_, configEnv := useTestUserConfigDir(t)
	configEnv["EMISAR_URL"] = testEndpointOrigin
	configEnv["EMISAR_API_KEY"] = testAPIKey(74)

	stdout, stderr, code := runMain(t, "", []string{"--account", "blitz", "list_tools"}, configEnv)
	if code != 1 || stdout != "" || !strings.Contains(stderr, "cannot be combined") {
		t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestAccountSelectionRefusesEnvironmentOverride(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)
	storeTestCLIAccount(t, configDir, "https://other.example", immersiveAccountID, "immersive", "Immersive", testAPIKey(75), false)
	configEnv["EMISAR_URL"] = testEndpointOrigin
	configEnv["EMISAR_API_KEY"] = testAPIKey(76)

	stdout, stderr, code := runMain(t, "", []string{"accounts", "use", "immersive"}, configEnv)
	if code != 1 || stdout != "" || !strings.Contains(stderr, "overrides stored accounts") {
		t.Fatalf("use exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	_, state, err := loadCLICredential("")
	if err != nil || state.AccountID != blitzAccountID {
		t.Fatalf("environment override changed current account: %#v, %v", state, err)
	}
}

func TestAuthStatusWarnsWhenEnvironmentOverridesStoredAccount(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)
	configEnv["EMISAR_URL"] = testEndpointOrigin
	configEnv["EMISAR_API_KEY"] = testAPIKey(75)

	stdout, stderr, code := runMain(t, "", []string{"auth", "status"}, configEnv)
	if code != 0 || !strings.Contains(stdout, "Account: Blitz (blitz)") ||
		!strings.Contains(stderr, "overrides stored accounts") {
		t.Fatalf("status exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestAccountsListHasNoCurrentAccountDuringEnvironmentOverride(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)
	configEnv["EMISAR_URL"] = testEndpointOrigin
	configEnv["EMISAR_API_KEY"] = testAPIKey(75)

	stdout, stderr, code := runMain(t, "", []string{"accounts", "list"}, configEnv)
	if code != 0 || strings.Contains(stdout, "*") ||
		!strings.Contains(stderr, "overrides stored accounts") {
		t.Fatalf("human list exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "list", "--json"}, configEnv)
	var entries []accountListEntry
	if code != 0 || json.Unmarshal([]byte(stdout), &entries) != nil || len(entries) != 1 ||
		entries[0].Current || !strings.Contains(stderr, "overrides stored accounts") {
		t.Fatalf("JSON list exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestPartialAuthenticationEnvironmentWarnsWithoutHidingCurrentAccount(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)
	configEnv["EMISAR_URL"] = testEndpointOrigin

	stdout, stderr, code := runMain(t, "", []string{"accounts", "list"}, configEnv)
	if code != 0 || !strings.Contains(stdout, "*") || !strings.Contains(stdout, "Blitz") ||
		!strings.Contains(stderr, "Warning: Authentication environment is incomplete") ||
		!strings.Contains(stderr, "EMISAR_API_KEY is not") ||
		strings.Contains(stderr, "Environment credentials are active") {
		t.Fatalf("list exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	stdout, stderr, code = runMain(t, "", []string{"accounts", "use", "blitz"}, configEnv)
	if code != 1 || stdout != "" ||
		!strings.Contains(stderr, "Error: Authentication environment is incomplete") ||
		!strings.Contains(stderr, "Set both EMISAR_URL and EMISAR_API_KEY") {
		t.Fatalf("use exit=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestEmptyAuthenticationEnvironmentIsNotAnActiveOverride(t *testing.T) {
	tests := []struct {
		name string
		env  map[string]string
		want string
	}{
		{
			name: "both empty",
			env:  map[string]string{"EMISAR_URL": "", "EMISAR_API_KEY": ""},
			want: "EMISAR_URL is empty",
		},
		{
			name: "whitespace key",
			env: map[string]string{
				"EMISAR_URL":     testEndpointOrigin,
				"EMISAR_API_KEY": " \n\t ",
			},
			want: "EMISAR_API_KEY is empty",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			configDir, configEnv := useTestUserConfigDir(t)
			storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", testAPIKey(74), true)
			for name, value := range test.env {
				configEnv[name] = value
			}

			stdout, stderr, code := runMain(t, "", []string{"accounts", "list"}, configEnv)
			if code != 0 || !strings.Contains(stdout, "*") ||
				!strings.Contains(stderr, "Warning: Authentication environment is incomplete") ||
				!strings.Contains(stderr, test.want) ||
				strings.Contains(stderr, "Environment credentials are active") {
				t.Fatalf("list exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
		})
	}
}

func TestDirectCLINeverCompletesPartialEnvironmentFromStoredAccount(t *testing.T) {
	configDir, configEnv := useTestUserConfigDir(t)
	key := testAPIKey(75)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", key, true)

	for name, override := range map[string]map[string]string{
		"URL only":       {"EMISAR_URL": testEndpointOrigin},
		"key only":       {"EMISAR_API_KEY": key},
		"empty URL":      {"EMISAR_URL": ""},
		"whitespace key": {"EMISAR_API_KEY": " \n"},
	} {
		t.Run(name, func(t *testing.T) {
			env := copyStringMap(configEnv)
			for key, value := range override {
				env[key] = value
			}
			stdout, stderr, code := runMain(t, "", []string{"list_tools"}, env)
			if code != 1 || stdout != "" || !strings.Contains(stderr, "must be set") {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout, stderr)
			}
		})
	}
}

func TestStoredCLIAccountKeepsRotationInAccountState(t *testing.T) {
	configDir, _ := useTestUserConfigDir(t)
	key := testAPIKey(76)
	storeTestCLIAccount(t, configDir, testEndpointOrigin, blitzAccountID, "blitz", "Blitz", key, true)
	store := newCLIAccountCredentialStoreAt(configDir, blitzAccountID, testEndpointOrigin, keyPrefix(key))

	b, err := newBridgeFromEnv("emisar-mcp-cli", true, "blitz", io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if b.credentialStore == nil || b.credentialStore.path != store.path {
		t.Fatalf("bridge credential store = %#v, want %s", b.credentialStore, store.path)
	}
	if !strings.HasPrefix(filepath.Base(store.path), cliAccountFilePrefix) {
		t.Fatalf("account credential path = %q", store.path)
	}
	prefix, hash := b.rotationProposal()
	if prefix == "" || hash == "" {
		t.Fatal("stored CLI credential did not prepare a rotation")
	}
	loaded, err := store.load("")
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Current != key || loaded.Pending == "" || keyPrefix(loaded.Pending) != prefix {
		t.Fatalf("rotated state = %#v", loaded)
	}
}

func newBrowserAuthServer(
	t *testing.T,
	accountID, accountSlug, accountName, key string,
) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/mcp/device_authorization":
			origin := "http://" + r.Host
			_ = json.NewEncoder(w).Encode(map[string]any{
				"device_code":               "emdg-0123456789abcdef",
				"user_code":                 "ABCD-2345",
				"verification_uri":          origin + "/activate",
				"verification_uri_complete": origin + "/activate?code=ABCD-2345",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/mcp/device_token":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"account_id":   accountID,
				"account_slug": accountSlug,
				"account_name": accountName,
				"client_keys":  map[string]string{deviceAuthClientID: key},
			})
		default:
			http.NotFound(w, r)
		}
	}))
}

func storeTestCLIAccount(
	t *testing.T,
	configDir, endpoint, accountID, accountSlug, accountName, key string,
	current bool,
) {
	t.Helper()
	store := newCLIAccountCredentialStoreAt(configDir, accountID, endpoint, keyPrefix(key))
	if err := store.persist(credentialState{
		Version:         credentialStateVersion,
		EndpointOrigin:  endpoint,
		AccountID:       accountID,
		AccountSlug:     accountSlug,
		AccountName:     accountName,
		BootstrapPrefix: keyPrefix(key),
		Current:         key,
	}); err != nil {
		t.Fatal(err)
	}
	if current {
		if err := writeAccountSelection(accountSelection{
			Version:        accountSelectionVersion,
			EndpointOrigin: endpoint,
			AccountID:      accountID,
		}); err != nil {
			t.Fatal(err)
		}
	}
}

func useTestUserConfigDir(t *testing.T) (string, map[string]string) {
	t.Helper()
	root := t.TempDir()
	env := map[string]string{}
	switch runtime.GOOS {
	case "windows":
		t.Setenv("APPDATA", root)
		env["APPDATA"] = root
	case "darwin":
		t.Setenv("HOME", root)
		env["HOME"] = root
		root = filepath.Join(root, "Library", "Application Support")
	default:
		t.Setenv("XDG_CONFIG_HOME", root)
		env["XDG_CONFIG_HOME"] = root
	}
	t.Setenv("EMISAR_URL", "")
	_ = os.Unsetenv("EMISAR_URL")
	t.Setenv("EMISAR_API_KEY", "")
	_ = os.Unsetenv("EMISAR_API_KEY")
	t.Setenv("EMISAR_ALLOW_INSECURE", "")
	return root, env
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != want {
		t.Fatalf("%s mode = %04o, want %04o", path, info.Mode().Perm(), want)
	}
}

func copyStringMap(source map[string]string) map[string]string {
	copy := make(map[string]string, len(source))
	for key, value := range source {
		copy[key] = value
	}
	return copy
}
