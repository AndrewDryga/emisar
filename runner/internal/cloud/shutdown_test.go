package cloud

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"testing"
	"time"
)

type shutdownLogEntry struct {
	level   slog.Level
	message string
	attrs   map[string]string
}

type shutdownLogHandler struct {
	mu      sync.Mutex
	entries []shutdownLogEntry
}

func (*shutdownLogHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *shutdownLogHandler) WithAttrs([]slog.Attr) slog.Handler { return h }

func (h *shutdownLogHandler) WithGroup(string) slog.Handler { return h }

func (h *shutdownLogHandler) Handle(_ context.Context, record slog.Record) error {
	entry := shutdownLogEntry{
		level:   record.Level,
		message: record.Message,
		attrs:   map[string]string{},
	}
	record.Attrs(func(attr slog.Attr) bool {
		entry.attrs[attr.Key] = attr.Value.String()
		return true
	})

	h.mu.Lock()
	h.entries = append(h.entries, entry)
	h.mu.Unlock()
	return nil
}

func (h *shutdownLogHandler) entriesSnapshot() []shutdownLogEntry {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]shutdownLogEntry(nil), h.entries...)
}

func shutdownFrame(t *testing.T, reason, message string) []byte {
	t.Helper()
	raw, err := json.Marshal(ShutdownMsg{
		Envelope: Envelope{Type: MsgShutdown, ProtocolVersion: ProtocolVersion},
		Reason:   reason,
		Message:  message,
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestClient_DispatchShutdownLogsAndClassifiesReason(t *testing.T) {
	tests := []struct {
		name     string
		reason   string
		message  string
		terminal bool
	}{
		{
			name:     "planned cloud shutdown reconnects",
			reason:   "cloud_shutdown",
			message:  "Cloud is shutting down. Reconnect to resync.",
			terminal: false,
		},
		{
			name:     "revoked runner stops",
			reason:   "runner_revoked",
			message:  "This runner was disabled or removed. Disconnecting.",
			terminal: true,
		},
		{
			name:     "unsupported runner stops",
			reason:   "runner_version_unsupported",
			message:  "Runner version 0.0.0 is below the minimum 0.1.0 this control plane accepts. Upgrade the runner to reconnect.",
			terminal: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			capture := &shutdownLogHandler{}
			cli := buildClient(t, &queuedDialer{}, func(opts *Options) {
				opts.Logger = slog.New(capture)
			})

			err := cli.dispatch(context.Background(), shutdownFrame(t, test.reason, test.message))
			if got := errors.Is(err, errTerminalShutdown); got != test.terminal {
				t.Fatalf("terminal error = %v, want %t (err=%v)", got, test.terminal, err)
			}

			entries := capture.entriesSnapshot()
			var shutdown *shutdownLogEntry
			for i := range entries {
				if entries[i].message == "cloud.shutdown" {
					shutdown = &entries[i]
					break
				}
			}
			if shutdown == nil {
				t.Fatalf("shutdown was not logged at WARN: %+v", entries)
			}
			if shutdown.level != slog.LevelWarn {
				t.Fatalf("shutdown log level = %s, want WARN", shutdown.level)
			}
			if shutdown.attrs["reason"] != test.reason {
				t.Fatalf("shutdown reason = %q, want %q", shutdown.attrs["reason"], test.reason)
			}
			if shutdown.attrs["message"] != test.message {
				t.Fatalf("shutdown message = %q, want %q", shutdown.attrs["message"], test.message)
			}
		})
	}
}

func TestClient_RunShutdownReconnectPolicy(t *testing.T) {
	tests := []struct {
		name      string
		reason    string
		reconnect bool
	}{
		{name: "cloud shutdown reconnects", reason: "cloud_shutdown", reconnect: true},
		{name: "terminal shutdown stops", reason: "runner_version_unsupported", reconnect: false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			first, second := newFakeConn(), newFakeConn()
			dialer := &queuedDialer{conns: []*fakeConn{first, second}}
			capture := &shutdownLogHandler{}
			cli := buildClient(t, dialer, func(opts *Options) {
				opts.Logger = slog.New(capture)
				opts.ReconnectMin = time.Millisecond
				opts.ReconnectMax = time.Millisecond
			})

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- cli.Run(ctx) }()

			waitUntil(t, time.Second, func() bool {
				return len(first.sentByType(MsgRunnerState)) == 1
			})
			first.in <- shutdownFrame(t, test.reason, "test shutdown")
			waitUntil(t, time.Second, func() bool {
				for _, entry := range capture.entriesSnapshot() {
					if entry.message == "cloud.shutdown" {
						return true
					}
				}
				return false
			})

			if test.reconnect {
				if err := first.Close(); err != nil {
					t.Fatal(err)
				}
				waitUntil(t, time.Second, func() bool {
					return len(second.sentByType(MsgRunnerState)) == 1
				})
				cancel()
				if err := <-done; !errors.Is(err, context.Canceled) {
					t.Fatalf("Run error = %v, want context.Canceled", err)
				}
				return
			}

			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("Run error = %v, want context.Canceled", err)
				}
			case <-time.After(time.Second):
				t.Fatal("Run kept reconnecting after terminal shutdown")
			}
			dialer.mu.Lock()
			remaining := len(dialer.conns)
			dialer.mu.Unlock()
			if remaining != 1 {
				t.Fatalf("remaining connections = %d, want 1", remaining)
			}
		})
	}
}
