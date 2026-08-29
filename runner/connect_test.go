package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

// reloadConfigYAML is a complete config the daemon accepts, parameterised on
// the sections a reload test edits.
func reloadConfigYAML(packsDir, dataDir, jsonlPath, deny, group, maxAge, redactLiteral string) string {
	return `schema_version: 1
runner:
  group: ` + group + `
paths:
  data_dir: ` + dataDir + `
  packs:
    - ` + packsDir + `
events:
  jsonl_path: ` + jsonlPath + `
admission:
  deny:
    - ` + deny + `
signing:
  max_attestation_age: ` + maxAge + `
redaction:
  rules:
    - name: operator-literal
      type: literal
      literal: ` + redactLiteral + `
`
}

// SIGHUP re-read the whole config but applied only packs and signing, so an
// operator who tightened admission.deny and reloaded was told the reload
// succeeded while the runner kept admitting exactly what they had banned.
func TestReloadRuntime_AppliesAdmissionAndRedaction(t *testing.T) {
	tmp := t.TempDir()
	packsDir := filepath.Join(tmp, "packs")
	writeValidPack(t, packsDir, "redis")
	cfgPath := filepath.Join(tmp, "config.yaml")
	dataDir := filepath.Join(tmp, "data")
	jsonlPath := filepath.Join(tmp, "events.jsonl")
	write := func(deny, group, maxAge, redactLiteral string) {
		t.Helper()
		body := reloadConfigYAML(packsDir, dataDir, jsonlPath, deny, group, maxAge, redactLiteral)
		if err := os.WriteFile(cfgPath, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	write("nothing.*", "prod", "1h", "old-secret")
	origConfig, origPacks := flagConfig, flagPacksDir
	t.Cleanup(func() { flagConfig, flagPacksDir = origConfig, origPacks })
	flagConfig, flagPacksDir = cfgPath, nil
	t.Setenv("EMISAR_CONFIG", "")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatal(err)
	}
	rt, err := bootWithConfig(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = rt.journal.Close() })
	if ok, _ := rt.engine.Admission().Admit("redis.a"); !ok {
		t.Fatal("the action must be admitted before the operator bans it")
	}

	// The operator bans the action, adds a redaction rule, widens the
	// attestation window, and edits a section only a restart can apply.
	write("redis.*", "staging", "2h", "new-secret")
	logs := &captureLogs{}
	client := cloud.NewClient(refusingDialer{}, cloud.Options{Engine: rt.engine})
	if !reloadRuntime(rt, client, signing.NewMemoryNonceStore(), slog.New(logs)) {
		t.Fatal("reload applied nothing")
	}

	if ok, _ := rt.engine.Admission().Admit("redis.a"); ok {
		t.Fatal("the reloaded deny list is not enforced; the runner still admits the banned action")
	}
	if masked, _ := rt.engine.Redactor().Apply("value new-secret here"); strings.Contains(masked, "new-secret") {
		t.Fatalf("the reloaded redaction rule is not applied: %q", masked)
	}
	if got := client.Verifier().MaxAge(); got != 2*time.Hour {
		t.Fatalf("verifier max age=%s after reload, want the reloaded 2h", got)
	}
	// Identity is what this process registered and advertises, so a changed
	// runner section is reported rather than half-applied to the verifier.
	if !logs.has("reload_restart_required", "runner") {
		t.Fatalf("a changed runner section must be reported as restart-required: %v", logs.records)
	}
}

func TestRestartRequiredChanges(t *testing.T) {
	booted := &config.Config{
		Runner: config.Runner{Group: "prod"},
		Cloud:  config.Cloud{URL: "wss://portal.example/runner"},
		Paths:  config.Paths{DataDir: "/var/lib/emisar"},
		Events: config.Events{JSONLPath: "/var/log/emisar/events.jsonl"},
	}
	if got := restartRequiredChanges(booted, booted); got != nil {
		t.Fatalf("unchanged config reported %v", got)
	}

	cases := map[string]func(*config.Config){
		"runner":    func(c *config.Config) { c.Runner.Group = "staging" },
		"cloud":     func(c *config.Config) { c.Cloud.URL = "wss://other.example/runner" },
		"paths":     func(c *config.Config) { c.Paths.DataDir = "/srv/emisar" },
		"execution": func(c *config.Config) { c.Execution.InheritEnv = []string{"NOMAD_ADDR"} },
		"events":    func(c *config.Config) { c.Events.MaxBackups = 9 },
	}
	for name, edit := range cases {
		t.Run(name, func(t *testing.T) {
			edited := *booted
			edit(&edited)
			got := restartRequiredChanges(booted, &edited)
			if len(got) != 1 || got[0] != name {
				t.Fatalf("restartRequiredChanges = %v, want [%s]", got, name)
			}
		})
	}
}

// captureLogs records structured log records so a test can assert on what the
// operator is told.
type captureLogs struct {
	mu      sync.Mutex
	records []string
}

func (h *captureLogs) Enabled(context.Context, slog.Level) bool { return true }
func (h *captureLogs) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *captureLogs) WithGroup(string) slog.Handler            { return h }

func (h *captureLogs) Handle(_ context.Context, r slog.Record) error {
	line := r.Message
	r.Attrs(func(a slog.Attr) bool {
		line += " " + a.Key + "=" + a.Value.String()
		return true
	})
	h.mu.Lock()
	defer h.mu.Unlock()
	h.records = append(h.records, line)
	return nil
}

func (h *captureLogs) has(parts ...string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, record := range h.records {
		matched := true
		for _, part := range parts {
			if !strings.Contains(record, part) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

// refusingDialer stands in for the control plane: reloadRuntime only swaps the
// client's verifier, so no session is ever established.
type refusingDialer struct{}

func (refusingDialer) Dial(context.Context) (cloud.Conn, error) {
	return nil, errors.New("test dialer never connects")
}

func TestConnectRequiresDurableDataDir(t *testing.T) {
	for _, dataDir := range []string{"", "  ", "\n"} {
		if err := validateConnectDataDir(dataDir); err == nil {
			t.Fatalf("validateConnectDataDir(%q) accepted memory-only dispatch state", dataDir)
		}
	}
	if err := validateConnectDataDir(t.TempDir()); err != nil {
		t.Fatalf("validateConnectDataDir(valid): %v", err)
	}
}

func TestDispatchLogPaths(t *testing.T) {
	dataDir := t.TempDir()
	if got, want := cloud.DispatchLogPath(dataDir), filepath.Join(dataDir, "dispatches.jsonl"); got != want {
		t.Fatalf("DispatchLogPath = %q, want %q", got, want)
	}
	// The pre-v0.12 location the daemon adopts on first boot without a
	// current log.
	if got, want := cloud.LegacyDispatchLogPath(dataDir), filepath.Join(dataDir, "dedup.jsonl"); got != want {
		t.Fatalf("LegacyDispatchLogPath = %q, want %q", got, want)
	}
}

func TestResolveExternalIDUsesConfiguredIDOrHostname(t *testing.T) {
	tests := []struct {
		name       string
		configured string
		hostname   string
		want       string
		wantErr    bool
	}{
		{name: "hostname default", hostname: "emisar-07qx", want: "emisar-07qx"},
		{
			name:       "configured override",
			configured: "  operator-pinned  ",
			hostname:   "emisar-07qx",
			want:       "operator-pinned",
		},
		{name: "trimmed hostname", hostname: "  emisar-95qv  ", want: "emisar-95qv"},
		{name: "empty hostname", hostname: "  ", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := resolveExternalID(tt.configured, tt.hostname)
			if tt.wantErr {
				if err == nil || got != "" {
					t.Fatalf("resolveExternalID = %q, %v; want empty id and error", got, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("resolveExternalID: %v", err)
			}
			if got != tt.want {
				t.Fatalf("resolveExternalID = %q, want %q", got, tt.want)
			}
		})
	}
}
