package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func rotationTestCredential(t *testing.T, now time.Time) (*WebsocketDialer, runnerToken) {
	t.Helper()
	token := runnerToken{
		Raw:          "rnrtok-abcde-current-secret",
		KeyFP:        "enrollment-fingerprint",
		RefreshAfter: now.Add(60 * 24 * time.Hour).Format(time.RFC3339Nano),
	}
	d := &WebsocketDialer{TokenPath: filepath.Join(t.TempDir(), "token.json")}
	if err := d.writeToken(token); err != nil {
		t.Fatal(err)
	}
	d.noteSessionCredential(token, now)
	return d, token
}

func TestRequestCredentialRotationMatchesTheCompleteCachedPrefix(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 123, time.UTC)
	for _, tc := range []struct {
		name   string
		prefix string
		want   bool
	}{
		{"matching", "rnrtok-abcde", true},
		{"different credential", "rnrtok-other", false},
		{"empty", "", false},
		{"partial", "rnrtok-", false},
		{"overlong", "rnrtok-abcde-extra", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d, before := rotationTestCredential(t, now)
			requested, err := d.RequestCredentialRotation(tc.prefix, now)
			if err != nil || requested != tc.want {
				t.Fatalf("requested=%v error=%v, want %v", requested, err, tc.want)
			}
			// A new dialer reads exactly what a process restart would adopt.
			restarted := &WebsocketDialer{TokenPath: d.TokenPath}
			after, err := restarted.readToken()
			if err != nil {
				t.Fatal(err)
			}
			if after.Raw != before.Raw || after.KeyFP != before.KeyFP {
				t.Fatal("the request replaced the credential or enrollment fingerprint")
			}
			if after.refreshDue(now) != tc.want || d.CredentialRotationDue(now) != tc.want {
				t.Fatal("persisted and session rotation deadlines disagree with the request")
			}
			if !tc.want && after != before {
				t.Fatal("a stale or invalid prefix changed the cached credential")
			}
			if runtime.GOOS != "windows" {
				info, err := os.Stat(d.TokenPath)
				if err != nil || info.Mode().Perm() != 0o600 {
					t.Fatalf("credential is not owner-only: %v", err)
				}
			}
		})
	}
}

func TestRequestedCredentialRotationKeepsTheHourlyRetryAfterRefreshFailure(t *testing.T) {
	now := time.Date(2026, 9, 5, 12, 0, 0, 0, time.UTC)
	d, _ := rotationTestCredential(t, now)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	d.URL = srv.URL
	if requested, err := d.RequestCredentialRotation("rnrtok-abcde", now); err != nil || !requested {
		t.Fatalf("request=%v error=%v", requested, err)
	}
	token, err := d.readToken()
	if err != nil {
		t.Fatal(err)
	}
	after := d.maybeRefreshToken(context.Background(), token)
	if after != token {
		t.Fatal("failed refresh changed the credential")
	}
	d.noteSessionCredential(after, now)
	for _, elapsed := range []time.Duration{time.Second, time.Minute, 59 * time.Minute} {
		requested, err := d.RequestCredentialRotation("rnrtok-abcde", now.Add(elapsed))
		if err != nil || requested || d.CredentialRotationDue(now.Add(elapsed)) {
			t.Fatalf("repeat at %s reset the retry deadline: request=%v error=%v", elapsed, requested, err)
		}
	}
	if !d.CredentialRotationDue(now.Add(time.Hour)) {
		t.Fatal("the normal hourly retry was lost")
	}
}

func TestRequestCredentialRotationWriteFailurePreservesTheSessionDeadline(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("requires Unix directory permissions without root bypass")
	}
	now := time.Now().UTC()
	d, before := rotationTestCredential(t, now)
	dir := filepath.Dir(d.TokenPath)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })
	requested, err := d.RequestCredentialRotation("rnrtok-abcde", now)
	if err == nil || requested || d.CredentialRotationDue(now) {
		t.Fatalf("failed persistence scheduled a reconnect: request=%v error=%v", requested, err)
	}
	after, err := d.readToken()
	if err != nil || after != before {
		t.Fatal("failed persistence changed the cached credential")
	}
	cli := buildClient(t, d)
	frame := []byte(`{"type":"refresh_credentials","protocol_version":1,"token_prefix":"rnrtok-abcde"}`)
	if err := cli.dispatch(context.Background(), frame); err != nil {
		t.Fatalf("failed persistence asked the client to end its session: %v", err)
	}
}

// This transport uses the real secure credential store with in-memory sockets.
// A reconnect deliberately retains the old token, modelling a refresh outage.
type manuallyRotatingDialer struct {
	*queuedDialer
	credential *WebsocketDialer
}

func (d *manuallyRotatingDialer) Dial(ctx context.Context) (Conn, error) {
	if token, err := d.credential.readToken(); err == nil {
		d.credential.noteSessionCredential(token, time.Now().UTC())
	}
	return d.queuedDialer.Dial(ctx)
}

func (d *manuallyRotatingDialer) RequestCredentialRotation(prefix string, now time.Time) (bool, error) {
	return d.credential.RequestCredentialRotation(prefix, now)
}

func (d *manuallyRotatingDialer) CredentialRotationDue(now time.Time) bool {
	return d.credential.CredentialRotationDue(now)
}

func TestManualCredentialRotationReconnectsWithoutCancellingAnActiveAction(t *testing.T) {
	first, second := newFakeConn(), newFakeConn()
	credential, _ := rotationTestCredential(t, time.Now().UTC())
	d := &manuallyRotatingDialer{
		queuedDialer: &queuedDialer{conns: []*fakeConn{first, second}},
		credential:   credential,
	}
	cli := buildClient(t, d)
	cli.opts.HeartbeatEvery = 10 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	requestID := testRequestID("manual_rotation_inflight")
	sendRunAction(t, first, cli, requestID, "t.sleep", nil)
	waitUntil(t, 3*time.Second, func() bool {
		return countMessagesForRequest(first, MsgActionStarted, requestID) == 1
	})
	frame := []byte(`{"type":"refresh_credentials","protocol_version":1,"token_prefix":"rnrtok-abcde"}`)
	first.in <- frame
	waitUntil(t, 3*time.Second, func() bool {
		return countMessagesForRequest(second, MsgActionStarted, requestID) == 1
	})
	if !first.closed.Load() || cli.countInflight() != 1 {
		t.Fatal("rotation did not reconnect while retaining the active action")
	}
	for _, conn := range []*fakeConn{first, second} {
		if states := conn.sentByType(MsgRunnerState); len(states) == 0 || states[0]["credential_rotation_supported"] != true {
			t.Fatal("the connected client did not advertise manual rotation support")
		}
	}
	// The portal will repeat a pending request when the refresh failed. The
	// new session must not recycle again before its normal hourly retry.
	second.in <- frame
	heartbeats := len(second.sentByType(MsgHeartbeat))
	waitUntil(t, 3*time.Second, func() bool {
		return len(second.sentByType(MsgHeartbeat)) >= heartbeats+3
	})
	if second.closed.Load() {
		t.Fatal("the repeated request ended the retry session")
	}
	cli.Readvertise()
	waitUntil(t, 3*time.Second, func() bool { return len(second.sentByType(MsgRunnerState)) >= 2 })
	if states := second.sentByType(MsgRunnerState); states[len(states)-1]["credential_rotation_supported"] != true {
		t.Fatal("repeat runner_state lost manual rotation support")
	}
	stop, err := json.Marshal(CancelMsg{Envelope: Envelope{
		Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: requestID,
	}})
	if err != nil {
		t.Fatal(err)
	}
	second.in <- stop
	if result := waitForResult(t, second, requestID, 10*time.Second); result["status"] != "cancelled" {
		t.Fatalf("active action could not be cancelled after rotation: %v", result["status"])
	}
}

func TestRefreshCredentialsRejectsInvalidFramesBeforeChangingTheCredential(t *testing.T) {
	for name, raw := range map[string]string{
		"wrong version":    `{"type":"refresh_credentials","protocol_version":2,"token_prefix":"rnrtok-abcde"}`,
		"missing version":  `{"type":"refresh_credentials","token_prefix":"rnrtok-abcde"}`,
		"case alias":       `{"type":"refresh_credentials","protocol_version":1,"Token_Prefix":"rnrtok-abcde"}`,
		"duplicate prefix": `{"type":"refresh_credentials","protocol_version":1,"token_prefix":"rnrtok-other","token_prefix":"rnrtok-abcde"}`,
		"wrong type":       `{"type":"refresh_credentials","protocol_version":1,"token_prefix":12}`,
	} {
		t.Run(name, func(t *testing.T) {
			d, before := rotationTestCredential(t, time.Now().UTC())
			cli := buildClient(t, d)
			err := cli.dispatch(context.Background(), []byte(raw))
			if errors.Is(err, errCredentialRotationRequested) {
				t.Fatal("invalid frame requested rotation")
			}
			if name == "wrong version" || name == "missing version" {
				if !errors.Is(err, errProtocolVersionUnsupported) {
					t.Fatalf("unsupported version was not rejected: %v", err)
				}
			}
			after, readErr := d.readToken()
			if readErr != nil || after != before {
				t.Fatal("invalid frame changed the credential")
			}
		})
	}
}
