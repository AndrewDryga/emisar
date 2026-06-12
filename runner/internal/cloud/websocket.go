package cloud

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

// WebsocketDialer is the real cloud transport. It does the two-step
// runner bootstrap (register → exchange auth key for per-runner token,
// then open the websocket) and wraps the resulting conn so the rest of
// the cloud package can treat send/recv as message-level.
//
// Token persistence:
//
//   - If the file at TokenPath exists and is non-empty, its contents
//     are used as the bearer for the websocket upgrade.
//   - Otherwise, AuthKey is presented to POST {URL}/runner/register; the
//     response token is persisted to TokenPath (perms 0600) and used.
//
// Auth-key revocation surfaces as HTTP 401 from /runner/register; the
// dialer returns an `unauthorized` error and exits — the runner will
// not retry forever against a bad key.
type WebsocketDialer struct {
	// URL is the cloud base, e.g. "https://emisar.dev" or
	// "http://localhost:4000". The dialer derives the register URL and
	// the ws URL from this base.
	URL string

	// AuthKey is the bootstrap secret (env-provided, typically). Only
	// consulted on first connect.
	AuthKey string

	// TokenPath is where the per-runner token is persisted between
	// boots. Parent dir is created with 0750 if missing.
	TokenPath string

	// Hostname + Group + Version are reported during register so the
	// cloud can label the runner row.
	Hostname string
	Group    string
	Version  string

	// ExternalID is the runner's durable identity: persisted across
	// boots and presented on every register so the cloud maps reconnects
	// back to the same runner row. When empty, the cloud assigns a fresh
	// id each register (older behavior — a new row per connect).
	ExternalID string

	// HTTPClient is used for /runner/register; defaults to a 10s-timeout
	// client. Tests can inject a stub.
	HTTPClient *http.Client

	// Logger; defaults to slog.Default().
	Logger *slog.Logger
}

// ErrUnauthorized is returned when /runner/register or the websocket
// upgrade comes back 401. Callers should fail closed.
var ErrUnauthorized = errors.New("cloud: unauthorized (bad or revoked auth key / token)")

// Dial implements cloud.Dialer. It ensures a token exists (calling
// register if needed), then opens the websocket and returns a wrapper
// satisfying cloud.Conn.
func (d *WebsocketDialer) Dial(ctx context.Context) (Conn, string, error) {
	log := d.Logger
	if log == nil {
		log = slog.Default()
	}

	if d.URL == "" {
		return nil, "", errors.New("cloud: WebsocketDialer.URL is empty")
	}

	token, err := d.loadOrMintToken(ctx)
	if err != nil {
		return nil, "", err
	}

	wsURL, err := d.deriveWSURL()
	if err != nil {
		return nil, "", err
	}

	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+token.Raw)

	log.Info("cloud.dial", "url", wsURL, "runner_id", token.AgentID)

	conn, resp, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: headers,
		HTTPClient: d.HTTPClient,
	})

	if err != nil {
		if resp != nil && resp.StatusCode == http.StatusUnauthorized {
			// Token was rejected — drop the file so the next attempt
			// re-runs /runner/register (in case the old token was rotated
			// or revoked).
			_ = os.Remove(d.TokenPath)
			return nil, "", fmt.Errorf("%w: ws upgrade returned 401", ErrUnauthorized)
		}
		return nil, "", fmt.Errorf("cloud: ws dial failed: %w", err)
	}

	// Disable the library's read-size cap; large action_result envelopes
	// can exceed the default 32KB.
	conn.SetReadLimit(8 * 1024 * 1024)

	return &wsConn{ws: conn, log: log}, token.AgentID, nil
}

// -- Token persistence ----------------------------------------------

type agentToken struct {
	Raw     string
	AgentID string
	// KeyFP fingerprints the auth key that minted this token, so a later
	// boot can tell when the operator swapped the key under it.
	KeyFP string
}

func (d *WebsocketDialer) loadOrMintToken(ctx context.Context) (agentToken, error) {
	if existing, err := d.readToken(); err == nil && existing.Raw != "" {
		// Reuse the cached token unless the operator has rotated the auth
		// key under it (e.g. moving the runner to another account): a
		// configured key whose fingerprint no longer matches the one stamped
		// on the token means re-register with the new key. An empty key
		// (operator unset it after first boot) or an unstamped legacy token
		// keeps the old reuse-always behavior.
		if d.AuthKey == "" || existing.KeyFP == "" || existing.KeyFP == keyFingerprint(d.AuthKey) {
			return existing, nil
		}
		d.logger().Info("cloud.auth_key_rotated",
			"path", d.TokenPath,
			"detail", "configured auth key no longer matches the cached token; re-registering")
		_ = os.Remove(d.TokenPath)
	}

	if d.AuthKey == "" {
		return agentToken{}, fmt.Errorf("%w: no token cached and no auth key provided", ErrUnauthorized)
	}

	token, err := d.register(ctx)
	if err != nil {
		return agentToken{}, err
	}
	token.KeyFP = keyFingerprint(d.AuthKey)

	if err := d.writeToken(token); err != nil {
		// Non-fatal: we proceed with the in-memory token but log that
		// we'll have to re-register next time.
		(d.logger()).Warn("cloud.token_persist_failed", "path", d.TokenPath, "error", err)
	}

	return token, nil
}

func (d *WebsocketDialer) readToken() (agentToken, error) {
	if d.TokenPath == "" {
		return agentToken{}, errors.New("no token path")
	}

	// The token is a bearer secret, so treat its path as hostile. O_NOFOLLOW
	// refuses to follow a symlink swapped in at TokenPath (which could point
	// the read somewhere it shouldn't, or be a marker for where a later write
	// leaks); a non-0600 file means the token was exposed (bad umask, manual
	// edit, tampering), so we reject it and let the caller re-register, which
	// rewrites a fresh 0600 file. We always WRITE 0600, so a clean install
	// never trips this.
	f, err := os.OpenFile(d.TokenPath, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return agentToken{}, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return agentToken{}, err
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return agentToken{}, fmt.Errorf("token file %s has insecure perms %#o (want 0600); refusing to reuse it", d.TokenPath, perm)
	}

	bytes, err := io.ReadAll(f)
	if err != nil {
		return agentToken{}, err
	}

	var stored struct {
		Token string `json:"token"`
		// Read both field names — the rename to `runner_id` left existing
		// dev installs with `agent_id` on disk. Prefer the new name.
		RunnerID    string `json:"runner_id"`
		LegacyAgent string `json:"agent_id"`
		KeyFP       string `json:"key_fp"`
	}

	if err := json.Unmarshal(bytes, &stored); err != nil {
		// Backwards compat: an earlier version may have stored just the
		// raw bytes. Treat that as the token.
		raw := strings.TrimSpace(string(bytes))
		if raw == "" {
			return agentToken{}, errors.New("token file empty")
		}
		return agentToken{Raw: raw}, nil
	}

	id := stored.RunnerID
	if id == "" {
		id = stored.LegacyAgent
	}
	return agentToken{Raw: stored.Token, AgentID: id, KeyFP: stored.KeyFP}, nil
}

func (d *WebsocketDialer) writeToken(t agentToken) error {
	if d.TokenPath == "" {
		return nil
	}

	if err := os.MkdirAll(filepath.Dir(d.TokenPath), 0o750); err != nil {
		return err
	}

	body, err := json.Marshal(struct {
		Token   string `json:"token"`
		AgentID string `json:"runner_id"`
		KeyFP   string `json:"key_fp,omitempty"`
	}{t.Raw, t.AgentID, t.KeyFP})
	if err != nil {
		return err
	}

	// Write atomically: a partial-write that crashes mid-flight should
	// not leave a corrupt token file.
	tmp := d.TokenPath + ".tmp"
	if err := os.WriteFile(tmp, body, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, d.TokenPath)
}

// keyFingerprint is a short, one-way fingerprint of the bootstrap auth
// key, stamped into the token file so a later boot can detect that the
// operator swapped the key under the runner (e.g. moving it to another
// account). Not a secret and not reversible — 8 bytes of SHA-256 is
// ample to tell one key from another.
func keyFingerprint(authKey string) string {
	sum := sha256.Sum256([]byte(authKey))
	return hex.EncodeToString(sum[:8])
}

// -- Register --------------------------------------------------------

// serverErrorMessage pulls a human-readable message out of an error response
// body — preferring the JSON `message` field, then `error`, then raw text —
// and bounds the read so a stray HTML error page can't flood the log.
func serverErrorMessage(body io.Reader) string {
	raw, err := io.ReadAll(io.LimitReader(body, 4096))
	if err != nil || len(raw) == 0 {
		return ""
	}
	var parsed struct {
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	if json.Unmarshal(raw, &parsed) == nil {
		if parsed.Message != "" {
			return parsed.Message
		}
		if parsed.Error != "" {
			return parsed.Error
		}
	}
	return strings.TrimSpace(string(raw))
}

func (d *WebsocketDialer) register(ctx context.Context) (agentToken, error) {
	client := d.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}

	registerURL, err := httpURL(d.URL, "/runner/register")
	if err != nil {
		return agentToken{}, err
	}

	payload := map[string]any{
		"hostname": d.Hostname,
		"group":    d.Group,
		"version":  d.Version,
	}
	// Only send external_id when we have one — a blank value must not be
	// sent (the cloud would otherwise have to special-case empty strings).
	if d.ExternalID != "" {
		payload["external_id"] = d.ExternalID
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return agentToken{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, registerURL, strings.NewReader(string(body)))
	if err != nil {
		return agentToken{}, err
	}
	req.Header.Set("Authorization", "Bearer "+d.AuthKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return agentToken{}, fmt.Errorf("cloud: register http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized {
		return agentToken{}, fmt.Errorf("%w: /runner/register returned 401", ErrUnauthorized)
	}

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		// Surface the server's message (e.g. a name conflict the operator
		// must resolve) instead of just the status code.
		if msg := serverErrorMessage(resp.Body); msg != "" {
			return agentToken{}, fmt.Errorf("cloud: register returned %d: %s", resp.StatusCode, msg)
		}
		return agentToken{}, fmt.Errorf("cloud: register returned %d", resp.StatusCode)
	}

	var parsed struct {
		AgentID string `json:"runner_id"`
		Token   string `json:"token"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return agentToken{}, fmt.Errorf("cloud: register response decode: %w", err)
	}

	if parsed.Token == "" {
		return agentToken{}, errors.New("cloud: register returned empty token")
	}

	return agentToken{Raw: parsed.Token, AgentID: parsed.AgentID}, nil
}

// -- URL derivation --------------------------------------------------

func (d *WebsocketDialer) deriveWSURL() (string, error) {
	u, err := url.Parse(d.URL)
	if err != nil {
		return "", fmt.Errorf("cloud: bad URL %q: %w", d.URL, err)
	}

	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	case "ws", "wss":
		// already a ws URL — accept it.
	default:
		return "", fmt.Errorf("cloud: unsupported URL scheme %q (want http/https/ws/wss)", u.Scheme)
	}

	u.Path = strings.TrimRight(u.Path, "/") + "/runner/socket/websocket"
	return u.String(), nil
}

// httpURL joins path under base, normalizing a websocket scheme to its
// HTTP equivalent. cloud.url may be configured as wss:// (the form the
// runner dials for the socket); the register step is a plain HTTP POST,
// and net/http rejects ws/wss with "unsupported protocol scheme". This
// mirrors deriveWSURL in reverse so both http(s):// and ws(s):// configs
// register correctly.
func httpURL(base, path string) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "http", "https":
		// already an HTTP scheme.
	case "ws":
		u.Scheme = "http"
	case "wss":
		u.Scheme = "https"
	default:
		return "", fmt.Errorf("cloud: unsupported URL scheme %q (want http/https/ws/wss)", u.Scheme)
	}
	u.Path = strings.TrimRight(u.Path, "/") + path
	return u.String(), nil
}

func (d *WebsocketDialer) logger() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}

// -- Conn wrapper ----------------------------------------------------

// wsConn adapts a github.com/coder/websocket.Conn to the cloud.Conn interface.
// Messages are JSON-encoded text frames; binary frames are an error.
type wsConn struct {
	ws  *websocket.Conn
	log *slog.Logger
}

func (c *wsConn) Send(ctx context.Context, msg any) error {
	bytes, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("cloud: encode msg: %w", err)
	}
	return c.ws.Write(ctx, websocket.MessageText, bytes)
}

func (c *wsConn) Recv(ctx context.Context) ([]byte, error) {
	typ, bytes, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	if typ != websocket.MessageText {
		return nil, fmt.Errorf("cloud: unexpected frame type %v", typ)
	}
	return bytes, nil
}

func (c *wsConn) Close() error {
	return c.ws.Close(websocket.StatusNormalClosure, "")
}
