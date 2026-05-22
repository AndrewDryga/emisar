package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func writeYAML(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

const minimalConfig = `schema_version: 1
runner:
  group: test-group
cloud:
  url: wss://cloud/runner
  auth_key_env: EMISAR_AUTH_KEY
paths:
  packs:
    - ./packs
events:
  jsonl_path: ./var/log/events.jsonl
`

func TestLoad_AppliesDefaults(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	writeYAML(t, cfgPath, minimalConfig)

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	// Cloud defaults
	if cfg.Cloud.HeartbeatEvery.Std() != 30*time.Second {
		t.Errorf("heartbeat_every default: %s", cfg.Cloud.HeartbeatEvery)
	}
	if cfg.Cloud.ReconnectMin.Std() != time.Second {
		t.Errorf("reconnect_min default: %s", cfg.Cloud.ReconnectMin)
	}
	if cfg.Cloud.ReconnectMax.Std() != 60*time.Second {
		t.Errorf("reconnect_max default: %s", cfg.Cloud.ReconnectMax)
	}
	// Execution defaults
	if cfg.Execution.CancelGrace.Std() != 30*time.Second {
		t.Errorf("cancel_grace default: %s", cfg.Execution.CancelGrace)
	}
	// Events defaults
	if cfg.Events.MaxPreviewBytes != 4096 {
		t.Errorf("max_preview_bytes default: %d", cfg.Events.MaxPreviewBytes)
	}
	if cfg.Events.MaxSizeBytes != 100*1024*1024 {
		t.Errorf("max_size_bytes default: %d", cfg.Events.MaxSizeBytes)
	}
	if cfg.Events.MaxBackups != 5 {
		t.Errorf("max_backups default: %d", cfg.Events.MaxBackups)
	}
	// CursorPath should default to <jsonl_path>.cursor
	if !strings.HasSuffix(cfg.Events.CursorPath, ".jsonl.cursor") {
		t.Errorf("cursor_path default: %s", cfg.Events.CursorPath)
	}
}

func TestLoad_ResolvesRelativePaths(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	writeYAML(t, cfgPath, minimalConfig)

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(cfg.Events.JSONLPath) {
		t.Errorf("JSONLPath should be absolute: %s", cfg.Events.JSONLPath)
	}
	wantPrefix := dir
	if !strings.HasPrefix(cfg.Events.JSONLPath, wantPrefix) {
		t.Errorf("JSONLPath %s should start with config dir %s", cfg.Events.JSONLPath, wantPrefix)
	}
	if !strings.HasPrefix(cfg.Paths.Packs[0], wantPrefix) {
		t.Errorf("packs[0] %s should start with config dir %s", cfg.Paths.Packs[0], wantPrefix)
	}
}

func TestLoad_RejectsMissingGroup(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	writeYAML(t, cfgPath, strings.Replace(minimalConfig, "group: test-group\n", "", 1))

	if _, err := Load(cfgPath); err == nil {
		t.Fatal("expected missing-group to fail")
	}
}

func TestLoad_RejectsMissingAuthKeyEnvWhenCloudSet(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := strings.Replace(minimalConfig, "auth_key_env: EMISAR_AUTH_KEY\n", "", 1)
	writeYAML(t, cfgPath, body)

	if _, err := Load(cfgPath); err == nil {
		t.Fatal("expected missing auth_key_env to fail")
	}
}

func TestLoad_AllowsCloudURLEmpty(t *testing.T) {
	// CLI-only / local-debug mode: no cloud URL is acceptable.
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := strings.Replace(minimalConfig, `cloud:
  url: wss://cloud/runner
  auth_key_env: EMISAR_AUTH_KEY
`, "cloud: {}\n", 1)
	writeYAML(t, cfgPath, body)
	if _, err := Load(cfgPath); err != nil {
		t.Fatalf("cloud URL empty should be allowed: %v", err)
	}
}

func TestLoad_RejectsMissingJSONLPath(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := strings.Replace(minimalConfig, "jsonl_path: ./var/log/events.jsonl\n", "", 1)
	writeYAML(t, cfgPath, body)

	if _, err := Load(cfgPath); err == nil {
		t.Fatal("expected missing jsonl_path to fail")
	}
}

func TestLoad_RedactionRuleValidated(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := minimalConfig + `redaction:
  rules:
    - name: bad
      type: regexp  # typo
      pattern: x
`
	writeYAML(t, cfgPath, body)
	if _, err := Load(cfgPath); err == nil {
		t.Fatal("invalid redaction rule should fail")
	}
}

func TestLoad_PreservesNonDefaultDurations(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := `schema_version: 1
runner:
  group: test-group
cloud:
  url: wss://cloud/runner
  auth_key_env: EMISAR_AUTH_KEY
  heartbeat_every: 5s
  reconnect_min: 100ms
paths:
  packs:
    - ./packs
events:
  jsonl_path: ./var/log/events.jsonl
execution:
  cancel_grace: 2m
`
	writeYAML(t, cfgPath, body)
	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Cloud.HeartbeatEvery != actionspec.Duration(5*time.Second) {
		t.Errorf("heartbeat: %s", cfg.Cloud.HeartbeatEvery)
	}
	if cfg.Cloud.ReconnectMin != actionspec.Duration(100*time.Millisecond) {
		t.Errorf("reconnect_min: %s", cfg.Cloud.ReconnectMin)
	}
	if cfg.Execution.CancelGrace != actionspec.Duration(2*time.Minute) {
		t.Errorf("cancel_grace: %s", cfg.Execution.CancelGrace)
	}
}
