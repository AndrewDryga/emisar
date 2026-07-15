package cloud

import (
	"bytes"
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
	"time"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
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
	// back to the same runner row. Registration requires 1-255 characters
	// without surrounding whitespace.
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

const (
	cloudHandshakeTimeout        = 10 * time.Second
	maxRegistrationResponseBytes = 4 << 10
	maxRunnerTokenBytes          = 512
)

// Dial implements cloud.Dialer. It ensures a token exists (calling
// register if needed), then opens the websocket and returns a wrapper
// satisfying cloud.Conn.
func (d *WebsocketDialer) Dial(ctx context.Context) (Conn, error) {
	log := d.Logger
	if log == nil {
		log = slog.Default()
	}

	if d.URL == "" {
		return nil, errors.New("cloud: WebsocketDialer.URL is empty")
	}

	token, err := d.loadOrMintToken(ctx)
	if err != nil {
		return nil, err
	}

	wsURL, err := d.deriveWSURL()
	if err != nil {
		return nil, err
	}

	headers := http.Header{}
	headers.Set("Authorization", "Bearer "+token.Raw)

	log.Info("cloud.dial", "url", wsURL, "external_id", d.ExternalID)

	conn, resp, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		HTTPHeader: headers,
		HTTPClient: d.portalHTTPClient(),
	})

	if err != nil {
		if resp != nil {
			defer resp.Body.Close()
		}
		if resp != nil && resp.StatusCode == http.StatusUnauthorized {
			// Token was rejected — drop the file so the next process start
			// re-runs /runner/register (in case the old token was rotated
			// or revoked).
			if removeErr := os.Remove(d.TokenPath); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
				return nil, fmt.Errorf("%w: ws upgrade returned 401; remove cached token: %v", ErrUnauthorized, removeErr)
			}
			return nil, fmt.Errorf("%w: ws upgrade returned 401", ErrUnauthorized)
		}
		return nil, fmt.Errorf("cloud: ws dial failed: %w", err)
	}

	// Disable the library's read-size cap; large action_result envelopes
	// can exceed the default 32KB.
	conn.SetReadLimit(8 * 1024 * 1024)

	return &wsConn{ws: conn, log: log}, nil
}

// -- Token persistence ----------------------------------------------

type agentToken struct {
	Raw string
	// KeyFP fingerprints the auth key that minted this token, so a later
	// boot can tell when the operator swapped the key under it.
	KeyFP string
}

func (d *WebsocketDialer) loadOrMintToken(ctx context.Context) (agentToken, error) {
	if existing, err := d.readToken(); err == nil && existing.Raw != "" {
		// Reuse the cached token unless the operator has rotated the auth
		// key under it (e.g. moving the runner to another account): a
		// configured key whose fingerprint no longer matches the one stamped
		// on the token means re-register with the new key. An empty key means
		// the operator intentionally relies only on the persisted runner token.
		if d.AuthKey == "" || existing.KeyFP == keyFingerprint(d.AuthKey) {
			return existing, nil
		}
		d.logger().Info("cloud.auth_key_rotated",
			"path", d.TokenPath,
			"detail", "configured auth key no longer matches the cached token; re-registering")
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
		return agentToken{}, fmt.Errorf("persist runner token: %w", err)
	}

	return token, nil
}

func (d *WebsocketDialer) readToken() (agentToken, error) {
	if d.TokenPath == "" {
		return agentToken{}, errors.New("no token path")
	}

	// The token is a bearer secret, so treat its path as hostile. The platform
	// helper must refuse symlink traversal; a non-0600 file means the token was
	// exposed (bad umask, manual edit, tampering), so reject it and let the
	// caller re-register. We always write 0600, so a clean install never trips.
	f, err := openTokenFile(d.TokenPath)
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

	contents, err := io.ReadAll(f)
	if err != nil {
		return agentToken{}, err
	}

	var stored struct {
		Token string `json:"token"`
		KeyFP string `json:"key_fp"`
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&stored); err != nil {
		return agentToken{}, fmt.Errorf("decode token file: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return agentToken{}, errors.New("decode token file: trailing JSON value")
	}
	if stored.Token == "" {
		return agentToken{}, errors.New("token file has empty token")
	}
	return agentToken{Raw: stored.Token, KeyFP: stored.KeyFP}, nil
}

func (d *WebsocketDialer) writeToken(t agentToken) error {
	if d.TokenPath == "" {
		return errors.New("token path is empty")
	}

	dir := filepath.Dir(d.TokenPath)
	if err := fsutil.SecureMkdirAll(dir, 0o750); err != nil {
		return err
	}

	body, err := json.Marshal(struct {
		Token string `json:"token"`
		KeyFP string `json:"key_fp,omitempty"`
	}{t.Raw, t.KeyFP})
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(dir, "."+filepath.Base(d.TokenPath)+".tmp-")
	if err != nil {
		return fmt.Errorf("create temporary token: %w", err)
	}
	tmpPath := tmp.Name()
	cleanup := func() {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
	}
	if err := tmp.Chmod(0o600); err != nil {
		cleanup()
		return fmt.Errorf("secure temporary token: %w", err)
	}
	if _, err := tmp.Write(body); err != nil {
		cleanup()
		return fmt.Errorf("write temporary token: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		cleanup()
		return fmt.Errorf("sync temporary token: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("close temporary token: %w", err)
	}
	if err := os.Rename(tmpPath, d.TokenPath); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("activate runner token: %w", err)
	}
	if err := fsutil.SyncDirectory(dir); err != nil {
		return fmt.Errorf("sync token directory: %w", err)
	}
	return nil
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

// serverErrorMessage pulls a bounded human-readable message from a JSON error
// response. Arbitrary HTML/text is not copied into runner logs.
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
	return ""
}

func (d *WebsocketDialer) register(ctx context.Context) (agentToken, error) {
	externalID := strings.TrimSpace(d.ExternalID)
	if externalID == "" || externalID != d.ExternalID || !utf8.ValidString(externalID) ||
		utf8.RuneCountInString(externalID) > 255 {
		return agentToken{}, errors.New("cloud: external id must be 1-255 characters without surrounding whitespace")
	}

	client := d.portalHTTPClient()

	registerURL, err := httpURL(d.URL, "/runner/register")
	if err != nil {
		return agentToken{}, err
	}

	payload := map[string]any{
		"external_id": externalID,
		"hostname":    d.Hostname,
		"group":       d.Group,
		"version":     d.Version,
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

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return agentToken{}, fmt.Errorf("%w: /runner/register returned %d", ErrUnauthorized, resp.StatusCode)
	}

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		// Surface the server's message (e.g. a name conflict the operator
		// must resolve) instead of just the status code.
		if msg := serverErrorMessage(resp.Body); msg != "" {
			return agentToken{}, fmt.Errorf("cloud: register returned %d: %s", resp.StatusCode, msg)
		}
		return agentToken{}, fmt.Errorf("cloud: register returned %d", resp.StatusCode)
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistrationResponseBytes+1))
	if err != nil {
		return agentToken{}, fmt.Errorf("cloud: register response read: %w", err)
	}
	if len(raw) > maxRegistrationResponseBytes {
		return agentToken{}, fmt.Errorf("cloud: register response exceeds %d bytes", maxRegistrationResponseBytes)
	}

	var parsed struct {
		Token string `json:"token"`
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&parsed); err != nil {
		return agentToken{}, fmt.Errorf("cloud: register response decode: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return agentToken{}, errors.New("cloud: register response has trailing JSON")
	}
	if parsed.Token == "" || parsed.Token != strings.TrimSpace(parsed.Token) ||
		!utf8.ValidString(parsed.Token) || len(parsed.Token) > maxRunnerTokenBytes {
		return agentToken{}, errors.New("cloud: register returned an invalid token")
	}

	return agentToken{Raw: parsed.Token}, nil
}

// -- URL derivation --------------------------------------------------

func (d *WebsocketDialer) deriveWSURL() (string, error) {
	u, err := parsePortalBaseURL(d.URL)
	if err != nil {
		return "", err
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
	u, err := parsePortalBaseURL(base)
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

func parsePortalBaseURL(raw string) (*url.URL, error) {
	if err := config.CheckEndpointScheme(raw, true); err != nil {
		return nil, fmt.Errorf("cloud: invalid base URL: %w", err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("cloud: invalid base URL: %w", err)
	}
	if u.RawQuery != "" {
		return nil, errors.New("cloud: base URL must not contain a query")
	}
	return u, nil
}

func (d *WebsocketDialer) portalHTTPClient() *http.Client {
	client := http.Client{}
	if d.HTTPClient != nil {
		client = *d.HTTPClient
	}
	if client.Timeout <= 0 {
		client.Timeout = cloudHandshakeTimeout
	}
	client.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return &client
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
