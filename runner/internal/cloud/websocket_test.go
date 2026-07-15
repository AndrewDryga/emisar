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
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeCloud is a stand-in for the Phoenix control plane. It implements
// just enough of the runner transport (POST /runner/register +
// GET /runner/socket/websocket) for the dialer tests below to drive a
// real round trip.
type fakeCloud struct {
	authKey       string
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
		authKey:     "emkey-auth-good",
		mintedToken: "rnrtok-minted-once",
		wsAccepted:  make(chan *websocket.Conn, 1),
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/runner/register", func(w http.ResponseWriter, r *http.Request) {
		fc.registerSeen++

		if fc.failRegister {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		auth := r.Header.Get("Authorization")
		if auth != "Bearer "+fc.authKey {
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
		URL:        srv.URL,
		AuthKey:    fc.authKey,
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		Version:    "0.test",
		ExternalID: "stable-id-123",
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
	if stored.KeyFP != keyFingerprint(fc.authKey) {
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
	blocker := filepath.Join(dir, "not-a-directory")
	if err := os.WriteFile(blocker, []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}

	d := &WebsocketDialer{
		URL:        srv.URL,
		AuthKey:    fc.authKey,
		TokenPath:  filepath.Join(blocker, "token.json"),
		Hostname:   "test-host",
		Group:      "default",
		Version:    "0.test",
		ExternalID: "stable-id-123",
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
	if err := d.writeToken(agentToken{Raw: "new", KeyFP: "new-fingerprint"}); err == nil {
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
		URL:        srv.URL,
		AuthKey:    fc.authKey,
		TokenPath:  filepath.Join(t.TempDir(), "token.json"),
		Hostname:   "test-host",
		Group:      "default",
		Version:    "0.test",
		ExternalID: "stable-id-123",
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
				URL:        srv.URL,
				AuthKey:    fc.authKey,
				TokenPath:  filepath.Join(t.TempDir(), "token.json"),
				Hostname:   "test-host",
				Group:      "default",
				Version:    "0.test",
				ExternalID: externalID,
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

func TestWebsocketDialerReusesCachedToken(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// Pre-seed the token file.
	cached, _ := json.Marshal(map[string]string{
		"token":  fc.mintedToken,
		"key_fp": keyFingerprint(fc.authKey),
	})
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:        srv.URL,
		AuthKey:    fc.authKey,
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
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

func TestWebsocketDialerReregistersWhenAuthKeyRotated(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// A token minted under a *different* auth key: the runner was pointed at
	// a new account and EMISAR_AUTH_KEY was swapped under it. The cached
	// token is still well-formed, but its key fingerprint no longer matches.
	seeded, _ := json.Marshal(map[string]string{
		"token":  "token-from-old-account",
		"key_fp": keyFingerprint("emkey-auth-OLD-account"),
	})
	if err := os.WriteFile(tokenPath, seeded, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:        srv.URL,
		AuthKey:    fc.authKey, // the new account's key
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if fc.registerSeen != 1 {
		t.Errorf("register hit %d times, want 1 (auth key rotated → re-register)", fc.registerSeen)
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
	if stored.KeyFP != keyFingerprint(fc.authKey) {
		t.Errorf("stored key_fp = %q, want fingerprint of the new key", stored.KeyFP)
	}

	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
}

func TestWebsocketDialerReusesTokenWhenAuthKeyUnchanged(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// Token stamped with the same key the dialer is configured with — a
	// normal restart, no re-register.
	seeded, _ := json.Marshal(map[string]string{
		"token":  fc.mintedToken,
		"key_fp": keyFingerprint(fc.authKey),
	})
	if err := os.WriteFile(tokenPath, seeded, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:        srv.URL,
		AuthKey:    fc.authKey,
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
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
		URL:        srv.URL,
		AuthKey:    "emkey-auth-WRONG",
		TokenPath:  filepath.Join(t.TempDir(), "token.json"),
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
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

	d := &WebsocketDialer{URL: source.URL, AuthKey: "emkey-auth-secret", ExternalID: "stable-id"}
	if _, err := d.register(context.Background()); err == nil || !strings.Contains(err.Error(), "307") {
		t.Fatalf("register redirect error = %v, want refused 307", err)
	}
	if redirected {
		t.Fatal("authenticated registration redirect was followed")
	}
}

func TestWebsocketDialerRegistrationResponseIsBoundedAndExact(t *testing.T) {
	tests := map[string]string{
		"unknown field":     `{"token":"rnrtok-ok","extra":true}`,
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

			d := &WebsocketDialer{URL: srv.URL, AuthKey: "key", ExternalID: "stable-id"}
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
		URL:        srv.URL,
		AuthKey:    "",
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
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

func TestWebsocketDialer401SurfacesTokenRemovalFailure(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")
	cached, _ := json.Marshal(map[string]string{"token": "stale-token"})
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
