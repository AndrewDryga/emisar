package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/actionhost"
	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestCheckCredential(t *testing.T) {
	t.Run("token file 0600 present", func(t *testing.T) {
		path := writeToken(t, validTokenFile, 0o600)
		got := checkCredential(&config.Config{Cloud: config.Cloud{TokenPath: path, EnrollmentKeyEnv: "X"}})
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	// connect refuses to reuse an exposed token and will not re-register over
	// it, so the runner stays down until the mode is fixed — that's a failure,
	// and the remedy has to name the file and the exact fix.
	t.Run("token file group-readable fails with the chmod remedy", func(t *testing.T) {
		path := writeToken(t, validTokenFile, 0o644)
		got := checkCredential(&config.Config{Cloud: config.Cloud{TokenPath: path}})
		if got.status != checkFail {
			t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
		}
		for _, want := range []string{path, "0644", "chmod 600"} {
			if !strings.Contains(got.detail, want) {
				t.Errorf("detail %q should contain %q", got.detail, want)
			}
		}
	})

	t.Run("no token, env set", func(t *testing.T) {
		t.Setenv("EMISAR_ENROLLMENT_KEY", "emk-secret")
		missing := filepath.Join(t.TempDir(), "absent")
		got := checkCredential(&config.Config{
			Cloud: config.Cloud{TokenPath: missing, EnrollmentKeyEnv: "EMISAR_ENROLLMENT_KEY"},
		})
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	t.Run("no token, env unset, fails", func(t *testing.T) {
		t.Setenv("EMISAR_ENROLLMENT_KEY", "")
		missing := filepath.Join(t.TempDir(), "absent")
		got := checkCredential(&config.Config{
			Cloud: config.Cloud{TokenPath: missing, EnrollmentKeyEnv: "EMISAR_ENROLLMENT_KEY"},
		})
		if got.status != checkFail {
			t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
		}
	})
}

// A cached token file connect would REJECT is never rescued by an enrollment
// key: connect refuses to register over a rejected cache (that would mint a
// fresh token on top of the evidence), so the runner stays down and doctor has
// to say so — naming the path and the cause instead of reporting a healthy
// credential. Only a missing file is the pre-enrollment case, covered above.
func TestCheckCredentialRejectsWhatConnectRejects(t *testing.T) {
	tests := map[string]struct {
		// setup returns the token path to check.
		setup     func(t *testing.T) string
		wantCause string
	}{
		"group-readable": {
			setup:     func(t *testing.T) string { return writeToken(t, validTokenFile, 0o644) },
			wantCause: "chmod 600",
		},
		"malformed json": {
			setup:     func(t *testing.T) string { return writeToken(t, `{"token":`, 0o600) },
			wantCause: "decode token file",
		},
		"unknown field": {
			setup:     func(t *testing.T) string { return writeToken(t, `{"token":"tok","extra":1}`, 0o600) },
			wantCause: "decode token file",
		},
		"empty file": {
			setup:     func(t *testing.T) string { return writeToken(t, "", 0o600) },
			wantCause: "decode token file",
		},
		"empty token": {
			setup:     func(t *testing.T) string { return writeToken(t, `{"token":""}`, 0o600) },
			wantCause: "empty token",
		},
		"symlinked path": {
			// The target is a perfectly good token; connect still refuses to
			// follow a symlink at the cache path (O_NOFOLLOW).
			setup: func(t *testing.T) string {
				target := writeToken(t, validTokenFile, 0o600)
				link := filepath.Join(t.TempDir(), "token.link")
				if err := os.Symlink(target, link); err != nil {
					t.Fatal(err)
				}
				return link
			},
		},
		"not a regular file": {
			// A directory at the cache path: the open succeeds but the read
			// can't, standing in for any unreadable cache without depending on
			// permission tricks that a root test runner would defeat.
			setup: func(t *testing.T) string {
				path := filepath.Join(t.TempDir(), "token")
				if err := os.Mkdir(path, 0o700); err != nil {
					t.Fatal(err)
				}
				return path
			},
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Setenv("EMISAR_ENROLLMENT_KEY", "emk-secret")
			path := tc.setup(t)
			got := checkCredential(&config.Config{
				Cloud: config.Cloud{TokenPath: path, EnrollmentKeyEnv: "EMISAR_ENROLLMENT_KEY"},
			})
			if got.status != checkFail {
				t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
			}
			if !strings.Contains(got.detail, path) {
				t.Errorf("detail %q should name the token path %s", got.detail, path)
			}
			if tc.wantCause != "" && !strings.Contains(got.detail, tc.wantCause) {
				t.Errorf("detail %q should carry the cause %q", got.detail, tc.wantCause)
			}
		})
	}
}

// validTokenFile is the on-disk shape connect writes and accepts — a strict
// {"token": …} document, not raw token bytes.
const validTokenFile = `{"token":"tok"}`

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

// checkPacks caps the pack sample at maxPackSample (12): with 13 packs loaded
// it reports the true count, lists 12 `id@version` entries, and summarizes the
// rest as "+1 more" so the doctor line stays scannable (`pack list` has the
// full set).
func TestCheckPacks_SampleCappedAtTwelve(t *testing.T) {
	root := t.TempDir()
	const n = maxPackSample + 1 // 13
	for i := 0; i < n; i++ {
		// Distinct pack ids p00..p12; writePack makes a one-action pack per id.
		writePack(t, root, fmt.Sprintf("p%02d", i))
	}

	reg, got := checkPacks([]string{root})
	if reg == nil {
		t.Fatal("checkPacks should return the loaded registry")
	}
	if got.status != checkOK {
		t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
	}
	// The true count is reported even though the sample is capped.
	if !strings.Contains(got.detail, fmt.Sprintf("%d loaded", n)) {
		t.Fatalf("detail should report the true count %d: %q", n, got.detail)
	}
	// Exactly maxPackSample `id@version` entries are listed (count the "@0.0.1").
	if c := strings.Count(got.detail, "@0.0.1"); c != maxPackSample {
		t.Fatalf("expected %d sampled packs, got %d: %q", maxPackSample, c, got.detail)
	}
	// The overflow is summarized as "+1 more".
	if !strings.Contains(got.detail, "+1 more") {
		t.Fatalf("detail should summarize the overflow as +1 more: %q", got.detail)
	}
}

// A broken installed pack degrades (the daemon skips it and keeps serving the
// rest) — doctor must FAIL the packs check naming the directory and remedy,
// because the pack silently missing from the catalog is exactly what an
// operator comes to doctor to explain.
func TestCheckPacks_ReportsDegraded(t *testing.T) {
	root := t.TempDir()
	writePack(t, root, "healthy")
	brokenDir := filepath.Join(root, "broken")
	if err := os.MkdirAll(brokenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(brokenDir, "pack.yaml"), []byte("not: [valid"), 0o644); err != nil {
		t.Fatal(err)
	}

	reg, got := checkPacks([]string{root})
	if reg == nil {
		t.Fatal("checkPacks should still return the healthy registry")
	}
	if got.status != checkFail {
		t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
	}
	if !strings.Contains(got.detail, brokenDir) || !strings.Contains(got.detail, "1 loaded") {
		t.Fatalf("detail should name the broken dir and the healthy count: %q", got.detail)
	}
	// `pack update <id>` is the repair path for an already-installed pack (it
	// re-fetches and swaps the tree); `pack install` refuses an existing id
	// without --force, so guidance must never send the operator there.
	if !strings.Contains(got.detail, "emisar pack update <id>") || !strings.Contains(got.detail, "installer") {
		t.Errorf("detail should offer the update + re-run-the-installer remedies: %q", got.detail)
	}
	if strings.Contains(got.detail, "pack install") {
		t.Errorf("detail must not send the operator to 'pack install' for an installed pack: %q", got.detail)
	}
}

func TestCheckDispatchLog(t *testing.T) {
	t.Run("absent is ok", func(t *testing.T) {
		got := checkDispatchLog(&config.Config{Paths: config.Paths{DataDir: t.TempDir()}})
		if got.status != checkOK {
			t.Fatalf("status = %v, want ok (%s)", got.status, got.detail)
		}
	})

	t.Run("corrupt fails with the quarantine remedy", func(t *testing.T) {
		dataDir := t.TempDir()
		logPath := filepath.Join(dataDir, "dispatches.jsonl")
		if err := os.WriteFile(logPath, []byte("not-json\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		legacyPath := filepath.Join(dataDir, "dedup.jsonl")
		if err := os.WriteFile(legacyPath, []byte("stale\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		got := checkDispatchLog(&config.Config{Paths: config.Paths{DataDir: dataDir}})
		if got.status != checkFail {
			t.Fatalf("status = %v, want fail (%s)", got.status, got.detail)
		}
		if !strings.Contains(got.detail, logPath) || !strings.Contains(got.detail, legacyPath) ||
			!strings.Contains(got.detail, "stop the runner and prove it is idle") ||
			!strings.Contains(got.detail, "may allow a redelivered action to run again") {
			t.Fatalf("detail should name the file and the quarantine remedy: %q", got.detail)
		}
	})

	t.Run("legacy state is ok pending migration", func(t *testing.T) {
		dataDir := t.TempDir()
		legacy := `{"request_id":"req","result":{"type":"action_result","protocol_version":1,"request_id":"req","status":"success"}}` + "\n"
		if err := os.WriteFile(filepath.Join(dataDir, "dedup.jsonl"), []byte(legacy), 0o600); err != nil {
			t.Fatal(err)
		}
		got := checkDispatchLog(&config.Config{Paths: config.Paths{DataDir: dataDir}})
		if got.status != checkOK || !strings.Contains(got.detail, "older dispatch state") {
			t.Fatalf("legacy state should be ok pending migration: %v (%s)", got.status, got.detail)
		}
	})
}

func TestDoctorUsesActionHostExecutableVerdict(t *testing.T) {
	exec := &actionspec.Action{
		Kind:      actionspec.KindExec,
		Execution: actionspec.Execution{Command: &actionspec.Command{Binary: "redis-cli"}},
	}
	script := &actionspec.Action{
		Kind:      actionspec.KindScript,
		Execution: actionspec.Execution{Script: &actionspec.Script{Interpreter: "/bin/sh"}},
	}
	execNoCmd := &actionspec.Action{Kind: actionspec.KindExec}

	if got := actionhost.PrimaryExecutable(exec); got != "redis-cli" {
		t.Errorf("exec binary = %q, want redis-cli", got)
	}
	if got := actionhost.PrimaryExecutable(script); got != "/bin/sh" {
		t.Errorf("script interpreter = %q, want /bin/sh", got)
	}
	if got := actionhost.PrimaryExecutable(execNoCmd); got != "" {
		t.Errorf("exec with no command = %q, want empty", got)
	}
}

func TestActionHostExecutableAvailability(t *testing.T) {
	action := func(binary string) *actionspec.Action {
		return &actionspec.Action{Kind: actionspec.KindExec, Execution: actionspec.Execution{
			Command: &actionspec.Command{Binary: binary},
		}}
	}
	// A real path that exists: the test binary itself.
	if !actionhost.PrimaryExecutableAvailable(action(os.Args[0])) {
		t.Errorf("PrimaryExecutableAvailable(%q) = false, want true", os.Args[0])
	}
	if actionhost.PrimaryExecutableAvailable(action("/definitely/not/here/emisar-xyz")) {
		t.Error("missing absolute path reported available")
	}
	if actionhost.PrimaryExecutableAvailable(action("emisar-definitely-not-a-real-binary-xyz")) {
		t.Error("missing PATH binary reported available")
	}

	// A bare name resolvable on PATH.
	dir := t.TempDir()
	fake := filepath.Join(dir, "emisar-fake-tool")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	if !actionhost.PrimaryExecutableAvailable(action("emisar-fake-tool")) {
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

func TestCheckCloudReportsRecentTerminalShutdown(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	now := time.Now().UTC()
	tests := []struct {
		name       string
		state      *cloud.TerminalShutdownState
		wantStatus checkStatus
		wantDetail []string
	}{
		{
			name: "recent unsupported runner is actionable",
			state: &cloud.TerminalShutdownState{
				Reason:    "runner_version_unsupported",
				Message:   "upgrade to 1.2.3",
				Timestamp: now.Add(-time.Minute),
			},
			wantStatus: checkFail,
			wantDetail: []string{"the control plane rejected this runner", "runner_version_unsupported", "upgrade to 1.2.3", "upgrade the runner"},
		},
		{
			name: "recent revoked runner is actionable",
			state: &cloud.TerminalShutdownState{
				Reason:    "runner_revoked",
				Message:   "runner removed",
				Timestamp: now.Add(-time.Minute),
			},
			wantStatus: checkFail,
			wantDetail: []string{"the control plane rejected this runner", "runner_revoked", "runner removed", "re-register"},
		},
		{
			name: "stale rejection falls back to reachability",
			state: &cloud.TerminalShutdownState{
				Reason:    "runner_revoked",
				Message:   "old rejection",
				Timestamp: now.Add(-cloud.TerminalShutdownFreshness - time.Minute),
			},
			wantStatus: checkOK,
			wantDetail: []string{"reachable"},
		},
		{
			name:       "missing rejection falls back to reachability",
			wantStatus: checkOK,
			wantDetail: []string{"reachable"},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			if test.state != nil {
				body, err := json.Marshal(test.state)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(cloud.TerminalShutdownStatePath(dir), body, 0o600); err != nil {
					t.Fatal(err)
				}
			}

			cfg := &config.Config{
				Cloud: config.Cloud{URL: "ws://" + hostOf(srv.URL)},
				Paths: config.Paths{DataDir: dir},
			}
			got := checkCloud(context.Background(), cfg, srv.Client())
			if got.status != test.wantStatus {
				t.Fatalf("status = %v, want %v (%s)", got.status, test.wantStatus, got.detail)
			}
			for _, want := range test.wantDetail {
				if !strings.Contains(got.detail, want) {
					t.Errorf("detail %q missing %q", got.detail, want)
				}
			}
		})
	}
}

func hostOf(rawURL string) string {
	return strings.TrimPrefix(strings.TrimPrefix(rawURL, "https://"), "http://")
}

// `emisar doctor` runs end-to-end and exits 0 when every check passes: a
// loadable config, a present credential, packs that load, action binaries on
// disk, and a reachable control plane. The cloud check HEADs cfg.Cloud.URL, so
// we point it at a loopback httptest server (loopback cleartext is allowed).
// The one-action pack runs /bin/true, which resolves. Driven through the real
// command; RunE returns nil and reportDoctor prints to os.Stdout.
func TestDoctorCmd_AllPassExitZero(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	dir := t.TempDir()
	// Use /bin/sh (present on every supported host, and the canonical
	// absolute-path binary the doctor stats on disk) so the action-tools check
	// passes — /bin/true isn't at that path on macOS.
	packDir := writeShPack(t, filepath.Join(dir, "packs"), "linux")
	tokenPath := writeToken(t, validTokenFile, 0o600)
	flagConfig = writeDoctorConfig(t, dir, packDir, "ws://"+hostOf(srv.URL), tokenPath)

	var execErr error
	out := captureStdout(t, func() {
		cmd := doctorCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("doctor should exit 0 when all checks pass: %v\n%s", execErr, out)
	}
	if !strings.Contains(out, "All checks passed") {
		t.Fatalf("doctor summary should report all-clear:\n%s", out)
	}
	if strings.Contains(out, "✗") {
		t.Fatalf("no check should fail:\n%s", out)
	}
}

// When the config itself can't load, doctor short-circuits: only the config
// check is reported (its dependents are skipped) and the command returns a
// non-nil error so the exit status is non-zero.
func TestDoctorCmd_ConfigFailShortCircuits(t *testing.T) {
	withFlags(t)
	withJSONOut(t, false)
	bad := filepath.Join(t.TempDir(), "broken.yaml")
	if err := os.WriteFile(bad, []byte("schema_version: 1\nrunner: : :\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	flagConfig = bad

	var execErr error
	out := captureStdout(t, func() {
		cmd := doctorCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr == nil {
		t.Fatalf("doctor must exit non-zero when config fails:\n%s", out)
	}
	// The config line is present; dependent checks (credential, packs, cloud)
	// are not — they'd run against a zero config otherwise.
	if !strings.Contains(out, "config") {
		t.Fatalf("the config check should still be reported:\n%s", out)
	}
	for _, skipped := range []string{"credential", "cloud"} {
		if strings.Contains(out, skipped) {
			t.Fatalf("dependent check %q should be skipped on a config failure:\n%s", skipped, out)
		}
	}
}

// writeShPack drops a one-action pack whose exec binary is /bin/sh (which
// resolves on disk on every supported host) under root/<id>/ and returns root.
// Used where the doctor's action-binary check must pass.
func writeShPack(t *testing.T, root, id string) string {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
		t.Fatalf("mkdir pack: %v", err)
	}
	manifest := "schema_version: 1\nid: " + id + "\nname: " + id + "\nversion: 0.0.1\ndescription: d\nactions:\n  - actions/ping.yaml\n"
	action := "schema_version: 1\nid: " + id + ".ping\ntitle: Ping\nkind: exec\nrisk: low\ndescription: d\nside_effects: [none]\n" +
		"execution:\n  command:\n    binary: /bin/sh\n    argv: [\"-c\", \"true\"]\n  timeout: 5s\n  timeout_min: 1s\n  timeout_max: 30s\n" +
		"output:\n  parser: text\n  max_stdout_bytes: 1024\n  max_stderr_bytes: 1024\n"
	if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatalf("write pack.yaml: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "actions", "ping.yaml"), []byte(action), 0o644); err != nil {
		t.Fatalf("write action: %v", err)
	}
	return root
}

// writeDoctorConfig writes a full config the doctor command can run every
// check against: a packs dir, a cloud URL, a token-path credential, and the
// journal under dir.
func writeDoctorConfig(t *testing.T, dir, packDir, cloudURL, tokenPath string) string {
	t.Helper()
	cfgPath := filepath.Join(dir, "config.yaml")
	yaml := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"cloud:\n  url: " + cloudURL + "\n  enrollment_key_env: EMISAR_ENROLLMENT_KEY\n  token_path: " + tokenPath + "\n" +
		"paths:\n  packs:\n    - " + packDir + "\n  data_dir: " + filepath.Join(dir, "data") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write doctor config: %v", err)
	}
	return cfgPath
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

// newDoctorReport carries every check across with a string status, and the
// overall verdict is the WORST check — a warning never masks a failure, and a
// clean run is unambiguously "ok".
func TestNewDoctorReport(t *testing.T) {
	tests := []struct {
		name    string
		results []checkResult
		want    doctorReport
	}{
		{
			name:    "all ok",
			results: []checkResult{{"config", checkOK, "loaded"}, {"packs", checkOK, "1 loaded"}},
			want:    doctorReport{Status: "ok", Passed: 2},
		},
		{
			name:    "a warning downgrades the verdict",
			results: []checkResult{{"config", checkOK, "loaded"}, {"action tools", checkWarn, "redis-cli missing"}},
			want:    doctorReport{Status: "warn", Passed: 1, Warned: 1},
		},
		{
			name:    "a failure outranks a warning",
			results: []checkResult{{"credential", checkFail, "no token"}, {"action tools", checkWarn, "missing"}},
			want:    doctorReport{Status: "fail", Warned: 1, Failed: 1},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := newDoctorReport(tc.results)
			if got.Status != tc.want.Status {
				t.Errorf("status = %q, want %q", got.Status, tc.want.Status)
			}
			if got.Passed != tc.want.Passed || got.Warned != tc.want.Warned || got.Failed != tc.want.Failed {
				t.Errorf("counts = %d/%d/%d, want %d/%d/%d (passed/warnings/failed)",
					got.Passed, got.Warned, got.Failed, tc.want.Passed, tc.want.Warned, tc.want.Failed)
			}
			if len(got.Checks) != len(tc.results) {
				t.Fatalf("checks = %d, want one per result (%d)", len(got.Checks), len(tc.results))
			}
			for i, check := range got.Checks {
				if check.Name != tc.results[i].name || check.Detail != tc.results[i].detail {
					t.Errorf("check %d = %+v, want the %q result verbatim", i, check, tc.results[i].name)
				}
				if check.Status != tc.results[i].status.String() {
					t.Errorf("check %d status = %q, want %q", i, check.Status, tc.results[i].status)
				}
			}
		})
	}
}

// `doctor --json` emits a parseable report instead of the human text: no
// banner, no glyphs, no ANSI — and the failing check's remedy still rides
// along in its detail so the JSON is diagnostically useful, not just valid.
// The command still exits non-zero, so a wrapper script can't read a broken
// runner as healthy.
func TestDoctorCmd_JSONReportsFailuresAndExitsNonZero(t *testing.T) {
	withFlags(t)
	withJSONOut(t, true)
	dir := t.TempDir()
	packDir := writeShPack(t, filepath.Join(dir, "packs"), "linux")
	// A token file others can read: connect refuses to reuse it, so the
	// credential check fails with a chmod remedy. No server is listening on the
	// cloud URL either, so that check fails too.
	tokenPath := writeToken(t, validTokenFile, 0o644)
	flagConfig = writeDoctorConfig(t, dir, packDir, "ws://127.0.0.1:1", tokenPath)

	var execErr error
	out := captureStdout(t, func() {
		cmd := doctorCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr == nil {
		t.Fatalf("doctor must exit non-zero when checks fail:\n%s", out)
	}
	if !strings.Contains(execErr.Error(), "preflight check(s) failed") {
		t.Errorf("error should name the failed preflight, got %v", execErr)
	}

	var report doctorReport
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("doctor --json must emit a JSON object: %v\n%s", err, out)
	}
	if report.Status != "fail" || report.Failed == 0 {
		t.Errorf("report = %+v, want a failing verdict", report)
	}
	if len(report.Checks) == 0 {
		t.Fatalf("report carries no checks:\n%s", out)
	}
	credential, ok := findDoctorCheck(report, "credential")
	if !ok {
		t.Fatalf("report is missing the credential check: %+v", report.Checks)
	}
	if credential.Status != "fail" {
		t.Errorf("credential status = %q, want fail (%s)", credential.Status, credential.Detail)
	}
	if !strings.Contains(credential.Detail, "chmod 600") {
		t.Errorf("the JSON detail must carry the remedy, got %q", credential.Detail)
	}
	for _, check := range report.Checks {
		switch check.Status {
		case "ok", "warn", "fail":
		default:
			t.Errorf("check %q has status %q, want one of ok/warn/fail", check.Name, check.Status)
		}
	}
	// Nothing from the human renderer leaks into the machine payload.
	for _, forbidden := range []string{"emisar doctor", "✓", "⚠", "✗", "\x1b[", "problem(s)"} {
		if strings.Contains(out, forbidden) {
			t.Errorf("--json output must not contain %q:\n%s", forbidden, out)
		}
	}
}

// `doctor --json` on a healthy runner is an "ok" verdict with every check
// counted — the shape a fleet script polls.
func TestDoctorCmd_JSONAllPass(t *testing.T) {
	withFlags(t)
	withJSONOut(t, true)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	dir := t.TempDir()
	packDir := writeShPack(t, filepath.Join(dir, "packs"), "linux")
	tokenPath := writeToken(t, validTokenFile, 0o600)
	flagConfig = writeDoctorConfig(t, dir, packDir, "ws://"+hostOf(srv.URL), tokenPath)

	var execErr error
	out := captureStdout(t, func() {
		cmd := doctorCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		execErr = cmd.Execute()
	})
	if execErr != nil {
		t.Fatalf("doctor --json should exit 0 when all checks pass: %v\n%s", execErr, out)
	}
	var report doctorReport
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("doctor --json must emit a JSON object: %v\n%s", err, out)
	}
	if report.Status != "ok" || report.Failed != 0 || report.Warned != 0 {
		t.Errorf("report = %+v, want an all-clear verdict", report)
	}
	if report.Passed != len(report.Checks) {
		t.Errorf("passed = %d, want one per check (%d)", report.Passed, len(report.Checks))
	}
}

func findDoctorCheck(report doctorReport, name string) (doctorCheck, bool) {
	for _, check := range report.Checks {
		if check.Name == name {
			return check, true
		}
	}
	return doctorCheck{}, false
}
