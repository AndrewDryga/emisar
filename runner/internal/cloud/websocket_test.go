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

	"nhooyr.io/websocket"
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
		URL:       srv.URL,
		AuthKey:   fc.authKey,
		TokenPath: tokenPath,
		Hostname:  "test-host",
		Group:     "default",
		Version:   "0.test",
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
		URL:       srv.URL,
		AuthKey:   "should-not-be-used",
		TokenPath: tokenPath,
		Hostname:  "test-host",
		Group:     "default",
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

func TestWebsocketDialer401OnRegisterIsUnauthorized(t *testing.T) {
	fc, srv := newFakeCloud(t)

	d := &WebsocketDialer{
		URL:       srv.URL,
		AuthKey:   "emkey-auth-WRONG",
		TokenPath: filepath.Join(t.TempDir(), "token.json"),
		Hostname:  "test-host",
		Group:     "default",
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
		URL:       srv.URL,
		AuthKey:   "",
		TokenPath: tokenPath,
		Hostname:  "test-host",
		Group:     "default",
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
		{"https://app.emisar.dev", "wss://app.emisar.dev/runner/socket/websocket"},
		{"https://app.emisar.dev/", "wss://app.emisar.dev/runner/socket/websocket"},
		{"wss://app.emisar.dev", "wss://app.emisar.dev/runner/socket/websocket"},
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
