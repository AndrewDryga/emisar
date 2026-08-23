package attest

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net/url"
	"strings"
	"testing"
	"time"
)

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
			name: "empty args",
			claim: Claim{
				PortalOrigin: "https://emisar.dev", ActionID: "linux.uptime",
				PackRef: "linux@1.0.0/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
				ArgsRaw: json.RawMessage(`{}`), RunnerRefs: []string{"db-a~11111111111111111111111111111111"},
				Reason: "Check load.", OperationID: "op_01", Nonce: "00000000000000000000000000000001",
				IssuedAt: "2026-06-17T12:00:00Z",
			},
			bytes: `{"version":"emisar-attestation-v5","tool":"run_action","portal_origin":"https://emisar.dev","action_id":"linux.uptime","pack_ref":"linux@1.0.0/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","args_sha256":"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a","runner_refs_sha256":"589c61cbb2a6783bdd43f634b32c84a59040eed70a62e4b3cde9034511500c2d","reason":"Check load.","evidence_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","expected_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","operation_id":"op_01","nonce":"00000000000000000000000000000001","issued_at":"2026-06-17T12:00:00Z"}`,
			sig:   `1710cd8576e6ac256043e132e3e36989a94dbcfc3a0581c8aeb349e2108b89670faf288060758d129ea276cd1a0664fa6eddae0402565bf0dd079fc40fc8e907`,
		},
		{
			name: "exact large number and sorted runner refs",
			claim: Claim{
				PortalOrigin: "https://ops.example:8443", ActionID: "cockroach.pause_job",
				PackRef:     "cockroach@1.4.0/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
				ArgsRaw:     json.RawMessage(`{"job_id":891234567890123456,"force":true}`),
				RunnerRefs:  []string{"db-b~33333333333333333333333333333333", "db-a~22222222222222222222222222222222"},
				Reason:      "Pause the selected job before maintenance.",
				Evidence:    "p99 write latency 40s since 12:10Z, job 891234567890123456 holds the lock",
				Expected:    "writes resume within 60s of the pause",
				OperationID: "op_02",
				Nonce:       "00000000000000000000000000000002", IssuedAt: "2026-06-17T12:05:00Z",
			},
			bytes: `{"version":"emisar-attestation-v5","tool":"run_action","portal_origin":"https://ops.example:8443","action_id":"cockroach.pause_job","pack_ref":"cockroach@1.4.0/sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","args_sha256":"bfb315278c463b5e42d6ed32b071bf0389d887e2bd2877d08e57a4a36b02403f","runner_refs_sha256":"41bcc8c1820d2787411727666d93e585d4d32c798c6f25e2335130154cc7f079","reason":"Pause the selected job before maintenance.","evidence_sha256":"84f42024269cc69ef725a2841c5596edef7ad940d445f68c2e6af576b8877f43","expected_sha256":"1575b4783811db3956097c98d85ed8c5ea5fe283660e86eae46b322c02a34b54","operation_id":"op_02","nonce":"00000000000000000000000000000002","issued_at":"2026-06-17T12:05:00Z"}`,
			sig:   `1808fd25ea462ed1e0527497baf7c8e8b1f540c2205494c9bdc8522b390b3909b92d75b84c38ed0cd04913795ef5dd78e84f8fc9037b3d50be302a6ef5cd830d`,
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
	for _, vector := range vectorClaims() {
		t.Run(vector.name, func(t *testing.T) {
			got, err := SigningBytes(vector.claim)
			if err != nil {
				t.Fatalf("SigningBytes: %v", err)
			}
			if string(got) != vector.bytes {
				t.Fatalf("canonical bytes drifted:\n got %q\nwant %q", got, vector.bytes)
			}
		})
	}
}

func TestSignVectors(t *testing.T) {
	priv, pub := vectorKey(t)
	for _, vector := range vectorClaims() {
		t.Run(vector.name, func(t *testing.T) {
			got, err := Sign(priv, vector.claim)
			if err != nil {
				t.Fatalf("Sign: %v", err)
			}
			if got != vector.sig {
				t.Fatalf("signature drifted:\n got %s\nwant %s", got, vector.sig)
			}
			ok, err := Verify(pub, vector.claim, vector.sig)
			if err != nil || !ok {
				t.Fatalf("Verify = %v, %v; want true", ok, err)
			}
		})
	}
}

func TestSigningBytesBindsEveryIntentField(t *testing.T) {
	priv, pub := vectorKey(t)
	base := vectorClaims()[1].claim
	sig, err := Sign(priv, base)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}

	tampered := map[string]Claim{}
	add := func(name string, mutate func(*Claim)) {
		claim := base
		claim.ArgsRaw = append(json.RawMessage(nil), base.ArgsRaw...)
		claim.RunnerRefs = append([]string(nil), base.RunnerRefs...)
		mutate(&claim)
		tampered[name] = claim
	}
	add("portal origin", func(c *Claim) { c.PortalOrigin = "https://evil.example" })
	add("action", func(c *Claim) { c.ActionID = "cockroach.resume_job" })
	add("pack", func(c *Claim) { c.PackRef = strings.Replace(c.PackRef, "bbbb", "cccc", 1) })
	add("args", func(c *Claim) { c.ArgsRaw = json.RawMessage(`{"job_id":891234567890123457,"force":true}`) })
	add("runner refs", func(c *Claim) { c.RunnerRefs[0] = "db-c~44444444444444444444444444444444" })
	add("reason", func(c *Claim) { c.Reason = "Different reason." })
	add("operation", func(c *Claim) { c.OperationID = "op_other" })
	add("nonce", func(c *Claim) { c.Nonce = "ffffffffffffffffffffffffffffffff" })
	add("issued at", func(c *Claim) { c.IssuedAt = "2026-06-17T12:06:00Z" })

	for name, claim := range tampered {
		t.Run(name, func(t *testing.T) {
			ok, err := Verify(pub, claim, sig)
			if err != nil {
				t.Fatalf("Verify: %v", err)
			}
			if ok {
				t.Fatal("tampered claim verified")
			}
		})
	}
}

func TestSigningBytesHardcodesRunActionDomain(t *testing.T) {
	got, err := SigningBytes(vectorClaims()[0].claim)
	if err != nil {
		t.Fatalf("SigningBytes: %v", err)
	}
	if !bytes.Contains(got, []byte(`"tool":"run_action"`)) {
		t.Fatalf("signed body does not bind run_action: %s", got)
	}
}

func TestArgsSHA256UsesExactObjectBytes(t *testing.T) {
	spellings := []json.RawMessage{
		json.RawMessage(`{"n":1000}`),
		json.RawMessage(`{"n":1e3}`),
		json.RawMessage(`{ "n" : 1000 }`),
	}
	digests := map[string]bool{}
	for _, raw := range spellings {
		digest, err := ArgsSHA256(raw)
		if err != nil {
			t.Fatalf("ArgsSHA256(%s): %v", raw, err)
		}
		digests[digest] = true
	}
	if len(digests) != len(spellings) {
		t.Fatal("distinct exact argument bytes produced the same digest")
	}

	empty, err := ArgsSHA256(nil)
	if err != nil {
		t.Fatalf("ArgsSHA256(nil): %v", err)
	}
	explicit, err := ArgsSHA256(json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("ArgsSHA256({}): %v", err)
	}
	if empty != explicit {
		t.Fatal("omitted no-argument object did not normalize to {}")
	}
}

func TestArgsSHA256RejectsInvalidOrNonObjectJSON(t *testing.T) {
	for _, raw := range []json.RawMessage{
		json.RawMessage(`null`), json.RawMessage(`[]`), json.RawMessage(`{"x":`), json.RawMessage(`1`),
	} {
		if _, err := ArgsSHA256(raw); err == nil {
			t.Fatalf("ArgsSHA256(%q) accepted invalid/non-object input", raw)
		}
	}
}

func TestCanonicalRunnerRefs(t *testing.T) {
	got, err := CanonicalRunnerRefs([]string{"z~22222222222222222222222222222222", "a~11111111111111111111111111111111"})
	if err != nil {
		t.Fatalf("CanonicalRunnerRefs: %v", err)
	}
	if strings.Join(got, ",") != "a~11111111111111111111111111111111,z~22222222222222222222222222222222" {
		t.Fatalf("sorted refs = %v", got)
	}
	tooMany := make([]string, MaxRunnerRefs+1)
	for i := range tooMany {
		tooMany[i] = string(rune('a' + i))
	}
	for _, refs := range [][]string{nil, {""}, {"same", "same"}, {strings.Repeat("x", MaxRunnerRefBytes+1)}, tooMany} {
		if _, err := CanonicalRunnerRefs(refs); err == nil {
			t.Fatalf("CanonicalRunnerRefs(%v) unexpectedly succeeded", refs)
		}
	}
}

func TestVerifyRejectsMalformedSignature(t *testing.T) {
	_, pub := vectorKey(t)
	ok, err := Verify(pub, vectorClaims()[0].claim, "not-hex")
	if err == nil || ok {
		t.Fatalf("Verify = %v, %v; want false, error", ok, err)
	}
}

const (
	vectorCASeedHex = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	vectorCAPubHex  = "e7f162a10bec559afea195e4dce84b69568d5d2cb0963eb446c0685e2b17f2f0"
	// The frozen DER digest of the vector leaf certificate. X.509 minting from a
	// FIXED template with an Ed25519 issuer is deterministic (RFC 8032), so this
	// is a real cross-implementation vector in the same sense the claim vectors
	// are: the runner and the bridge must build byte-identical certificates from
	// identical inputs, or one side is encoding the profile differently.
	vectorLeafDERSHA256 = "e299818e97704d560f062f67595d99c8a211d59cff1c4f81b8777dc633bcdd93"
)

// vectorNotBefore fixes the certificate validity window so the DER digest above
// is stable. Tests that need a live window pass their own `now`.
var vectorNotBefore = time.Date(2026, 6, 25, 0, 0, 0, 0, time.UTC)

func vectorCAKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	seed, err := hex.DecodeString(vectorCASeedHex)
	if err != nil {
		t.Fatalf("decode CA seed: %v", err)
	}
	priv := ed25519.NewKeyFromSeed(seed)
	if got := hex.EncodeToString(priv.Public().(ed25519.PublicKey)); got != vectorCAPubHex {
		t.Fatalf("CA public key drifted: got %s want %s", got, vectorCAPubHex)
	}
	return priv
}

// mintTestCA self-signs a CA certificate for a test fixture. It mirrors what
// `emisar signing new-ca` issues, kept here so the attest package's tests do
// not depend on the CLI.
func mintTestCA(t *testing.T, key crypto.Signer, notBefore time.Time) (*x509.Certificate, []byte) {
	t.Helper()
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "vector-ca"},
		NotBefore:             notBefore,
		NotAfter:              notBefore.Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		t.Fatalf("mint CA: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse CA: %v", err)
	}
	return cert, der
}

// leafOptions are the knobs the negative suite turns to build a certificate
// that violates exactly one profile rule.
type leafOptions struct {
	scopeURIs []string // nil = the canonical vector scope
	isCA      bool
	keyUsage  x509.KeyUsage
	notBefore time.Time
	ttl       time.Duration
	issuer    *x509.Certificate
	issuerKey crypto.Signer
	leafPub   crypto.PublicKey
}

func mintTestLeaf(t *testing.T, opts leafOptions) []byte {
	t.Helper()
	uris := opts.scopeURIs
	if uris == nil {
		uris = []string{"emisar://dispatch/v1?group=edge&label.env=prod&label.region=us"}
	}
	parsed := make([]*url.URL, 0, len(uris))
	for _, raw := range uris {
		uri, err := url.Parse(raw)
		if err != nil {
			t.Fatalf("parse scope URI %q: %v", raw, err)
		}
		parsed = append(parsed, uri)
	}
	keyUsage := opts.keyUsage
	if keyUsage == 0 {
		keyUsage = x509.KeyUsageDigitalSignature
	}
	ttl := opts.ttl
	if ttl == 0 {
		ttl = 24 * time.Hour
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "vector-operator"},
		NotBefore:             opts.notBefore,
		NotAfter:              opts.notBefore.Add(ttl),
		KeyUsage:              keyUsage,
		BasicConstraintsValid: true,
		IsCA:                  opts.isCA,
		URIs:                  parsed,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, opts.issuer, opts.leafPub, opts.issuerKey)
	if err != nil {
		t.Fatalf("mint leaf: %v", err)
	}
	return der
}

// untrustedLeaf issues a well-formed certificate from a CA the runner does not
// trust — the distribution failure, distinct from a malformed one.
func untrustedLeaf(t *testing.T, leafPub crypto.PublicKey) []byte {
	t.Helper()
	_, otherKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate untrusted CA: %v", err)
	}
	otherCA, _ := mintTestCA(t, otherKey, vectorNotBefore)
	return mintTestLeaf(t, leafOptions{
		notBefore: vectorNotBefore, issuer: otherCA, issuerKey: otherKey, leafPub: leafPub,
	})
}

// vectorChain builds the fixture chain: the vector CA and a leaf for the
// vector signing key, both inside the frozen validity window.
func vectorChain(t *testing.T) (*x509.CertPool, []byte) {
	t.Helper()
	caKey := vectorCAKey(t)
	caCert, _ := mintTestCA(t, caKey, vectorNotBefore)
	_, leafPub := vectorKey(t)
	leafDER := mintTestLeaf(t, leafOptions{
		notBefore: vectorNotBefore, issuer: caCert, issuerKey: caKey, leafPub: leafPub,
	})
	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	return roots, leafDER
}

func vectorEnvelope(t *testing.T) Envelope {
	t.Helper()
	vector := vectorClaims()[1]
	argsDigest, err := ArgsSHA256(vector.claim.ArgsRaw)
	if err != nil {
		t.Fatalf("ArgsSHA256: %v", err)
	}
	_, leafDER := vectorChain(t)
	runnerRefs, err := CanonicalRunnerRefs(vector.claim.RunnerRefs)
	if err != nil {
		t.Fatalf("CanonicalRunnerRefs: %v", err)
	}
	return Envelope{
		Version: Version, Tool: Tool, PortalOrigin: vector.claim.PortalOrigin,
		ActionID: vector.claim.ActionID, PackRef: vector.claim.PackRef,
		ArgsSHA256: argsDigest, RunnerRefs: runnerRefs,
		Reason:         vector.claim.Reason,
		EvidenceSHA256: TextSHA256(vector.claim.Evidence),
		ExpectedSHA256: TextSHA256(vector.claim.Expected),
		OperationID:    vector.claim.OperationID,
		Signature:      vector.sig, Nonce: vector.claim.Nonce, IssuedAt: vector.claim.IssuedAt,
		CertChain: []string{base64.StdEncoding.EncodeToString(leafDER)},
	}
}

func TestEnvelopeWireVector(t *testing.T) {
	raw, err := json.Marshal(vectorEnvelope(t))
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	var decoded Envelope
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("unmarshal envelope: %v", err)
	}
	if len(decoded.CertChain) != 1 || len(decoded.RunnerRefs) != 2 {
		t.Fatalf("decoded envelope lost signed fields: %+v", decoded)
	}
	// The chain travels as base64 DER, and its digest is frozen: both
	// implementations must build the same certificate bytes from the same
	// inputs, exactly as they must for the claim vectors above.
	leafDER, err := base64.StdEncoding.DecodeString(decoded.CertChain[0])
	if err != nil {
		t.Fatalf("decode cert chain: %v", err)
	}
	digest := sha256.Sum256(leafDER)
	if got := hex.EncodeToString(digest[:]); got != vectorLeafDERSHA256 {
		t.Fatalf("vector certificate DER drifted:\n got %s\nwant %s", got, vectorLeafDERSHA256)
	}
	// The narrative digests are the v5 addition, and an EMPTY one is not the
	// same as the digest of an empty string: the portal requires 64 lower-hex,
	// so a blank here would be an envelope it refuses.
	for name, digest := range map[string]string{
		"evidence_sha256": decoded.EvidenceSHA256,
		"expected_sha256": decoded.ExpectedSHA256,
	} {
		if len(digest) != 64 {
			t.Fatalf("%s is %q, want a 64-character digest", name, digest)
		}
	}
	if decoded.EvidenceSHA256 == decoded.ExpectedSHA256 {
		t.Fatal("vector should carry DIFFERENT evidence and expected, or a field swap passes")
	}
}

func TestCertVectors(t *testing.T) {
	roots, leafDER := vectorChain(t)
	now := vectorNotBefore.Add(time.Hour)

	leaf, scope, err := VerifyChain(roots, [][]byte{leafDER}, now)
	if err != nil {
		t.Fatalf("VerifyChain: %v", err)
	}
	want := Scope{Group: "edge", Labels: map[string]string{"env": "prod", "region": "us"}}
	if scope.Group != want.Group || len(scope.Labels) != len(want.Labels) {
		t.Fatalf("scope = %+v, want %+v", scope, want)
	}
	for key, value := range want.Labels {
		if scope.Labels[key] != value {
			t.Fatalf("scope label %q = %q, want %q", key, scope.Labels[key], value)
		}
	}

	// The claim signature verifies under the certified leaf key, and a tampered
	// claim does not.
	priv, _ := vectorKey(t)
	vector := vectorClaims()[1]
	sig, err := SignClaim(priv, vector.claim)
	if err != nil {
		t.Fatalf("SignClaim: %v", err)
	}
	if sig != vector.sig {
		t.Fatalf("SignClaim drifted from the frozen vector:\n got %s\nwant %s", sig, vector.sig)
	}
	ok, err := VerifyClaim(leaf, vector.claim, sig)
	if err != nil || !ok {
		t.Fatalf("VerifyClaim = %v, %v; want true", ok, err)
	}
	tampered := vector.claim
	tampered.Reason = "something else"
	ok, err = VerifyClaim(leaf, tampered, sig)
	if err != nil {
		t.Fatalf("VerifyClaim(tampered): %v", err)
	}
	if ok {
		t.Fatal("a tampered claim verified")
	}
}

// TestScopeURICanonicalRoundTrip proves one scope has exactly one spelling.
func TestScopeURICanonicalRoundTrip(t *testing.T) {
	for _, scope := range []Scope{
		{},
		{Group: "edge"},
		{Labels: map[string]string{"env": "prod"}},
		{Group: "edge", Labels: map[string]string{"env": "prod", "region": "us"}},
		// Free-form operator input: runner label keys and values are validated
		// nowhere in config, so the encoding must survive whatever they hold.
		{Group: "a b&c=d", Labels: map[string]string{"key with space": "v/a?l&ue", "ünïcode": "ok"}},
	} {
		encoded, err := EncodeScopeURI(scope)
		if err != nil {
			t.Fatalf("EncodeScopeURI(%+v): %v", scope, err)
		}
		parsed, err := ParseScopeURI(encoded)
		if err != nil {
			t.Fatalf("ParseScopeURI(%q): %v", encoded, err)
		}
		if parsed.Group != scope.Group || len(parsed.Labels) != len(scope.Labels) {
			t.Fatalf("round trip lost data: %+v -> %q -> %+v", scope, encoded, parsed)
		}
		for key, value := range scope.Labels {
			if parsed.Labels[key] != value {
				t.Fatalf("round trip lost label %q: %+v -> %q -> %+v", key, scope, encoded, parsed)
			}
		}
	}
}

func TestParseScopeURIRejectsNonCanonical(t *testing.T) {
	for name, raw := range map[string]string{
		"unsorted params":      "emisar://dispatch/v1?label.region=us&group=edge",
		"lowercase hex":        "emisar://dispatch/v1?group=a%2eb",
		"over-encoded":         "emisar://dispatch/v1?group=%65dge",
		"duplicate group":      "emisar://dispatch/v1?group=a&group=b",
		"duplicate label":      "emisar://dispatch/v1?label.env=a&label.env=b",
		"unknown parameter":    "emisar://dispatch/v1?tenant=acme",
		"empty query":          "emisar://dispatch/v1?",
		"wrong base":           "emisar://dispatch/v2?group=edge",
		"parameter with no =":  "emisar://dispatch/v1?group",
		"raw unencoded byte":   "emisar://dispatch/v1?group=a b",
		"empty group value":    "emisar://dispatch/v1?group=",
		"truncated encoding":   "emisar://dispatch/v1?group=a%2",
		"invalid hex encoding": "emisar://dispatch/v1?group=a%zz",
	} {
		if _, err := ParseScopeURI(raw); err == nil {
			t.Errorf("%s: ParseScopeURI(%q) accepted a non-canonical scope", name, raw)
		}
	}
}

// TestVerifyChainRejectsProfileViolations is the security core of the X.509
// switch: a certificate reaches dispatch-signing authority only by satisfying
// every profile rule, so a general-purpose CA in the same trust store cannot
// vouch for infrastructure execution.
func TestVerifyChainRejectsProfileViolations(t *testing.T) {
	caKey := vectorCAKey(t)
	caCert, _ := mintTestCA(t, caKey, vectorNotBefore)
	_, leafPub := vectorKey(t)
	roots := x509.NewCertPool()
	roots.AddCert(caCert)
	now := vectorNotBefore.Add(time.Hour)
	base := leafOptions{notBefore: vectorNotBefore, issuer: caCert, issuerKey: caKey, leafPub: leafPub}

	withOptions := func(mutate func(*leafOptions)) []byte {
		opts := base
		mutate(&opts)
		return mintTestLeaf(t, opts)
	}

	// A TLS server certificate from the SAME trusted CA: no emisar SAN, so it
	// carries no dispatch authority. This is the case the profile exists for.
	tlsShaped := withOptions(func(o *leafOptions) { o.scopeURIs = []string{} })
	twoScopes := withOptions(func(o *leafOptions) {
		o.scopeURIs = []string{
			"emisar://dispatch/v1?group=edge",
			"emisar://dispatch/v1?group=prod",
		}
	})
	caLeaf := withOptions(func(o *leafOptions) { o.isCA = true })
	wrongUsage := withOptions(func(o *leafOptions) { o.keyUsage = x509.KeyUsageKeyEncipherment })
	nonCanonical := withOptions(func(o *leafOptions) {
		o.scopeURIs = []string{"emisar://dispatch/v1?label.env=prod&group=edge"}
	})
	expired := withOptions(func(o *leafOptions) { o.ttl = 30 * time.Minute })

	for name, testCase := range map[string]struct {
		chain [][]byte
		code  string
	}{
		"no emisar SAN (a TLS-shaped certificate)": {[][]byte{tlsShaped}, CodeCertProfile},
		"several emisar SANs":                      {[][]byte{twoScopes}, CodeCertProfile},
		"CA certificate used as a leaf":            {[][]byte{caLeaf}, CodeCertProfile},
		"key usage without digital signature":      {[][]byte{wrongUsage}, CodeCertProfile},
		"non-canonical scope URI":                  {[][]byte{nonCanonical}, CodeCertProfile},
		"chain deeper than one intermediate": {
			[][]byte{withOptions(func(*leafOptions) {}), caCert.Raw, caCert.Raw}, CodeCertProfile,
		},
		"empty chain":         {[][]byte{}, CodeCertProfile},
		"malformed DER":       {[][]byte{[]byte("not a certificate")}, CodeCertProfile},
		"expired certificate": {[][]byte{expired}, CodeCertExpired},
		"untrusted issuer":    {[][]byte{untrustedLeaf(t, leafPub)}, CodeCertUntrusted},
	} {
		_, _, err := VerifyChain(roots, testCase.chain, now)
		if err == nil {
			t.Errorf("%s: VerifyChain accepted the certificate", name)
			continue
		}
		var certErr *CertError
		if !errors.As(err, &certErr) {
			t.Errorf("%s: error %v is not a *CertError", name, err)
			continue
		}
		if certErr.Code != testCase.code {
			t.Errorf("%s: code = %s, want %s (%s)", name, certErr.Code, testCase.code, certErr.Reason)
		}
	}
}

// TestVerifyChainAcceptsP256Leaf proves the KMS-friendly algorithm works end to
// end: a P-256 leaf issues, verifies, and signs a claim.
func TestVerifyChainAcceptsP256Leaf(t *testing.T) {
	caKey := vectorCAKey(t)
	caCert, _ := mintTestCA(t, caKey, vectorNotBefore)
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate P-256 key: %v", err)
	}
	leafDER := mintTestLeaf(t, leafOptions{
		notBefore: vectorNotBefore, issuer: caCert, issuerKey: caKey, leafPub: leafKey.Public(),
	})
	roots := x509.NewCertPool()
	roots.AddCert(caCert)

	leaf, _, err := VerifyChain(roots, [][]byte{leafDER}, vectorNotBefore.Add(time.Hour))
	if err != nil {
		t.Fatalf("VerifyChain(P-256): %v", err)
	}
	claim := vectorClaims()[0].claim
	sig, err := SignClaim(leafKey, claim)
	if err != nil {
		t.Fatalf("SignClaim(P-256): %v", err)
	}
	ok, err := VerifyClaim(leaf, claim, sig)
	if err != nil || !ok {
		t.Fatalf("VerifyClaim(P-256) = %v, %v; want true", ok, err)
	}
}

// TestScopeMatches covers the runner-side ceiling: an empty scope matches any
// runner, a group must match exactly, and labels are a subset test.
func TestScopeMatches(t *testing.T) {
	labels := map[string]string{"env": "prod", "region": "us"}
	for name, testCase := range map[string]struct {
		scope Scope
		want  bool
	}{
		"empty scope matches":        {Scope{}, true},
		"exact group matches":        {Scope{Group: "edge"}, true},
		"other group does not":       {Scope{Group: "core"}, false},
		"label subset matches":       {Scope{Labels: map[string]string{"env": "prod"}}, true},
		"wrong label value does not": {Scope{Labels: map[string]string{"env": "staging"}}, false},
		"absent label does not":      {Scope{Labels: map[string]string{"tier": "1"}}, false},
	} {
		if got := testCase.scope.Matches("edge", labels); got != testCase.want {
			t.Errorf("%s: Matches = %v, want %v", name, got, testCase.want)
		}
	}
}
