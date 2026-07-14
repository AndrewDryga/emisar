package signing

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/runnerref"
)

const (
	fixedNow      = "2026-06-17T12:00:00Z"
	testCAID      = "ca-test"
	testCASeedHex = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	testLeafSeed  = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	testRunnerID  = "runner-test-1"
	testOrigin    = "https://emisar.test"
	testPackRef   = "test@1.0.0/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testGroup     = "test-grp"
)

func testLabels() map[string]string { return map[string]string{"env": "test"} }

func mustParse(t *testing.T, s string) time.Time {
	t.Helper()
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return ts
}

// testCA returns the CA config (for NewVerifier) and the CA private key certs
// are signed with.
func testCA(t *testing.T) ([]CAConfig, ed25519.PrivateKey) {
	t.Helper()
	seed, _ := hex.DecodeString(testCASeedHex)
	caPriv := ed25519.NewKeyFromSeed(seed)
	caPub := caPriv.Public().(ed25519.PublicKey)
	return []CAConfig{{CAID: testCAID, PublicKeyHex: hex.EncodeToString(caPub)}}, caPriv
}

// testLeaf returns the leaf private key and its hex public key the certs vouch for.
func testLeaf(t *testing.T) (ed25519.PrivateKey, string) {
	t.Helper()
	seed, _ := hex.DecodeString(testLeafSeed)
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	return priv, hex.EncodeToString(pub)
}

// certWith mints a CA-signed cert for the test leaf over the given scope and
// RFC3339 validity window.
func certWith(t *testing.T, caPriv ed25519.PrivateKey, scope attest.Scope, validFrom, validUntil string) attest.Cert {
	t.Helper()
	_, leafPub := testLeaf(t)
	cert := attest.Cert{
		CAID: testCAID, KeyID: "op-test", PublicKey: leafPub,
		ValidFrom: validFrom, ValidUntil: validUntil, Scope: scope, Serial: "01TESTCERT0000000000000000",
	}
	sig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	cert.Sig = sig
	return cert
}

// validCert is a wide-window, any-scope cert for the happy paths — valid at both
// fixedNow and the real clock the persistence tests use, so only the freshness
// and replay gates (not the cert window) drive those tests.
func validCert(t *testing.T) attest.Cert {
	t.Helper()
	_, caPriv := testCA(t)
	return certWith(t, caPriv, attest.Scope{}, "2026-01-01T00:00:00Z", "2030-01-01T00:00:00Z")
}

// newTestVerifier returns an enforcing verifier (clock pinned to fixedNow) that
// trusts the test CA and whose local group/labels satisfy validCert's scope, plus
// the leaf private key callers sign attestations with.
func newTestVerifier(t *testing.T) (*Verifier, ed25519.PrivateKey) {
	t.Helper()
	cas, _ := testCA(t)
	v, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	v.now = func() time.Time { return mustParse(t, fixedNow) }
	leafPriv, _ := testLeaf(t)
	return v, leafPriv
}

// sign produces a valid attestation — the leaf signature plus the wide-window,
// any-scope valid cert — for the given dispatch at issuedAt.
func sign(t *testing.T, priv ed25519.PrivateKey, actionID string, args map[string]any, nonce, issuedAt string) *Attestation {
	t.Helper()
	return signForTargets(t, priv, actionID, args, []string{testRunnerRef(t)}, nonce, issuedAt)
}

func signForTargets(t *testing.T, priv ed25519.PrivateKey, actionID string, args map[string]any, runnerRefs []string, nonce, issuedAt string) *Attestation {
	t.Helper()
	nonce = testNonce(nonce)
	dispatch := testDispatch(t, actionID, args)
	cert := validCert(t)
	return signedAttestation(t, priv, dispatch, runnerRefs, nonce, issuedAt, cert)
}

func signedAttestation(t testing.TB, priv ed25519.PrivateKey, dispatch Dispatch, runnerRefs []string, nonce, issuedAt string, cert attest.Cert) *Attestation {
	t.Helper()
	runnerRefs, err := attest.CanonicalRunnerRefs(runnerRefs)
	if err != nil {
		t.Fatalf("CanonicalRunnerRefs: %v", err)
	}
	claim := attest.Claim{
		ActionID: dispatch.ActionID, PackRef: dispatch.PackRef, ArgsRaw: dispatch.ArgsRaw,
		RunnerRefs: runnerRefs, Reason: dispatch.Reason, OperationID: dispatch.OperationID,
		PortalOrigin: testOrigin, Nonce: nonce, IssuedAt: issuedAt,
	}
	sig, err := attest.Sign(priv, claim)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	argsDigest, err := attest.ArgsSHA256(dispatch.ArgsRaw)
	if err != nil {
		t.Fatalf("ArgsSHA256: %v", err)
	}
	return &Attestation{
		Version: attest.Version, Tool: attest.Tool, PortalOrigin: testOrigin,
		ActionID: dispatch.ActionID, PackRef: dispatch.PackRef, ArgsSHA256: argsDigest,
		RunnerRefs: runnerRefs, Reason: dispatch.Reason, OperationID: dispatch.OperationID,
		Signature: sig, Nonce: nonce, IssuedAt: issuedAt, Cert: &cert,
	}
}

func testRunnerRef(t testing.TB) string {
	t.Helper()
	ref, err := runnerref.Build("runner-test", testRunnerID)
	if err != nil {
		t.Fatalf("runnerref.Build: %v", err)
	}
	return ref
}

func testDispatch(t testing.TB, actionID string, args map[string]any) Dispatch {
	t.Helper()
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	if string(raw) == "null" {
		raw = []byte(`{}`)
	}
	return Dispatch{
		ActionID: actionID, PackRef: testPackRef, ArgsRaw: raw,
		Reason: "test dispatch", OperationID: "op-test",
	}
}

func testNonce(label string) string {
	if label == "" {
		return ""
	}
	digest := sha256.Sum256([]byte(label))
	return hex.EncodeToString(digest[:16])
}

func TestNewVerifierRejectsBadKeys(t *testing.T) {
	nonces := NewMemoryNonceStore()
	if _, err := NewVerifier(true, []CAConfig{{CAID: "c", PublicKeyHex: "zz"}}, time.Hour, testRunnerID, testOrigin, "", nil, nonces); err == nil {
		t.Fatal("expected error for non-hex public key")
	}
	if _, err := NewVerifier(true, []CAConfig{{CAID: "c", PublicKeyHex: "00"}}, time.Hour, testRunnerID, testOrigin, "", nil, nonces); err == nil {
		t.Fatal("expected error for wrong-length public key")
	}
	if _, err := NewVerifier(true, nil, time.Hour, testRunnerID, testOrigin, "", nil, nonces); err == nil {
		t.Fatal("expected error for enforcement with no CAs")
	}
	if _, err := NewVerifier(false, nil, time.Hour, "", "", "", nil, nonces); err != nil {
		t.Fatalf("non-enforcing verifier with no CAs should be fine: %v", err)
	}
	cas, _ := testCA(t)
	if _, err := NewVerifier(true, cas, time.Hour, "", testOrigin, "", nil, nonces); err == nil {
		t.Fatal("expected error for enforcement with no durable runner id")
	}
	if _, err := NewVerifier(true, cas, time.Hour, testRunnerID, "", "", nil, nonces); err == nil {
		t.Fatal("expected error for enforcement with no portal origin")
	}
	if _, err := NewVerifier(false, nil, time.Hour, "", "", "", nil, nil); err == nil {
		t.Fatal("expected error for a missing nonce store")
	}
}

func TestVerifierCAIDsSortedAndMaxAge(t *testing.T) {
	seed1, _ := hex.DecodeString("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	seed2, _ := hex.DecodeString("2102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	pub1 := ed25519.NewKeyFromSeed(seed1).Public().(ed25519.PublicKey)
	pub2 := ed25519.NewKeyFromSeed(seed2).Public().(ed25519.PublicKey)

	// Config order is c2, c1; CAIDs() must come back sorted for a stable advertisement.
	v, err := NewVerifier(true, []CAConfig{
		{CAID: "c2", PublicKeyHex: hex.EncodeToString(pub2)},
		{CAID: "c1", PublicKeyHex: hex.EncodeToString(pub1)},
	}, 2*time.Hour, testRunnerID, testOrigin, "", nil, NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}

	if ids := v.CAIDs(); len(ids) != 2 || ids[0] != "c1" || ids[1] != "c2" {
		t.Fatalf("CAIDs not sorted: %v", ids)
	}
	if v.MaxAge() != 2*time.Hour {
		t.Fatalf("MaxAge = %v, want 2h", v.MaxAge())
	}
}

func TestCheckEnforcementOffAlwaysAllows(t *testing.T) {
	v, err := NewVerifier(false, nil, time.Hour, "", "", "", nil, NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	if d := v.Check(testDispatch(t, "a.b", map[string]any{"x": 1}), nil); !d.Allowed {
		t.Fatalf("non-enforcing runner must allow an unsigned dispatch, got %+v", d)
	}
}

func TestCheckHappyPath(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"container": "web", "force": true}
	att := sign(t, priv, "docker.restart", args, "n1", fixedNow)
	if d := v.Check(testDispatch(t, "docker.restart", args), att); !d.Allowed {
		t.Fatalf("valid signed dispatch refused: %+v", d)
	}
}

func TestCheckBindsRelayedEnvelopeToDeliveredIntent(t *testing.T) {
	args := map[string]any{"container": "web"}
	tests := []struct {
		name   string
		code   string
		mutate func(*Attestation)
	}{
		{"tool", "attestation_tool", func(att *Attestation) { att.Tool = "create_runbook" }},
		{"portal origin", "portal_mismatch", func(att *Attestation) { att.PortalOrigin = "https://evil.example" }},
		{"action", "intent_mismatch", func(att *Attestation) { att.ActionID = "docker.stop" }},
		{"pack", "intent_mismatch", func(att *Attestation) {
			att.PackRef = "other@1.0.0/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
		}},
		{"argument digest", "intent_mismatch", func(att *Attestation) { att.ArgsSHA256 = strings.Repeat("0", 64) }},
		{"reason", "intent_mismatch", func(att *Attestation) { att.Reason = "different reason" }},
		{"operation", "intent_mismatch", func(att *Attestation) { att.OperationID = "op-other" }},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			v, priv := newTestVerifier(t)
			att := sign(t, priv, "docker.restart", args, "bind-"+test.name, fixedNow)
			test.mutate(att)
			if d := v.Check(testDispatch(t, "docker.restart", args), att); d.Allowed || d.Code != test.code {
				t.Fatalf("tampered %s decision = %+v, want %s", test.name, d, test.code)
			}
		})
	}
}

func TestCheckBindsExactTargetSet(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"container": "web"}

	t.Run("local runner in fanout", func(t *testing.T) {
		peerRef, err := runnerref.Build("runner-peer", "runner-peer-id")
		if err != nil {
			t.Fatalf("runnerref.Build: %v", err)
		}
		att := signForTargets(t, priv, "docker.restart", args, []string{peerRef, testRunnerRef(t)}, "fanout", fixedNow)
		if d := v.Check(testDispatch(t, "docker.restart", args), att); !d.Allowed {
			t.Fatalf("signed fanout containing this runner was refused: %+v", d)
		}
	})

	t.Run("local runner absent", func(t *testing.T) {
		peerRef, err := runnerref.Build("runner-peer", "runner-peer-id")
		if err != nil {
			t.Fatalf("runnerref.Build: %v", err)
		}
		att := signForTargets(t, priv, "docker.restart", args, []string{peerRef}, "redirect", fixedNow)
		if d := v.Check(testDispatch(t, "docker.restart", args), att); d.Allowed || d.Code != "target_mismatch" {
			t.Fatalf("dispatch redirected outside its signed targets must be refused, got %+v", d)
		}
	})

	t.Run("targets changed after signing", func(t *testing.T) {
		att := signForTargets(t, priv, "docker.restart", args, []string{testRunnerRef(t)}, "tampered", fixedNow)
		att.RunnerRefs = append(att.RunnerRefs, "zz-injected~00000000000000000000000000000000")
		if d := v.Check(testDispatch(t, "docker.restart", args), att); d.Allowed || d.Code != "bad_signature" {
			t.Fatalf("target-set tampering must invalidate the signature, got %+v", d)
		}
	})

	t.Run("noncanonical target order", func(t *testing.T) {
		peerRef, err := runnerref.Build("a-peer", "runner-peer-id")
		if err != nil {
			t.Fatalf("runnerref.Build: %v", err)
		}
		att := signForTargets(t, priv, "docker.restart", args, []string{peerRef, testRunnerRef(t)}, "reordered", fixedNow)
		att.RunnerRefs[0], att.RunnerRefs[1] = att.RunnerRefs[1], att.RunnerRefs[0]
		if d := v.Check(testDispatch(t, "docker.restart", args), att); d.Allowed || d.Code != "target_mismatch" {
			t.Fatalf("noncanonical target order must be refused, got %+v", d)
		}
	})

	t.Run("wrong version", func(t *testing.T) {
		att := sign(t, priv, "docker.restart", args, "version", fixedNow)
		att.Version = "emisar-attestation-v1"
		if d := v.Check(testDispatch(t, "docker.restart", args), att); d.Allowed || d.Code != "attestation_version" {
			t.Fatalf("unsupported attestation version must be refused, got %+v", d)
		}
	})
}

func TestCheckRefusals(t *testing.T) {
	args := map[string]any{"container": "web"}

	tests := []struct {
		name string
		att  func(t *testing.T, priv ed25519.PrivateKey) *Attestation
		code string
	}{
		{"missing attestation", func(*testing.T, ed25519.PrivateKey) *Attestation { return nil }, "signature_required"},
		{"empty nonce", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "", fixedNow)
		}, "bad_nonce"},
		{"uppercase nonce", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "valid", fixedNow)
			a.Nonce = "0123456789ABCDEF0123456789ABCDEF"
			return a
		}, "bad_nonce"},
		{"non-hex nonce", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "valid", fixedNow)
			a.Nonce = "gggggggggggggggggggggggggggggggg"
			return a
		}, "bad_nonce"},
		{"bad issued_at", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "n1", "not-a-time")
			a.IssuedAt = "not-a-time"
			return a
		}, "bad_issued_at"},
		{"stale (past)", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "n1", "2026-06-17T10:00:00Z")
		}, "stale"},
		{"stale (future skew)", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "n1", "2026-06-17T14:00:00Z")
		}, "stale"},
		{"malformed signature", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "n1", fixedNow)
			a.Signature = "not-hex!!"
			return a
		}, "bad_signature"},
		{"signature over different args", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			// Signed for {container: db} but dispatched with {container: web}.
			return sign(t, priv, "docker.restart", map[string]any{"container": "db"}, "n1", fixedNow)
		}, "intent_mismatch"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			v, priv := newTestVerifier(t)
			d := v.Check(testDispatch(t, "docker.restart", args), tc.att(t, priv))
			if d.Allowed {
				t.Fatalf("expected refusal, got allowed")
			}
			if d.Code != tc.code {
				t.Fatalf("code = %q, want %q (detail: %s)", d.Code, tc.code, d.Detail)
			}
		})
	}
}

// the CA trust gates: an untrusted/forged CA, an out-of-window cert, and a scope
// the runner does not satisfy are each refused with their own code — and BEFORE
// the leaf-signature check, so a perfectly-valid leaf signature can't slip a bad
// cert past. The runner's local identity (group/labels) is the ONLY scope input.
func TestCheckCertRefusals(t *testing.T) {
	args := map[string]any{"x": float64(1)}
	const action = "a.b"
	leafPriv, leafPub := testLeaf(t)
	_, caPriv := testCA(t)
	otherCAPriv := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize)) // a CA the runner does NOT trust

	// signedAtt carries a VALID leaf signature + the given cert, so any refusal is
	// from the cert gates (which run before the leaf check).
	signedAtt := func(cert attest.Cert) *Attestation {
		nonce := testNonce("cert-refusal")
		return signedAttestation(t, leafPriv, testDispatch(t, action, args), []string{testRunnerRef(t)}, nonce, fixedNow, cert)
	}
	mkCert := func(caP ed25519.PrivateKey, caID string, scope attest.Scope, from, until string) attest.Cert {
		cert := attest.Cert{CAID: caID, KeyID: "op", PublicKey: leafPub, ValidFrom: from, ValidUntil: until, Scope: scope, Serial: "01CERTREFUSE000000000000000"}
		sig, err := attest.SignCert(caP, cert)
		if err != nil {
			t.Fatalf("SignCert: %v", err)
		}
		cert.Sig = sig
		return cert
	}
	const wf, wu = "2026-01-01T00:00:00Z", "2030-01-01T00:00:00Z"

	tests := []struct {
		name string
		att  *Attestation
		code string
	}{
		{"missing cert", &Attestation{Signature: "00", Nonce: "n", IssuedAt: fixedNow, Cert: nil}, "signature_required"},
		{"unknown ca_id", signedAtt(mkCert(caPriv, "ca-nope", attest.Scope{}, wf, wu)), "cert_untrusted"},
		{"forged CA signature", signedAtt(mkCert(otherCAPriv, testCAID, attest.Scope{}, wf, wu)), "cert_untrusted"},
		{"cert expired (past)", signedAtt(mkCert(caPriv, testCAID, attest.Scope{}, "2020-01-01T00:00:00Z", "2020-06-01T00:00:00Z")), "cert_expired"},
		{"cert not yet valid (future)", signedAtt(mkCert(caPriv, testCAID, attest.Scope{}, "2030-01-01T00:00:00Z", "2031-01-01T00:00:00Z")), "cert_expired"},
		{"cert valid_from not RFC3339", signedAtt(mkCert(caPriv, testCAID, attest.Scope{}, "nope", wu)), "cert_expired"},
		{"scope group mismatch", signedAtt(mkCert(caPriv, testCAID, attest.Scope{Group: "other-grp"}, wf, wu)), "cert_scope"},
		{"scope label mismatch", signedAtt(mkCert(caPriv, testCAID, attest.Scope{Labels: map[string]string{"env": "prod"}}, wf, wu)), "cert_scope"},
		{"scope label missing on runner", signedAtt(mkCert(caPriv, testCAID, attest.Scope{Labels: map[string]string{"region": "us"}}, wf, wu)), "cert_scope"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			v, _ := newTestVerifier(t) // group=test-grp, labels={env:test}
			d := v.Check(testDispatch(t, action, args), tc.att)
			if d.Allowed {
				t.Fatalf("expected refusal, got allowed")
			}
			if d.Code != tc.code {
				t.Fatalf("code = %q, want %q (detail: %s)", d.Code, tc.code, d.Detail)
			}
		})
	}
}

// a cert scoped to exactly this runner's group + a label subset is allowed —
// the positive side of the scope matcher.
func TestCheckCertScopeMatchAllowed(t *testing.T) {
	v, leafPriv := newTestVerifier(t)
	_, caPriv := testCA(t)
	args := map[string]any{"x": float64(1)}
	cert := certWith(t, caPriv, attest.Scope{Group: testGroup, Labels: map[string]string{"env": "test"}}, "2026-01-01T00:00:00Z", "2030-01-01T00:00:00Z")
	nonce := testNonce("scoped")
	att := signedAttestation(t, leafPriv, testDispatch(t, "a.b", args), []string{testRunnerRef(t)}, nonce, fixedNow, cert)
	if d := v.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("a cert scoped to this runner's group+labels must be allowed: %+v", d)
	}
}

// the leaf public key comes from the CA-verified cert: an attestation signed by
// a key OTHER than the one the cert vouches for is bad_signature — a stolen cert
// can't be paired with an attacker's own leaf key.
func TestCheckLeafKeyMustMatchCert(t *testing.T) {
	v, _ := newTestVerifier(t)
	_, caPriv := testCA(t)
	args := map[string]any{"x": float64(1)}

	// The cert vouches for a DIFFERENT leaf than the one that signs the attestation.
	otherLeaf := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize))
	otherPub := hex.EncodeToString(otherLeaf.Public().(ed25519.PublicKey))
	cert := attest.Cert{CAID: testCAID, KeyID: "op", PublicKey: otherPub, ValidFrom: "2026-01-01T00:00:00Z", ValidUntil: "2030-01-01T00:00:00Z", Serial: "01MISMATCH00000000000000000"}
	csig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	cert.Sig = csig

	testLeafPriv, _ := testLeaf(t)
	nonce := testNonce("mismatch")
	att := signedAttestation(t, testLeafPriv, testDispatch(t, "a.b", args), []string{testRunnerRef(t)}, nonce, fixedNow, cert)
	if d := v.Check(testDispatch(t, "a.b", args), att); d.Allowed || d.Code != "bad_signature" {
		t.Fatalf("a leaf signature not matching cert.public_key must be bad_signature, got %+v", d)
	}
}

func TestCheckReplayRefused(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}
	att := sign(t, priv, "a.b", args, "once", fixedNow)

	if d := v.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("first use must pass: %+v", d)
	}
	d := v.Check(testDispatch(t, "a.b", args), att)
	if d.Allowed || d.Code != "replayed" {
		t.Fatalf("replay must be refused as 'replayed', got %+v", d)
	}
}

func TestRefusalDoesNotBurnNonce(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}

	// A tampered dispatch (signature over different args) is refused...
	bad := sign(t, priv, "a.b", map[string]any{"x": float64(2)}, "n1", fixedNow)
	if d := v.Check(testDispatch(t, "a.b", args), bad); d.Allowed {
		t.Fatal("tampered dispatch should be refused")
	}
	// ...and must not have consumed nonce "n1": a later legitimate dispatch
	// that happens to reuse it still works.
	good := sign(t, priv, "a.b", args, "n1", fixedNow)
	if d := v.Check(testDispatch(t, "a.b", args), good); !d.Allowed {
		t.Fatalf("a refused dispatch must not burn its nonce: %+v", d)
	}
}

func TestNoncePruning(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{}

	// Consume a nonce at the fixed now.
	att := sign(t, priv, "a.b", args, "old", fixedNow)
	if d := v.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("first use must pass: %+v", d)
	}

	// Advance the clock past the window and consume a fresh nonce — the prune
	// pass should evict "old", keeping the cache bounded.
	later := mustParse(t, fixedNow).Add(2 * time.Hour)
	v.now = func() time.Time { return later }
	fresh := sign(t, priv, "a.b", args, "new", later.Format(time.RFC3339))
	if d := v.Check(testDispatch(t, "a.b", args), fresh); !d.Allowed {
		t.Fatalf("fresh nonce at the new time must pass: %+v", d)
	}

	v.nonces.mu.Lock()
	_, oldStillThere := v.nonces.seen["old"]
	size := len(v.nonces.seen)
	v.nonces.mu.Unlock()
	if oldStillThere {
		t.Fatal("expired nonce was not pruned")
	}
	if size != 1 {
		t.Fatalf("nonce cache size = %d, want 1 (only the fresh nonce)", size)
	}
}

// a non-positive freshness window is a misconfiguration —
// the constructor refuses it rather than booting a verifier that accepts
// nothing (age > 0 always fails) or everything.
func TestNewVerifierRejectsNonPositiveMaxAge(t *testing.T) {
	cas, _ := testCA(t)

	for _, maxAge := range []time.Duration{0, -time.Second, -time.Hour} {
		t.Run(maxAge.String(), func(t *testing.T) {
			if _, err := NewVerifier(true, cas, maxAge, testRunnerID, testOrigin, "", nil, NewMemoryNonceStore()); err == nil {
				t.Fatalf("maxAge %v must be rejected", maxAge)
			}
		})
	}
}

// freshness is inclusive at the edge (`age > maxAge`, not
// `>=`), so an attestation issued exactly maxAge ago — and exactly maxAge in the
// future — is still accepted, symmetric about now.
func TestCheckIssuedAtAtWindowEdgeAccepted(t *testing.T) {
	args := map[string]any{"x": float64(1)}
	now := mustParse(t, fixedNow)

	edges := map[string]string{
		"exactly -maxAge (past edge)":   now.Add(-time.Hour).Format(time.RFC3339),
		"exactly +maxAge (future edge)": now.Add(time.Hour).Format(time.RFC3339),
	}
	for name, issuedAt := range edges {
		t.Run(name, func(t *testing.T) {
			v, priv := newTestVerifier(t) // maxAge == time.Hour
			att := sign(t, priv, "a.b", args, "edge", issuedAt)
			if d := v.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
				t.Fatalf("attestation at the exact window edge must be accepted, got %+v", d)
			}
		})
	}
}

// the signature covers the EXACT issued_at string the
// signer sent; the parse is only for the freshness comparison. Re-displaying the
// same instant in a different RFC3339 form (here, an explicit +00:00 offset
// instead of Z) without re-signing breaks verification — you cannot massage the
// timestamp's presentation past the signature.
func TestCheckTimestampReformattedWithoutResigningRefused(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}

	// Sign over the canonical "Z" form, then present the same instant as
	// "+00:00". time.Parse accepts both (so freshness still passes), but the
	// signed bytes used "Z", so the signature no longer matches.
	att := sign(t, priv, "a.b", args, "n1", fixedNow)
	att.IssuedAt = "2026-06-17T12:00:00+00:00"

	// .Equal compares instants regardless of the zone form ("Z" vs "+00:00"),
	// confirming freshness still passes — so the only thing left to reject the
	// dispatch is the signature over the differing raw string.
	if !mustParse(t, att.IssuedAt).Equal(mustParse(t, fixedNow)) {
		t.Fatal("test setup: the two forms must denote the same instant")
	}
	d := v.Check(testDispatch(t, "a.b", args), att)
	if d.Allowed || d.Code != "bad_signature" {
		t.Fatalf("reformatted-but-not-resigned timestamp must fail as bad_signature, got %+v", d)
	}
}

// the nonce cache is mutex-guarded, so firing the same
// valid attestation from many goroutines admits it exactly once; every other
// caller is refused "replayed". Run under -race, this also asserts the cache has
// no data race.
func TestCheckConcurrentReplayExactlyOneWins(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}
	att := sign(t, priv, "a.b", args, "race", fixedNow)

	const goroutines = 32
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		allowed int
		replays int
	)
	start := make(chan struct{})
	for i := 0; i < goroutines; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			d := v.Check(testDispatch(t, "a.b", args), att)
			mu.Lock()
			defer mu.Unlock()
			switch {
			case d.Allowed:
				allowed++
			case d.Code == "replayed":
				replays++
			default:
				t.Errorf("unexpected refusal: %+v", d)
			}
		}()
	}
	close(start)
	wg.Wait()

	if allowed != 1 {
		t.Fatalf("exactly one dispatch must win, got %d allowed", allowed)
	}
	if replays != goroutines-1 {
		t.Fatalf("the other %d must be 'replayed', got %d", goroutines-1, replays)
	}
}

// a nonce string becomes reusable only once its recorded
// issued_at has aged past the window (so the prune pass evicts it) — AND the new
// presentation must carry an issued_at that itself passes freshness. The
// practical replay window is therefore bounded by maxAge, never the nonce
// string's lifetime.
func TestCheckSameNonceReusableOnlyAfterIssuedAtAgesOut(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{}
	now := mustParse(t, fixedNow)

	// Consume nonce N at T0.
	first := sign(t, priv, "a.b", args, "reuse", fixedNow)
	if d := v.Check(testDispatch(t, "a.b", args), first); !d.Allowed {
		t.Fatalf("first use must pass: %+v", d)
	}

	// Still inside the window: re-presenting N with the same issued_at is a
	// replay even though the clock advanced a little.
	v.now = func() time.Time { return now.Add(30 * time.Minute) }
	if d := v.Check(testDispatch(t, "a.b", args), first); d.Allowed || d.Code != "replayed" {
		t.Fatalf("re-presenting the nonce in-window must be 'replayed', got %+v", d)
	}

	// Move the clock past the window and present N again with a NEW, in-window
	// issued_at: the old entry is pruned and the new freshness check passes, so
	// the same nonce string is accepted again.
	later := now.Add(2 * time.Hour)
	v.now = func() time.Time { return later }
	reused := sign(t, priv, "a.b", args, "reuse", later.Format(time.RFC3339))
	if d := v.Check(testDispatch(t, "a.b", args), reused); !d.Allowed {
		t.Fatalf("a pruned nonce with a fresh issued_at must be accepted: %+v", d)
	}
}

// the replay cache is process-local (an
// in-memory map, no external store), so a runner restart clears it. A fresh
// verifier with the same keys will re-allow a nonce it never saw — but only if
// that nonce's issued_at is still inside the freshness window. Once it ages out,
// the freshness gate is the sole post-restart protection and refuses it. This
// documents the accepted replay-across-restart limitation and its bound.
func TestCheckReplayAcrossRestartBoundedByFreshness(t *testing.T) {
	args := map[string]any{"x": float64(1)}

	// First "process": consume nonce N at fixedNow.
	v1, priv := newTestVerifier(t)
	att := sign(t, priv, "a.b", args, "survivor", fixedNow)
	if d := v1.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("first process must accept: %+v", d)
	}
	if d := v1.Check(testDispatch(t, "a.b", args), att); d.Allowed {
		t.Fatal("same process must refuse the replay")
	}

	// "Restart": a brand-new verifier with the same key and an empty cache.
	// Within the freshness window, the nonce is accepted once more (the
	// limitation).
	v2, _ := newTestVerifier(t)
	if d := v2.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("a fresh verifier (restart) re-allows an in-window nonce: %+v", d)
	}

	// Restart again, but now the same attestation is outside the window: the
	// freshness gate refuses it, bounding the cross-restart replay to ±maxAge.
	v3, _ := newTestVerifier(t)
	v3.now = func() time.Time { return mustParse(t, fixedNow).Add(2 * time.Hour) }
	if d := v3.Check(testDispatch(t, "a.b", args), att); d.Allowed || d.Code != "stale" {
		t.Fatalf("post-restart, an aged-out nonce must be refused 'stale', got %+v", d)
	}
}

// pruning runs on every consume, so over a window the cache
// is bounded by the number of distinct in-window nonces, not by the total ever
// seen. Drive many distinct nonces while advancing the clock past the window and
// assert the cache never accumulates the aged-out ones.
func TestNonceCacheBoundedByWindow(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{}
	base := mustParse(t, fixedNow)

	// 200 dispatches, one every minute. maxAge is 1h, so at any consume at most
	// ~60 prior nonces are still in-window.
	const dispatches = 200
	for i := 0; i < dispatches; i++ {
		at := base.Add(time.Duration(i) * time.Minute)
		v.now = func() time.Time { return at }
		nonce := fmt.Sprintf("n%d", i)
		att := sign(t, priv, "a.b", args, nonce, at.Format(time.RFC3339))
		if d := v.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
			t.Fatalf("dispatch %d must pass: %+v", i, d)
		}
		v.nonces.mu.Lock()
		size := len(v.nonces.seen)
		v.nonces.mu.Unlock()
		// 1h / 1min = 60 entries within the window, plus the one just inserted.
		if size > 62 {
			t.Fatalf("after %d dispatches the cache holds %d entries; pruning is not bounding it", i+1, size)
		}
	}
}

// the cache key is the raw nonce string — no normalization.
// Two nonces differing only by case or surrounding whitespace are distinct
// entries, so neither replays the other.
func TestNonceCacheKeyIsRawString(t *testing.T) {
	args := map[string]any{"x": float64(1)}

	variants := []struct{ a, b string }{
		{"abc", "ABC"},  // case
		{"abc", " abc"}, // leading whitespace
		{"abc", "abc "}, // trailing whitespace
		{"a\tb", "a b"}, // tab vs space
	}
	for _, vv := range variants {
		t.Run(vv.a+" vs "+vv.b, func(t *testing.T) {
			v, priv := newTestVerifier(t)
			a := sign(t, priv, "a.b", args, vv.a, fixedNow)
			b := sign(t, priv, "a.b", args, vv.b, fixedNow)
			if d := v.Check(testDispatch(t, "a.b", args), a); !d.Allowed {
				t.Fatalf("first nonce must pass: %+v", d)
			}
			if d := v.Check(testDispatch(t, "a.b", args), b); !d.Allowed {
				t.Fatalf("a nonce differing only by case/whitespace must be distinct, got %+v", d)
			}
		})
	}
}

// the enforcement gate's per-call cost is one Ed25519
// verify plus a bounded prune — no unbounded growth across a window of distinct
// nonces. This is the perf baseline for the dispatch hot path.
func BenchmarkCheck(b *testing.B) {
	caSeed, _ := hex.DecodeString(testCASeedHex)
	caPriv := ed25519.NewKeyFromSeed(caSeed)
	caPub := caPriv.Public().(ed25519.PublicKey)
	leafSeed, _ := hex.DecodeString(testLeafSeed)
	priv := ed25519.NewKeyFromSeed(leafSeed)
	leafPub := hex.EncodeToString(priv.Public().(ed25519.PublicKey))

	v, err := NewVerifier(true, []CAConfig{{CAID: testCAID, PublicKeyHex: hex.EncodeToString(caPub)}}, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), NewMemoryNonceStore())
	if err != nil {
		b.Fatalf("NewVerifier: %v", err)
	}
	// Pin the clock to the vectors' instant so the fixed issued_at stays in-window.
	now, err := time.Parse(time.RFC3339, fixedNow)
	if err != nil {
		b.Fatalf("parse fixedNow: %v", err)
	}
	v.now = func() time.Time { return now }
	args := map[string]any{"container": "web", "force": true}

	// One wide-window, any-scope cert vouching for the leaf, reused every iteration
	// (the per-call cost the benchmark measures is one cert verify + one leaf verify).
	cert := attest.Cert{CAID: testCAID, KeyID: "op-test", PublicKey: leafPub, ValidFrom: "2026-01-01T00:00:00Z", ValidUntil: "2030-01-01T00:00:00Z", Serial: "01BENCH00000000000000000000"}
	csig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		b.Fatalf("SignCert: %v", err)
	}
	cert.Sig = csig

	// Pre-sign distinct-nonce attestations so each iteration is a fresh, valid
	// dispatch (no replay short-circuit, no signing cost in the measured loop).
	atts := make([]*Attestation, b.N)
	for i := range atts {
		nonce := testNonce(fmt.Sprintf("n%d", i))
		atts[i] = signedAttestation(b, priv, testDispatch(b, "docker.restart", args), []string{testRunnerRef(b)}, nonce, fixedNow, cert)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if d := v.Check(testDispatch(b, "docker.restart", args), atts[i]); !d.Allowed {
			b.Fatalf("benchmark dispatch refused: %+v", d)
		}
	}
}

// persistCAs returns the trusted-CA config + the leaf private key both
// persistence tests sign with — the same fixtures as newTestVerifier.
func persistCAs(t *testing.T) ([]CAConfig, ed25519.PrivateKey) {
	t.Helper()
	cas, _ := testCA(t)
	leafPriv, _ := testLeaf(t)
	return cas, leafPriv
}

// TestSharedNonceStoreClosesVerifierReloadWindow constructs the replacement
// verifier, pauses before the caller's atomic pointer swap, and admits a nonce
// through the old verifier. Because both policies reference the same store, the
// replacement refuses the replay without needing another disk snapshot.
func TestSharedNonceStoreClosesVerifierReloadWindow(t *testing.T) {
	cas, priv := persistCAs(t)
	store := NewMemoryNonceStore()
	oldVerifier, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store)
	if err != nil {
		t.Fatalf("NewVerifier old: %v", err)
	}
	newVerifier, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store)
	if err != nil {
		t.Fatalf("NewVerifier replacement: %v", err)
	}

	args := map[string]any{"x": 1}
	att := sign(t, priv, "a.b", args, "nonce-during-reload", time.Now().UTC().Format(time.RFC3339))
	if d := oldVerifier.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("old verifier refused the dispatch in the reload window: %+v", d)
	}
	if d := newVerifier.Check(testDispatch(t, "a.b", args), att); d.Allowed {
		t.Fatal("replacement verifier replayed a nonce consumed before the swap")
	} else if d.Code != "replayed" {
		t.Fatalf("replacement refused with %q, want replayed", d.Code)
	}
}

// TestNonceCachePersistsAcrossRestart proves a new process store reloads a
// still-fresh nonce from disk and refuses its replay.
func TestNonceCachePersistsAcrossRestart(t *testing.T) {
	cas, priv := persistCAs(t)
	storePath := filepath.Join(t.TempDir(), "signing", "nonce-cache.json")
	args := map[string]any{"x": 1}
	// Real-clock issued_at so the nonce stays inside the window across the reload;
	// both verifiers use the real clock, so the load cutoff and freshness agree.
	issuedAt := time.Now().UTC().Format(time.RFC3339)
	att := sign(t, priv, "a.b", args, "nonce-restart", issuedAt)

	store1, err := OpenNonceStore(storePath, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore v1: %v", err)
	}
	v1, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store1)
	if err != nil {
		t.Fatalf("NewVerifier v1: %v", err)
	}
	if d := v1.Check(testDispatch(t, "a.b", args), att); !d.Allowed {
		t.Fatalf("first dispatch refused: %+v", d)
	}
	if err := store1.Close(); err != nil {
		t.Fatalf("Close store v1: %v", err)
	}

	// A new process opens a distinct store object over the same durable file.
	store2, err := OpenNonceStore(storePath, time.Hour)
	if err != nil {
		t.Fatalf("OpenNonceStore v2: %v", err)
	}
	t.Cleanup(func() { _ = store2.Close() })
	v2, err := NewVerifier(true, cas, time.Hour, testRunnerID, testOrigin, testGroup, testLabels(), store2)
	if err != nil {
		t.Fatalf("NewVerifier v2 (restart): %v", err)
	}
	if d := v2.Check(testDispatch(t, "a.b", args), att); d.Allowed {
		t.Fatalf("restart let the in-window nonce replay")
	} else if d.Code != "replayed" {
		t.Fatalf("restart replay refused with %q, want \"replayed\"", d.Code)
	}
}

// TestNonceCacheCorruptStoreFailsClosed: a present-but-corrupt cache must fail
// construction, not silently start enforcing with a replay cache we can't trust.
func TestNonceCacheCorruptStoreFailsClosed(t *testing.T) {
	store := filepath.Join(t.TempDir(), "nonce-cache.json")
	if err := os.WriteFile(store, []byte("{ not valid json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenNonceStore(store, time.Hour); err == nil {
		t.Fatal("a corrupt nonce cache must fail opening (fail closed), got nil error")
	}
}

func TestNonceJournalUnwritableFailsStartupClosed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses the directory write bit this test relies on")
	}
	roDir := t.TempDir()
	if err := os.Chmod(roDir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(roDir, 0o700) }) // let TempDir cleanup remove it
	store := filepath.Join(roDir, "nonce-cache.json")

	if _, err := OpenNonceStore(store, time.Hour); err == nil {
		t.Fatal("an unwritable replay journal must fail startup")
	}
}
