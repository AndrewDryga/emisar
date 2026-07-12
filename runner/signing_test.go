package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/config"
)

func TestGenerateEd25519(t *testing.T) {
	id, pubHex, seedHex, err := generateEd25519("ca-prod", "ca-")
	if err != nil {
		t.Fatalf("generateEd25519: %v", err)
	}
	if id != "ca-prod" {
		t.Fatalf("id = %q", id)
	}
	seed, err := hex.DecodeString(seedHex)
	if err != nil || len(seed) != ed25519.SeedSize {
		t.Fatalf("bad seed hex: %v len=%d", err, len(seed))
	}
	pub, err := hex.DecodeString(pubHex)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("bad public hex: %v len=%d", err, len(pub))
	}
	if hex.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)) != pubHex {
		t.Fatal("public key does not match the seed")
	}
}

func TestGenerateEd25519DefaultIDAndRandomness(t *testing.T) {
	id, _, seed1, _ := generateEd25519("", "op-")
	if !strings.HasPrefix(id, "op-") || id != "op-"+seed1[:8] {
		t.Fatalf("default id %q should be op-<first 8 of seed>", id)
	}
	_, _, seed2, _ := generateEd25519("", "op-")
	if seed1 == seed2 {
		t.Fatal("two key generations must produce different seeds")
	}
}

func TestParseScope(t *testing.T) {
	cases := []struct {
		in    string
		group string
		labs  map[string]string
		err   bool
	}{
		{"", "", nil, false},
		{"group=edge", "edge", nil, false},
		{"group=edge,env=prod", "edge", map[string]string{"env": "prod"}, false},
		{"env=prod,region=us", "", map[string]string{"env": "prod", "region": "us"}, false},
		{"  group = edge , env = prod ", "edge", map[string]string{"env": "prod"}, false},
		{"noequals", "", nil, true},
		{"key=", "", nil, true},
		{"=value", "", nil, true},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			scope, err := parseScope(c.in)
			if c.err {
				if err == nil {
					t.Fatalf("parseScope(%q) should error", c.in)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseScope(%q): %v", c.in, err)
			}
			if scope.Group != c.group {
				t.Errorf("group = %q, want %q", scope.Group, c.group)
			}
			if len(scope.Labels) != len(c.labs) {
				t.Errorf("labels = %v, want %v", scope.Labels, c.labs)
			}
			for k, v := range c.labs {
				if scope.Labels[k] != v {
					t.Errorf("label %q = %q, want %q", k, scope.Labels[k], v)
				}
			}
		})
	}
}

func TestParseTTL(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
		err  bool
	}{
		{"24h", 24 * time.Hour, false},
		{"90m", 90 * time.Minute, false},
		{"30d", 30 * 24 * time.Hour, false},
		{"1y", 365 * 24 * time.Hour, false},
		{"", 0, true},
		{"0s", 0, true},
		{"-1h", 0, true},
		{"bogus", 0, true},
		{"0d", 0, true},
	}
	for _, c := range cases {
		t.Run(c.in, func(t *testing.T) {
			got, err := parseTTL(c.in)
			if c.err {
				if err == nil {
					t.Fatalf("parseTTL(%q) should error", c.in)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseTTL(%q): %v", c.in, err)
			}
			if got != c.want {
				t.Fatalf("parseTTL(%q) = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestMintCertVerifiesUnderCA(t *testing.T) {
	_, _, caSeed, _ := generateEd25519("ca", "ca-")
	caPriv, err := parseCASeed(caSeed)
	if err != nil {
		t.Fatalf("parseCASeed: %v", err)
	}
	caPub := caPriv.Public().(ed25519.PublicKey)
	_, leafPub, _, _ := generateEd25519("op", "op-")

	cert, err := mintCert(caPriv, "ca-x", "op-y", leafPub, attest.Scope{Group: "edge"}, time.Hour)
	if err != nil {
		t.Fatalf("mintCert: %v", err)
	}
	if cert.CAID != "ca-x" || cert.KeyID != "op-y" || cert.PublicKey != leafPub {
		t.Fatalf("cert fields wrong: %+v", cert)
	}
	if cert.Serial == "" || cert.Sig == "" {
		t.Fatal("cert must carry a serial and signature")
	}
	// valid_until is ttl after valid_from.
	from, _ := time.Parse(time.RFC3339, cert.ValidFrom)
	until, _ := time.Parse(time.RFC3339, cert.ValidUntil)
	if until.Sub(from) != time.Hour {
		t.Fatalf("validity window = %v, want 1h", until.Sub(from))
	}
	ok, err := attest.VerifyCert(caPub, cert)
	if err != nil || !ok {
		t.Fatalf("minted cert must verify under the CA: ok=%v err=%v", ok, err)
	}
}

func TestSigningNewCACmd_JSONShape(t *testing.T) {
	withJSONOut(t, true)
	cmd := signingNewCACmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-id", "ca-ci"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-ca --json: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing new-ca --json must emit a JSON object, got %q: %v", out, err)
	}
	if got["ca_id"] != "ca-ci" {
		t.Errorf("ca_id = %q, want ca-ci", got["ca_id"])
	}
	if pub, err := hex.DecodeString(got["public_key"]); err != nil || len(pub) != ed25519.PublicKeySize {
		t.Errorf("public_key not a %d-byte hex key", ed25519.PublicKeySize)
	}
	if seed, err := hex.DecodeString(got["private_key"]); err != nil || len(seed) != ed25519.SeedSize {
		t.Errorf("private_key not a %d-byte hex seed", ed25519.SeedSize)
	}
}

func TestSigningNewCACmd_HumanOutput(t *testing.T) {
	withJSONOut(t, false)
	cmd := signingNewCACmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-id", "ca-prod"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-ca: %v", runErr)
	}
	for _, want := range []string{"enforce_signatures: true", "trusted_cas:", "ca_id: ca-prod", "OFFLINE", "emisar signing new-cert"} {
		if !strings.Contains(out, want) {
			t.Errorf("signing new-ca guide missing %q\n--- output ---\n%s", want, out)
		}
	}
}

// signing new-cert mints a leaf + a cert; the printed EMISAR_SIGNING_CERT must
// parse and verify under the CA, vouching for the printed EMISAR_SIGNING_KEY's
// public key.
func TestSigningNewCertCmd_MintsVerifiableCert(t *testing.T) {
	withJSONOut(t, true)
	_, caPubHex, caSeed, _ := generateEd25519("ca-x", "ca-")

	cmd := signingNewCertCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-id", "ca-x", "--ca-key", caSeed, "--key-id", "op-z", "--scope", "group=edge,env=prod", "--ttl", "12h"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-cert: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing new-cert --json must emit a JSON object, got %q: %v", out, err)
	}

	var cert attest.Cert
	if err := json.Unmarshal([]byte(got["cert"]), &cert); err != nil {
		t.Fatalf("the cert value must be valid JSON: %v", err)
	}
	if cert.CAID != "ca-x" || cert.KeyID != "op-z" {
		t.Fatalf("cert fields: %+v", cert)
	}
	if cert.Scope.Group != "edge" || cert.Scope.Labels["env"] != "prod" {
		t.Fatalf("scope not carried: %+v", cert.Scope)
	}
	// The leaf private key printed must correspond to the cert's public key.
	leafSeed, err := hex.DecodeString(got["private_key"])
	if err != nil {
		t.Fatalf("private_key hex: %v", err)
	}
	leafPub := hex.EncodeToString(ed25519.NewKeyFromSeed(leafSeed).Public().(ed25519.PublicKey))
	if cert.PublicKey != leafPub {
		t.Fatal("the printed leaf key does not match the cert's public_key")
	}
	// And the cert verifies under the CA we minted it with.
	caPub, _ := hex.DecodeString(caPubHex)
	if ok, err := attest.VerifyCert(ed25519.PublicKey(caPub), cert); err != nil || !ok {
		t.Fatalf("cert must verify under its CA: ok=%v err=%v", ok, err)
	}
}

// signing new-cert with --ca-key set but missing --ca-id errors (the cert's
// ca_id must match the runner's trusted_cas).
func TestSigningNewCertCmd_RequiresCAID(t *testing.T) {
	withJSONOut(t, true)
	_, _, caSeed, _ := generateEd25519("ca-x", "ca-")
	cmd := signingNewCertCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-key", caSeed})
	if err := cmd.Execute(); err == nil {
		t.Fatal("signing new-cert without --ca-id must error")
	}
}

// signing init's emitted `signing:` block is a VALID enforcing config: the
// trusted_cas it prints loads through config.go validateSigning (where
// enforce-with-no-CAs is rejected), proving the quickstart → runner handoff
// round-trips, not just looks plausible.
func TestSigningInitCmd_OutputIsValidEnforcingConfig(t *testing.T) {
	withJSONOut(t, true)
	cmd := signingInitCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-id", "ca-quick", "--scope", "group=edge"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing init: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing init --json must emit a JSON object: %v", err)
	}

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	yaml := "schema_version: 1\n" +
		"runner:\n  group: edge\n" +
		"paths:\n  packs:\n    - " + filepath.Join(dir, "packs") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n" +
		"signing:\n" +
		"  enforce_signatures: true\n" +
		"  trusted_cas:\n" +
		"    - ca_id: " + got["ca_id"] + "\n" +
		"      public_key: " + got["ca_public_key"] + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("the signing block signing init prints must load as a valid config: %v", err)
	}
	if !cfg.Signing.EnforceSignatures {
		t.Fatal("enforce_signatures should be on")
	}
	if len(cfg.Signing.TrustedCAs) != 1 || cfg.Signing.TrustedCAs[0].PublicKey != got["ca_public_key"] {
		t.Fatalf("trusted CA not loaded from the emitted block: %+v", cfg.Signing.TrustedCAs)
	}

	// The minted cert in the same output verifies under that CA.
	var cert attest.Cert
	if err := json.Unmarshal([]byte(got["cert"]), &cert); err != nil {
		t.Fatalf("cert JSON: %v", err)
	}
	caPub, _ := hex.DecodeString(got["ca_public_key"])
	if ok, err := attest.VerifyCert(ed25519.PublicKey(caPub), cert); err != nil || !ok {
		t.Fatalf("the quickstart cert must verify under the quickstart CA: ok=%v err=%v", ok, err)
	}
}
