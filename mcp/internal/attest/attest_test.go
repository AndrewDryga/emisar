package attest

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"go/parser"
	"go/token"
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
			bytes: "emisar-attestation-v2\nlinux.uptime\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\nf8c0981f12f5dcdd9528c68f097d72c518bf908ffb137cc0a7d352273524e6dd\nnonce-1\n2026-06-17T12:00:00Z",
			sig:   "4e7de9136d2cc5a6cdcfcc822bed01f2d85b6619923fb3ca2036e2cea64044a7beeb58f028c67b8b438be44d571b397ee30d486ad75a73606eb43ccad5ad0d07",
		},
		{
			name:  "mixed scalar args (sorted keys)",
			claim: Claim{ActionID: "docker.restart", Args: map[string]any{"container": "web", "force": true, "signal": float64(15)}, Targets: []string{"runner-b", "runner-a"}, Nonce: "nonce-2", IssuedAt: "2026-06-17T12:05:00Z"},
			bytes: "emisar-attestation-v2\ndocker.restart\nb8119ee468effeab897d29e97bb44f5d3318b6b5d7dc5308fe5bb7526784a3da\n7e47da3e9f953ce82de6a7e630a10cc82e1dbaa6dd8f3ea651c906de29dfb8c0\nnonce-2\n2026-06-17T12:05:00Z",
			sig:   "b9b209fe8c2796f2594d899db20c64e40959a612cbacbba9f344bde8421b9719316fb66583fc9c56fc28d7acf37192118d4e8293d5cbf53529d02f77e7cdfa00",
		},
		{
			name:  "nested map + array (keys sorted, array order kept)",
			claim: Claim{ActionID: "x.y", Args: map[string]any{"names": []any{"b", "a"}, "opts": map[string]any{"z": float64(1), "a": float64(2)}}, Targets: []string{"runner-c"}, Nonce: "n3", IssuedAt: "2026-06-17T12:10:00Z"},
			bytes: "emisar-attestation-v2\nx.y\n492e23689996160b37c27461bafd6e137c129e9eb9650d62250914e2072949b4\n055fc237f0963735210d02d64c0bbcf5b7081b628546543b67d15e95486ce51f\nn3\n2026-06-17T12:10:00Z",
			sig:   "c950f0351e267c0449842401c07d9815f8fc41bb13c2b5a9e376ec858cf94b68dda73f82344d3f10a008c119c708dd328cec98b942477814bfb0689b71b7f307",
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

// numeric args normalize across the portal jsonb round-trip. The
// portal stores args as jsonb and re-decodes JSON numbers as float64; the bridge
// signs the same logical args as a Go int literal. Both must canonicalize to the
// same JSON number form ("15") so the digest — and therefore the signature —
// matches on both sides. (encoding/json renders int 15 and float64(15) identically.)
func TestSigningBytes_NumericArgsNormalizeAcrossJSONBRoundTrip(t *testing.T) {
	asInt := Claim{ActionID: "docker.restart", Args: map[string]any{"signal": 15}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}
	asFloat := Claim{ActionID: "docker.restart", Args: map[string]any{"signal": float64(15)}, Nonce: "n", IssuedAt: "2026-06-17T12:00:00Z"}

	intBytes, err := SigningBytes(asInt)
	if err != nil {
		t.Fatalf("SigningBytes(int): %v", err)
	}
	floatBytes, err := SigningBytes(asFloat)
	if err != nil {
		t.Fatalf("SigningBytes(float64): %v", err)
	}
	if !bytes.Equal(intBytes, floatBytes) {
		t.Fatalf("int 15 and float64(15) must canonicalize to the same digest:\n int:   %q\n float: %q", intBytes, floatBytes)
	}

	// And the signature itself must match — a runner that re-decoded the arg as
	// float64 would otherwise reject a signature minted over the int form.
	priv, pub := vectorKey(t)
	sig, err := Sign(priv, asInt)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	ok, err := Verify(pub, asFloat, sig)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !ok {
		t.Fatal("signature over int args did not verify against the float64-decoded form (jsonb round-trip would break dispatch)")
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

// the args digest defeats delimiter smuggling. SigningBytes is a
// newline-delimited string; the args are reduced to a sha256 hex digest precisely
// so a value containing a "\n" (or the whole "Version\nActionID\n…" framing)
// cannot inject a fake field boundary into the signing string. We assert the
// digest is hashed in (the raw newline never appears in the signing bytes) and
// that two distinct smuggling-shaped values yield distinct signing bytes.
func TestSigningBytes_ArgsDigestDefeatsDelimiterSmuggling(t *testing.T) {
	smuggle := Claim{
		ActionID: "x.y",
		Args:     map[string]any{"note": "evil\nemisar-attestation-v1\nspoofed.action"},
		Nonce:    "n",
		IssuedAt: "2026-06-17T12:00:00Z",
	}
	got, err := SigningBytes(smuggle)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}

	// The signing string has exactly five newlines (6 fields: Version, ActionID,
	// args digest, targets digest, Nonce, IssuedAt). Embedded newlines are hashed into
	// the digest line, not spliced into the framing.
	if n := bytes.Count(got, []byte("\n")); n != 5 {
		t.Fatalf("smuggled newline leaked into the signing framing: want 5 delimiters, got %d in %q", n, got)
	}
	if bytes.Contains(got, []byte("spoofed.action")) {
		t.Fatalf("arg value bytes appear verbatim in the signing string — digest did not contain them: %q", got)
	}

	// A different smuggled value must change the digest line (it is bound in).
	other := smuggle
	other.Args = map[string]any{"note": "evil\nemisar-attestation-v1\nDIFFERENT"}
	otherBytes, err := SigningBytes(other)
	if err != nil {
		t.Fatalf("SigningBytes(other): %v", err)
	}
	if bytes.Equal(got, otherBytes) {
		t.Fatal("two distinct arg values produced identical signing bytes — value not bound into the digest")
	}
}

// an un-marshalable Args value is an error, not a partial encoding.
// A channel cannot be JSON-marshaled; SigningBytes must surface that rather than
// signing over a truncated/empty digest.
func TestSigningBytes_MarshalFailureIsError(t *testing.T) {
	claim := Claim{
		ActionID: "x.y",
		Args:     map[string]any{"bad": make(chan int)},
		Nonce:    "n",
		IssuedAt: "2026-06-17T12:00:00Z",
	}
	if _, err := SigningBytes(claim); err == nil {
		t.Fatal("expected an error marshaling an un-marshalable args value, got nil")
	}

	// Sign threads SigningBytes' error out rather than returning a bogus signature.
	priv, _ := vectorKey(t)
	if _, err := Sign(priv, claim); err == nil {
		t.Fatal("Sign must propagate the marshal error, got nil")
	}
}

// the attest package is stdlib-only (no external deps). The
// cross-impl contract relies on this: each module ships its own verbatim copy, so
// a third-party import would couple them and is forbidden. Parse attest.go's own
// import block and assert every import is one of the four expected stdlib paths.
func TestAttestImportsAreStdlibOnly(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "attest.go", nil, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse attest.go: %v", err)
	}
	allowed := map[string]bool{
		"crypto/ed25519": true,
		"crypto/sha256":  true,
		"encoding/hex":   true,
		"encoding/json":  true,
		"fmt":            true,
		"math":           true,
		"math/big":       true,
		"sort":           true,
		"strconv":        true,
		"strings":        true,
	}
	for _, imp := range f.Imports {
		path := strings.Trim(imp.Path.Value, `"`)
		if !allowed[path] {
			t.Errorf("unexpected import %q — attest must stay stdlib-only (no shared/external deps)", path)
		}
	}
}

// ----- emisar-cert-v1 cross-impl vectors -----

// CROSS-IMPL CONTRACT for the cert. These are IDENTICAL in runner/internal/attest,
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
			bytes: "emisar-cert-v1\nca-acme\nop-alice\n79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664\n2026-06-25T00:00:00Z\n2026-06-26T00:00:00Z\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a\n01J0CERT0000000000000000A",
			sig:   "9e69c413be4b0132271d1d28ac15214b861546f4ae68ea64a4f32917bd906c69f749f76b7ac88864ccd53cfcb77185abfcfa6636f8af816f5617f4ffd3ef890d",
		},
		{
			name:  "group scope",
			cert:  Cert{CAID: "ca-acme", KeyID: "op-bob", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{Group: "prod"}, Serial: "01J0CERT0000000000000000B"},
			bytes: "emisar-cert-v1\nca-acme\nop-bob\n79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664\n2026-06-25T00:00:00Z\n2026-06-26T00:00:00Z\n871a625f41f8103f3a4cbcb19445ae4a1941ae900da7c6e29cdb4e7bc432e22f\n01J0CERT0000000000000000B",
			sig:   "50973262a130a51a5bcdb733df180acdadfac1944ddd4deae0ee0cafeb9d873aa402311c46915f2cefb7220388ede784214c99e3212e29173c727597a723d905",
		},
		{
			name:  "group + labels scope (keys sorted)",
			cert:  Cert{CAID: "ca-acme", KeyID: "op-carol", PublicKey: vectorCertLeafPub, ValidFrom: "2026-06-25T00:00:00Z", ValidUntil: "2026-06-26T00:00:00Z", Scope: Scope{Group: "edge", Labels: map[string]string{"region": "us", "env": "prod"}}, Serial: "01J0CERT0000000000000000C"},
			bytes: "emisar-cert-v1\nca-acme\nop-carol\n79b5562e8fe654f94078b112e8a98ba7901f853ae695bed7e0e3910bad049664\n2026-06-25T00:00:00Z\n2026-06-26T00:00:00Z\n75d22a7b0f024c454095764648cb9e08de2df93cfed413b76fa0aa74d93fddd4\n01J0CERT0000000000000000C",
			sig:   "abfd0748e03ad1dbf463702f69f4be20ebb60d0e3237631581f06956513311e1a29ebf55a204ea087314a7498850f58c69fa563f14dfa36a9e627d0902dff40d",
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
// CertVersion is exactly "emisar-cert-v1" and is the leading line of every cert
// vector — a bump to one module's attest.go without the other fails here.
func TestCertVersionIsTheCrossImplWireContract(t *testing.T) {
	const wireContract = "emisar-cert-v1"
	if CertVersion != wireContract {
		t.Fatalf("CertVersion=%q, want %q — this string is the cross-impl wire contract; "+
			"a bump must be applied to BOTH runner and mcp attest.go in the same change, "+
			"with the cert vectors regenerated, or the MCP that signs and the runner that verifies diverge",
			CertVersion, wireContract)
	}
	for _, v := range vectorCerts() {
		t.Run(v.name, func(t *testing.T) {
			if !strings.HasPrefix(v.bytes, wireContract+"\n") {
				t.Fatalf("cert vector %q does not lead with the contract version line %q:\n%q", v.name, wireContract, v.bytes)
			}
			got, err := CertSigningBytes(v.cert)
			if err != nil {
				t.Fatalf("CertSigningBytes: %v", err)
			}
			if !strings.HasPrefix(string(got), wireContract+"\n") {
				t.Fatalf("CertSigningBytes for %q must lead with %q, got %q", v.name, wireContract, string(got))
			}
		})
	}
}
