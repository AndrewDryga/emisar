package config

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
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
		"enrollment_key_env: EMISAR_ENROLLMENT_KEY",
		"enrollment_key_env: EMISAR_ENROLLMENT_KEY\n  allow_insecure: true", 1)
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
		Cloud:         Cloud{URL: "wss://cloud.example.com/runner", EnrollmentKeyEnv: "EMISAR_ENROLLMENT_KEY"},
		Paths:         Paths{DataDir: "/var/lib/emisar"},
		Events:        Events{JSONLPath: "/tmp/events.jsonl"},
	}
}

func TestValidate_RejectsEnrollmentKeyVarInInheritEnv(t *testing.T) {
	base := validConfig

	// Listing the enrollment-key var in inherit_env would leak the bootstrap secret
	// into every action's environment — must be rejected.
	cfg := base()
	cfg.Execution.InheritEnv = []string{"NOMAD_ADDR", "EMISAR_ENROLLMENT_KEY"}
	if err := cfg.Validate(); err == nil {
		t.Fatal("inherit_env including the enrollment key var must be rejected")
	}

	// The same config without the overlap validates — proving the rejection is
	// the overlap specifically, not some other missing field.
	cfg = base()
	cfg.Execution.InheritEnv = []string{"NOMAD_ADDR"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("config without the overlap should validate, got %v", err)
	}
}

func TestValidate_RejectsLinkerHijackVarsInInheritEnv(t *testing.T) {
	base := validConfig

	// LD_*/DYLD_*/BASH_ENV in inherit_env would let the runner's own process
	// env hijack the dynamic linker or shell init of every action's child —
	// the same vector validateExecutionEnv blocks for pack env. Must be
	// rejected.
	for _, name := range []string{"LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "BASH_ENV"} {
		cfg := base()
		cfg.Execution.InheritEnv = []string{"NOMAD_TOKEN", name}
		if err := cfg.Validate(); err == nil {
			t.Fatalf("inherit_env including %q must be rejected", name)
		}
	}

	// A benign var still validates — proving the rejection is the hijack vector
	// specifically, not inherit_env in general.
	cfg := base()
	cfg.Execution.InheritEnv = []string{"NOMAD_TOKEN"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("config with only a benign inherit_env var should validate, got %v", err)
	}
}

// TestValidate_MaxRisk covers the admission risk ceiling: a valid tier (or
// empty = no ceiling) validates; a bogus tier is rejected so a typo can't
// silently disable the read-only-demo switch.
func TestValidate_MaxRisk(t *testing.T) {
	cfg := validConfig()
	cfg.Admission.MaxRisk = actionspec.RiskMedium
	if err := cfg.Validate(); err != nil {
		t.Fatalf("a valid admission.max_risk should validate, got %v", err)
	}

	cfg = validConfig()
	cfg.Admission.MaxRisk = ""
	if err := cfg.Validate(); err != nil {
		t.Fatalf("an empty admission.max_risk should validate, got %v", err)
	}

	cfg = validConfig()
	cfg.Admission.MaxRisk = actionspec.Risk("bogus")
	if err := cfg.Validate(); err == nil {
		t.Fatal("an invalid admission.max_risk must be rejected")
	}
}

func TestValidate_RejectsNegativeAuditRotationLimits(t *testing.T) {
	for _, tc := range []struct {
		name   string
		events Events
	}{
		{name: "size", events: Events{JSONLPath: "/tmp/events.jsonl", MaxSizeBytes: -1}},
		{name: "backups", events: Events{JSONLPath: "/tmp/events.jsonl", MaxBackups: -1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validConfig()
			cfg.Events = tc.events
			if err := cfg.Validate(); err == nil {
				t.Fatal("negative audit rotation limit must be rejected")
			}
		})
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

func TestValidate_SigningEnforcementRequiresDataDir(t *testing.T) {
	cfg := validConfig()
	cfg.Paths.DataDir = ""
	cfg.Signing = Signing{
		EnforceSignatures: true,
		TrustedCAs: []TrustedCA{{
			CAID:      "acme",
			PublicKey: "1111111111111111111111111111111111111111111111111111111111111111",
		}},
	}
	if err := cfg.Validate(); err == nil {
		t.Fatal("signature enforcement without paths.data_dir must be rejected")
	}
}

// TestValidate_MaxAttestationAgeDefault confirms the 24h default the signing
// validator applies when max_attestation_age is unset (config.go:240-242) —
// the bound that caps replay exposure and defines the journal retention horizon.
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
//	-: unsupported and hostless URLs fail before a transport is opened.
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
		{"unknown scheme rejected", "foo://prod-host", false, true},
		{"empty url rejected", "", false, true},
		{"hostless rejected", "https:///runner", false, true},
		{"credentials rejected", "https://user:secret@cloud.emisar.dev", false, true},
		{"fragment rejected", "https://cloud.emisar.dev/#token", false, true},
		{"https query accepted for signed fetch URL", "https://packs.example/pack.tgz?sig=abc", false, false},
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

func TestValidateCloudTransportSecurityRejectsQuery(t *testing.T) {
	cfg := &Config{Cloud: Cloud{URL: "https://cloud.emisar.dev?token=secret"}}
	if err := cfg.validateCloudTransportSecurity(); err == nil || strings.Contains(err.Error(), "secret") {
		t.Fatalf("query-bearing cloud URL error = %v, want sanitized rejection", err)
	}
}
