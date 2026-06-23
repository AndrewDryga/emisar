package attest

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
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

	// The signing string has exactly four newlines (5 fields: Version, ActionID,
	// digest, Nonce, IssuedAt). The arg value's embedded newline is hashed into
	// the digest line, not spliced into the framing.
	if n := bytes.Count(got, []byte("\n")); n != 4 {
		t.Fatalf("smuggled newline leaked into the signing framing: want 4 delimiters, got %d in %q", n, got)
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
	}
	for _, imp := range f.Imports {
		path := strings.Trim(imp.Path.Value, `"`)
		if !allowed[path] {
			t.Errorf("unexpected import %q — attest must stay stdlib-only (no shared/external deps)", path)
		}
	}
}
