package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeCloud is a stand-in for the Phoenix control plane. It implements
// just enough of the runner transport (POST /runner/register +
// GET /runner/socket/websocket) for the dialer tests below to drive a
// real round trip.
type fakeCloud struct {
	enrollmentKey string
	mintedToken   string
	registerSeen  int
	wsAccepted    chan *websocket.Conn
	failRegister  bool
	failWSUpgrade bool
	lastRegister  map[string]any
}

func newFakeCloud(t *testing.T) (*fakeCloud, *httptest.Server) {
	t.Helper()

	fc := &fakeCloud{
		enrollmentKey: "emkey-enroll-good",
		mintedToken:   "rnrtok-minted-once",
		wsAccepted:    make(chan *websocket.Conn, 1),
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/runner/register", func(w http.ResponseWriter, r *http.Request) {
		fc.registerSeen++

		if fc.failRegister {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+fc.enrollmentKey {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		body, _ := io.ReadAll(r.Body)
		var got map[string]any
		_ = json.Unmarshal(body, &got)
		fc.lastRegister = got

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"token": fc.mintedToken})
	})

	mux.HandleFunc("/runner/socket/websocket", func(w http.ResponseWriter, r *http.Request) {
		if fc.failWSUpgrade {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+fc.mintedToken {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			t.Logf("ws accept: %v", err)
			return
		}
		fc.wsAccepted <- conn
		// Hold the conn open so the test goroutine can drive it.
		<-r.Context().Done()
	})

	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	return fc, srv
}

func TestWebsocketDialerRegistersAndConnects(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey,
		TokenPath:     tokenPath,
		Hostname:      "test-host",
		Group:         "default",
		Version:       "0.test",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	// Token was persisted with mode 0600 and contains the minted token.
	info, err := os.Stat(tokenPath)
	if err != nil {
		t.Fatalf("token file should exist: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("token file mode = %v, want 0600", info.Mode().Perm())
	}

	body, _ := os.ReadFile(tokenPath)
	var stored struct {
		Token string `json:"token"`
		KeyFP string `json:"key_fp"`
	}
	_ = json.Unmarshal(body, &stored)
	if stored.Token != fc.mintedToken {
		t.Errorf("stored token = %q, want %q", stored.Token, fc.mintedToken)
	}
	if stored.KeyFP != keyFingerprint(fc.enrollmentKey) {
		t.Errorf("stored key_fp = %q, want enrollment-key fingerprint", stored.KeyFP)
	}

	if fc.registerSeen != 1 {
		t.Errorf("register called %d times, want 1", fc.registerSeen)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "token.json" {
		t.Fatalf("token directory contains temporary files after activation: %v", entries)
	}

	// Drain the server-side ws so the goroutine doesn't leak.
	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialerDoesNotConnectBeforeTokenPersistence(t *testing.T) {
	fc, srv := newFakeCloud(t)
	dir := t.TempDir()
	// A token directory that reads as "no token yet" (so the dialer takes the
	// enrollment path) but can never be created: the path component is a
	// symlink to nothing, so the open resolves to ENOENT and the later
	// SecureMkdirAll refuses to replace the dangling link.
	stateDir := filepath.Join(dir, "state")
	if err := os.Symlink(filepath.Join(dir, "missing"), stateDir); err != nil {
		t.Fatal(err)
	}

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey,
		TokenPath:     filepath.Join(stateDir, "token.json"),
		Hostname:      "test-host",
		Group:         "default",
		Version:       "0.test",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if conn, err := d.Dial(ctx); err == nil {
		_ = conn.Close()
		t.Fatal("Dial succeeded without durably persisting the minted token")
	}
	if fc.registerSeen != 1 {
		t.Fatalf("register called %d times, want 1", fc.registerSeen)
	}
	select {
	case conn := <-fc.wsAccepted:
		_ = conn.Close(websocket.StatusInternalError, "unexpected connection")
		t.Fatal("WebSocket opened before token persistence")
	default:
	}
}

func TestWriteTokenLeavesTargetUntouchedWhenActivationFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "token.json")
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}
	originalPath := filepath.Join(path, "original")
	if err := os.WriteFile(originalPath, []byte("unchanged"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := &WebsocketDialer{TokenPath: path}
	if err := d.writeToken(runnerToken{Raw: "new", KeyFP: "new-fingerprint"}); err == nil {
		t.Fatal("writeToken replaced a directory target")
	}
	got, err := os.ReadFile(originalPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "unchanged" {
		t.Fatalf("failed replacement changed the target: got %q", got)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "token.json" {
		t.Fatalf("failed replacement left temporary files: %v", entries)
	}
}

func TestWebsocketDialerSendsExternalID(t *testing.T) {
	fc, srv := newFakeCloud(t)

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey,
		TokenPath:     filepath.Join(t.TempDir(), "token.json"),
		Hostname:      "test-host",
		Group:         "default",
		Version:       "0.test",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if got := fc.lastRegister["external_id"]; got != "stable-id-123" {
		t.Errorf("register external_id = %v, want stable-id-123", got)
	}

	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialerRejectsInvalidExternalIDBeforeRegistration(t *testing.T) {
	for name, externalID := range map[string]string{
		"blank":               "",
		"surrounding space":   " stable-id ",
		"over 255 characters": strings.Repeat("x", 256),
		"invalid UTF-8":       string([]byte{0xff}),
	} {
		t.Run(name, func(t *testing.T) {
			fc, srv := newFakeCloud(t)

			d := &WebsocketDialer{
				URL:           srv.URL,
				EnrollmentKey: fc.enrollmentKey,
				TokenPath:     filepath.Join(t.TempDir(), "token.json"),
				Hostname:      "test-host",
				Group:         "default",
				Version:       "0.test",
				ExternalID:    externalID,
			}

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			conn, err := d.Dial(ctx)
			if err == nil || !strings.Contains(err.Error(), "external id must be 1-255 characters") {
				t.Fatalf("Dial() = %v, %v; want external-id error", conn, err)
			}
			if got := fc.registerSeen; got != 0 {
				t.Fatalf("register requests = %d, want 0", got)
			}
		})
	}
}

func TestReadTokenRejectsSymlinkAndLoosePerms(t *testing.T) {
	dir := t.TempDir()
	body := []byte(`{"token":"t","key_fp":"fp"}`)

	// 0600 regular file reads fine.
	good := filepath.Join(dir, "token.json")
	if err := os.WriteFile(good, body, 0o600); err != nil {
		t.Fatal(err)
	}
	d := &WebsocketDialer{TokenPath: good}
	if tok, err := d.readToken(); err != nil || tok.Raw != "t" {
		t.Fatalf("0600 token should read: tok=%+v err=%v", tok, err)
	}

	// Loose perms → refused (the secret was exposed).
	loose := filepath.Join(dir, "loose.json")
	if err := os.WriteFile(loose, body, 0o644); err != nil {
		t.Fatal(err)
	}
	// WriteFile honors umask; force the exact bits under test.
	if err := os.Chmod(loose, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := (&WebsocketDialer{TokenPath: loose}).readToken(); err == nil {
		t.Error("0644 token should be refused")
	}

	// A symlink at the token path → refused (O_NOFOLLOW), even if it points
	// at a perfectly good 0600 file.
	link := filepath.Join(dir, "link.json")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	if _, err := (&WebsocketDialer{TokenPath: link}).readToken(); err == nil {
		t.Error("symlinked token path should be refused")
	}

	// A FIFO at the token path → refused, and refused WITHOUT blocking. Opening
	// a FIFO for reading parks in open(2) until a writer arrives, so the guard
	// has to be the O_NONBLOCK open flag; an fstat check alone never runs. The
	// deadline is what makes this a real assertion — a regression hangs here
	// rather than failing.
	fifo := filepath.Join(dir, "fifo.json")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		_, err := (&WebsocketDialer{TokenPath: fifo}).readToken()
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Errorf("fifo token path error = %v, want not-a-regular-file", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("reading a FIFO token path blocked — O_NONBLOCK is missing from the open")
	}
}

// ValidateTokenFile is what diagnostics use to judge a cached token without
// touching the secret. Its one load-bearing distinction: a missing file is
// os.ErrNotExist (not enrolled yet), while every other rejection is a host
// problem callers must surface. The parser itself is covered above.
func TestValidateTokenFile(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "token.json")
	if err := os.WriteFile(good, []byte(`{"token":"t"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateTokenFile(good); err != nil {
		t.Errorf("a 0600 token file connect accepts should validate: %v", err)
	}

	missing := filepath.Join(dir, "absent.json")
	if err := ValidateTokenFile(missing); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("missing token = %v, want os.ErrNotExist", err)
	}

	malformed := filepath.Join(dir, "malformed.json")
	if err := os.WriteFile(malformed, []byte(`{"token":`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateTokenFile(malformed); err == nil || errors.Is(err, os.ErrNotExist) {
		t.Errorf("malformed token = %v, want a rejection distinct from os.ErrNotExist", err)
	}
}

func TestReadTokenRejectsUnsupportedShapes(t *testing.T) {
	for name, body := range map[string]string{
		"raw string":        "raw-token-bytes\n",
		"agent id field":    `{"token":"t","agent_id":"old"}`,
		"runner id field":   `{"token":"t","runner_id":"old"}`,
		"unknown field":     `{"token":"t","extra":true}`,
		"trailing document": `{"token":"t"} {"token":"other"}`,
		"empty token":       `{"token":""}`,
		"empty file":        "   \n",
	} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "token.json")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := (&WebsocketDialer{TokenPath: path}).readToken(); err == nil {
				t.Fatal("readToken accepted an unsupported token-file shape")
			}
		})
	}
}

// A token cache the reader REJECTS (exposed perms, malformed contents) is a
// host problem, not a first-boot enrollment cue: Dial fails naming the path and
// the cause, and never registers over the file — doing so would mint a fresh
// token on top of the evidence, exactly what tampering wants.
func TestWebsocketDialerRefusesToRegisterOverRejectedTokenCache(t *testing.T) {
	for name, tc := range map[string]struct {
		body string
		perm os.FileMode
		// wantCauses are all the fragments the failure must carry — the cause,
		// and for a fixable host problem the exact remedy, so the operator can
		// act on the connect error without reaching for doctor.
		wantCauses []string
	}{
		"insecure perms": {`{"token":"rnrtok-cached"}`, 0o644, []string{"insecure perms", "chmod 600"}},
		"malformed":      {`{"token":`, 0o600, []string{"decode token file"}},
	} {
		t.Run(name, func(t *testing.T) {
			fc, srv := newFakeCloud(t)

			tokenPath := filepath.Join(t.TempDir(), "token.json")
			if err := os.WriteFile(tokenPath, []byte(tc.body), tc.perm); err != nil {
				t.Fatal(err)
			}
			// WriteFile honors umask; force the exact bits under test.
			if err := os.Chmod(tokenPath, tc.perm); err != nil {
				t.Fatal(err)
			}

			// An enrollment key is configured: registration is available and
			// must still not happen.
			d := &WebsocketDialer{
				URL:           srv.URL,
				EnrollmentKey: fc.enrollmentKey,
				TokenPath:     tokenPath,
				Hostname:      "test-host",
				Group:         "default",
				ExternalID:    "stable-id-123",
			}

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			conn, err := d.Dial(ctx)
			if err == nil {
				conn.Close()
				t.Fatal("Dial accepted a rejected token cache")
			}
			if !strings.Contains(err.Error(), tokenPath) {
				t.Errorf("error = %v, want it to name the token path %s", err, tokenPath)
			}
			for _, want := range tc.wantCauses {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error = %v, want it to preserve %q", err, want)
				}
			}
			if fc.registerSeen != 0 {
				t.Errorf("register hit %d times, want 0 — a rejected cache is never re-registered over", fc.registerSeen)
			}
			if body, err := os.ReadFile(tokenPath); err != nil || string(body) != tc.body {
				t.Errorf("token file = %q (%v), want it left untouched for the operator", body, err)
			}
		})
	}
}

func TestWebsocketDialerReusesCachedToken(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// Pre-seed the token file.
	cached, _ := json.Marshal(map[string]string{
		"token":  fc.mintedToken,
		"key_fp": keyFingerprint(fc.enrollmentKey),
	})
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey,
		TokenPath:     tokenPath,
		Hostname:      "test-host",
		Group:         "default",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if fc.registerSeen != 0 {
		t.Errorf("register hit %d times, want 0 (token was cached)", fc.registerSeen)
	}

	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialerReregistersWhenEnrollmentKeyRotated(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// A token minted under a *different* enrollment key: the runner was pointed at
	// a new account and EMISAR_ENROLLMENT_KEY was swapped under it. The cached
	// token is still well-formed, but its key fingerprint no longer matches.
	seeded, _ := json.Marshal(map[string]string{
		"token":  "token-from-old-account",
		"key_fp": keyFingerprint("emkey-enroll-OLD-account"),
	})
	if err := os.WriteFile(tokenPath, seeded, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey, // the new account's key
		TokenPath:     tokenPath,
		Hostname:      "test-host",
		Group:         "default",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if fc.registerSeen != 1 {
		t.Errorf("register hit %d times, want 1 (enrollment key rotated → re-register)", fc.registerSeen)
	}

	// The token file is rewritten with the freshly minted token and stamped
	// with the new key's fingerprint, so the next boot reuses it.
	body, _ := os.ReadFile(tokenPath)
	var stored struct {
		Token string `json:"token"`
		KeyFP string `json:"key_fp"`
	}
	_ = json.Unmarshal(body, &stored)
	if stored.Token != fc.mintedToken {
		t.Errorf("stored token = %q, want %q", stored.Token, fc.mintedToken)
	}
	if stored.KeyFP != keyFingerprint(fc.enrollmentKey) {
		t.Errorf("stored key_fp = %q, want fingerprint of the new key", stored.KeyFP)
	}

	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialerReusesTokenWhenEnrollmentKeyUnchanged(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// Token stamped with the same key the dialer is configured with — a
	// normal restart, no re-register.
	seeded, _ := json.Marshal(map[string]string{
		"token":  fc.mintedToken,
		"key_fp": keyFingerprint(fc.enrollmentKey),
	})
	if err := os.WriteFile(tokenPath, seeded, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: fc.enrollmentKey,
		TokenPath:     tokenPath,
		Hostname:      "test-host",
		Group:         "default",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if fc.registerSeen != 0 {
		t.Errorf("register hit %d times, want 0 (same key → reuse token)", fc.registerSeen)
	}

	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialer401OnRegisterIsUnauthorized(t *testing.T) {
	fc, srv := newFakeCloud(t)

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: "emkey-enroll-WRONG",
		TokenPath:     filepath.Join(t.TempDir(), "token.json"),
		Hostname:      "test-host",
		Group:         "default",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := d.Dial(ctx)
	if err == nil {
		t.Fatal("expected unauthorized error")
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Errorf("error = %v, want to contain 'unauthorized'", err)
	}
	_ = fc
}

func TestWebsocketDialerRefusesAuthenticatedRedirects(t *testing.T) {
	var redirected bool
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirected = true
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("redirect leaked Authorization = %q", got)
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"rnrtok-leaked"}`)
	}))
	defer destination.Close()

	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL+"/runner/register", http.StatusTemporaryRedirect)
	}))
	defer source.Close()

	d := &WebsocketDialer{URL: source.URL, EnrollmentKey: "emkey-enroll-secret", ExternalID: "stable-id"}
	if _, err := d.register(context.Background()); err == nil || !strings.Contains(err.Error(), "307") {
		t.Fatalf("register redirect error = %v, want refused 307", err)
	}
	if redirected {
		t.Fatal("authenticated registration redirect was followed")
	}
}

// A registration body that grows a field must not strand deployed runners: a
// fresh host has no cached token, so a rejection here is an enrollment that
// cannot happen at all. The size cap and the trailing-document check still
// bound the input — see the rejection table below.
func TestWebsocketDialerRegistrationAcceptsAnAddedField(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"rnrtok-ok","refresh_after":"2030-01-01T00:00:00Z","plan":"team","limit":5}`)
	}))
	defer srv.Close()

	d := &WebsocketDialer{URL: srv.URL, EnrollmentKey: "key", ExternalID: "stable-id"}
	token, err := d.register(context.Background())
	if err != nil {
		t.Fatalf("register rejected an additive response: %v", err)
	}
	if token.Raw != "rnrtok-ok" {
		t.Errorf("token = %q, want rnrtok-ok", token.Raw)
	}
}

func TestWebsocketDialerRegistrationResponseIsBoundedAndExact(t *testing.T) {
	tests := map[string]string{
		"trailing document": `{"token":"rnrtok-ok"} {"token":"other"}`,
		"whitespace token":  `{"token":" rnrtok-ok"}`,
		"oversized body":    `{"token":"` + strings.Repeat("x", maxRegistrationResponseBytes) + `"}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusCreated)
				_, _ = io.WriteString(w, body)
			}))
			defer srv.Close()

			d := &WebsocketDialer{URL: srv.URL, EnrollmentKey: "key", ExternalID: "stable-id"}
			if _, err := d.register(context.Background()); err == nil {
				t.Fatal("register accepted an invalid response")
			}
		})
	}
}

func TestWebsocketDialerHTTPClientHasHandshakeDeadline(t *testing.T) {
	d := &WebsocketDialer{}
	client := d.portalHTTPClient()
	if client.Timeout != cloudHandshakeTimeout {
		t.Fatalf("default HTTP timeout = %s, want %s", client.Timeout, cloudHandshakeTimeout)
	}
	req, _ := http.NewRequest(http.MethodGet, "https://other.example", nil)
	if err := client.CheckRedirect(req, nil); !errors.Is(err, http.ErrUseLastResponse) {
		t.Fatalf("redirect policy error = %v, want http.ErrUseLastResponse", err)
	}
}

func TestWebsocketWriteContextIsBounded(t *testing.T) {
	ctx, cancel := websocketWriteContext(context.Background())
	defer cancel()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("websocket write context has no deadline")
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || remaining > cloudWebsocketWriteTimeout {
		t.Fatalf("write deadline remaining = %s, want (0, %s]", remaining, cloudWebsocketWriteTimeout)
	}

	parent, parentCancel := context.WithTimeout(context.Background(), time.Second)
	defer parentCancel()
	ctx, cancel = websocketWriteContext(parent)
	defer cancel()
	deadline, _ = ctx.Deadline()
	if remaining := time.Until(deadline); remaining <= 0 || remaining > time.Second {
		t.Fatalf("earlier parent deadline was not preserved: %s", remaining)
	}
}

func TestWebsocketDialer401OnUpgradeDropsCachedToken(t *testing.T) {
	fc, srv := newFakeCloud(t)
	fc.failWSUpgrade = true

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	cached, _ := json.Marshal(map[string]string{
		"token": "stale-token",
	})
	_ = os.WriteFile(tokenPath, cached, 0o600)

	d := &WebsocketDialer{
		URL:           srv.URL,
		EnrollmentKey: "",
		TokenPath:     tokenPath,
		Hostname:      "test-host",
		Group:         "default",
		ExternalID:    "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := d.Dial(ctx)
	if err == nil {
		t.Fatal("expected error from 401 upgrade")
	}

	// Token file should have been removed so the next attempt re-registers.
	if _, statErr := os.Stat(tokenPath); !os.IsNotExist(statErr) {
		t.Errorf("expected token file removed after 401; stat err = %v", statErr)
	}
}

func TestWebsocketDialer403DisabledRetainsCachedToken(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")
	cached, _ := json.Marshal(cachedToken("valid-disabled-token"))
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "runner_disabled"})
	}))
	defer srv.Close()

	d := &WebsocketDialer{URL: srv.URL, TokenPath: tokenPath, ExternalID: "stable-id"}
	_, err := d.Dial(context.Background())
	if !errors.Is(err, ErrRunnerDisabled) {
		t.Fatalf("Dial error = %v, want ErrRunnerDisabled", err)
	}
	if got, readErr := os.ReadFile(tokenPath); readErr != nil || string(got) != string(cached) {
		t.Fatalf("cached token changed after disabled response: bytes=%q error=%v", got, readErr)
	}
}

func TestWebsocketDialer403AccountDisabledRetainsCachedToken(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")
	cached, _ := json.Marshal(cachedToken("valid-account-disabled-token"))
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "account_disabled"})
	}))
	defer srv.Close()

	d := &WebsocketDialer{URL: srv.URL, TokenPath: tokenPath, ExternalID: "stable-id"}
	_, err := d.Dial(context.Background())
	if !errors.Is(err, ErrAccountDisabled) {
		t.Fatalf("Dial error = %v, want ErrAccountDisabled", err)
	}
	if got, readErr := os.ReadFile(tokenPath); readErr != nil || string(got) != string(cached) {
		t.Fatalf("cached token changed after account disabled response: bytes=%q error=%v", got, readErr)
	}
}

// cachedToken builds the on-disk shape of a token in ordinary operation: one
// whose refresh horizon is still ahead, so a Dial goes straight to the socket.
// Without a refresh_after the dialer asks the portal for a successor first —
// correct for a pre-rotation token, but an extra request these tests are not
// about.
func cachedToken(raw string) map[string]string {
	return map[string]string{
		"token":         raw,
		"refresh_after": time.Now().Add(30 * 24 * time.Hour).Format(time.RFC3339),
	}
}

func TestWebsocketDialer401SurfacesTokenRemovalFailure(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")
	cached, _ := json.Marshal(cachedToken("stale-token"))
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatal(err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if err := os.Remove(tokenPath); err != nil {
			t.Error(err)
		}
		if err := os.Mkdir(tokenPath, 0o700); err != nil {
			t.Error(err)
		}
		if err := os.WriteFile(filepath.Join(tokenPath, "blocker"), []byte("x"), 0o600); err != nil {
			t.Error(err)
		}
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	d := &WebsocketDialer{URL: srv.URL, TokenPath: tokenPath, ExternalID: "stable-id"}
	_, err := d.Dial(context.Background())
	if !errors.Is(err, ErrUnauthorized) || !strings.Contains(err.Error(), "remove cached token") {
		t.Fatalf("Dial error = %v, want unauthorized removal failure", err)
	}
}

func TestWebsocketDialerDerivesWSScheme(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"http://localhost:4000", "ws://localhost:4000/runner/socket/websocket"},
		{"https://emisar.dev", "wss://emisar.dev/runner/socket/websocket"},
		{"https://emisar.dev/", "wss://emisar.dev/runner/socket/websocket"},
		{"wss://emisar.dev", "wss://emisar.dev/runner/socket/websocket"},
	}

	for _, c := range cases {
		d := &WebsocketDialer{URL: c.in}
		got, err := d.deriveWSURL()
		if err != nil {
			t.Errorf("%s: deriveWSURL: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: got %s, want %s", c.in, got, c.want)
		}
	}

	for _, invalid := range []string{"https:///missing-host", "https://user:pass@emisar.dev", "https://emisar.dev?token=x"} {
		if _, err := (&WebsocketDialer{URL: invalid}).deriveWSURL(); err == nil {
			t.Errorf("deriveWSURL accepted invalid base %q", invalid)
		}
	}
}

// The register POST is plain HTTP; a wss:// config (the form the runner
// dials for the socket) must be normalized to https:// or net/http
// rejects it with "unsupported protocol scheme".
func TestRegisterURLNormalizesScheme(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"https://emisar.dev", "https://emisar.dev/runner/register"},
		{"http://localhost:4000", "http://localhost:4000/runner/register"},
		{"wss://emisar.dev", "https://emisar.dev/runner/register"},
		{"ws://localhost:4000", "http://localhost:4000/runner/register"},
		{"wss://emisar.dev/", "https://emisar.dev/runner/register"},
	}
	for _, c := range cases {
		got, err := httpURL(c.in, "/runner/register")
		if err != nil {
			t.Errorf("%s: httpURL: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("%s: got %s, want %s", c.in, got, c.want)
		}
	}

	if _, err := httpURL("ftp://nope", "/x"); err == nil {
		t.Error("expected error for unsupported scheme ftp")
	}
}

// maybeRefreshToken is allowed to fail at every step, and every failure must
// return the caller's existing token. This is the property that lets rotation
// ship before expiry is enforced: a broken refresh degrades to "keep using the
// credential that already works", never to a failed connect.
func TestMaybeRefreshTokenNeverBlocksAConnect(t *testing.T) {
	current := runnerToken{Raw: "rnrtok-current", KeyFP: "fp"}

	cases := []struct {
		name    string
		handler http.HandlerFunc
	}{
		{"not due", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusConflict)
		}},
		{"portal error", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}},
		{"token rejected", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusUnauthorized)
		}},
		{"malformed body", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"tokn":"typo"}`))
		}},
		{"empty token", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"token":"   "}`))
		}},
		{"oversized body", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"token":"` + repeated("x", maxRegistrationResponseBytes+64) + `"}`))
		}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv := httptest.NewServer(c.handler)
			defer srv.Close()

			d := &WebsocketDialer{URL: srv.URL, TokenPath: filepath.Join(t.TempDir(), "token.json")}
			if got := d.maybeRefreshToken(context.Background(), current); got != current {
				t.Fatalf("refresh replaced the working token on %q: %+v", c.name, got)
			}
		})
	}

	// The portal is simply gone.
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	unreachable := srv.URL
	srv.Close()
	d := &WebsocketDialer{URL: unreachable, TokenPath: filepath.Join(t.TempDir(), "token.json")}
	if got := d.maybeRefreshToken(context.Background(), current); got != current {
		t.Fatalf("refresh replaced the working token when the portal was unreachable: %+v", got)
	}
}

// An empty RefreshAfter must mean ASK, not never.
//
// A token minted before rotation existed carries no expiry, and the portal
// states RefreshAfter only at enrollment and at refresh — it has no way to
// reach a connected runner and tell it otherwise. Treating empty as "never"
// deadlocks the two halves: the runner waits to be told, the portal waits to be
// asked, and those tokens can never migrate onto an expiring credential. That
// makes enforcing expiry impossible without locking those runners out on one
// day, which is the whole reason rotation shipped first.
func TestRefreshDue(t *testing.T) {
	now := time.Date(2026, 8, 5, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name         string
		refreshAfter string
		want         bool
	}{
		{"pre-rotation token asks once", "", true},
		{"horizon passed", now.Add(-time.Minute).Format(time.RFC3339), true},
		{"horizon exactly now", now.Format(time.RFC3339), true},
		{"horizon still ahead", now.Add(time.Minute).Format(time.RFC3339), false},
		// A corrupt store, not a migration — retrying it every connect would be
		// a hot loop against the portal.
		{"unparseable", "not-a-timestamp", false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			token := runnerToken{Raw: "rnrtok-x", RefreshAfter: c.refreshAfter}
			if got := token.refreshDue(now); got != c.want {
				t.Errorf("refreshDue(%q) = %v, want %v", c.refreshAfter, got, c.want)
			}
		})
	}
}

// A successor that cannot be written to disk must NOT be adopted: the runner
// would then be using a token it cannot reload after a restart. The outgoing
// token's grace window exists for exactly this.
func TestMaybeRefreshTokenKeepsTheOldTokenWhenPersistFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"token":"rnrtok-successor"}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	// Same unwritable shape the persistence test above uses.
	stateDir := filepath.Join(dir, "state")
	if err := os.Symlink(filepath.Join(dir, "missing"), stateDir); err != nil {
		t.Fatal(err)
	}

	current := runnerToken{Raw: "rnrtok-current", KeyFP: "fp"}
	d := &WebsocketDialer{URL: srv.URL, TokenPath: filepath.Join(stateDir, "token.json")}

	if got := d.maybeRefreshToken(context.Background(), current); got != current {
		t.Fatalf("adopted a successor that was never persisted: %+v", got)
	}
}

// The successful path: a durably persisted successor is adopted and reloads.
func TestMaybeRefreshTokenAdoptsAPersistedSuccessor(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer rnrtok-current" {
			t.Errorf("refresh authenticated with %q", got)
		}
		_, _ = w.Write([]byte(`{"token":"rnrtok-successor"}`))
	}))
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "token.json")
	d := &WebsocketDialer{URL: srv.URL, TokenPath: path}

	got := d.maybeRefreshToken(context.Background(), runnerToken{Raw: "rnrtok-current", KeyFP: "fp"})
	if got.Raw != "rnrtok-successor" || got.KeyFP != "fp" {
		t.Fatalf("successor not adopted: %+v", got)
	}

	reloaded, err := d.readToken()
	if err != nil {
		t.Fatalf("successor did not persist: %v", err)
	}
	if reloaded.Raw != "rnrtok-successor" {
		t.Fatalf("persisted token = %q, want the successor", reloaded.Raw)
	}
}

// The dialer is what knows when the session's credential becomes rotatable.
// The bookkeeping has to survive the case that actually strands a runner: a
// portal that will not grant the refresh. A deadline left in the past would
// make the client end the session on every heartbeat, so a declined refresh
// buys rotationRetryInterval instead — there are 30 days between eligibility
// and expiry, so hourly retries are ample margin.
func TestWebsocketDialerTracksTheSessionCredentialRotationDeadline(t *testing.T) {
	now := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	rfc := func(at time.Time) string { return at.UTC().Format(time.RFC3339) }

	tests := map[string]struct {
		token       runnerToken
		wantDueAt   time.Time
		wantDueNow  bool
		wantRetried bool
	}{
		"fresh token is not due until the portal's instant": {
			token:     runnerToken{Raw: "rnrtok-a", RefreshAfter: rfc(now.Add(60 * 24 * time.Hour))},
			wantDueAt: now.Add(60 * 24 * time.Hour),
		},
		"a refresh the portal declined retries after the interval": {
			token:       runnerToken{Raw: "rnrtok-a", RefreshAfter: rfc(now.Add(-time.Hour))},
			wantDueAt:   now.Add(rotationRetryInterval),
			wantRetried: true,
		},
		"a pre-rotation token retries after the interval": {
			token:       runnerToken{Raw: "rnrtok-a"},
			wantDueAt:   now.Add(rotationRetryInterval),
			wantRetried: true,
		},
		"a corrupt deadline retries after the interval": {
			token:       runnerToken{Raw: "rnrtok-a", RefreshAfter: "not-a-time"},
			wantDueAt:   now.Add(rotationRetryInterval),
			wantRetried: true,
		},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			d := &WebsocketDialer{}
			// Before any dial there is no session credential to judge.
			if d.CredentialRotationDue(now) {
				t.Fatal("rotation reported due before the first dial")
			}
			d.noteSessionCredential(tc.token, now)

			if d.CredentialRotationDue(now) {
				t.Errorf("rotation is due at the instant of the dial: deadline %s", d.rotateAfter)
			}
			if !d.rotateAfter.Equal(tc.wantDueAt) {
				t.Errorf("deadline = %s, want %s", d.rotateAfter, tc.wantDueAt)
			}
			if !d.CredentialRotationDue(tc.wantDueAt) {
				t.Errorf("rotation is not due at its own deadline %s", tc.wantDueAt)
			}
			// A declined refresh must not make the very next heartbeat recycle
			// the session — that is the reconnect storm this bound prevents.
			if tc.wantRetried && d.CredentialRotationDue(now.Add(time.Minute)) {
				t.Error("a declined refresh recycles the session a minute later")
			}
		})
	}
}
