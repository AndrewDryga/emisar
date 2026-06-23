package attest

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

// CROSS-IMPL CONTRACT. These vectors are IDENTICAL in mcp/internal/attest. They
// pin the canonical encoding (SigningBytes) and the deterministic Ed25519
// signature for a fixed key, so the MCP that SIGNS and the runner that VERIFIES
// can never silently diverge: a change to either copy's encoding fails its
// vector test. If you change the encoding, bump Version, regenerate, and update
// BOTH copies in the same change.
const (
	vectorSeedHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	vectorPubHex  = "79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664"
)

func vectorClaims() []struct {
	name  string
	claim Claim
	bytes string
	sig   string
} {
	return []struct {
		name  string
		claim Claim
		bytes string
		sig   string
	}{
		{
			name:  "empty args",
			claim: Claim{ActionID: "linux.uptime", Args: map[string]any{}, Nonce: "nonce-1", IssuedAt: "2026-06-17T12:00:00Z"},
			bytes: "emisar-attestation-v1\nlinux.uptime\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\nnonce-1\n2026-06-17T12:00:00Z",
			sig:   "b47006e2ebb9154f6d31155acc8409d69bb039f2d5432e30341679f24c758ec202442e7e92848033c5f9bdc5fd8032afbf1db85d9c246342dce7d7ff14e4830b",
		},
		{
			name:  "mixed scalar args (sorted keys)",
			claim: Claim{ActionID: "docker.restart", Args: map[string]any{"container": "web", "force": true, "signal": float64(15)}, Nonce: "nonce-2", IssuedAt: "2026-06-17T12:05:00Z"},
			bytes: "emisar-attestation-v1\ndocker.restart\nb8119ee468effeab897d29e97bb44f5d3318b6b5d7dc5308fe5bb7526784a3da\nnonce-2\n2026-06-17T12:05:00Z",
			sig:   "9c871495cf4a45bcf7c242ea0a270e401a3234a86811f581d2108e1c1b0d4796ec722f443d47326378fc8cc11d20c6a547da049ffa9c60cc8f171f45d2d64101",
		},
		{
			name:  "nested map + array (keys sorted, array order kept)",
			claim: Claim{ActionID: "x.y", Args: map[string]any{"names": []any{"b", "a"}, "opts": map[string]any{"z": float64(1), "a": float64(2)}}, Nonce: "n3", IssuedAt: "2026-06-17T12:10:00Z"},
			bytes: "emisar-attestation-v1\nx.y\n492e23689996160b37c27461bafd6e137c129e9eb9650d62250914e2072949b4\nn3\n2026-06-17T12:10:00Z",
			sig:   "2fb6c0cdd53ecc3596232b67e3080d2f2d439471ad6d03e2e8b34cdcbfc8eac1f077229182416d015dfce51c506d245539ffed5854045ec29792b1d9c8b2c002",
		},
	}
}

func vectorKey(t *testing.T) (ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	seed, err := hex.DecodeString(vectorSeedHex)
	if err != nil {
		t.Fatalf("decode seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(pub); got != vectorPubHex {
		t.Fatalf("public key drifted: got %s want %s", got, vectorPubHex)
	}
	return priv, pub
}

func TestSigningBytesVectors(t *testing.T) {
	for _, v := range vectorClaims() {
		t.Run(v.name, func(t *testing.T) {
			got, err := SigningBytes(v.claim)
			if err != nil {
				t.Fatalf("SigningBytes: %v", err)
			}
			if string(got) != v.bytes {
				t.Fatalf("canonical bytes drifted:\n got %q\nwant %q", string(got), v.bytes)
			}
		})
	}
}

func TestSignVectors(t *testing.T) {
	priv, _ := vectorKey(t)
	for _, v := range vectorClaims() {
		t.Run(v.name, func(t *testing.T) {
			got, err := Sign(priv, v.claim)
			if err != nil {
				t.Fatalf("Sign: %v", err)
			}
			if got != v.sig {
				t.Fatalf("signature drifted:\n got %s\nwant %s", got, v.sig)
			}
		})
	}
}

func TestVerifyRoundTrip(t *testing.T) {
	priv, pub := vectorKey(t)
	for _, v := range vectorClaims() {
		t.Run(v.name, func(t *testing.T) {
			ok, err := Verify(pub, v.claim, v.sig)
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			if !ok {
				t.Fatal("valid signature rejected")
			}
			_ = priv
		})
	}
}

// A signature is bound to every field: tampering with the action, any arg, the
// nonce, or the timestamp must invalidate it. This is the whole security
// property — a compromised control plane can relay but not alter.
func TestVerifyRejectsTampering(t *testing.T) {
	priv, pub := vectorKey(t)
	base := Claim{ActionID: "docker.restart", Args: map[string]any{"container": "web", "force": true}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	sig, err := Sign(priv, base)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	tampered := map[string]Claim{
		"action swapped":   {ActionID: "docker.kill", Args: base.Args, Nonce: base.Nonce, IssuedAt: base.IssuedAt},
		"arg value edited": {ActionID: base.ActionID, Args: map[string]any{"container": "db", "force": true}, Nonce: base.Nonce, IssuedAt: base.IssuedAt},
		"arg added":        {ActionID: base.ActionID, Args: map[string]any{"container": "web", "force": true, "signal": float64(9)}, Nonce: base.Nonce, IssuedAt: base.IssuedAt},
		"nonce replayed":   {ActionID: base.ActionID, Args: base.Args, Nonce: "other", IssuedAt: base.IssuedAt},
		"timestamp moved":  {ActionID: base.ActionID, Args: base.Args, Nonce: base.Nonce, IssuedAt: "2026-06-17T13:00:00Z"},
	}
	for name, c := range tampered {
		t.Run(name, func(t *testing.T) {
			ok, err := Verify(pub, c, sig)
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			if ok {
				t.Fatal("tampered claim accepted — signature is not bound to this field")
			}
		})
	}
}

func TestVerifyMalformedSignature(t *testing.T) {
	_, pub := vectorKey(t)
	claim := Claim{ActionID: "a.b", Args: map[string]any{}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	if _, err := Verify(pub, claim, "not-hex!!"); err == nil {
		t.Fatal("expected an error for a non-hex signature")
	}
}

// closes RSEC-003-T08: args that cannot be JSON-marshaled surface as a (false,
// error) from both Sign and Verify — never a silent false that a caller might
// read as "validly signed but mismatched". A channel value is the simplest
// unmarshalable type.
func TestSignVerifyUnmarshalableArgs(t *testing.T) {
	priv, pub := vectorKey(t)
	claim := Claim{ActionID: "a.b", Args: map[string]any{"bad": make(chan int)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	if _, err := Sign(priv, claim); err == nil {
		t.Fatal("Sign must error on unmarshalable args, not return a bogus signature")
	}
	ok, err := Verify(pub, claim, "00")
	if err == nil {
		t.Fatal("Verify must error on unmarshalable args, not a silent false")
	}
	if ok {
		t.Fatal("Verify must not report valid when it could not encode the claim")
	}
}

// closes RSEC-003-T09: a raw secret in an arg value flows verbatim into the
// signing pre-image (it is part of the args digest's input). This pins the
// accepted runner trade-off — args, including secret-bearing ones, are bound by
// the signature; confidentiality of the persisted claim rests elsewhere (0o600
// perms), not on the attestation hiding the value.
func TestSigningBytesIncludesRawSecretInDigestPreimage(t *testing.T) {
	const secret = "emk-super-secret-token-value"
	claim := Claim{ActionID: "a.b", Args: map[string]any{"token": secret}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	// The secret is reduced into the args digest, so it is NOT visible in the
	// final SigningBytes — but it IS the input to that digest: a claim with the
	// secret and one without must produce different signing bytes.
	withSecret, err := SigningBytes(claim)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if strings.Contains(string(withSecret), secret) {
		t.Fatal("setup expectation: the raw secret should be hashed into the digest, not appear literally")
	}

	noSecret, err := SigningBytes(Claim{ActionID: "a.b", Args: map[string]any{"token": "redacted"}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"})
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if string(withSecret) == string(noSecret) {
		t.Fatal("the secret arg value must influence the digest — the claim binds the raw value")
	}

	// And the digest's pre-image is the canonical args JSON, which DOES contain
	// the raw secret verbatim (the documented limitation: the value is signed,
	// not hidden).
	argsJSON, err := json.Marshal(claim.Args)
	if err != nil {
		t.Fatalf("marshal args: %v", err)
	}
	if !strings.Contains(string(argsJSON), secret) {
		t.Fatal("the canonical args JSON (the digest pre-image) must carry the raw secret value")
	}
}

// closes RSEC-003-T10: a hostile arg value cannot smuggle in the newline
// delimiter or a field name to forge a different claim, because the args are
// reduced to a fixed-width SHA-256 digest BEFORE being placed in the
// newline-delimited layout. An arg whose value embeds "\n...Version..." and an
// innocuous arg must still verify only against their own signatures, never each
// other's.
func TestDelimiterCannotBeSmuggledViaArgValue(t *testing.T) {
	priv, pub := vectorKey(t)

	// A value crafted to look like extra signing-byte lines if it were ever
	// concatenated raw.
	injected := "x\n" + Version + "\nattacker.action\ndeadbeef"
	hostile := Claim{ActionID: "real.action", Args: map[string]any{"v": injected}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	sig, err := Sign(priv, hostile)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// The signing bytes must have exactly the 5 documented fields — the embedded
	// newlines in the arg value are absorbed into the single digest field.
	bytes, err := SigningBytes(hostile)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if got := strings.Count(string(bytes), "\n"); got != 4 {
		t.Fatalf("signing bytes have %d newlines, want 4 (a value cannot inject delimiters)", got)
	}

	// The crafted "attacker.action" claim the value was trying to impersonate
	// must NOT verify under the hostile claim's signature.
	forged := Claim{ActionID: "attacker.action", Args: map[string]any{"v": "deadbeef"}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	ok, err := Verify(pub, forged, sig)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if ok {
		t.Fatal("a smuggled-delimiter value forged a different claim — the digest boundary failed")
	}

	// The honest claim still verifies.
	ok, err = Verify(pub, hostile, sig)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !ok {
		t.Fatal("the honest claim must verify against its own signature")
	}
}

// closes RSEC-003-T11: the Version constant is the first signed line, so a
// signature made under one format revision cannot be replayed as another. A
// verifier whose layout is built with a different version yields different
// signing bytes and rejects the signature — preventing format-confusion across
// a future v2.
func TestVersionPrefixPreventsFormatConfusion(t *testing.T) {
	priv, pub := vectorKey(t)
	claim := Claim{ActionID: "a.b", Args: map[string]any{"x": float64(1)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	sig, err := Sign(priv, claim)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Reconstruct the signing bytes as a hypothetical v2 would (different version
	// prefix, same fields) and confirm the v1 signature does not verify over it.
	msg, err := SigningBytes(claim)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if !strings.HasPrefix(string(msg), Version+"\n") {
		t.Fatalf("signing bytes must lead with the version line, got %q", string(msg))
	}
	v2Msg := []byte("emisar-attestation-v2" + strings.TrimPrefix(string(msg), Version))

	rawSig, err := hex.DecodeString(sig)
	if err != nil {
		t.Fatalf("decode sig: %v", err)
	}
	if ed25519.Verify(pub, v2Msg, rawSig) {
		t.Fatal("a v1 signature verified against v2-prefixed bytes — version is not binding")
	}
}

// closes RSEC-003-T12: canonical JSON sorts map keys at every level, so two
// claims whose Args differ only by Go map iteration / declared key order produce
// the same digest and the same signature. This is what lets the control plane
// round-trip args through jsonb without breaking the signature.
func TestCanonicalJSONKeyOrderNormalized(t *testing.T) {
	priv, pub := vectorKey(t)

	a := Claim{ActionID: "a.b", Args: map[string]any{"b": float64(1), "a": float64(2), "nested": map[string]any{"y": float64(3), "x": float64(4)}}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	b := Claim{ActionID: "a.b", Args: map[string]any{"a": float64(2), "nested": map[string]any{"x": float64(4), "y": float64(3)}, "b": float64(1)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	ba, err := SigningBytes(a)
	if err != nil {
		t.Fatalf("SigningBytes(a): %v", err)
	}
	bb, err := SigningBytes(b)
	if err != nil {
		t.Fatalf("SigningBytes(b): %v", err)
	}
	if string(ba) != string(bb) {
		t.Fatalf("key order changed the canonical bytes:\n a=%q\n b=%q", string(ba), string(bb))
	}

	// A signature over one verifies against the other.
	sig, err := Sign(priv, a)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	ok, err := Verify(pub, b, sig)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !ok {
		t.Fatal("re-ordered-key claim must verify against the same signature")
	}
}

// closes RSEC-003-T13: empty Args produces a stable, deterministic digest that
// matches the "empty args" cross-impl vector — and nil Args must canonicalize
// identically, because a no-argument action signed by the MCP (which always
// signs over an empty map, mcp/sign.go) is verified by the runner with whatever
// the wire delivered, which is nil when the `args` field is omitted.
func TestEmptyAndNilArgsStableDigest(t *testing.T) {
	empty := Claim{ActionID: "linux.uptime", Args: map[string]any{}, Nonce: "nonce-1", IssuedAt: "2026-06-17T12:00:00Z"}

	// Empty args: deterministic and pinned to the cross-impl vector digest.
	be, err := SigningBytes(empty)
	if err != nil {
		t.Fatalf("SigningBytes(empty): %v", err)
	}
	const wantEmptyDigest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a" // sha256("{}")
	if !strings.Contains(string(be), wantEmptyDigest) {
		t.Fatalf("empty-args digest drifted from the cross-impl vector; got %q", string(be))
	}
	be2, err := SigningBytes(empty)
	if err != nil {
		t.Fatalf("SigningBytes(empty) again: %v", err)
	}
	if string(be) != string(be2) {
		t.Fatal("empty-args signing bytes are not deterministic")
	}

	// nil Args must produce the SAME digest as empty: the signer (mcp/sign.go
	// coerces nil arguments to map[string]any{} before signing) and the verifier
	// (runner reconstructs the claim from m.Args, which is nil when the wire
	// frame omits `args` — protocol.go `json:"args,omitempty"`) would otherwise
	// disagree, refusing every legitimately-signed no-argument dispatch.
	bn, err := SigningBytes(Claim{ActionID: "linux.uptime", Args: nil, Nonce: "nonce-1", IssuedAt: "2026-06-17T12:00:00Z"})
	if err != nil {
		t.Fatalf("SigningBytes(nil): %v", err)
	}
	if string(be) != string(bn) {
		t.Fatalf("nil and empty args must produce the same bytes:\n empty=%q\n nil=%q", string(be), string(bn))
	}
}

// closes RSEC-003-T14: the two-copy drift guard. attest.go is duplicated VERBATIM
// in the runner and mcp modules; the cross-impl vectors (vectorSeedHex/vectorPubHex
// and each claim's bytes/sig) are the contract, IDENTICAL on both sides. The
// per-vector TestSigningBytesVectors/TestSignVectors already fail if THIS copy's
// encoding drifts from the recorded bytes — but the single most likely silent
// divergence is a Version bump applied to one module's attest.go and not the
// other. This pins the wire-contract invariant explicitly: Version is exactly
// "emisar-attestation-v1", and that exact string is the leading line of every
// documented vector's signing bytes. If a change bumps Version here without
// regenerating the vectors (and updating the mcp twin in the same change), this
// fails with a message that names the cross-impl obligation — a guard the vector
// table provides only incidentally and without explanation.
func TestVersionIsTheCrossImplWireContract(t *testing.T) {
	const wireContract = "emisar-attestation-v1"
	if Version != wireContract {
		t.Fatalf("Version=%q, want %q — this string is the cross-impl wire contract; "+
			"a bump must be applied to BOTH runner and mcp attest.go in the same change, "+
			"with the vectors regenerated, or the MCP that signs and the runner that verifies diverge",
			Version, wireContract)
	}
	for _, v := range vectorClaims() {
		t.Run(v.name, func(t *testing.T) {
			if !strings.HasPrefix(v.bytes, wireContract+"\n") {
				t.Fatalf("vector %q does not lead with the contract version line %q:\n%q",
					v.name, wireContract, v.bytes)
			}
			// Belt and suspenders: the live encoding must produce that same leading
			// line, so a Version change that the literals were NOT regenerated for
			// is caught here as well as in TestSigningBytesVectors.
			got, err := SigningBytes(v.claim)
			if err != nil {
				t.Fatalf("SigningBytes: %v", err)
			}
			if !strings.HasPrefix(string(got), wireContract+"\n") {
				t.Fatalf("SigningBytes for %q must lead with %q, got %q", v.name, wireContract, string(got))
			}
		})
	}
}

// closes RSEC-003-T15: Sign + Verify cost is the deterministic RFC 8032 Ed25519
// cost plus one SHA-256 over the canonical args — the perf baseline for the
// signing contract.
func BenchmarkSignVerify(b *testing.B) {
	seed, err := hex.DecodeString(vectorSeedHex)
	if err != nil {
		b.Fatalf("decode seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	claim := Claim{ActionID: "docker.restart", Args: map[string]any{"container": "web", "force": true, "signal": float64(15)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		sig, err := Sign(priv, claim)
		if err != nil {
			b.Fatalf("Sign: %v", err)
		}
		ok, err := Verify(pub, claim, sig)
		if err != nil || !ok {
			b.Fatalf("Verify: ok=%v err=%v", ok, err)
		}
	}
}
