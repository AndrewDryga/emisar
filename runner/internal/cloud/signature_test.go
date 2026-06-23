package cloud

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

// enforcingClient builds a runner client that requires a valid signature from a
// single fixed test key, and returns the matching private key for signing.
func enforcingClient(t *testing.T, dialer Dialer) (*Client, ed25519.PrivateKey) {
	t.Helper()
	seed, _ := hex.DecodeString("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	v, err := signing.NewVerifier(true, []signing.KeyConfig{{KeyID: "k1", PublicKeyHex: hex.EncodeToString(pub)}}, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	cli := buildClient(t, dialer, func(o *Options) {
		o.Verifier = v
		o.StateBuilder.GetVerifier = func() *signing.Verifier { return v }
	})
	return cli, priv
}

func attestationFor(t *testing.T, priv ed25519.PrivateKey, actionID string, args map[string]any) *Attestation {
	t.Helper()
	nonce := "nonce-" + actionID
	issuedAt := time.Now().UTC().Format(time.RFC3339)
	sig, err := attest.Sign(priv, attest.Claim{ActionID: actionID, Args: args, Nonce: nonce, IssuedAt: issuedAt})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	return &Attestation{KeyID: "k1", Signature: sig, Nonce: nonce, IssuedAt: issuedAt}
}

func sendRunActionWithAttestation(t *testing.T, c *fakeConn, requestID, actionID string, args map[string]any, att *Attestation) {
	t.Helper()
	raw, err := json.Marshal(RunActionMsg{
		Envelope:    Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: requestID},
		ActionID:    actionID,
		Args:        args,
		Reason:      "test",
		Attestation: att,
	})
	if err != nil {
		t.Fatal(err)
	}
	c.in <- raw
}

func runEnforcingClient(t *testing.T) (*fakeConn, ed25519.PrivateKey) {
	t.Helper()
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli, priv := enforcingClient(t, d)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })
	return conn, priv
}

// An enforcing runner runs a validly-signed dispatch normally.
func TestClient_SignatureGate_PassesWhenSigned(t *testing.T) {
	conn, priv := runEnforcingClient(t)
	args := map[string]any{"msg": "ok"}
	att := attestationFor(t, priv, "t.echo", args)

	sendRunActionWithAttestation(t, conn, "req_signed", "t.echo", args, att)
	res := waitForResult(t, conn, "req_signed", 3*time.Second)
	if res["status"] != "success" {
		t.Fatalf("status=%v reason=%v error=%v", res["status"], res["reason"], res["error"])
	}
}

// An enforcing runner refuses an unsigned dispatch — the cloud (which can't
// forge a signature) cannot originate a run on this host.
func TestClient_SignatureGate_RefusesUnsigned(t *testing.T) {
	conn, _ := runEnforcingClient(t)

	sendRunAction(t, conn, "req_unsigned", "t.echo", map[string]any{"msg": "ok"})
	res := waitForResult(t, conn, "req_unsigned", 3*time.Second)
	if res["status"] != "signature_invalid" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}
	if res["reason"] != "signature_required" {
		t.Fatalf("reason=%v, want signature_required", res["reason"])
	}
}

// A signature is bound to the args: a dispatch whose args were altered after
// signing (a tampering control plane) is refused.
func TestClient_SignatureGate_RefusesTamperedArgs(t *testing.T) {
	conn, priv := runEnforcingClient(t)
	// Signed for {"msg":"ok"} but dispatched with {"msg":"evil"}.
	att := attestationFor(t, priv, "t.echo", map[string]any{"msg": "ok"})

	sendRunActionWithAttestation(t, conn, "req_tampered", "t.echo", map[string]any{"msg": "evil"}, att)
	res := waitForResult(t, conn, "req_tampered", 3*time.Second)
	if res["status"] != "signature_invalid" {
		t.Fatalf("status=%v reason=%v", res["status"], res["reason"])
	}
	if res["reason"] != "bad_signature" {
		t.Fatalf("reason=%v, want bad_signature", res["reason"])
	}
}

// SetVerifier swaps the gate live: a key dropped from the rebuilt verifier — an
// operator revoking it in config + SIGHUP — stops verifying immediately, with no
// reconnect. This is the security point of live key rotation/revocation.
func TestClient_SetVerifier_RevokesKeyLive(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli, priv := enforcingClient(t, d) // trusts k1

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// A k1-signed dispatch runs while k1 is trusted.
	args := map[string]any{"msg": "ok"}
	sendRunActionWithAttestation(t, conn, "req_before", "t.echo", args, attestationFor(t, priv, "t.echo", args))
	if res := waitForResult(t, conn, "req_before", 3*time.Second); res["status"] != "success" {
		t.Fatalf("pre-revoke status=%v, want success", res["status"])
	}

	// Operator rotates config to a different key and SIGHUPs; the rebuilt
	// verifier no longer trusts k1.
	seed2, _ := hex.DecodeString("2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40")
	pub2 := ed25519.NewKeyFromSeed(seed2).Public().(ed25519.PublicKey)
	v2, err := signing.NewVerifier(true, []signing.KeyConfig{{KeyID: "k2", PublicKeyHex: hex.EncodeToString(pub2)}}, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	cli.SetVerifier(v2)

	// The same validly-k1-signed dispatch shape is now refused — k1 is unknown
	// to the swapped-in verifier.
	sendRunActionWithAttestation(t, conn, "req_after", "t.echo", args, attestationFor(t, priv, "t.echo", args))
	if res := waitForResult(t, conn, "req_after", 3*time.Second); res["status"] != "signature_invalid" {
		t.Fatalf("post-revoke status=%v, want signature_invalid", res["status"])
	}
}

// closes RSEC-001-T20
//
// The other half of a live key rotation: after SetVerifier swaps in a verifier
// trusting a NEW key, a dispatch signed by that new key is ACCEPTED — rotation
// isn't just revoking the old key, it's bringing the new one online without a
// restart. And the Verifier() getter returns the swapped instance, which is how
// the StateBuilder re-advertises the new key id set on the next Build() (the
// readvertise after SIGHUP). TestClient_SetVerifier_RevokesKeyLive proves the
// old key stops working; this proves the new key starts working and the swap is
// observable through the getter the advertisement reads.
func TestClient_SetVerifier_NewKeyAcceptedAndGetterReflectsSwap(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli, priv1 := enforcingClient(t, d) // initially trusts k1 (priv1)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Build the rotated-in verifier: trusts ONLY k2 (a different keypair).
	seed2, _ := hex.DecodeString("2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40")
	priv2 := ed25519.NewKeyFromSeed(seed2)
	pub2 := priv2.Public().(ed25519.PublicKey)
	v2, err := signing.NewVerifier(true, []signing.KeyConfig{{KeyID: "k2", PublicKeyHex: hex.EncodeToString(pub2)}}, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	// Sanity: before the swap the getter reflects the original (k1) keyring.
	if got := cli.Verifier().KeyIDs(); len(got) != 1 || got[0] != "k1" {
		t.Fatalf("pre-swap getter KeyIDs=%v, want [k1]", got)
	}

	cli.SetVerifier(v2)

	// The getter now returns the swapped verifier — the StateBuilder reads this
	// to advertise the live key set after a SIGHUP, so the swap must be visible
	// here, not just inside the gate.
	if cli.Verifier() != v2 {
		t.Fatal("Verifier() must return the swapped-in verifier")
	}
	if got := cli.Verifier().KeyIDs(); len(got) != 1 || got[0] != "k2" {
		t.Fatalf("post-swap getter KeyIDs=%v, want [k2] (advertisement would be stale otherwise)", got)
	}

	// A dispatch signed with the NEW key (k2) is accepted by the swapped-in
	// verifier — rotation brought the new key online live.
	args := map[string]any{"msg": "ok"}
	sendRunActionWithAttestation(t, conn, "req_newkey", "t.echo", args, attestationForKey(t, priv2, "k2", "t.echo", args))
	if res := waitForResult(t, conn, "req_newkey", 3*time.Second); res["status"] != "success" {
		t.Fatalf("a dispatch signed by the rotated-in key must pass; status=%v reason=%v error=%v",
			res["status"], res["reason"], res["error"])
	}

	// And the OLD key (k1) is now rejected by the same swapped verifier — both
	// directions of the rotation hold simultaneously.
	sendRunActionWithAttestation(t, conn, "req_oldkey", "t.echo", args, attestationFor(t, priv1, "t.echo", args))
	if res := waitForResult(t, conn, "req_oldkey", 3*time.Second); res["status"] != "signature_invalid" {
		t.Fatalf("the rotated-out key must be refused; status=%v", res["status"])
	}
}

// attestationForKey is attestationFor with an explicit key id, so a test can
// sign under a key id other than the fixed "k1" the bare helper uses.
func attestationForKey(t *testing.T, priv ed25519.PrivateKey, keyID, actionID string, args map[string]any) *Attestation {
	t.Helper()
	nonce := "nonce-" + keyID + "-" + actionID
	issuedAt := time.Now().UTC().Format(time.RFC3339)
	sig, err := attest.Sign(priv, attest.Claim{ActionID: actionID, Args: args, Nonce: nonce, IssuedAt: issuedAt})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	return &Attestation{KeyID: keyID, Signature: sig, Nonce: nonce, IssuedAt: issuedAt}
}
