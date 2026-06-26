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

const (
	sigTestCAID     = "ca1"
	sigTestCASeed   = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	sigTestLeafSeed = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
)

func keyFromSeed(t *testing.T, seedHex string) (ed25519.PrivateKey, string) {
	t.Helper()
	seed, err := hex.DecodeString(seedHex)
	if err != nil {
		t.Fatalf("decode seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	return priv, hex.EncodeToString(priv.Public().(ed25519.PublicKey))
}

// sigCert mints a wide-window, any-scope cert signed by caPriv vouching for
// leafPubHex — the verifier trusts the CA, so the leaf signature is what binds
// each dispatch.
func sigCert(t *testing.T, caPriv ed25519.PrivateKey, caID, leafPubHex string) attest.Cert {
	t.Helper()
	cert := attest.Cert{
		CAID: caID, KeyID: "op", PublicKey: leafPubHex,
		ValidFrom: "2026-01-01T00:00:00Z", ValidUntil: "2030-01-01T00:00:00Z",
		Serial: "01SIGTESTCERT00000000000000",
	}
	sig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	cert.Sig = sig
	return cert
}

// enforcingClient builds a runner client that requires a valid signed cert from a
// single fixed test CA, and returns the matching leaf private key for signing.
func enforcingClient(t *testing.T, dialer Dialer) (*Client, ed25519.PrivateKey) {
	t.Helper()
	_, caPubHex := keyFromSeed(t, sigTestCASeed)
	v, err := signing.NewVerifier(true, []signing.CAConfig{{CAID: sigTestCAID, PublicKeyHex: caPubHex}}, time.Hour, "", nil, "")
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	cli := buildClient(t, dialer, func(o *Options) {
		o.Verifier = v
		o.StateBuilder.GetVerifier = func() *signing.Verifier { return v }
	})
	leafPriv, _ := keyFromSeed(t, sigTestLeafSeed)
	return cli, leafPriv
}

// attestationFor signs a dispatch with the fixed test leaf key and attaches a
// cert from the fixed test CA the enforcingClient trusts.
func attestationFor(t *testing.T, priv ed25519.PrivateKey, actionID string, args map[string]any) *Attestation {
	t.Helper()
	caPriv, _ := keyFromSeed(t, sigTestCASeed)
	_, leafPubHex := keyFromSeed(t, sigTestLeafSeed)
	return attestationCertifiedBy(t, priv, caPriv, sigTestCAID, leafPubHex, "nonce-"+actionID, actionID, args)
}

// attestationCertifiedBy signs the dispatch with priv and attaches a cert that
// caPriv vouches for leafPubHex under — so a test can mint a dispatch certified
// by a specific CA (e.g. one the runner was just rotated to trust).
func attestationCertifiedBy(t *testing.T, priv, caPriv ed25519.PrivateKey, caID, leafPubHex, nonce, actionID string, args map[string]any) *Attestation {
	t.Helper()
	issuedAt := time.Now().UTC().Format(time.RFC3339)
	sig, err := attest.Sign(priv, attest.Claim{ActionID: actionID, Args: args, Nonce: nonce, IssuedAt: issuedAt})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	cert := sigCert(t, caPriv, caID, leafPubHex)
	return &Attestation{Signature: sig, Nonce: nonce, IssuedAt: issuedAt, Cert: &cert}
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

// An enforcing runner runs a validly-signed-and-certified dispatch normally.
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

// SetVerifier swaps the gate live: rotating the trusted CA in config + SIGHUP
// stops verifying certs from the old CA immediately, with no reconnect. This is
// the security point of live CA rotation/revocation.
func TestClient_SetVerifier_RevokesCALive(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli, priv := enforcingClient(t, d) // trusts ca1

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// A ca1-certified dispatch runs while ca1 is trusted.
	args := map[string]any{"msg": "ok"}
	sendRunActionWithAttestation(t, conn, "req_before", "t.echo", args, attestationFor(t, priv, "t.echo", args))
	if res := waitForResult(t, conn, "req_before", 3*time.Second); res["status"] != "success" {
		t.Fatalf("pre-revoke status=%v, want success", res["status"])
	}

	// Operator rotates config to a different CA and SIGHUPs; the rebuilt verifier
	// no longer trusts ca1.
	seed2, _ := hex.DecodeString("3132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f50")
	pub2 := ed25519.NewKeyFromSeed(seed2).Public().(ed25519.PublicKey)
	v2, err := signing.NewVerifier(true, []signing.CAConfig{{CAID: "ca2", PublicKeyHex: hex.EncodeToString(pub2)}}, time.Hour, "", nil, "")
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	cli.SetVerifier(v2)

	// The same validly-ca1-certified dispatch shape is now refused — ca1 is
	// unknown to the swapped-in verifier.
	sendRunActionWithAttestation(t, conn, "req_after", "t.echo", args, attestationFor(t, priv, "t.echo", args))
	if res := waitForResult(t, conn, "req_after", 3*time.Second); res["status"] != "signature_invalid" {
		t.Fatalf("post-revoke status=%v, want signature_invalid", res["status"])
	}
}

// The other half of a live CA rotation: after SetVerifier swaps in a verifier
// trusting a NEW CA, a dispatch certified by that new CA is ACCEPTED — rotation
// isn't just revoking the old CA, it's bringing the new one online without a
// restart. And the Verifier() getter returns the swapped instance, which is how
// the StateBuilder re-advertises the new CA id set on the next Build().
func TestClient_SetVerifier_NewCAAcceptedAndGetterReflectsSwap(t *testing.T) {
	conn := newFakeConn()
	d := &queuedDialer{conns: []*fakeConn{conn}}
	cli, priv := enforcingClient(t, d) // initially trusts ca1

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- cli.Run(ctx) }()
	t.Cleanup(func() { cancel(); <-done })

	// Build the rotated-in verifier: trusts ONLY ca2 (a different CA keypair).
	ca2Priv, ca2PubHex := keyFromSeed(t, "3132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f50")
	v2, err := signing.NewVerifier(true, []signing.CAConfig{{CAID: "ca2", PublicKeyHex: ca2PubHex}}, time.Hour, "", nil, "")
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	// Sanity: before the swap the getter reflects the original (ca1) keyring.
	if got := cli.Verifier().CAIDs(); len(got) != 1 || got[0] != "ca1" {
		t.Fatalf("pre-swap getter CAIDs=%v, want [ca1]", got)
	}

	cli.SetVerifier(v2)

	// The getter now returns the swapped verifier — the StateBuilder reads this to
	// advertise the live CA set after a SIGHUP, so the swap must be visible here.
	if cli.Verifier() != v2 {
		t.Fatal("Verifier() must return the swapped-in verifier")
	}
	if got := cli.Verifier().CAIDs(); len(got) != 1 || got[0] != "ca2" {
		t.Fatalf("post-swap getter CAIDs=%v, want [ca2] (advertisement would be stale otherwise)", got)
	}

	// A dispatch certified by the NEW CA (ca2) is accepted by the swapped-in
	// verifier — rotation brought the new CA online live. The same leaf key signs;
	// only the certifying CA changed.
	args := map[string]any{"msg": "ok"}
	_, leafPubHex := keyFromSeed(t, sigTestLeafSeed)
	newAtt := attestationCertifiedBy(t, priv, ca2Priv, "ca2", leafPubHex, "nonce-ca2", "t.echo", args)
	sendRunActionWithAttestation(t, conn, "req_newca", "t.echo", args, newAtt)
	if res := waitForResult(t, conn, "req_newca", 3*time.Second); res["status"] != "success" {
		t.Fatalf("a dispatch certified by the rotated-in CA must pass; status=%v reason=%v error=%v",
			res["status"], res["reason"], res["error"])
	}

	// And a dispatch certified by the OLD CA (ca1) is now rejected by the same
	// swapped verifier — both directions of the rotation hold simultaneously.
	sendRunActionWithAttestation(t, conn, "req_oldca", "t.echo", args, attestationFor(t, priv, "t.echo", args))
	if res := waitForResult(t, conn, "req_oldca", 3*time.Second); res["status"] != "signature_invalid" {
		t.Fatalf("the rotated-out CA must be refused; status=%v", res["status"])
	}
}
