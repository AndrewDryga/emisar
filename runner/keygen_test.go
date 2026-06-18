package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/attest"
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
