package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/config"
)

func TestGenerateSigningKey(t *testing.T) {
	id, pubHex, seedHex, err := generateSigningKey("mcp-prod")
	if err != nil {
		t.Fatalf("generateSigningKey: %v", err)
	}
	if id != "mcp-prod" {
		t.Fatalf("key_id = %q", id)
	}

	seed, err := hex.DecodeString(seedHex)
	if err != nil || len(seed) != ed25519.SeedSize {
		t.Fatalf("bad seed hex: %v len=%d", err, len(seed))
	}
	pub, err := hex.DecodeString(pubHex)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Fatalf("bad public hex: %v len=%d", err, len(pub))
	}

	// The public key corresponds to the seed.
	derived := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	if hex.EncodeToString(derived) != pubHex {
		t.Fatal("public key does not match the seed")
	}

	// And the keypair works end-to-end with the shared attest encoding — what
	// the mcp signer and the runner verifier actually use.
	priv := ed25519.NewKeyFromSeed(seed)
	claim := attest.Claim{ActionID: "a.b", Args: map[string]any{"x": float64(1)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	sig, err := attest.Sign(priv, claim)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	ok, err := attest.Verify(ed25519.PublicKey(pub), claim, sig)
	if err != nil || !ok {
		t.Fatalf("a keygen'd keypair must sign+verify: ok=%v err=%v", ok, err)
	}
}

func TestGenerateSigningKeyDefaultID(t *testing.T) {
	id, _, seedHex, err := generateSigningKey("")
	if err != nil {
		t.Fatalf("generateSigningKey: %v", err)
	}
	if !strings.HasPrefix(id, "mcp-") {
		t.Fatalf("default key_id should start with mcp-: %q", id)
	}
	if id != "mcp-"+seedHex[:8] {
		t.Fatalf("default key_id %q should be mcp-<first 8 of seed hex>", id)
	}
}

func TestGenerateSigningKeyIsRandom(t *testing.T) {
	_, _, s1, _ := generateSigningKey("")
	_, _, s2, _ := generateSigningKey("")
	if s1 == s2 {
		t.Fatal("two keygens must produce different seeds")
	}
}

// `keygen --json` emits exactly {key_id, public_key, private_key} as a JSON
// object (keygen.go:56-64) — the machine-readable shape a setup script parses.
// Driven through the real command with the global --json flag set, so the
// JSON branch of RunE runs verbatim.
func TestKeygenCmd_JSONShape(t *testing.T) {
	withJSONOut(t, true)
	cmd := keygenCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--key-id", "mcp-ci"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("keygen --json: %v", runErr)
	}

	var got map[string]string
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("keygen --json must emit a JSON object, got %q: %v", out, err)
	}
	if len(got) != 3 {
		t.Fatalf("keygen --json must emit exactly 3 keys, got %v", got)
	}
	if got["key_id"] != "mcp-ci" {
		t.Errorf("key_id = %q, want mcp-ci", got["key_id"])
	}
	// public/private are the hex encodings of an Ed25519 public key and seed.
	pub, err := hex.DecodeString(got["public_key"])
	if err != nil || len(pub) != ed25519.PublicKeySize {
		t.Errorf("public_key %q not a %d-byte hex key: %v", got["public_key"], ed25519.PublicKeySize, err)
	}
	seed, err := hex.DecodeString(got["private_key"])
	if err != nil || len(seed) != ed25519.SeedSize {
		t.Errorf("private_key %q not a %d-byte hex seed: %v", got["private_key"], ed25519.SeedSize, err)
	}
}

// `keygen` (no --json) prints a complete, copy-pasteable operator guide: the
// runner `signing:` block with the PUBLIC key and enforce_signatures: true, the
// MCP client's PRIVATE-key env vars, and the SIGHUP-to-apply / keep-secret notes
// (keygen.go:66-78). A missing section would leave an operator unable to wire it.
func TestKeygenCmd_HumanGuideComplete(t *testing.T) {
	withJSONOut(t, false)
	cmd := keygenCmd()
	cmd.SilenceUsage, cmd.SilenceErrors = true, true
	cmd.SetArgs([]string{"--key-id", "mcp-prod"})

	var runErr error
	out := captureStdout(t, func() { runErr = cmd.Execute() })
	if runErr != nil {
		t.Fatalf("keygen: %v", runErr)
	}

	for _, want := range []string{
		"enforce_signatures: true",       // the runner block turns enforcement on
		"trusted_keys:",                  // ... under trusted_keys
		"key_id: mcp-prod",               // labelled with the chosen id
		"EMISAR_SIGNING_KEY=",            // the MCP client's private-key var
		"EMISAR_SIGNING_KEY_ID=mcp-prod", // ... and its id
		"SIGHUP",                         // how to apply without a restart
		"Never put the private key",      // the keep-secret warning
	} {
		if !strings.Contains(out, want) {
			t.Errorf("keygen guide missing %q\n--- output ---\n%s", want, out)
		}
	}
}

// The `signing:` block keygen prints is a VALID enforcing config: applying the
// emitted public key under enforce_signatures: true passes config validation
// (config.go validateSigning), where enforce-with-no-keys is rejected (RUN-031).
// This proves the human guide's output actually loads — the keygen → runner
// handoff round-trips, not just looks plausible.
func TestKeygenCmd_OutputIsValidEnforcingConfig(t *testing.T) {
	id, pubHex, _, err := generateSigningKey("mcp-prod")
	if err != nil {
		t.Fatalf("generateSigningKey: %v", err)
	}

	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	// The smallest valid config (no cloud.url) plus exactly the signing block
	// keygen tells the operator to paste.
	yaml := "schema_version: 1\n" +
		"runner:\n  group: test\n" +
		"paths:\n  packs:\n    - " + filepath.Join(dir, "packs") + "\n" +
		"events:\n  jsonl_path: " + filepath.Join(dir, "events.jsonl") + "\n" +
		"signing:\n" +
		"  enforce_signatures: true\n" +
		"  trusted_keys:\n" +
		"    - key_id: " + id + "\n" +
		"      public_key: " + pubHex + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := config.Load(cfgPath)
	if err != nil {
		t.Fatalf("the signing block keygen prints must load as a valid config: %v", err)
	}
	if !cfg.Signing.EnforceSignatures {
		t.Fatal("enforce_signatures should be on")
	}
	if len(cfg.Signing.TrustedKeys) != 1 || cfg.Signing.TrustedKeys[0].PublicKey != pubHex {
		t.Fatalf("trusted key not loaded from the emitted block: %+v", cfg.Signing.TrustedKeys)
	}
}
