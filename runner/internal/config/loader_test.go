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
  enrollment_key_env: EMISAR_ENROLLMENT_KEY
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
}

func TestLoad_RejectsUnknownFieldsAndTrailingDocuments(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{
			name: "unknown field",
			body: minimalConfig + "cloud_typo: true\n",
		},
		{name: "trailing document", body: minimalConfig + "---\nextra: true\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.yaml")
			writeYAML(t, path, tc.body)
			if _, err := Load(path); err == nil {
				t.Fatalf("Load accepted %s", tc.name)
			}
		})
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

func TestLoad_RejectsMissingEnrollmentKeyEnvWhenCloudSet(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := strings.Replace(minimalConfig, "enrollment_key_env: EMISAR_ENROLLMENT_KEY\n", "", 1)
	writeYAML(t, cfgPath, body)

	if _, err := Load(cfgPath); err == nil {
		t.Fatal("expected missing enrollment_key_env to fail")
	}
}

func TestLoad_AllowsCloudURLEmpty(t *testing.T) {
	// CLI-only / local-debug mode: no cloud URL is acceptable.
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	body := strings.Replace(minimalConfig, `cloud:
  url: wss://cloud/runner
  enrollment_key_env: EMISAR_ENROLLMENT_KEY
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
  enrollment_key_env: EMISAR_ENROLLMENT_KEY
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

// TestLoad_EMISAR_URLOverride covers: $EMISAR_URL overrides
// cloud.url from the file (loader.go:36-40), so the same baked-in config can
// target dev/prod control planes without re-templating. The override lands
// before Validate, so the env value is the one that's transport-checked.
func TestLoad_EMISAR_URLOverride(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	writeYAML(t, cfgPath, minimalConfig) // file says wss://cloud/runner

	const override = "wss://override-host/runner"
	t.Setenv("EMISAR_URL", override)

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.Cloud.URL != override {
		t.Errorf("cloud.url = %q, want the EMISAR_URL override %q", cfg.Cloud.URL, override)
	}
}

// TestLoad_EmptyEMISAR_URLLeavesConfig confirms the override is skipped when
// the env var is empty, so an unset/blank EMISAR_URL never blanks a valid
// configured cloud.url (loader.go:38).
func TestLoad_EmptyEMISAR_URLLeavesConfig(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	writeYAML(t, cfgPath, minimalConfig)

	t.Setenv("EMISAR_URL", "")

	cfg, err := Load(cfgPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.Cloud.URL != "wss://cloud/runner" {
		t.Errorf("cloud.url = %q, want the file value (empty EMISAR_URL must not override)", cfg.Cloud.URL)
	}
}

// TestLoad_MalformedAndUnreadable covers: a parse error on broken
// YAML and a read error on a missing file are both surfaced as wrapped errors
// (loader.go). No defaults are silently applied over a file that can't be read.
func TestLoad_MalformedAndUnreadable(t *testing.T) {
	t.Run("malformed yaml", func(t *testing.T) {
		dir := t.TempDir()
		cfgPath := filepath.Join(dir, "config.yaml")
		// A mapping value that is obviously not valid YAML structure.
		writeYAML(t, cfgPath, "schema_version: 1\nrunner: : : :\n  group: [\n")
		if _, err := Load(cfgPath); err == nil {
			t.Fatal("expected a parse error for malformed YAML")
		}
	})

	t.Run("missing file", func(t *testing.T) {
		dir := t.TempDir()
		cfgPath := filepath.Join(dir, "does-not-exist.yaml")
		if _, err := Load(cfgPath); err == nil {
			t.Fatal("expected a read error for a missing config file")
		}
	})
}
