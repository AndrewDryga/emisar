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
	"strings"
	"time"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/fsutil"
	"github.com/andrewdryga/emisar/runner/internal/httpsecurity"
	"github.com/coder/websocket"
)

// WebsocketDialer is the real cloud transport. It does the two-step
// runner bootstrap (register → exchange enrollment key for per-runner token,
// then open the websocket) and wraps the resulting conn so the rest of
// the cloud package can treat send/recv as message-level.
//
// Token persistence:
//
//   - If the file at TokenPath exists and is non-empty, its contents
//     are used as the bearer for the websocket upgrade.
//   - Otherwise, EnrollmentKey is presented to POST {URL}/runner/register; the
//     response token is persisted to TokenPath (perms 0600) and used.
//
// Enrollment-key revocation surfaces as HTTP 401 from /runner/register; the
// dialer returns an `unauthorized` error and exits — the runner will
// not retry forever against a bad key.
type WebsocketDialer struct {
	// URL is the cloud base, e.g. "https://emisar.dev" or
	// "http://localhost:4000". The dialer derives the register URL and
	// the ws URL from this base.
	URL string

	// EnrollmentKey is the bootstrap secret (env-provided, typically). Only
	// consulted on first connect.
	EnrollmentKey string

	// TokenPath is where the per-runner token is persisted between
	// boots. Parent dir is created with 0750 if missing.
	TokenPath string

	// Hostname + Group + Version are reported during register so the
	// cloud can label the runner row.
	Hostname string
	Group    string
	Version  string

	// ExternalID is the configured id or host hostname presented on every
	// register. Registration requires 1-255 characters without surrounding
	// whitespace.
	ExternalID string

	// HTTPClient is used for /runner/register; defaults to a 10s-timeout
	// client. Tests can inject a stub.
	HTTPClient *http.Client

	// Logger; defaults to slog.Default().
	Logger *slog.Logger
}

var (
	// ErrUnauthorized is returned when /runner/register or the websocket
	// upgrade rejects an invalid credential. Callers should fail closed.
	ErrUnauthorized = errors.New("cloud: unauthorized (bad or revoked enrollment key / token)")

	// ErrRunnerDisabled means the credential is valid but the reversible runner
	// state currently forbids a connection. Callers should retain it and retry.
	ErrRunnerDisabled = errors.New("cloud: runner disabled")

	// ErrAccountDisabled is the tenant-wide equivalent. The account can be
	// re-enabled without changing this runner identity, so retain the token.
	ErrAccountDisabled = errors.New("cloud: account disabled")
)

const (
	cloudHandshakeTimeout        = 10 * time.Second
	cloudWebsocketWriteTimeout   = 15 * time.Second
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

	// Only when the portal said this token was due, so an ordinary reconnect
	// costs no extra round-trip. Before the dial, so the connection uses
	// whichever token we end up with — and never blocking it: maybeRefreshToken
	// returns the token it was given on every failure path.
	if token.refreshDue(time.Now()) {
		token = d.maybeRefreshToken(ctx, token)
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
		if resp != nil && resp.StatusCode == http.StatusForbidden {
			switch serverErrorMessage(resp.Body) {
			case "runner_disabled":
				return nil, fmt.Errorf("%w: ws upgrade returned 403", ErrRunnerDisabled)
			case "account_disabled":
				return nil, fmt.Errorf("%w: ws upgrade returned 403", ErrAccountDisabled)
			}
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

	// run_action is the largest cloud-to-runner envelope and enforces the same
	// bound while decoding. Keep the transport ceiling aligned with it.
	conn.SetReadLimit(maxRunActionMessageBytes)

	return &wsConn{ws: conn, log: log}, nil
}

// -- Token persistence ----------------------------------------------

type runnerToken struct {
	Raw string
	// KeyFP fingerprints the enrollment key that minted this token, so a later
	// boot can tell when the operator swapped the key under it.
	KeyFP string
	// RefreshAfter is when this token becomes eligible for rotation, RFC3339, as
	// the portal stated it at issue. Empty means the portal never stated one —
	// a token minted before rotation existed.
	RefreshAfter string
}

// refreshDue reports whether it is worth asking the portal for a successor.
//
// Empty means ASK. A token from before rotation existed carries no expiry, and
// the portal has no way to reach a connected runner to tell it otherwise — it
// states RefreshAfter only at enrollment and at refresh. Treating empty as
// "never" deadlocked the two halves: the runner waited to be told, the portal
// waited for the runner to ask, and those tokens could never migrate onto an
// expiring credential. That costs one extra round-trip on the first connect
// after upgrading, once, and then the token has a real RefreshAfter.
//
// An unparseable value still means no — that is a corrupt store, not a
// migration, and retrying it every connect would be a hot loop.
func (t runnerToken) refreshDue(now time.Time) bool {
	if t.RefreshAfter == "" {
		return true
	}
	at, err := time.Parse(time.RFC3339, t.RefreshAfter)
	if err != nil {
		return false
	}
	return !now.Before(at)
}

func (d *WebsocketDialer) loadOrMintToken(ctx context.Context) (runnerToken, error) {
	existing, err := d.readToken()
	switch {
	case err == nil:
		// Reuse the cached token unless the operator has rotated the auth
		// key under it (e.g. moving the runner to another account): a
		// configured key whose fingerprint no longer matches the one stamped
		// on the token means re-register with the new key. An empty key means
		// the operator intentionally relies only on the persisted runner token.
		if d.EnrollmentKey == "" || existing.KeyFP == keyFingerprint(d.EnrollmentKey) {
			return existing, nil
		}
		d.logger().Info("cloud.enrollment_key_rotated",
			"path", d.TokenPath,
			"detail", "configured enrollment key no longer matches the cached token; re-registering")
	case errors.Is(err, os.ErrNotExist):
		// No cache yet — first boot, the normal enrollment path below.
	default:
		// Every other rejection (insecure perms, a symlink, malformed or
		// unreadable contents) is a host problem, never a reason to mint a
		// fresh token over it: re-registering would overwrite the evidence and
		// silently reward whoever tampered with the cache.
		return runnerToken{}, fmt.Errorf("cached runner token %s is unusable: %w", d.TokenPath, err)
	}

	if d.EnrollmentKey == "" {
		return runnerToken{}, fmt.Errorf("%w: no token cached and no enrollment key provided", ErrUnauthorized)
	}

	token, err := d.register(ctx)
	if err != nil {
		return runnerToken{}, err
	}
	token.KeyFP = keyFingerprint(d.EnrollmentKey)

	if err := d.writeToken(token); err != nil {
		return runnerToken{}, fmt.Errorf("persist runner token: %w", err)
	}

	return token, nil
}

// maybeRefreshToken exchanges a live token for its successor, and is allowed to
// fail at every step.
//
// The portal answers 409 until a token is old enough to rotate, so the ordinary
// answer here is "not yet". Every other outcome — the portal is down, the
// response is junk, the disk is full — returns the CALLER'S EXISTING TOKEN and
// logs. That is the property the whole design rests on: a broken refresh must
// degrade to "keep using the credential that already works", never to a failed
// connect. The outgoing token stays valid for a grace window after its
// successor is minted, so even a successful refresh that fails to persist
// leaves a runner that can reconnect and try again.
func (d *WebsocketDialer) maybeRefreshToken(ctx context.Context, current runnerToken) runnerToken {
	refreshURL, err := httpURL(d.URL, "/runner/token/refresh")
	if err != nil {
		return current
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, refreshURL, nil)
	if err != nil {
		return current
	}
	req.Header.Set("Authorization", "Bearer "+current.Raw)

	resp, err := d.portalHTTPClient().Do(req)
	if err != nil {
		d.logger().Debug("cloud.token_refresh_skipped", "detail", err.Error())
		return current
	}
	defer resp.Body.Close()

	// Not due yet. The overwhelmingly common answer; not worth a log line.
	if resp.StatusCode == http.StatusConflict {
		return current
	}
	if resp.StatusCode != http.StatusOK {
		d.logger().Debug("cloud.token_refresh_skipped", "status", resp.StatusCode)
		return current
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistrationResponseBytes+1))
	if err != nil || len(raw) > maxRegistrationResponseBytes {
		d.logger().Debug("cloud.token_refresh_skipped", "detail", "unreadable refresh response")
		return current
	}

	var parsed struct {
		Token        string `json:"token"`
		RefreshAfter string `json:"refresh_after"`
	}
	// Additive-safe for the same reason as the register body above. This one
	// degrades softly — an undecodable response keeps the current token — but a
	// runner that stops refreshing eventually runs one out.
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(&parsed); err != nil || strings.TrimSpace(parsed.Token) == "" {
		d.logger().Debug("cloud.token_refresh_skipped", "detail", "malformed refresh response")
		return current
	}

	successor := runnerToken{Raw: parsed.Token, KeyFP: current.KeyFP, RefreshAfter: parsed.RefreshAfter}
	if err := d.writeToken(successor); err != nil {
		// The successor exists server-side but is not on disk. Keep using the
		// outgoing token, which the grace window keeps alive precisely for this.
		d.logger().Warn("cloud.token_refresh_not_persisted", "error", err.Error())
		return current
	}

	d.logger().Info("cloud.token_refreshed", "path", d.TokenPath)
	return successor
}

// ValidateTokenFile reports whether the cached runner token at path is one
// connect would accept, running the exact secure open, permission check, and
// strict parse the dial path uses. Only the error is returned — never the
// token — so diagnostics can mirror connect without handling the secret. A
// missing file is reported as os.ErrNotExist, the one rejection that means
// "not enrolled yet" rather than "this host is broken".
func ValidateTokenFile(path string) error {
	_, err := (&WebsocketDialer{TokenPath: path}).readToken()
	return err
}

func (d *WebsocketDialer) readToken() (runnerToken, error) {
	if d.TokenPath == "" {
		return runnerToken{}, errors.New("no token path")
	}

	// The token is a bearer secret, so treat its path as hostile. The platform
	// helper must refuse symlink traversal; a non-0600 file means the token was
	// exposed (bad umask, manual edit, tampering), so reject it — the caller
	// fails the dial rather than registering over rejected cache state. We
	// always write 0600, so a clean install never trips.
	f, err := openSecureLocalFile(d.TokenPath)
	if err != nil {
		return runnerToken{}, err
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		return runnerToken{}, err
	}
	if !info.Mode().IsRegular() {
		return runnerToken{}, fmt.Errorf("token file %s is not a regular file", d.TokenPath)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		return runnerToken{}, fmt.Errorf("insecure perms %#o (want 0600); chmod 600 %s", perm, d.TokenPath)
	}

	contents, err := io.ReadAll(f)
	if err != nil {
		return runnerToken{}, err
	}

	var stored struct {
		Token string `json:"token"`
		KeyFP string `json:"key_fp"`
		// RFC3339, written by whoever issued the token. Absent on every token
		// minted before rotation shipped, which is exactly right: those have no
		// refresh path, so the runner must never ask for one.
		RefreshAfter string `json:"refresh_after,omitempty"`
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&stored); err != nil {
		return runnerToken{}, fmt.Errorf("decode token file: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return runnerToken{}, errors.New("decode token file: trailing JSON value")
	}
	if stored.Token == "" {
		return runnerToken{}, errors.New("token file has empty token")
	}
	return runnerToken{Raw: stored.Token, KeyFP: stored.KeyFP, RefreshAfter: stored.RefreshAfter}, nil
}

func (d *WebsocketDialer) writeToken(t runnerToken) error {
	if d.TokenPath == "" {
		return errors.New("token path is empty")
	}

	body, err := json.Marshal(struct {
		Token        string `json:"token"`
		KeyFP        string `json:"key_fp,omitempty"`
		RefreshAfter string `json:"refresh_after,omitempty"`
	}{t.Raw, t.KeyFP, t.RefreshAfter})
	if err != nil {
		return err
	}

	if err := fsutil.ReplaceFile(d.TokenPath, func(w io.Writer) error {
		_, err := w.Write(body)
		return err
	}); err != nil {
		return fmt.Errorf("persist runner token: %w", err)
	}
	return nil
}

// keyFingerprint is a short, one-way fingerprint of the bootstrap auth
// key, stamped into the token file so a later boot can detect that the
// operator swapped the key under the runner (e.g. moving it to another
// account). Not a secret and not reversible — 8 bytes of SHA-256 is
// ample to tell one key from another.
func keyFingerprint(enrollmentKey string) string {
	sum := sha256.Sum256([]byte(enrollmentKey))
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

func (d *WebsocketDialer) register(ctx context.Context) (runnerToken, error) {
	externalID := strings.TrimSpace(d.ExternalID)
	if externalID == "" || externalID != d.ExternalID || !utf8.ValidString(externalID) ||
		utf8.RuneCountInString(externalID) > 255 {
		return runnerToken{}, errors.New("cloud: external id must be 1-255 characters without surrounding whitespace")
	}

	client := d.portalHTTPClient()

	registerURL, err := httpURL(d.URL, "/runner/register")
	if err != nil {
		return runnerToken{}, err
	}

	payload := map[string]any{
		"external_id": externalID,
		"hostname":    d.Hostname,
		"group":       d.Group,
		"version":     d.Version,
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return runnerToken{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, registerURL, strings.NewReader(string(body)))
	if err != nil {
		return runnerToken{}, err
	}
	req.Header.Set("Authorization", "Bearer "+d.EnrollmentKey)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return runnerToken{}, fmt.Errorf("cloud: register http: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return runnerToken{}, fmt.Errorf("%w: /runner/register returned %d", ErrUnauthorized, resp.StatusCode)
	}

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		// Surface the server's message (e.g. a name conflict the operator
		// must resolve) instead of just the status code.
		if msg := serverErrorMessage(resp.Body); msg != "" {
			return runnerToken{}, fmt.Errorf("cloud: register returned %d: %s", resp.StatusCode, msg)
		}
		return runnerToken{}, fmt.Errorf("cloud: register returned %d", resp.StatusCode)
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxRegistrationResponseBytes+1))
	if err != nil {
		return runnerToken{}, fmt.Errorf("cloud: register response read: %w", err)
	}
	if len(raw) > maxRegistrationResponseBytes {
		return runnerToken{}, fmt.Errorf("cloud: register response exceeds %d bytes", maxRegistrationResponseBytes)
	}

	var parsed struct {
		Token string `json:"token"`
		// Optional so an older portal still registers a newer runner: absent
		// simply means this token is never due for rotation.
		RefreshAfter string `json:"refresh_after"`
	}
	// Unknown fields are ignored, matching the additive-safety the wire contract
	// promises for every other frame. This body bootstraps the connection and a
	// fresh host has no cached token to fall back on, so rejecting an added
	// field here would strand every deployed runner on the next portal that
	// grows one — and the 402 body already carries fields the runner ignores.
	// The size cap and the trailing-JSON check below still bound the input.
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(&parsed); err != nil {
		return runnerToken{}, fmt.Errorf("cloud: register response decode: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return runnerToken{}, errors.New("cloud: register response has trailing JSON")
	}
	if parsed.Token == "" || parsed.Token != strings.TrimSpace(parsed.Token) ||
		!utf8.ValidString(parsed.Token) || len(parsed.Token) > maxRunnerTokenBytes {
		return runnerToken{}, errors.New("cloud: register returned an invalid token")
	}

	return runnerToken{Raw: parsed.Token, RefreshAfter: parsed.RefreshAfter}, nil
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
	client = *httpsecurity.ClientWithTLS12(&client)
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
	writeCtx, cancel := websocketWriteContext(ctx)
	defer cancel()
	if err := c.ws.Write(writeCtx, websocket.MessageText, bytes); err != nil {
		return fmt.Errorf("cloud: write msg: %w", err)
	}
	return nil
}

func websocketWriteContext(parent context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(parent, cloudWebsocketWriteTimeout)
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
