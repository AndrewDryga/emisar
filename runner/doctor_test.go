package main

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestCheckCredential(t *testing.T) {
	t.Run("token file 0600 present", func(t *testing.T) {
		path := writeToken(t, "tok", 0o600)
		got := checkCredential(&config.Config{Cloud: config.Cloud{TokenPath: path, AuthKeyEnv: "X"}})
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	t.Run("token file group-readable warns", func(t *testing.T) {
		path := writeToken(t, "tok", 0o644)
		got := checkCredential(&config.Config{Cloud: config.Cloud{TokenPath: path}})
		if got.status != checkWarn {
			t.Fatalf("status = %v, want warn (%s)", got.status, got.detail)
		}
	})

	t.Run("no token, env set", func(t *testing.T) {
		t.Setenv("EMISAR_AUTH_KEY", "emk-secret")
		missing := filepath.Join(t.TempDir(), "absent")
		got := checkCredential(&config.Config{
			Cloud: config.Cloud{TokenPath: missing, AuthKeyEnv: "EMISAR_AUTH_KEY"},
		})
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	t.Run("no token, env unset, fails", func(t *testing.T) {
		t.Setenv("EMISAR_AUTH_KEY", "")
		missing := filepath.Join(t.TempDir(), "absent")
		got := checkCredential(&config.Config{
			Cloud: config.Cloud{TokenPath: missing, AuthKeyEnv: "EMISAR_AUTH_KEY"},
		})
		if got.status != checkFail {
			t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
		}
	})

	t.Run("empty token file falls back to env", func(t *testing.T) {
		t.Setenv("EMISAR_AUTH_KEY", "emk-secret")
		path := writeToken(t, "", 0o600)
		got := checkCredential(&config.Config{
			Cloud: config.Cloud{TokenPath: path, AuthKeyEnv: "EMISAR_AUTH_KEY"},
		})
		if got.status != checkOK || !strings.Contains(got.detail, "EMISAR_AUTH_KEY") {
			t.Fatalf("got %v %q, want ok via env", got.status, got.detail)
		}
	})
}

func writeToken(t *testing.T, body string, perm os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte(body), perm); err != nil {
		t.Fatal(err)
	}
	// WriteFile honors umask; force the exact bits we're testing.
	if err := os.Chmod(path, perm); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCheckPackDirs(t *testing.T) {
	tmp := t.TempDir()

	tests := []struct {
		name string
		dirs []string
		want checkStatus
	}{
		{"none configured", nil, checkWarn},
		{"existing dir", []string{tmp}, checkOK},
		{"missing dir", []string{filepath.Join(tmp, "nope")}, checkWarn},
		{"one missing among present", []string{tmp, filepath.Join(tmp, "nope")}, checkWarn},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := checkPackDirs(tc.dirs); got.status != tc.want {
				t.Fatalf("status = %v, want %v (%s)", got.status, tc.want, got.detail)
			}
		})
	}
}

func TestActionBinary(t *testing.T) {
	exec := &actionspec.Action{
		Kind:      actionspec.KindExec,
		Execution: actionspec.Execution{Command: &actionspec.Command{Binary: "redis-cli"}},
	}
	script := &actionspec.Action{
		Kind:      actionspec.KindScript,
		Execution: actionspec.Execution{Script: &actionspec.Script{Interpreter: "/bin/sh"}},
	}
	execNoCmd := &actionspec.Action{Kind: actionspec.KindExec}

	if got := actionBinary(exec); got != "redis-cli" {
		t.Errorf("exec binary = %q, want redis-cli", got)
	}
	if got := actionBinary(script); got != "/bin/sh" {
		t.Errorf("script interpreter = %q, want /bin/sh", got)
	}
	if got := actionBinary(execNoCmd); got != "" {
		t.Errorf("exec with no command = %q, want empty", got)
	}
}

func TestBinaryAvailable(t *testing.T) {
	// A real path that exists: the test binary itself.
	if !binaryAvailable(os.Args[0]) {
		t.Errorf("binaryAvailable(%q) = false, want true", os.Args[0])
	}
	if binaryAvailable("/definitely/not/here/emisar-xyz") {
		t.Error("missing absolute path reported available")
	}
	if binaryAvailable("emisar-definitely-not-a-real-binary-xyz") {
		t.Error("missing PATH binary reported available")
	}

	// A bare name resolvable on PATH.
	dir := t.TempDir()
	fake := filepath.Join(dir, "emisar-fake-tool")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	if !binaryAvailable("emisar-fake-tool") {
		t.Error("PATH binary reported unavailable")
	}
}

func TestHTTPProbeURL(t *testing.T) {
	tests := []struct {
		raw     string
		want    string
		wantErr bool
	}{
		{"wss://app.emisar.dev/socket/websocket", "https://app.emisar.dev/", false},
		{"ws://127.0.0.1:4000/socket", "http://127.0.0.1:4000/", false},
		{"https://app.emisar.dev", "https://app.emisar.dev/", false},
		{"http://localhost:4000", "http://localhost:4000/", false},
		{"ftp://app.emisar.dev", "", true},
		{"wss://", "", true},
		{"://bad", "", true},
	}
	for _, tc := range tests {
		t.Run(tc.raw, func(t *testing.T) {
			got, err := httpProbeURL(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("got %q, want error", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestClockSkew(t *testing.T) {
	now := time.Now().UTC().Format(http.TimeFormat)
	skewed := time.Now().Add(2 * time.Hour).UTC().Format(http.TimeFormat)

	if d, ok := clockSkew(now); !ok || d > time.Minute {
		t.Errorf("clockSkew(now) = %v %v, want small + ok", d, ok)
	}
	if d, ok := clockSkew(skewed); !ok || d < time.Hour {
		t.Errorf("clockSkew(+2h) = %v %v, want ~2h + ok", d, ok)
	}
	if _, ok := clockSkew(""); ok {
		t.Error("clockSkew(empty) ok = true, want false")
	}
	if _, ok := clockSkew("not a date"); ok {
		t.Error("clockSkew(garbage) ok = true, want false")
	}
}

func TestCheckCloud(t *testing.T) {
	t.Run("reachable", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
		}))
		defer srv.Close()

		cfg := &config.Config{Cloud: config.Cloud{URL: "ws://" + hostOf(srv.URL)}}
		got := checkCloud(context.Background(), cfg, srv.Client())
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	t.Run("skewed clock warns", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Date", time.Now().Add(2*time.Hour).UTC().Format(http.TimeFormat))
			w.WriteHeader(http.StatusOK)
		}))
		defer srv.Close()

		cfg := &config.Config{Cloud: config.Cloud{URL: "ws://" + hostOf(srv.URL)}}
		got := checkCloud(context.Background(), cfg, srv.Client())
		if got.status != checkWarn {
			t.Fatalf("status = %v, want warn (%s)", got.status, got.detail)
		}
	})

	t.Run("unreachable fails", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		host := hostOf(srv.URL)
		srv.Close() // nothing listens now

		cfg := &config.Config{Cloud: config.Cloud{URL: "ws://" + host}}
		got := checkCloud(context.Background(), cfg, &http.Client{Timeout: time.Second})
		if got.status != checkFail {
			t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
		}
	})
}

func hostOf(rawURL string) string {
	return strings.TrimPrefix(strings.TrimPrefix(rawURL, "https://"), "http://")
}

func TestReportDoctor(t *testing.T) {
	results := []checkResult{
		{"config", checkOK, "loaded"},
		{"credential", checkFail, "no token"},
		{"action tools", checkWarn, "redis-cli missing"},
	}
	var buf bytes.Buffer
	fails := reportDoctor(&buf, results)

	if fails != 1 {
		t.Errorf("fails = %d, want 1", fails)
	}
	out := buf.String()
	for _, want := range []string{"config", "credential", "no token", "action tools", "✓", "✗", "⚠"} {
		if !strings.Contains(out, want) {
			t.Errorf("report missing %q\n%s", want, out)
		}
	}
}
