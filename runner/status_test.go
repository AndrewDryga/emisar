package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
)

func statusFixture(now time.Time, pid int) cloud.RuntimeStatus {
	connected := now.Add(-2 * time.Minute)
	heartbeat := now.Add(-5 * time.Second)
	return cloud.RuntimeStatus{
		SchemaVersion: 1, PID: pid, State: cloud.RuntimeStateConnected,
		StartedAt: now.Add(-time.Hour), UpdatedAt: now.Add(-5 * time.Second),
		ConnectedAt: &connected, LastHeartbeatSentAt: &heartbeat,
		HeartbeatEverySeconds: 30, Packs: 3, Actions: 40,
		UnavailableActions: 1, InflightRuns: 2, ConnectionAttempts: 2,
	}
}

func writeStatusFixture(t *testing.T, dataDir string, status cloud.RuntimeStatus) {
	t.Helper()
	body, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	path := cloud.RuntimeStatusPath(dataDir)
	if err := os.WriteFile(path, append(body, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestCheckRuntimeStatusRequiresHeldMatchingLockAndFreshSnapshot(t *testing.T) {
	now := time.Now().UTC()
	t.Run("healthy live daemon", func(t *testing.T) {
		dataDir := t.TempDir()
		lock, err := lockConnectDataDir(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = lock.Close() }()
		writeStatusFixture(t, dataDir, statusFixture(now, os.Getpid()))

		status, checks, connected := checkRuntimeStatus(&config.Config{Paths: config.Paths{DataDir: dataDir}}, now)
		if status == nil || !connected || checks[0].status != checkOK {
			t.Fatalf("status=%+v connected=%t checks=%+v", status, connected, checks)
		}
		if checks[1].status != checkWarn || !strings.Contains(checks[1].detail, "1 unavailable") {
			t.Fatalf("catalog check = %+v", checks[1])
		}
	})

	t.Run("leftover snapshot after daemon exit", func(t *testing.T) {
		dataDir := t.TempDir()
		lock, err := lockConnectDataDir(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		writeStatusFixture(t, dataDir, statusFixture(now, os.Getpid()))
		if err := lock.Close(); err != nil {
			t.Fatal(err)
		}

		_, checks, connected := checkRuntimeStatus(&config.Config{Paths: config.Paths{DataDir: dataDir}}, now)
		if connected || checks[0].status != checkFail || !strings.Contains(checks[0].detail, "not running") {
			t.Fatalf("connected=%t checks=%+v", connected, checks)
		}
	})

	t.Run("snapshot belongs to another PID", func(t *testing.T) {
		dataDir := t.TempDir()
		lock, err := lockConnectDataDir(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = lock.Close() }()
		writeStatusFixture(t, dataDir, statusFixture(now, os.Getpid()+1))

		_, checks, connected := checkRuntimeStatus(&config.Config{Paths: config.Paths{DataDir: dataDir}}, now)
		if connected || checks[0].status != checkFail || !strings.Contains(checks[0].detail, "live daemon") {
			t.Fatalf("connected=%t checks=%+v", connected, checks)
		}
	})

	t.Run("stale heartbeat", func(t *testing.T) {
		dataDir := t.TempDir()
		lock, err := lockConnectDataDir(dataDir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = lock.Close() }()
		status := statusFixture(now, os.Getpid())
		stale := now.Add(-2 * time.Minute)
		status.LastHeartbeatSentAt = &stale
		writeStatusFixture(t, dataDir, status)

		_, checks, connected := checkRuntimeStatus(&config.Config{Paths: config.Paths{DataDir: dataDir}}, now)
		if connected || checks[0].status != checkFail || !strings.Contains(checks[0].detail, "stale") {
			t.Fatalf("connected=%t checks=%+v", connected, checks)
		}
	})
}

func TestReportStatusIsCompactAndPlainOffTerminal(t *testing.T) {
	checks := []checkResult{
		{"connection", checkOK, "connected · heartbeat sent 2s ago"},
		{"catalog", checkWarn, "3 packs · 40 actions advertised · 1 unavailable"},
		{"process", checkOK, "PID 42 · up 1h0m0s · 1 connection attempt(s)"},
		{"runs", checkOK, "0 in flight"},
		{"config", checkOK, "/etc/emisar/config.yaml"},
		{"credential", checkOK, "token present"},
	}
	var out bytes.Buffer
	if fails := reportStatus(&out, checks, 4); fails != 0 {
		t.Fatalf("fails = %d", fails)
	}
	text := out.String()
	for _, want := range []string{"emisar status", "connection", "catalog", "process", "runs", "2 local readiness checks passed"} {
		if !strings.Contains(text, want) {
			t.Errorf("output missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "token present") || strings.Contains(text, "\x1b[") {
		t.Fatalf("healthy local detail or ANSI leaked into compact output:\n%q", text)
	}
}

func TestNewStatusReportMatchesDoctorVocabulary(t *testing.T) {
	report := newStatusReport(nil, []checkResult{
		{"connection", checkOK, "connected"},
		{"catalog", checkWarn, "one unavailable"},
	})
	if report.Status != "warn" || report.Passed != 1 || report.Warnings != 1 || report.Failed != 0 {
		t.Fatalf("report = %+v", report)
	}
	body, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(body), "\x1b[") || !bytes.Contains(body, []byte(`"status":"warn"`)) {
		t.Fatalf("JSON = %s", body)
	}
}

func TestReadRuntimeStatusPathIsInsideDataDir(t *testing.T) {
	dataDir := t.TempDir()
	if got, want := cloud.RuntimeStatusPath(dataDir), filepath.Join(dataDir, "runtime-status.json"); got != want {
		t.Fatalf("path = %s, want %s", got, want)
	}
}
