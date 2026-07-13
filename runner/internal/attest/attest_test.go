package attest

import (
	"bytes"
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
			claim: Claim{ActionID: "linux.uptime", Args: map[string]any{}, Targets: []string{"runner-a"}, Nonce: "nonce-1", IssuedAt: "2026-06-17T12:00:00Z"},
			bytes: `{"version":"emisar-attestation-v3","action_id":"linux.uptime","args_sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a","targets_sha256":"f8c0981f12f5dcdd9528c68f097d72c518bf908ffb137cc0a7d352273524e6dd","nonce":"nonce-1","issued_at":"2026-06-17T12:00:00Z"}`,
			sig:   "45759cd39b17bb2ac85b5e3c437b0893799fd6c85d302f1f97bc0f21d8e682a46cd657509c92dc9501f74071f7c2d306bf0984a99e836358ede3a3dfbc887d09",
		},
		{
			name:  "mixed scalar args (sorted keys)",
			claim: Claim{ActionID: "docker.restart", Args: map[string]any{"container": "web", "force": true, "signal": float64(15)}, Targets: []string{"runner-b", "runner-a"}, Nonce: "nonce-2", IssuedAt: "2026-06-17T12:05:00Z"},
			bytes: `{"version":"emisar-attestation-v3","action_id":"docker.restart","args_sha256":"b8119ee468effeab897d29e97bb44f5d3318b6b5d7dc5308fe5bb7526784a3da","targets_sha256":"7e47da3e9f953ce82de6a7e630a10cc82e1dbaa6dd8f3ea651c906de29dfb8c0","nonce":"nonce-2","issued_at":"2026-06-17T12:05:00Z"}`,
			sig:   "1ed81704c78d09e11639ead3ec9b98330b07876c39f3f53bea4f439639c151ee08ca34d856a1cdec27863c756c4f6c96d0bad9a74672f68c3c63e70bd3c5f00f",
		},
		{
			name:  "nested map + array (keys sorted, array order kept)",
			claim: Claim{ActionID: "x.y", Args: map[string]any{"names": []any{"b", "a"}, "opts": map[string]any{"z": float64(1), "a": float64(2)}}, Targets: []string{"runner-c"}, Nonce: "n3", IssuedAt: "2026-06-17T12:10:00Z"},
			bytes: `{"version":"emisar-attestation-v3","action_id":"x.y","args_sha256":"492e23689996160b37c27461bafd6e137c129e9eb9650d62250914e2072949b4","targets_sha256":"055fc237f0963735210d02d64c0bbcf5b7081b628546543b67d15e95486ce51f","nonce":"n3","issued_at":"2026-06-17T12:10:00Z"}`,
			sig:   "0b847d04967e8eafe7281ac240d5a44badfed5eee81e99ce472e4ed05e228a1a175400d5f38d74cb3710a30bb9956bb7cbfbe0a90a5ef3bd30c3e037c02b7b0f",
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

func TestSigningBytesPreservesExactJSONNumbers(t *testing.T) {
	claim := func(number any) Claim {
		return Claim{
			ActionID: "cockroach.pause_job",
			Args: map[string]any{
				"job_id": number,
			},
			Targets:  []string{"runner-db-1"},
			Nonce:    "n",
			IssuedAt: "2026-06-17T12:00:00Z",
		}
	}

	var equivalent []byte
	for _, spelling := range []string{"1000", "1e3", "1000.0", "1.000e+3"} {
		got, err := SigningBytes(claim(json.Number(spelling)))
		if err != nil {
			t.Fatalf("SigningBytes(%s): %v", spelling, err)
		}
		if equivalent == nil {
			equivalent = got
		} else if !bytes.Equal(got, equivalent) {
			t.Fatalf("equivalent number %s changed the canonical bytes", spelling)
		}
	}

	exact, err := SigningBytes(claim(json.Number("9007199254740993")))
	if err != nil {
		t.Fatalf("SigningBytes(exact): %v", err)
	}
	rounded, err := SigningBytes(claim(float64(9007199254740993)))
	if err != nil {
		t.Fatalf("SigningBytes(rounded): %v", err)
	}
	if bytes.Equal(exact, rounded) {
		t.Fatal("an exact integer above 2^53 collapsed to its float64-rounded neighbour")
	}

	huge, err := SigningBytes(claim(json.Number("1e999999999999999999999")))
	if err != nil {
		t.Fatalf("SigningBytes(huge exponent): %v", err)
	}
	if len(huge) > 512 {
		t.Fatalf("huge exponent expanded into an unbounded signing payload: %d bytes", len(huge))
	}

	if _, err := SigningBytes(claim(json.Number("01"))); err == nil {
		t.Fatal("invalid JSON number with a leading zero must be rejected")
	}
}

func TestSigningBytesCanonicalizesAndBindsTargets(t *testing.T) {
	base := Claim{ActionID: "linux.uptime", Args: map[string]any{}, Targets: []string{"runner-b", "runner-a"}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	reordered := base
	reordered.Targets = []string{"runner-a", "runner-b"}
	a, err := SigningBytes(base)
	if err != nil {
		t.Fatalf("SigningBytes(base): %v", err)
	}
	b, err := SigningBytes(reordered)
	if err != nil {
		t.Fatalf("SigningBytes(reordered): %v", err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("target order must not change the signed claim")
	}

	changed := base
	changed.Targets = []string{"runner-a", "runner-c"}
	c, err := SigningBytes(changed)
	if err != nil {
		t.Fatalf("SigningBytes(changed): %v", err)
	}
	if bytes.Equal(a, c) {
		t.Fatal("changing a runner target did not change the signed claim")
	}

	for _, targets := range [][]string{{""}, {"runner-a", "runner-a"}} {
		invalid := base
		invalid.Targets = targets
		if _, err := SigningBytes(invalid); err == nil {
			t.Fatalf("invalid targets %#v must be rejected", targets)
		}
	}
}

// args that cannot be JSON-marshaled surface as a (false,
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

// a raw secret in an arg value flows verbatim into the
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

// A hostile arg value cannot smuggle a field into the fixed JSON body. Args are
// reduced to a fixed-width SHA-256 digest before that body is encoded.
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

	body, err := SigningBytes(hostile)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if !json.Valid(body) {
		t.Fatalf("signing body is not valid JSON: %q", body)
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

// Distinct legacy newline-delimited claims and certificates could share one
// preimage. The fixed JSON bodies must keep those same collision pairs apart.
func TestSigningBodiesSeparateLegacyDelimiterCollisions(t *testing.T) {
	const (
		emptyArgsDigest  = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
		mixedArgsDigest  = "b8119ee468effeab897d29e97bb44f5d3318b6b5d7dc5308fe5bb7526784a3da"
		runnerATargets   = "f8c0981f12f5dcdd9528c68f097d72c518bf908ffb137cc0a7d352273524e6dd"
		runnerABTargets  = "7e47da3e9f953ce82de6a7e630a10cc82e1dbaa6dd8f3ea651c906de29dfb8c0"
		emptyScopeDigest = "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
		prodScopeDigest  = "871a625f41f8103f3a4cbcb19445ae4a1941ae900da7c6e29cdb4e7bc432e22f"
	)

	t.Run("claim", func(t *testing.T) {
		first := Claim{
			ActionID: "docker.restart\n" + mixedArgsDigest + "\n" + runnerABTargets,
			Args:     map[string]any{}, Targets: []string{"runner-a"},
			Nonce: "nonce-1", IssuedAt: "2026-06-17T12:00:00Z",
		}
		second := Claim{
			ActionID: "docker.restart",
			Args:     map[string]any{"container": "web", "force": true, "signal": float64(15)},
			Targets:  []string{"runner-a", "runner-b"},
			Nonce:    emptyArgsDigest + "\n" + runnerATargets + "\nnonce-1",
			IssuedAt: first.IssuedAt,
		}
		legacyFirst := strings.Join([]string{"emisar-attestation-v2", first.ActionID, emptyArgsDigest, runnerATargets, first.Nonce, first.IssuedAt}, "\n")
		legacySecond := strings.Join([]string{"emisar-attestation-v2", second.ActionID, mixedArgsDigest, runnerABTargets, second.Nonce, second.IssuedAt}, "\n")
		if legacyFirst != legacySecond {
			t.Fatal("test setup no longer demonstrates the legacy claim collision")
		}
		firstBytes, err := SigningBytes(first)
		if err != nil {
			t.Fatalf("SigningBytes(first): %v", err)
		}
		secondBytes, err := SigningBytes(second)
		if err != nil {
			t.Fatalf("SigningBytes(second): %v", err)
		}
		if bytes.Equal(firstBytes, secondBytes) {
			t.Fatal("distinct claims still share one signed body")
		}
	})

	t.Run("certificate", func(t *testing.T) {
		first := Cert{
			CAID:      "ca-acme",
			KeyID:     "op-bob\nsecond-public-key\n2026-06-25T00:00:00Z\n2026-06-26T00:00:00Z\n" + prodScopeDigest,
			PublicKey: "first-public-key", ValidFrom: "2026-06-01T00:00:00Z",
			ValidUntil: "2026-07-01T00:00:00Z", Scope: Scope{}, Serial: "first-serial",
		}
		second := Cert{
			CAID: "ca-acme", KeyID: "op-bob", PublicKey: "second-public-key",
			ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z",
			Scope:  Scope{Group: "prod"},
			Serial: strings.Join([]string{first.PublicKey, first.ValidFrom, first.ValidUntil, emptyScopeDigest, first.Serial}, "\n"),
		}
		legacyFirst := strings.Join([]string{"emisar-cert-v1", first.CAID, first.KeyID, first.PublicKey, first.ValidFrom, first.ValidUntil, emptyScopeDigest, first.Serial}, "\n")
		legacySecond := strings.Join([]string{"emisar-cert-v1", second.CAID, second.KeyID, second.PublicKey, second.ValidFrom, second.ValidUntil, prodScopeDigest, second.Serial}, "\n")
		if legacyFirst != legacySecond {
			t.Fatal("test setup no longer demonstrates the legacy certificate collision")
		}
		firstBytes, err := CertSigningBytes(first)
		if err != nil {
			t.Fatalf("CertSigningBytes(first): %v", err)
		}
		secondBytes, err := CertSigningBytes(second)
		if err != nil {
			t.Fatalf("CertSigningBytes(second): %v", err)
		}
		if bytes.Equal(firstBytes, secondBytes) {
			t.Fatal("distinct certificates still share one signed body")
		}
	})
}

// The Version constant is the first signed field, so a
// signature made under one format revision cannot be replayed as another. A
// verifier whose layout is built with a different version yields different
// signing bytes and rejects the signature — preventing format-confusion across
// a future revision.
func TestVersionPrefixPreventsFormatConfusion(t *testing.T) {
	priv, pub := vectorKey(t)
	claim := Claim{ActionID: "a.b", Args: map[string]any{"x": float64(1)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	sig, err := Sign(priv, claim)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	// Reconstruct the signing bytes as a hypothetical v4 would (different version
	// field, same facts) and confirm the v3 signature does not verify over it.
	msg, err := SigningBytes(claim)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	prefix := `{"version":"` + Version + `"`
	if !strings.HasPrefix(string(msg), prefix) {
		t.Fatalf("signing bytes must lead with the version field, got %q", string(msg))
	}
	v4Msg := []byte(strings.Replace(string(msg), prefix, `{"version":"emisar-attestation-v4"`, 1))

	rawSig, err := hex.DecodeString(sig)
	if err != nil {
		t.Fatalf("decode sig: %v", err)
	}
	if ed25519.Verify(pub, v4Msg, rawSig) {
		t.Fatal("a v3 signature verified against v4 bytes — version is not binding")
	}
}

// canonical JSON sorts map keys at every level, so two
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

// empty Args produces a stable, deterministic digest that
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

// the two-copy drift guard. attest.go is duplicated VERBATIM
// in the runner and mcp modules; the cross-impl vectors (vectorSeedHex/vectorPubHex
// and each claim's bytes/sig) are the contract, IDENTICAL on both sides. The
// per-vector TestSigningBytesVectors/TestSignVectors already fail if THIS copy's
// encoding drifts from the recorded bytes — but the single most likely silent
// divergence is a Version bump applied to one module's attest.go and not the
// other. This pins the wire-contract invariant explicitly: Version is exactly
// "emisar-attestation-v3", and that exact string is the first field of every
// documented vector's signing bytes. If a change bumps Version here without
// regenerating the vectors (and updating the mcp twin in the same change), this
// fails with a message that names the cross-impl obligation — a guard the vector
// table provides only incidentally and without explanation.
func TestVersionIsTheCrossImplWireContract(t *testing.T) {
	const wireContract = "emisar-attestation-v3"
	if Version != wireContract {
		t.Fatalf("Version=%q, want %q — this string is the cross-impl wire contract; "+
			"a bump must be applied to BOTH runner and mcp attest.go in the same change, "+
			"with the vectors regenerated, or the MCP that signs and the runner that verifies diverge",
			Version, wireContract)
	}
	for _, v := range vectorClaims() {
		t.Run(v.name, func(t *testing.T) {
			if !strings.HasPrefix(v.bytes, `{"version":"`+wireContract+`"`) {
				t.Fatalf("vector %q does not lead with the contract version field %q:\n%q",
					v.name, wireContract, v.bytes)
			}
			// Belt and suspenders: the live encoding must produce that same leading
			// line, so a Version change that the literals were NOT regenerated for
			// is caught here as well as in TestSigningBytesVectors.
			got, err := SigningBytes(v.claim)
			if err != nil {
				t.Fatalf("SigningBytes: %v", err)
			}
			if !strings.HasPrefix(string(got), `{"version":"`+wireContract+`"`) {
				t.Fatalf("SigningBytes for %q must lead with version %q, got %q", v.name, wireContract, string(got))
			}
		})
	}
}

// ----- emisar-cert-v2 cross-impl vectors -----

// CROSS-IMPL CONTRACT for the cert. These are IDENTICAL in mcp/internal/attest,
// the same obligation as the attestation vectors above: a change to either
// copy's CertSigningBytes fails its vector test. Fixed CA seed → exact body
// bytes + the deterministic CA signature.
const (
	vectorCASeedHex = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	vectorCAPubHex  = "e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0"
	// the leaf pubkey the certs vouch for — the same real 32-byte key as the
	// attestation vector, so a signed claim can be checked end-to-end under it.
	vectorCertLeafPub = vectorPubHex
)

func vectorCerts() []struct {
	name  string
	cert  Cert
	bytes string
	sig   string
} {
	return []struct {
		name  string
		cert  Cert
		bytes string
		sig   string
	}{
		{
			name:  "empty scope (any runner)",
			cert:  Cert{CAID: "ca-acme", KeyID: "op-alice", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{}, Serial: "01J0CERT0000000000000000A"},
			bytes: `{"version":"emisar-cert-v2","ca_id":"ca-acme","key_id":"op-alice","public_key":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","valid_from":"2026-06-25T00:00:00Z","valid_until":"2026-06-26T00:00:00Z","scope_sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a","serial":"01J0CERT0000000000000000A"}`,
			sig:   "45dffebfb4140da3e6ca45fcc7cba0f3bad43fc50a61b2e3cf0d1227c41c903d2e071cf626ddcc9e47348bb284bc83f6fca4d7bc88a4913b87b33b32c8794f06",
		},
		{
			name:  "group scope",
			cert:  Cert{CAID: "ca-acme", KeyID: "op-bob", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{Group: "prod"}, Serial: "01J0CERT0000000000000000B"},
			bytes: `{"version":"emisar-cert-v2","ca_id":"ca-acme","key_id":"op-bob","public_key":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","valid_from":"2026-06-25T00:00:00Z","valid_until":"2026-06-26T00:00:00Z","scope_sha256":"871a625f41f8103f3a4cbcb19445ae4a1941ae900da7c6e29cdb4e7bc432e22f","serial":"01J0CERT0000000000000000B"}`,
			sig:   "af464c91597e15f2d14d5f3b81e16738502c92c89941821817f1c8f49daad1f042f2895f5aefa67125847527ec1ca65bd3cd239097b4754bd9652a8f6311db08",
		},
		{
			name:  "group + labels scope (keys sorted)",
			cert:  Cert{CAID: "ca-acme", KeyID: "op-carol", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{Group: "edge", Labels: map[string]string{"region": "us", "env": "prod"}}, Serial: "01J0CERT0000000000000000C"},
			bytes: `{"version":"emisar-cert-v2","ca_id":"ca-acme","key_id":"op-carol","public_key":"79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664","valid_from":"2026-06-25T00:00:00Z","valid_until":"2026-06-26T00:00:00Z","scope_sha256":"75d22a7b0f024c454095764648cb9e08de2df93cfed413b76fa0aa74d93fddd4","serial":"01J0CERT0000000000000000C"}`,
			sig:   "a9e8943291d35ca8cf4c8b52156337e38d061c84370b2cc8d379c9a54c9158fdfed75e19a6f6afee725d0a2b31d32e1d837204f2e7e7f649b35d506c53c4170b",
		},
	}
}

func vectorCAKey(t *testing.T) (ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	seed, err := hex.DecodeString(vectorCASeedHex)
	if err != nil {
		t.Fatalf("decode CA seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(pub); got != vectorCAPubHex {
		t.Fatalf("CA public key drifted: got %s want %s", got, vectorCAPubHex)
	}
	return priv, pub
}

func TestCertSigningBytesVectors(t *testing.T) {
	for _, v := range vectorCerts() {
		t.Run(v.name, func(t *testing.T) {
			got, err := CertSigningBytes(v.cert)
			if err != nil {
				t.Fatalf("CertSigningBytes: %v", err)
			}
			if string(got) != v.bytes {
				t.Fatalf("cert canonical bytes drifted:\n got %q\nwant %q", string(got), v.bytes)
			}
		})
	}
}

func TestSignCertVectors(t *testing.T) {
	priv, _ := vectorCAKey(t)
	for _, v := range vectorCerts() {
		t.Run(v.name, func(t *testing.T) {
			got, err := SignCert(priv, v.cert)
			if err != nil {
				t.Fatalf("SignCert: %v", err)
			}
			if got != v.sig {
				t.Fatalf("cert signature drifted:\n got %s\nwant %s", got, v.sig)
			}
		})
	}
}

func TestVerifyCertRoundTrip(t *testing.T) {
	_, pub := vectorCAKey(t)
	for _, v := range vectorCerts() {
		t.Run(v.name, func(t *testing.T) {
			c := v.cert
			c.Sig = v.sig
			ok, err := VerifyCert(pub, c)
			if err != nil {
				t.Fatalf("VerifyCert: %v", err)
			}
			if !ok {
				t.Fatal("valid cert signature rejected")
			}
		})
	}
}

// VerifyCert must bind every field of the cert body: a compromised portal can
// relay a cert but not edit which key/scope/window the CA vouched for.
func TestVerifyCertRejectsTampering(t *testing.T) {
	priv, pub := vectorCAKey(t)
	base := Cert{CAID: "ca-acme", KeyID: "op-alice", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{Group: "prod", Labels: map[string]string{"env": "prod"}}, Serial: "01J0CERT0000000000000000A"}
	sig, err := SignCert(priv, base)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}

	tampered := map[string]Cert{
		"ca_id swapped":      {CAID: "ca-evil", KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: base.Scope, Serial: base.Serial},
		"key_id swapped":     {CAID: base.CAID, KeyID: "op-mallory", PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: base.Scope, Serial: base.Serial},
		"public_key swapped": {CAID: base.CAID, KeyID: base.KeyID, PublicKey: "00" + base.PublicKey[2:], ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: base.Scope, Serial: base.Serial},
		"valid_from moved":   {CAID: base.CAID, KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: "2026-01-01T00:00:00Z", ValidUntil: base.ValidUntil, Scope: base.Scope, Serial: base.Serial},
		"valid_until moved":  {CAID: base.CAID, KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: "2030-01-01T00:00:00Z", Scope: base.Scope, Serial: base.Serial},
		"scope group edited": {CAID: base.CAID, KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: Scope{Group: "edge", Labels: base.Scope.Labels}, Serial: base.Serial},
		"scope label edited": {CAID: base.CAID, KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: Scope{Group: base.Scope.Group, Labels: map[string]string{"env": "dev"}}, Serial: base.Serial},
		"serial swapped":     {CAID: base.CAID, KeyID: base.KeyID, PublicKey: base.PublicKey, ValidFrom: base.ValidFrom, ValidUntil: base.ValidUntil, Scope: base.Scope, Serial: "01J0CERT0000000000000000Z"},
	}
	for name, c := range tampered {
		t.Run(name, func(t *testing.T) {
			c.Sig = sig
			ok, err := VerifyCert(pub, c)
			if err != nil {
				t.Fatalf("VerifyCert: %v", err)
			}
			if ok {
				t.Fatal("tampered cert accepted — the CA signature is not bound to this field")
			}
		})
	}
}

// A cert verified under the WRONG CA public key must fail — a runner trusts a
// specific CA, so a cert minted by a different (e.g. attacker) CA is refused.
func TestVerifyCertWrongCA(t *testing.T) {
	priv, _ := vectorCAKey(t)
	otherPub := ed25519.NewKeyFromSeed(make([]byte, ed25519.SeedSize)).Public().(ed25519.PublicKey)
	cert := vectorCerts()[0].cert
	sig, err := SignCert(priv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	cert.Sig = sig
	ok, err := VerifyCert(otherPub, cert)
	if err != nil {
		t.Fatalf("VerifyCert: %v", err)
	}
	if ok {
		t.Fatal("a cert verified under a CA that did not sign it")
	}
}

func TestVerifyCertMalformedSignature(t *testing.T) {
	_, pub := vectorCAKey(t)
	c := vectorCerts()[0].cert
	c.Sig = "not-hex!!"
	if _, err := VerifyCert(pub, c); err == nil {
		t.Fatal("expected an error for a non-hex cert signature")
	}
}

// the cert-version drift guard, mirroring TestVersionIsTheCrossImplWireContract.
// CertVersion is exactly "emisar-cert-v2" and is the first field of every cert
// vector — a bump to one module's attest.go without the other fails here.
func TestCertVersionIsTheCrossImplWireContract(t *testing.T) {
	const wireContract = "emisar-cert-v2"
	if CertVersion != wireContract {
		t.Fatalf("CertVersion=%q, want %q — this string is the cross-impl wire contract; "+
			"a bump must be applied to BOTH runner and mcp attest.go in the same change, "+
			"with the cert vectors regenerated, or the MCP that signs and the runner that verifies diverge",
			CertVersion, wireContract)
	}
	for _, v := range vectorCerts() {
		t.Run(v.name, func(t *testing.T) {
			if !strings.HasPrefix(v.bytes, `{"version":"`+wireContract+`"`) {
				t.Fatalf("cert vector %q does not lead with the contract version field %q:\n%q", v.name, wireContract, v.bytes)
			}
			got, err := CertSigningBytes(v.cert)
			if err != nil {
				t.Fatalf("CertSigningBytes: %v", err)
			}
			if !strings.HasPrefix(string(got), `{"version":"`+wireContract+`"`) {
				t.Fatalf("CertSigningBytes for %q must lead with version %q, got %q", v.name, wireContract, string(got))
			}
		})
	}
}

// Sign + Verify cost is the deterministic RFC 8032 Ed25519
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
