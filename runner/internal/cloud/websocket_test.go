package cloud

import (
	"context"
	"encoding/json"
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
		_ = json.NewEncoder(w).Encode(map[string]any{
			"runner_id":  "agt_test_001",
			"token":      fc.mintedToken,
			"account_id": "acct_test",
		})
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

	conn, agentID, err := d.Dial(ctx)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	if agentID != "agt_test_001" {
		t.Errorf("runner_id = %q, want %q", agentID, "agt_test_001")
	}

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
		Token   string `json:"token"`
		AgentID string `json:"runner_id"`
	}
	_ = json.Unmarshal(body, &stored)
	if stored.Token != fc.mintedToken {
		t.Errorf("stored token = %q, want %q", stored.Token, fc.mintedToken)
	}

	if fc.registerSeen != 1 {
		t.Errorf("register called %d times, want 1", fc.registerSeen)
	}

	// Drain the server-side ws so the goroutine doesn't leak.
	srvConn := <-fc.wsAccepted
	srvConn.Close(websocket.StatusNormalClosure, "")
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

	conn, _, err := d.Dial(ctx)
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

			conn, _, err := d.Dial(ctx)
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
	body := []byte(`{"token":"t","runner_id":"r"}`)

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

// readToken parses two backward-compatible on-disk shapes: a legacy JSON token
// file using the old `agent_id` field (renamed to `runner_id`), and a token
// file holding just the raw token bytes (an even earlier format). Both must
// still load so a runner upgraded from an older build reuses its token instead
// of needlessly re-registering.
func TestReadToken_LegacyAgentIDAndRawString(t *testing.T) {
	dir := t.TempDir()

	t.Run("legacy agent_id JSON", func(t *testing.T) {
		p := filepath.Join(dir, "legacy.json")
		// Old field name `agent_id`, no `runner_id`.
		if err := os.WriteFile(p, []byte(`{"token":"tok-legacy","agent_id":"agt_old_42","key_fp":"abcd"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		tok, err := (&WebsocketDialer{TokenPath: p}).readToken()
		if err != nil {
			t.Fatalf("legacy agent_id token should parse: %v", err)
		}
		if tok.Raw != "tok-legacy" {
			t.Errorf("Raw = %q, want tok-legacy", tok.Raw)
		}
		// The legacy agent_id is read into AgentID when runner_id is absent.
		if tok.AgentID != "agt_old_42" {
			t.Errorf("AgentID = %q, want the legacy agent_id agt_old_42", tok.AgentID)
		}
		if tok.KeyFP != "abcd" {
			t.Errorf("KeyFP = %q, want abcd", tok.KeyFP)
		}
	})

	t.Run("runner_id wins over legacy agent_id", func(t *testing.T) {
		p := filepath.Join(dir, "both.json")
		// Both fields present — the new runner_id must take precedence.
		if err := os.WriteFile(p, []byte(`{"token":"t","runner_id":"new_id","agent_id":"old_id"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		tok, err := (&WebsocketDialer{TokenPath: p}).readToken()
		if err != nil {
			t.Fatalf("readToken: %v", err)
		}
		if tok.AgentID != "new_id" {
			t.Errorf("AgentID = %q, want runner_id to win (new_id)", tok.AgentID)
		}
	})

	t.Run("raw-string token", func(t *testing.T) {
		p := filepath.Join(dir, "raw.token")
		// Not JSON — an even older format stored the raw token bytes.
		if err := os.WriteFile(p, []byte("  raw-token-bytes\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		tok, err := (&WebsocketDialer{TokenPath: p}).readToken()
		if err != nil {
			t.Fatalf("raw-string token should parse: %v", err)
		}
		// Trimmed, taken as the token; no id/fp.
		if tok.Raw != "raw-token-bytes" {
			t.Errorf("Raw = %q, want the trimmed raw bytes", tok.Raw)
		}
		if tok.AgentID != "" || tok.KeyFP != "" {
			t.Errorf("raw-string token carries no id/fp, got AgentID=%q KeyFP=%q", tok.AgentID, tok.KeyFP)
		}
	})

	t.Run("empty file is an error", func(t *testing.T) {
		p := filepath.Join(dir, "empty.token")
		if err := os.WriteFile(p, []byte("   \n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := (&WebsocketDialer{TokenPath: p}).readToken(); err == nil {
			t.Error("an empty token file must error, not yield a blank token")
		}
	})
}

func TestWebsocketDialerReusesCachedToken(t *testing.T) {
	fc, srv := newFakeCloud(t)

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	// Pre-seed the token file.
	cached, _ := json.Marshal(map[string]string{
		"token":     fc.mintedToken,
		"runner_id": "agt_cached_007",
	})
	if err := os.WriteFile(tokenPath, cached, 0o600); err != nil {
		t.Fatalf("seed token: %v", err)
	}

	d := &WebsocketDialer{
		URL:        srv.URL,
		AuthKey:    "should-not-be-used",
		TokenPath:  tokenPath,
		Hostname:   "test-host",
		Group:      "default",
		ExternalID: "stable-id-123",
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, _, err := d.Dial(ctx)
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
		"token":     "token-from-old-account",
		"runner_id": "agt_old",
		"key_fp":    keyFingerprint("emkey-auth-OLD-account"),
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

	conn, _, err := d.Dial(ctx)
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
		"token":     fc.mintedToken,
		"runner_id": "agt_cached",
		"key_fp":    keyFingerprint(fc.authKey),
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

	conn, _, err := d.Dial(ctx)
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

	_, _, err := d.Dial(ctx)
	if err == nil {
		t.Fatal("expected unauthorized error")
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Errorf("error = %v, want to contain 'unauthorized'", err)
	}
	_ = fc
}

func TestWebsocketDialer401OnUpgradeDropsCachedToken(t *testing.T) {
	fc, srv := newFakeCloud(t)
	fc.failWSUpgrade = true

	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token.json")

	cached, _ := json.Marshal(map[string]string{
		"token":     "stale-token",
		"runner_id": "agt_cached",
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

	_, _, err := d.Dial(ctx)
	if err == nil {
		t.Fatal("expected error from 401 upgrade")
	}

	// Token file should have been removed so the next attempt re-registers.
	if _, statErr := os.Stat(tokenPath); !os.IsNotExist(statErr) {
		t.Errorf("expected token file removed after 401; stat err = %v", statErr)
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
