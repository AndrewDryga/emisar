package config

import (
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// validConfig returns an in-memory config that passes Validate, so a test can
// mutate one field and prove the rejection is that field specifically.
func validConfig() *Config {
	return &Config{
		SchemaVersion: SchemaVersion,
		Runner:        Runner{Group: "g"},
		Cloud:         Cloud{URL: "wss://cloud.example.com/runner", AuthKeyEnv: "EMISAR_AUTH_KEY"},
		Events:        Events{JSONLPath: "/tmp/events.jsonl"},
	}
}

func TestValidate_RejectsAuthKeyVarInInheritEnv(t *testing.T) {
	base := validConfig

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

// TestValidate_Signing covers the client-attested-dispatch config gate
// (config.go validateSigning):
//
//	-: enforce_signatures with no trusted_cas is a footgun (the
//	  runner would refuse EVERY dispatch) and is rejected.
//	-: two trusted CAs sharing a ca_id are rejected.
//	-: a trusted CA missing ca_id or public_key is rejected.
//
// Each case starts from a config that validates and changes only the signing
// block, so a failure pins the rejection to the signing rule under test.
func TestValidate_Signing(t *testing.T) {
	const (
		keyA = "1111111111111111111111111111111111111111111111111111111111111111"
		keyB = "2222222222222222222222222222222222222222222222222222222222222222"
	)
	cases := []struct {
		name    string
		signing Signing
		wantErr bool
	}{
		{
			name:    "enforce with empty trusted_cas rejected",
			signing: Signing{EnforceSignatures: true},
			wantErr: true,
		},
		{
			name: "enforce with a trusted CA ok",
			signing: Signing{
				EnforceSignatures: true,
				TrustedCAs:        []TrustedCA{{CAID: "acme", PublicKey: keyA}},
			},
		},
		{
			// enforce off + no CAs is fine — signing is simply not in force.
			name:    "no enforce no CAs ok",
			signing: Signing{},
		},
		{
			name: "duplicate ca_id rejected",
			signing: Signing{
				TrustedCAs: []TrustedCA{
					{CAID: "dup", PublicKey: keyA},
					{CAID: "dup", PublicKey: keyB},
				},
			},
			wantErr: true,
		},
		{
			// ca_id missing.
			name:    "missing ca_id rejected",
			signing: Signing{TrustedCAs: []TrustedCA{{PublicKey: keyA}}},
			wantErr: true,
		},
		{
			// ca_id present but whitespace-only.
			name:    "blank ca_id rejected",
			signing: Signing{TrustedCAs: []TrustedCA{{CAID: "  ", PublicKey: keyA}}},
			wantErr: true,
		},
		{
			// public_key missing.
			name:    "missing public_key rejected",
			signing: Signing{TrustedCAs: []TrustedCA{{CAID: "acme"}}},
			wantErr: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := validConfig()
			cfg.Signing = c.signing
			err := cfg.Validate()
			if c.wantErr && err == nil {
				t.Fatalf("expected error for signing %+v", c.signing)
			}
			if !c.wantErr && err != nil {
				t.Fatalf("unexpected error for signing %+v: %v", c.signing, err)
			}
		})
	}
}

// TestValidate_MaxAttestationAgeDefault confirms the 24h default the signing
// validator applies when max_attestation_age is unset (config.go:240-242) —
// the bound that caps replay exposure and the nonce cache.
func TestValidate_MaxAttestationAgeDefault(t *testing.T) {
	cfg := validConfig()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	if cfg.Signing.MaxAttestationAge.Std() != 24*time.Hour {
		t.Errorf("max_attestation_age default = %s, want 24h", cfg.Signing.MaxAttestationAge)
	}
}

// TestValidate_RejectsWrongSchemaVersion covers: schema_version
// must equal the supported version (config.go:145-147). Zero (the field unset)
// and any other value are both rejected.
func TestValidate_RejectsWrongSchemaVersion(t *testing.T) {
	for _, v := range []int{0, 2, SchemaVersion + 1} {
		cfg := validConfig()
		cfg.SchemaVersion = v
		if err := cfg.Validate(); err == nil {
			t.Errorf("schema_version %d should be rejected", v)
		}
	}
}

// TestCheckEndpointScheme exercises the shared transport-security gate
// (config.go CheckEndpointScheme) directly — the function reused by both
// cloud.url validation and the pack fetch:
//
//	-: an unknown scheme passes this gate (left for the dialer).
//	-: localhost is matched case-insensitively as loopback.
//
// https/wss, loopback cleartext, and the allow_insecure opt-in are also
// asserted here at the exported-function level (the wrapper is covered by
// TestValidateCloudTransportSecurity).
func TestCheckEndpointScheme(t *testing.T) {
	cases := []struct {
		name          string
		url           string
		allowInsecure bool
		wantErr       bool
	}{
		{"https passes", "https://cloud.emisar.dev/runner", false, false},
		{"wss passes", "wss://cloud.emisar.dev/runner", false, false},
		// schemes other than http/ws are not this gate's concern.
		{"unknown scheme passes", "foo://prod-host", false, false},
		{"empty url passes", "", false, false},
		// any casing of localhost is loopback.
		{"ws LOCALHOST loopback", "ws://LOCALHOST:4000", false, false},
		{"http LocalHost loopback", "http://LocalHost:4000", false, false},
		{"http 127.0.0.1 loopback", "http://127.0.0.1:4000", false, false},
		{"ws ipv6 loopback", "ws://[::1]:4000", false, false},
		// Cleartext to a real host is the thing this gate exists to refuse.
		{"http non-loopback blocked", "http://prod-host", false, true},
		{"ws non-loopback blocked", "ws://10.0.0.5:4000", false, true},
		{"http non-loopback with opt-in", "http://prod-host", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := CheckEndpointScheme(c.url, c.allowInsecure)
			if c.wantErr && err == nil {
				t.Fatalf("expected error for %q (allow_insecure=%v)", c.url, c.allowInsecure)
			}
			if !c.wantErr && err != nil {
				t.Fatalf("unexpected error for %q (allow_insecure=%v): %v", c.url, c.allowInsecure, err)
			}
		})
	}
}
