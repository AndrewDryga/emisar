package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

type heartbeatFailConn struct{ *fakeConn }

func (c *heartbeatFailConn) Send(ctx context.Context, msg any) error {
	if _, ok := msg.(HeartbeatMsg); ok {
		return io.ErrClosedPipe
	}
	return c.fakeConn.Send(ctx, msg)
}

type stateFailConn struct{ *fakeConn }

func (c *stateFailConn) Send(context.Context, any) error { return io.ErrClosedPipe }

type oneConnDialer struct {
	conn Conn
	used bool
}

func (d *oneConnDialer) Dial(context.Context) (Conn, error) {
	if d.used {
		return nil, errors.New("no more conns")
	}
	d.used = true
	return d.conn, nil
}

func validRuntimeStatus(now time.Time) RuntimeStatus {
	connected := now.Add(-time.Minute)
	heartbeat := now.Add(-5 * time.Second)
	return RuntimeStatus{
		SchemaVersion: 1, PID: os.Getpid(), State: RuntimeStateConnected,
		StartedAt: now.Add(-time.Hour), UpdatedAt: now,
		ConnectedAt: &connected, LastHeartbeatSentAt: &heartbeat,
		HeartbeatEverySeconds: 30, Packs: 4, Actions: 82,
		UnavailableActions: 2, InflightRuns: 1, ConnectionAttempts: 2,
	}
}

func TestRuntimeStatusWriteReadIsStrictAndOwnerOnly(t *testing.T) {
	path := RuntimeStatusPath(t.TempDir())
	want := validRuntimeStatus(time.Now().UTC())
	if err := writeRuntimeStatus(path, want); err != nil {
		t.Fatalf("writeRuntimeStatus: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode = %#o, want 0600", got)
	}
	got, err := ReadRuntimeStatus(path)
	if err != nil {
		t.Fatalf("ReadRuntimeStatus: %v", err)
	}
	if got == nil || got.State != want.State || got.Actions != want.Actions || got.LastHeartbeatSentAt == nil {
		t.Fatalf("status = %+v, want core fields from %+v", got, want)
	}
}

func TestReadRuntimeStatusRejectsAmbiguousFiles(t *testing.T) {
	now := time.Now().UTC()
	valid, err := json.Marshal(validRuntimeStatus(now))
	if err != nil {
		t.Fatal(err)
	}
	tests := map[string]struct {
		body string
		mode os.FileMode
		want string
	}{
		"unknown field": {string(valid[:len(valid)-1]) + `,"secret":"must-not-pass"}`, 0o600, "unknown field"},
		"trailing JSON": {string(valid) + `{}`, 0o600, "trailing JSON"},
		"malformed":     {`{"schema_version":`, 0o600, "decode runtime status"},
		"loose mode":    {string(valid), 0o640, "insecure permissions"},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "runtime-status.json")
			if err := os.WriteFile(path, []byte(tc.body), tc.mode); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(path, tc.mode); err != nil {
				t.Fatal(err)
			}
			_, err := ReadRuntimeStatus(path)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %v, want %q", err, tc.want)
			}
		})
	}

	t.Run("symlink", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "target")
		if err := os.WriteFile(target, valid, 0o600); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(dir, "runtime-status.json")
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadRuntimeStatus(link); err == nil || !strings.Contains(err.Error(), "open runtime status") {
			t.Fatalf("symlink error = %v", err)
		}
	})

	t.Run("fifo", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "runtime-status.json")
		if err := syscall.Mkfifo(path, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadRuntimeStatus(path); err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("fifo error = %v", err)
		}
	})

	t.Run("oversized", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "runtime-status.json")
		if err := os.WriteFile(path, make([]byte, maxRuntimeStatusBytes+1), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadRuntimeStatus(path); err == nil || !strings.Contains(err.Error(), "exceeds") {
			t.Fatalf("oversized error = %v", err)
		}
	})
}

func TestClientRuntimeStatusSerializesStartupAndReadvertise(t *testing.T) {
	for range 20 {
		cli := buildClient(t, &queuedDialer{}, func(opts *Options) {
			opts.RuntimeStatusPath = RuntimeStatusPath(t.TempDir())
		})
		started := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			cli.startRuntimeStatus()
			close(started)
		}()
		for {
			select {
			case <-started:
				wg.Wait()
				cli.stopRuntimeStatus()
				goto next
			default:
				cli.Readvertise()
			}
		}
	next:
	}
}

func TestClientRuntimeStatusTracksSuccessfulSessionEvidence(t *testing.T) {
	conn := newFakeConn()
	path := RuntimeStatusPath(t.TempDir())
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}}, func(opts *Options) {
		opts.RuntimeStatusPath = path
		opts.HeartbeatEvery = 20 * time.Millisecond
	})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()

	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.State == RuntimeStateConnected &&
			status.LastHeartbeatSentAt != nil && status.Packs == 1 && status.Actions == 5
	})
	status, err := ReadRuntimeStatus(path)
	if err != nil {
		t.Fatal(err)
	}
	if status.ConnectionAttempts != 1 {
		t.Fatalf("connection attempts = %d, want 1", status.ConnectionAttempts)
	}
	if status.InflightRuns != 0 {
		t.Fatalf("inflight = %d, want 0", status.InflightRuns)
	}

	cancel()
	if err := <-done; err != nil && err != context.Canceled {
		t.Fatalf("Run: %v", err)
	}
	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.State == RuntimeStateStopped
	})
}

func TestClientRuntimeStatusTracksInflightRuns(t *testing.T) {
	conn := newFakeConn()
	path := RuntimeStatusPath(t.TempDir())
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}}, func(opts *Options) {
		opts.RuntimeStatusPath = path
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()

	waitUntil(t, 3*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) == 1 })
	requestID := testRequestID("req_runtime_status_inflight")
	sendRunAction(t, conn, cli, requestID, "t.sleep", nil)
	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.InflightRuns == 1
	})

	raw, err := json.Marshal(CancelMsg{Envelope: Envelope{
		Type: MsgCancel, ProtocolVersion: ProtocolVersion, RequestID: requestID,
	}})
	if err != nil {
		t.Fatal(err)
	}
	conn.in <- raw
	waitUntil(t, 5*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.InflightRuns == 0
	})
	cancel()
	<-done
}

func TestClientRuntimeStatusDoesNotRegressAfterImmediateRun(t *testing.T) {
	conn := newFakeConn()
	path := RuntimeStatusPath(t.TempDir())
	cli := buildClient(t, &queuedDialer{conns: []*fakeConn{conn}}, func(opts *Options) {
		opts.RuntimeStatusPath = path
		opts.HeartbeatEvery = time.Hour
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()

	waitUntil(t, 3*time.Second, func() bool { return len(conn.sentByType(MsgRunnerState)) == 1 })
	sendRunAction(t, conn, cli, testRequestID("req_runtime_status_immediate"), "t.echo", map[string]any{"msg": "ok"})
	waitUntil(t, 3*time.Second, func() bool { return len(conn.sentByType(MsgActionResult)) == 1 })

	cli.statusMu.Lock()
	inflight := cli.runtimeStatus.InflightRuns
	cli.statusMu.Unlock()
	if inflight != 0 {
		t.Fatalf("inflight after completed run = %d, want 0", inflight)
	}
	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.InflightRuns == 0
	})

	cancel()
	<-done
}

func TestClientRuntimeStatusOnlyAdvancesHeartbeatAfterSuccessfulSend(t *testing.T) {
	conn := &heartbeatFailConn{newFakeConn()}
	path := RuntimeStatusPath(t.TempDir())
	cli := buildClient(t, &oneConnDialer{conn: conn}, func(opts *Options) {
		opts.RuntimeStatusPath = path
		opts.HeartbeatEvery = 20 * time.Millisecond
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.State == RuntimeStateReconnecting
	})
	status, err := ReadRuntimeStatus(path)
	if err != nil {
		t.Fatal(err)
	}
	if status.LastHeartbeatSentAt != nil {
		t.Fatalf("failed heartbeat advanced timestamp to %s", status.LastHeartbeatSentAt)
	}
	cancel()
	<-done
}

func TestClientRuntimeStatusDoesNotAdvertiseAfterStateSendFailure(t *testing.T) {
	path := RuntimeStatusPath(t.TempDir())
	cli := buildClient(t, &oneConnDialer{conn: &stateFailConn{newFakeConn()}}, func(opts *Options) {
		opts.RuntimeStatusPath = path
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	waitUntil(t, 3*time.Second, func() bool {
		status, err := ReadRuntimeStatus(path)
		return err == nil && status != nil && status.State == RuntimeStateReconnecting
	})
	status, err := ReadRuntimeStatus(path)
	if err != nil {
		t.Fatal(err)
	}
	if status.Packs != 0 || status.Actions != 0 || status.ConnectedAt != nil {
		t.Fatalf("failed state send claimed advertisement: %+v", status)
	}
	cancel()
	<-done
}
