package config

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestValidateCloudTransportSecurity covers the cleartext-credential guard:
// https/wss always pass; http/ws pass only to a loopback host or with an
// explicit allow_insecure opt-in; http/ws to any other host is refused.
func TestValidateCloudTransportSecurity(t *testing.T) {
	cases := []struct {
		name          string
		url           string
		allowInsecure bool
		wantErr       bool
	}{
		{"https non-loopback ok", "https://cloud.emisar.dev/runner", false, false},
		{"wss non-loopback ok", "wss://cloud.emisar.dev/runner", false, false},
		{"http loopback ip ok", "http://127.0.0.1:4000", false, false},
		{"http localhost ok", "http://localhost:4000", false, false},
		{"http localhost uppercase ok", "http://LOCALHOST:4000", false, false},
		{"ws ipv6 loopback ok", "ws://[::1]:4000", false, false},
		{"http non-loopback blocked", "http://cloud.example.com", false, true},
		{"ws private-ip blocked", "ws://10.0.0.5:4000", false, true},
		{"http docker-internal blocked", "http://host.docker.internal:4000", false, true},
		{"http non-loopback with opt-in ok", "http://host.docker.internal:4000", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := &Config{Cloud: Cloud{URL: c.url, AllowInsecure: c.allowInsecure}}
			err := cfg.validateCloudTransportSecurity()
			if c.wantErr && err == nil {
				t.Fatalf("expected error for %q (allow_insecure=%v)", c.url, c.allowInsecure)
			}
			if !c.wantErr && err != nil {
				t.Fatalf("unexpected error for %q (allow_insecure=%v): %v", c.url, c.allowInsecure, err)
			}
		})
	}
}

// TestLoad_RejectsPlaintextNonLoopbackCloudURL proves the guard is wired
// into the real Load → Validate path, and that allow_insecure overrides it.
func TestLoad_RejectsPlaintextNonLoopbackCloudURL(t *testing.T) {
	insecure := strings.Replace(minimalConfig, "wss://cloud/runner", "http://cloud.example.com", 1)

	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.yaml")
	writeYAML(t, bad, insecure)
	if _, err := Load(bad); err == nil {
		t.Fatal("expected Load to reject cleartext http:// to a non-loopback host")
	}

	// Same URL, but the operator explicitly opted in.
	optedIn := strings.Replace(insecure,
		"auth_key_env: EMISAR_AUTH_KEY",
		"auth_key_env: EMISAR_AUTH_KEY\n  allow_insecure: true", 1)
	ok := filepath.Join(dir, "ok.yaml")
	writeYAML(t, ok, optedIn)
	if _, err := Load(ok); err != nil {
		t.Fatalf("allow_insecure: true should permit the cleartext URL, got %v", err)
	}
}

func TestValidate_RejectsAuthKeyVarInInheritEnv(t *testing.T) {
	base := func() *Config {
		return &Config{
			SchemaVersion: SchemaVersion,
			Runner:        Runner{Group: "g"},
			Cloud:         Cloud{URL: "wss://cloud.example.com/runner", AuthKeyEnv: "EMISAR_AUTH_KEY"},
			Events:        Events{JSONLPath: "/tmp/events.jsonl"},
		}
	}

	// Listing the auth-key var in inherit_env would leak the bootstrap secret
	// into every action's environment — must be rejected.
	cfg := base()
	cfg.Execution.InheritEnv = []string{"NOMAD_ADDR", "EMISAR_AUTH_KEY"}
	if err := cfg.Validate(); err == nil {
		t.Fatal("inherit_env including the auth key var must be rejected")
	}

	// The same config without the overlap validates — proving the rejection is
	// the overlap specifically, not some other missing field.
	cfg = base()
	cfg.Execution.InheritEnv = []string{"NOMAD_ADDR"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("config without the overlap should validate, got %v", err)
	}
}
