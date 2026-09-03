package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

func TestGenerateSigningKey(t *testing.T) {
	for _, alg := range []signingKeyAlg{algEd25519, algP256} {
		key, err := generateSigningKey(alg)
		if err != nil {
			t.Fatalf("generateSigningKey(%s): %v", alg, err)
		}
		encoded, err := encodePrivateKey(key)
		if err != nil {
			t.Fatalf("encodePrivateKey(%s): %v", alg, err)
		}
		// One line, and it round-trips — that is what makes it pasteable into an
		// env var or a secret manager.
		if strings.ContainsAny(encoded, "\n\r") {
			t.Errorf("%s private key is not one line", alg)
		}
		parsed, err := parsePrivateKey(encoded)
		if err != nil {
			t.Fatalf("parsePrivateKey(%s): %v", alg, err)
		}
		if !parsed.Public().(interface{ Equal(crypto.PublicKey) bool }).Equal(key.Public()) {
			t.Errorf("%s key did not round-trip", alg)
		}
	}
	if _, err := generateSigningKey("rsa"); err == nil {
		t.Error("an unaccepted key algorithm must be refused")
	}
}

func TestParsePrivateKeyRejectsUnusableKeys(t *testing.T) {
	if _, err := parsePrivateKey("not base64!"); err == nil {
		t.Error("non-base64 must be refused")
	}
	if _, err := parsePrivateKey(base64.StdEncoding.EncodeToString([]byte("not a key"))); err == nil {
		t.Error("non-PKCS#8 must be refused")
	}
	// An RSA key is well-formed PKCS#8 but is not a dispatch-signing algorithm,
	// so it must fail HERE rather than as an opaque refusal at a runner.
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate RSA key: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(rsaKey)
	if err != nil {
		t.Fatalf("marshal RSA key: %v", err)
	}
	if _, err := parsePrivateKey(base64.StdEncoding.EncodeToString(der)); err == nil {
		t.Error("an RSA leaf key must be refused")
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
		// `2w` is valid in the runner config and in pack action YAML, and was
		// rejected here: two duration parsers that happened to support
		// different units. They share one now, so an operator who learned a
		// spelling in one place can use it in the other.
		{"2w", 14 * 24 * time.Hour, false},
		{"1y", 365 * 24 * time.Hour, false},
		{"", 0, true},
		{"0s", 0, true},
		{"-1h", 0, true},
		{"bogus", 0, true},
		{"0d", 0, true},
		// time.Duration is int64 nanoseconds, so it tops out near 292 years.
		// Past that the multiplication wrapped and minted a cert whose not-after
		// was in the PAST — unusable forever, while reading as long-lived.
		{"292y", 292 * 365 * 24 * time.Hour, false},
		{"293y", 0, true},
		{"100000000y", 0, true},
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

// A minted certificate verifies through the same VerifyChain a runner uses,
// with its scope intact — the CLI and the verifier agree on the profile.
func TestMintedCertificateVerifiesThroughTheRunnerPath(t *testing.T) {
	caKey, err := generateSigningKey(algEd25519)
	if err != nil {
		t.Fatal(err)
	}
	caDER, err := mintCA(caKey, "ca-test", 365*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	leafKey, err := generateSigningKey(algEd25519)
	if err != nil {
		t.Fatal(err)
	}
	scope := attest.Scope{Group: "edge", Labels: map[string]string{"env": "prod"}}
	leafDER, err := mintLeaf(caKey, caCert, leafKey.Public(), "op", scope, 12*time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	leaf, gotScope, err := attest.VerifyChain(roots, [][]byte{leafDER}, time.Now())
	if err != nil {
		t.Fatalf("a minted certificate must verify through VerifyChain: %v", err)
	}
	if gotScope.Group != "edge" || gotScope.Labels["env"] != "prod" {
		t.Fatalf("scope not carried through the certificate: %+v", gotScope)
	}
	// And the certified key signs a claim the same certificate verifies.
	claim := attest.Claim{
		ActionID: "a.b", PackRef: "p@1/sha256:x", ArgsRaw: []byte(`{}`),
		RunnerRefs: []string{"r~1"}, Reason: "test", OperationID: "op_1",
		PortalOrigin: "https://emisar.test", Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z",
	}
	sig, err := attest.SignClaim(leafKey, claim)
	if err != nil {
		t.Fatalf("SignClaim: %v", err)
	}
	if ok, err := attest.VerifyClaim(leaf, claim, sig); err != nil || !ok {
		t.Fatalf("VerifyClaim = %v, %v; want true", ok, err)
	}
}

func TestSigningNewCACmd_JSONShape(t *testing.T) {
	withJSONOut(t, true)
	cmd := signingNewCACmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-name", "ca-ci"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-ca --json: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing new-ca --json must emit a JSON object, got %q: %v", out, err)
	}
	if got["ca_name"] != "ca-ci" {
		t.Errorf("ca_name = %q, want ca-ci", got["ca_name"])
	}
	caCert, err := parseCACertificate(got["ca_certificate"])
	if err != nil {
		t.Fatalf("ca_certificate must be a CA PEM: %v", err)
	}
	if caCert.Subject.CommonName != "ca-ci" {
		t.Errorf("CA common name = %q, want ca-ci", caCert.Subject.CommonName)
	}
	if _, err := parsePrivateKey(got["ca_private_key"]); err != nil {
		t.Errorf("ca_private_key must round-trip: %v", err)
	}
}

func TestSigningNewCACmd_HumanOutput(t *testing.T) {
	withJSONOut(t, false)
	cmd := signingNewCACmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-name", "ca-prod"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-ca: %v", runErr)
	}
	for _, want := range []string{
		"enforce_signatures: true", "trusted_cas:", "name: ca-prod", "pem: |",
		"BEGIN CERTIFICATE", "OFFLINE", "emisar signing new-cert", "--ca-key-file", "--ca-cert",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("signing new-ca guide missing %q\n--- output ---\n%s", want, out)
		}
	}
	// The CA private key is the one secret whose compromise reproduces the exact
	// threat signed dispatch exists to stop. The guide must not teach the argv
	// form that writes it to shell history and /proc/<pid>/cmdline — the operator
	// is following our own printed instruction at the moment the CA is created.
	if strings.Contains(out, "--ca-key ") || strings.Contains(out, "--ca-key=") {
		t.Errorf("signing new-ca guide still teaches the argv key form\n--- output ---\n%s", out)
	}
}

// signing new-cert issues a leaf; the printed EMISAR_SIGNING_CERT must decode,
// verify under the CA, and vouch for the printed EMISAR_SIGNING_KEY's key.
func TestSigningNewCertCmd_MintsVerifiableCert(t *testing.T) {
	withJSONOut(t, true)
	caName, caPEM, caKeyEncoded := runNewCA(t)

	cmd := signingNewCertCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{
		"--ca-key", caKeyEncoded, "--ca-cert", caPEM,
		"--key-name", "op-z", "--scope", "group=edge,env=prod", "--ttl", "12h",
	})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-cert: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing new-cert --json must emit a JSON object, got %q: %v", out, err)
	}

	leafDER := decodeChain(t, got["certificate_chain"])
	caCert, err := parseCACertificate(caPEM)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	leaf, scope, err := attest.VerifyChain(roots, [][]byte{leafDER}, time.Now())
	if err != nil {
		t.Fatalf("the issued certificate must verify under its CA (%s): %v", caName, err)
	}
	if scope.Group != "edge" || scope.Labels["env"] != "prod" {
		t.Fatalf("scope not carried: %+v", scope)
	}
	if leaf.Subject.CommonName != "op-z" {
		t.Errorf("leaf common name = %q, want op-z", leaf.Subject.CommonName)
	}
	// The printed private key must be the one the certificate vouches for.
	leafKey, err := parsePrivateKey(got["private_key"])
	if err != nil {
		t.Fatalf("private_key: %v", err)
	}
	if !leafKey.Public().(interface{ Equal(crypto.PublicKey) bool }).Equal(leaf.PublicKey) {
		t.Fatal("the printed leaf key does not match the certificate's public key")
	}
}

// new-cert needs both halves of the issuer: an X.509 leaf names its issuer
// exactly, so the certificate cannot be reconstructed from a label.
func TestSigningNewCertCmd_RequiresIssuer(t *testing.T) {
	withJSONOut(t, true)
	_, caPEM, caKeyEncoded := runNewCA(t)

	for name, args := range map[string][]string{
		"no --ca-key":  {"--ca-cert", caPEM},
		"no --ca-cert": {"--ca-key", caKeyEncoded},
	} {
		cmd := signingNewCertCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil {
			t.Errorf("%s: signing new-cert must error", name)
		}
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
	cmd.SetArgs([]string{"--ca-name", "ca-quick", "--scope", "group=edge"})

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
	var pemBlock strings.Builder
	for _, line := range strings.Split(strings.TrimRight(got["ca_certificate"], "\n"), "\n") {
		pemBlock.WriteString("        " + line + "\n")
	}
	yaml := "schema_version: 1\n" +
		"runner:\n  group: edge\n" +
		"paths:\n  data_dir: " + filepath.Join(dir, "data") + "\n  packs:\n    - " + filepath.Join(dir, "packs") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n" +
		"signing:\n" +
		"  enforce_signatures: true\n" +
		"  trusted_cas:\n" +
		"    - name: " + got["ca_name"] + "\n" +
		"      pem: |\n" + pemBlock.String()
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
	if len(cfg.Signing.TrustedCAs) != 1 {
		t.Fatalf("trusted CA not loaded from the emitted block: %+v", cfg.Signing.TrustedCAs)
	}

	// The emitted anchor and certificate are one working pair: the verifier the
	// runner would build accepts the certificate from the same output.
	verifier, err := signing.NewVerifier(true, []signing.CAConfig{
		{Name: cfg.Signing.TrustedCAs[0].Name, PEM: cfg.Signing.TrustedCAs[0].PEM},
	}, time.Hour, "runner-1", "https://emisar.test", "edge", nil, signing.NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("the emitted anchor must build a verifier: %v", err)
	}
	if ids := verifier.CAIDs(); len(ids) != 1 || ids[0] != "ca-quick" {
		t.Fatalf("advertised CA labels = %v, want [ca-quick]", ids)
	}
}

// runNewCA runs `signing new-ca --json` and returns its name, PEM, and key.
func runNewCA(t *testing.T) (name, caPEM, caKey string) {
	t.Helper()
	cmd := signingNewCACmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--ca-name", "ca-x"})
	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("signing new-ca: %v", runErr)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("signing new-ca --json: %v", err)
	}
	return got["ca_name"], got["ca_certificate"], got["ca_private_key"]
}

// decodeChain unwraps the one-line EMISAR_SIGNING_CERT value into leaf DER.
func decodeChain(t *testing.T, encoded string) []byte {
	t.Helper()
	pemText, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("certificate chain is not base64: %v", err)
	}
	block, _ := pem.Decode(pemText)
	if block == nil || block.Type != "CERTIFICATE" {
		t.Fatal("certificate chain does not carry a PEM CERTIFICATE block")
	}
	return block.Bytes
}
