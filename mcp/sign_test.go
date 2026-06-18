package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"testing"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const testSeedHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"

func testSigner(t *testing.T) (*signer, ed25519.PublicKey) {
	t.Helper()
	s, err := newSigner(testSeedHex, "k1")
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	return s, s.priv.Public().(ed25519.PublicKey)
}

func TestNewSigner(t *testing.T) {
	if s, err := newSigner("", ""); err != nil || s != nil {
		t.Fatalf("no key set should disable signing: signer=%v err=%v", s, err)
	}
	if _, err := newSigner(testSeedHex, ""); err == nil {
		t.Fatal("key without key_id should error")
	}
	if _, err := newSigner("", "k1"); err == nil {
		t.Fatal("key_id without key should error")
	}
	if _, err := newSigner("zz", "k1"); err == nil {
		t.Fatal("non-hex key should error")
	}
	if _, err := newSigner("00", "k1"); err == nil {
		t.Fatal("wrong-length key should error")
	}
	if s, err := newSigner(testSeedHex, "k1"); err != nil || s == nil {
		t.Fatalf("valid key should build a signer: %v", err)
	}
}

func TestSignFrameLeavesNonDispatchAlone(t *testing.T) {
	s, _ := testSigner(t)
	for _, frame := range []string{
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"arguments":{}}}`, // no name
		`not json`,
	} {
		if got := string(s.signFrame([]byte(frame))); got != frame {
			t.Fatalf("frame should be unchanged:\n in:  %s\n out: %s", frame, got)
		}
	}
}

// The whole contract: a frame the bridge signs verifies under the matching
// public key with EXACTLY the reconstruction the runner does — action args
// recovered by dropping the control keys, nonce + issued_at from the
// attestation. If this passes, the signer and the runner's verifier agree.
func TestSignFrameProducesRunnerVerifiableAttestation(t *testing.T) {
	s, pub := testSigner(t)

	frame := `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{` +
		`"name":"docker.restart","arguments":{"container":"web","force":true,` +
		`"runner":"prod-1","reason":"rotate","wait":"0"}}}`

	signed := s.signFrame([]byte(frame))

	var parsed struct {
		ID     json.RawMessage `json:"id"`
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &parsed); err != nil {
		t.Fatalf("signed frame is not valid JSON: %v", err)
	}

	// The envelope id is preserved byte-for-byte (idempotency keys off it).
	if string(parsed.ID) != "7" {
		t.Fatalf("id not preserved: %s", parsed.ID)
	}

	att, ok := parsed.Params.Arguments["attestation"].(map[string]any)
	if !ok {
		t.Fatalf("no attestation attached: %#v", parsed.Params.Arguments)
	}
	if att["key_id"] != "k1" {
		t.Fatalf("key_id = %v", att["key_id"])
	}

	// Reconstruct the action args exactly as the portal/runner do.
	actionArgs := map[string]any{}
	for k, v := range parsed.Params.Arguments {
		actionArgs[k] = v
	}
	for _, k := range reservedArgKeys {
		delete(actionArgs, k)
	}
	// Control keys must not be in the signed args.
	for _, k := range []string{"runner", "reason", "wait", "attestation"} {
		if _, leaked := actionArgs[k]; leaked {
			t.Fatalf("control key %q leaked into signed args", k)
		}
	}

	claim := attest.Claim{
		ActionID: parsed.Params.Name,
		Args:     actionArgs,
		Nonce:    att["nonce"].(string),
		IssuedAt: att["issued_at"].(string),
	}
	valid, err := attest.Verify(pub, claim, att["sig"].(string))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !valid {
		t.Fatal("the bridge's signature did not verify under the runner's reconstruction")
	}
}

// A nil signer (signing disabled) is never invoked; the forward path guards on
// it. This documents that signFrame is only reached when configured.
func TestSignerDisabledIsNil(t *testing.T) {
	s, err := newSigner("", "")
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	if s != nil {
		t.Fatal("expected nil signer when no key configured")
	}
}

func TestNonceIsRandomHex(t *testing.T) {
	a, err := newNonce()
	if err != nil {
		t.Fatalf("newNonce: %v", err)
	}
	b, _ := newNonce()
	if a == b {
		t.Fatal("nonces must differ")
	}
	if _, err := hex.DecodeString(a); err != nil {
		t.Fatalf("nonce not hex: %v", err)
	}
}
