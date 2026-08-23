package main

import (
	"bytes"
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const (
	testSeedHex      = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	testCASeedHex    = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
	testOperationID  = "op_01J0D82T8E7Q6A8W3M2YQH9C5V"
	testPortalOrigin = "https://emisar.example"
	testActionID     = "cockroach.pause_job"
	testPackRef      = "cockroach@1.4.0/sha256:7a65c099fe1d3c8d2b250d211d4792ec1e3919b87f49ffb998ee6e4366b4b6fe"
	testRunnerRefA   = "roach-a~0123456789abcdef0123456789abcdef"
	testRunnerRefB   = "roach-b~fedcba9876543210fedcba9876543210"
)

// signingPairFor builds the two env-var values the bridge reads: a base64
// PKCS#8 leaf key and a base64 PEM chain, issued by the fixed test CA.
func signingPairFor(t *testing.T, leafSeedHex string) (keyEncoded, certEncoded string) {
	t.Helper()
	seed, err := hex.DecodeString(leafSeedHex)
	if err != nil {
		t.Fatalf("decode leaf seed: %v", err)
	}
	leafKey := ed25519.NewKeyFromSeed(seed)
	return encodeTestKey(t, leafKey), encodeTestChain(t, testCAChain(t, leafKey.Public(), nil))
}

func encodeTestKey(t *testing.T, key crypto.Signer) string {
	t.Helper()
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatalf("marshal key: %v", err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func encodeTestChain(t *testing.T, chain [][]byte) string {
	t.Helper()
	var pemText strings.Builder
	for _, der := range chain {
		pemText.Write(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	}
	return base64.StdEncoding.EncodeToString([]byte(pemText.String()))
}

// testCAChain issues a leaf from the fixed test CA. scopeURIs nil means the
// canonical any-runner scope; pass a slice to build a profile violation.
func testCAChain(t *testing.T, leafPub crypto.PublicKey, scopeURIs []string) [][]byte {
	t.Helper()
	caSeed, err := hex.DecodeString(testCASeedHex)
	if err != nil {
		t.Fatalf("decode CA seed: %v", err)
	}
	caKey := ed25519.NewKeyFromSeed(caSeed)
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "ca-test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, caKey.Public(), caKey)
	if err != nil {
		t.Fatalf("mint CA: %v", err)
	}
	caCert, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatalf("parse CA: %v", err)
	}
	if scopeURIs == nil {
		scopeURI, err := attest.EncodeScopeURI(attest.Scope{})
		if err != nil {
			t.Fatalf("EncodeScopeURI: %v", err)
		}
		scopeURIs = []string{scopeURI}
	}
	parsed := make([]*url.URL, 0, len(scopeURIs))
	for _, raw := range scopeURIs {
		uri, err := url.Parse(raw)
		if err != nil {
			t.Fatalf("parse scope URI: %v", err)
		}
		parsed = append(parsed, uri)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "operator"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		URIs:                  parsed,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, caCert, leafPub, caKey)
	if err != nil {
		t.Fatalf("mint leaf: %v", err)
	}
	return [][]byte{leafDER}
}

func testSigner(t *testing.T) (*signer, ed25519.PublicKey) {
	t.Helper()
	key, cert := signingPairFor(t, testSeedHex)
	signer, err := newSigner(key, cert)
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	return signer, signer.key.Public().(ed25519.PublicKey)
}

func decodeAttestationHeader(raw string) (attest.Envelope, error) {
	if raw == "" || len(raw) > maxAttestationHeaderBytes {
		return attest.Envelope{}, fmt.Errorf("attestation header size is outside 1..%d bytes", maxAttestationHeaderBytes)
	}
	encoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return attest.Envelope{}, fmt.Errorf("decode attestation header: %w", err)
	}
	if err := validateStrictJSON(encoded); err != nil {
		return attest.Envelope{}, fmt.Errorf("decode attestation JSON: %w", err)
	}
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.DisallowUnknownFields()
	var envelope attest.Envelope
	if err := decoder.Decode(&envelope); err != nil {
		return attest.Envelope{}, fmt.Errorf("decode attestation object: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return attest.Envelope{}, fmt.Errorf("decode attestation object: %w", err)
	}
	return envelope, nil
}

func runActionFrame(args string, runnerRefs []string) []byte {
	refs, err := json.Marshal(runnerRefs)
	if err != nil {
		panic(err)
	}
	return []byte(fmt.Sprintf(
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":%q,"pack_ref":%q,"runner_refs":%s,"args":%s,"reason":"planned maintenance","wait":"60s"}}}`,
		testActionID, testPackRef, refs, args,
	))
}

func mustSignFrame(t *testing.T, signer *signer, frame []byte, operationID, portalOrigin string) string {
	t.Helper()
	header, err := signer.signFrame(frame, operationID, portalOrigin)
	if err != nil {
		t.Fatalf("signFrame: %v", err)
	}
	if header == "" {
		t.Fatal("valid run_action was not signed")
	}
	return header
}

func TestNewSignerRequiresOneStrictMatchingPair(t *testing.T) {
	key, cert := signingPairFor(t, testSeedHex)
	otherKey, _ := signingPairFor(t, "1102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")

	// A certificate with no emisar scope SAN is a TLS-shaped certificate: it
	// would be refused by every enforcing runner, so the bridge refuses it at
	// startup where the operator can still act on it.
	seed, err := hex.DecodeString(testSeedHex)
	if err != nil {
		t.Fatal(err)
	}
	leafKey := ed25519.NewKeyFromSeed(seed)
	noScopeCert := encodeTestChain(t, testCAChain(t, leafKey.Public(), []string{}))

	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	rsaDER, err := x509.MarshalPKCS8PrivateKey(rsaKey)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name string
		key  string
		cert string
	}{
		{name: "key only", key: key},
		{name: "cert only", cert: cert},
		{name: "key not base64", key: "!!", cert: cert},
		{name: "key not PKCS#8", key: base64.StdEncoding.EncodeToString([]byte("nope")), cert: cert},
		{name: "RSA key", key: base64.StdEncoding.EncodeToString(rsaDER), cert: cert},
		{name: "cert not base64", key: key, cert: "!!"},
		{name: "cert not PEM", key: key, cert: base64.StdEncoding.EncodeToString([]byte("nope"))},
		{name: "certificate without an emisar scope", key: key, cert: noScopeCert},
		{name: "mismatched key", key: otherKey, cert: cert},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := newSigner(test.key, test.cert); err == nil {
				t.Fatal("newSigner accepted invalid configuration")
			}
		})
	}

	if signer, err := newSigner("", ""); err != nil || signer != nil {
		t.Fatalf("empty pair should disable signing: signer=%v err=%v", signer, err)
	}
	if signer, err := newSigner(key, cert); err != nil || signer == nil {
		t.Fatalf("valid pair rejected: signer=%v err=%v", signer, err)
	}
}

func TestSignFrameProducesExactRunnerVerifiableClaim(t *testing.T) {
	signer, publicKey := testSigner(t)
	args := `{ "job_id" : 9007199254740993, "ratio": 1.2300e+4 }`
	frame := runActionFrame(args, []string{testRunnerRefB, testRunnerRefA})
	original := append([]byte(nil), frame...)

	header := mustSignFrame(t, signer, frame, testOperationID, testPortalOrigin)
	if !bytes.Equal(frame, original) {
		t.Fatalf("signFrame changed the public request:\n got %s\nwant %s", frame, original)
	}
	envelope, err := decodeAttestationHeader(header)
	if err != nil {
		t.Fatalf("decode header: %v", err)
	}

	if envelope.Version != attest.Version || envelope.Tool != attest.Tool ||
		envelope.PortalOrigin != testPortalOrigin || envelope.ActionID != testActionID ||
		envelope.PackRef != testPackRef || envelope.Reason != "planned maintenance" ||
		envelope.OperationID != testOperationID {
		t.Fatalf("attestation facts changed: %#v", envelope)
	}
	wantArgsDigest, err := attest.ArgsSHA256(json.RawMessage(args))
	if err != nil {
		t.Fatal(err)
	}
	if envelope.ArgsSHA256 != wantArgsDigest {
		t.Fatalf("args digest = %q, want %q", envelope.ArgsSHA256, wantArgsDigest)
	}
	if want := []string{testRunnerRefA, testRunnerRefB}; !slices.Equal(envelope.RunnerRefs, want) {
		t.Fatalf("runner refs = %v, want %v", envelope.RunnerRefs, want)
	}
	// The chain must carry the leaf whose key signed — that pairing is what a
	// runner resolves the verification key from.
	if len(envelope.CertChain) != 1 {
		t.Fatalf("attestation chain = %v, want one certificate", envelope.CertChain)
	}
	leafDER, err := base64.StdEncoding.DecodeString(envelope.CertChain[0])
	if err != nil {
		t.Fatalf("decode attestation chain: %v", err)
	}
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatalf("parse attestation leaf: %v", err)
	}
	if !leaf.PublicKey.(ed25519.PublicKey).Equal(publicKey) {
		t.Fatal("the attestation certificate does not carry the signing key")
	}
	claim := attest.Claim{
		ActionID:     envelope.ActionID,
		PackRef:      envelope.PackRef,
		ArgsRaw:      json.RawMessage(args),
		RunnerRefs:   envelope.RunnerRefs,
		Reason:       envelope.Reason,
		OperationID:  envelope.OperationID,
		PortalOrigin: envelope.PortalOrigin,
		Nonce:        envelope.Nonce,
		IssuedAt:     envelope.IssuedAt,
	}
	valid, err := attest.VerifyClaim(leaf, claim, envelope.Signature)
	if err != nil || !valid {
		t.Fatalf("runner reconstruction did not verify: valid=%v err=%v", valid, err)
	}
}

func TestSignFrameBindsExactRawArguments(t *testing.T) {
	signer, publicKey := testSigner(t)
	args := `{ "job_id":9007199254740993,"amount":1.000e+3 }`
	header := mustSignFrame(t, signer, runActionFrame(args, []string{testRunnerRefA}), testOperationID, testPortalOrigin)
	envelope, err := decodeAttestationHeader(header)
	if err != nil {
		t.Fatal(err)
	}

	base := attest.Claim{
		ActionID:     envelope.ActionID,
		PackRef:      envelope.PackRef,
		RunnerRefs:   envelope.RunnerRefs,
		Reason:       envelope.Reason,
		OperationID:  envelope.OperationID,
		PortalOrigin: envelope.PortalOrigin,
		Nonce:        envelope.Nonce,
		IssuedAt:     envelope.IssuedAt,
	}
	base.ArgsRaw = json.RawMessage(args)
	if valid, err := attest.Verify(publicKey, base, envelope.Signature); err != nil || !valid {
		t.Fatalf("exact args did not verify: valid=%v err=%v", valid, err)
	}
	for _, changed := range []string{
		`{"job_id":9007199254740993,"amount":1.000e+3}`,
		`{ "job_id":9007199254740992,"amount":1.000e+3 }`,
		`{ "job_id":9007199254740993,"amount":1000 }`,
	} {
		base.ArgsRaw = json.RawMessage(changed)
		if valid, err := attest.Verify(publicKey, base, envelope.Signature); err != nil || valid {
			t.Errorf("changed args verified: %s (valid=%v err=%v)", changed, valid, err)
		}
	}
}

func TestSignFrameOnlySignsWellFormedRunAction(t *testing.T) {
	signer, _ := testSigner(t)
	validRefs, _ := json.Marshal([]string{testRunnerRefA})
	validPrefix := fmt.Sprintf(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":%q,"pack_ref":%q,"runner_refs":%s,`, testActionID, testPackRef, validRefs)
	tests := []struct {
		name      string
		frame     string
		operation string
		origin    string
		wantError bool
	}{
		{name: "read", frame: `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_action","arguments":{}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "draft mutation", frame: `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_runbook_draft","arguments":{}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "method alias only", frame: `{"jsonrpc":"2.0","id":1,"METHOD":"tools/call","params":{"name":"run_action","arguments":{}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "name alias only", frame: `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"NAME":"run_action","arguments":{}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "missing args", frame: validPrefix + `"reason":"maintenance"}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "args alias only", frame: validPrefix + `"ARGS":{},"reason":"maintenance"}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "nonobject args", frame: validPrefix + `"args":7,"reason":"maintenance"}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "duplicate nested key", frame: validPrefix + `"args":{"x":1,"x":2},"reason":"maintenance"}}}`, operation: testOperationID, origin: testPortalOrigin},
		{name: "missing action", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), testActionID, "", 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "action alias only", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), `"action_id"`, `"ACTION_ID"`, 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "oversized action", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), testActionID, strings.Repeat("a", 129), 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "missing pack", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), testPackRef, "", 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "pack alias only", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), `"pack_ref"`, `"PACK_REF"`, 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "oversized pack", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), testPackRef, strings.Repeat("p", 257), 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "no targets", frame: string(runActionFrame(`{}`, nil)), operation: testOperationID, origin: testPortalOrigin},
		{name: "targets alias only", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), `"runner_refs"`, `"RUNNER_REFS"`, 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "duplicate targets", frame: string(runActionFrame(`{}`, []string{testRunnerRefA, testRunnerRefA})), operation: testOperationID, origin: testPortalOrigin},
		{name: "empty target", frame: string(runActionFrame(`{}`, []string{""})), operation: testOperationID, origin: testPortalOrigin},
		{name: "oversized target", frame: string(runActionFrame(`{}`, []string{strings.Repeat("r", attest.MaxRunnerRefBytes+1)})), operation: testOperationID, origin: testPortalOrigin},
		{name: "whitespace reason", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), "planned maintenance", "  ", 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "reason alias only", frame: strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), `"reason"`, `"REASON"`, 1), operation: testOperationID, origin: testPortalOrigin},
		{name: "bad operation", frame: string(runActionFrame(`{}`, []string{testRunnerRefA})), operation: "model-supplied", origin: testPortalOrigin, wantError: true},
		{name: "missing origin", frame: string(runActionFrame(`{}`, []string{testRunnerRefA})), operation: testOperationID, wantError: true},
		{name: "non-origin URL", frame: string(runActionFrame(`{}`, []string{testRunnerRefA})), operation: testOperationID, origin: testPortalOrigin + "/api/mcp/rpc", wantError: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			frame := []byte(test.frame)
			original := append([]byte(nil), frame...)
			header, err := signer.signFrame(frame, test.operation, test.origin)
			if (err != nil) != test.wantError {
				t.Fatalf("signFrame error = %v, wantError %v", err, test.wantError)
			}
			if header != "" {
				t.Fatalf("invalid/non-action frame received attestation %q", header)
			}
			if !bytes.Equal(frame, original) {
				t.Fatal("rejected frame was modified")
			}
		})
	}
}

func TestSignFrameTargetAndReasonBoundaries(t *testing.T) {
	signer, _ := testSigner(t)
	refs := make([]string, attest.MaxRunnerRefs)
	for i := range refs {
		refs[i] = fmt.Sprintf("runner-%02d~%032x", i, i+1)
	}
	frame := strings.Replace(string(runActionFrame(`{}`, refs)), "planned maintenance", strings.Repeat("r", 255), 1)
	header := mustSignFrame(t, signer, []byte(frame), testOperationID, testPortalOrigin)
	if len(header) > maxAttestationHeaderBytes {
		t.Fatalf("boundary header = %d bytes, limit %d", len(header), maxAttestationHeaderBytes)
	}

	tooMany := append(append([]string(nil), refs...), "runner-16~ffffffffffffffffffffffffffffffff")
	if header, err := signer.signFrame(runActionFrame(`{}`, tooMany), testOperationID, testPortalOrigin); err != nil || header != "" {
		t.Fatal("oversized target set was signed")
	}
	// The schema allows 2000 characters, so a reason of ordinary length must
	// still be SIGNED. A bound narrower than the schema silently forwarded a
	// valid run_action unsigned.
	schemaMaxReason := strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), "planned maintenance", strings.Repeat("r", maxSignedReasonRunes), 1)
	if header := mustSignFrame(t, signer, []byte(schemaMaxReason), testOperationID, testPortalOrigin); header == "" {
		t.Fatal("schema-maximum reason was not signed")
	}

	// Counted in runes, not bytes: a multi-byte reason well inside the schema
	// bound must not fall off the signing path.
	multibyte := strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), "planned maintenance", strings.Repeat("残", 300), 1)
	if header := mustSignFrame(t, signer, []byte(multibyte), testOperationID, testPortalOrigin); header == "" {
		t.Fatal("multi-byte reason inside the schema bound was not signed")
	}

	// Past the schema bound the portal owns the error, so the frame is
	// forwarded unsigned rather than signed over input it would reject.
	overlongReason := strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), "planned maintenance", strings.Repeat("r", maxSignedReasonRunes+1), 1)
	if header, err := signer.signFrame([]byte(overlongReason), testOperationID, testPortalOrigin); err != nil || header != "" {
		t.Fatal("schema-invalid reason was signed")
	}
}

// An envelope that cannot fit the portal's header budget must fail CLOSED —
// a local error, never a silent unsigned dispatch.
func TestSignFrameOverBudgetEnvelopeFailsClosed(t *testing.T) {
	signer, _ := testSigner(t)
	largeSigner := *signer
	// A chain past the header budget: the envelope built around it cannot fit,
	// so signing must error rather than emit a header the portal rejects.
	largeSigner.certChain = []string{strings.Repeat("A", maxAttestationHeaderBytes)}

	refs := make([]string, attest.MaxRunnerRefs)
	for i := range refs {
		name := fmt.Sprintf("runner-%02d-", i) + strings.Repeat("r", 70)
		refs[i] = name + "~" + fmt.Sprintf("%032x", i+1)
	}
	frame := strings.Replace(string(runActionFrame(`{}`, refs)), "planned maintenance", strings.Repeat("r", maxSignedReasonRunes), 1)

	header, err := largeSigner.signFrame([]byte(frame), testOperationID, testPortalOrigin)
	if err == nil {
		t.Fatal("over-budget envelope did not fail closed")
	}
	if header != "" {
		t.Fatal("over-budget envelope returned a header")
	}
	if !strings.Contains(err.Error(), "limit is") {
		t.Fatalf("error = %v, want the header budget", err)
	}
}

func TestSignFrameMaximumSupportedEnvelopeFitsPortalHeader(t *testing.T) {
	signer, _ := testSigner(t)
	largeSigner := *signer
	// A realistic worst-case certificate: a scope near the URI bound. The
	// envelope built around it plus a full 16-runner target set must still fit
	// the portal's header budget.
	seed, err := hex.DecodeString(testSeedHex)
	if err != nil {
		t.Fatal(err)
	}
	leafKey := ed25519.NewKeyFromSeed(seed)
	scopeURI, err := attest.EncodeScopeURI(attest.Scope{
		Labels: map[string]string{"scope": strings.Repeat("s", 300)},
	})
	if err != nil {
		t.Fatal(err)
	}
	largeChain := testCAChain(t, leafKey.Public(), []string{scopeURI})
	largeSigner.certChain = []string{base64.StdEncoding.EncodeToString(largeChain[0])}

	refs := make([]string, attest.MaxRunnerRefs)
	for i := range refs {
		name := fmt.Sprintf("runner-%02d-", i) + strings.Repeat("r", 70)
		refs[i] = name + "~" + fmt.Sprintf("%032x", i+1)
		if len(refs[i]) != attest.MaxRunnerRefBytes {
			t.Fatalf("runner ref %d = %d bytes, want %d", i, len(refs[i]), attest.MaxRunnerRefBytes)
		}
	}
	frame := string(runActionFrame(`{}`, refs))
	frame = strings.Replace(frame, testActionID, strings.Repeat("a", 128), 1)
	frame = strings.Replace(frame, testPackRef, strings.Repeat("p", maxSignedPackRefBytes), 1)
	// A 255-character reason is the largest that still fits alongside a
	// maximum certificate and a full 16-runner target set. Longer reasons are
	// legal and signed on ordinary fan-outs; this pins the worst case that must
	// keep working, and TestSignFrameOverBudgetEnvelopeFailsClosed pins that
	// exceeding the budget errors instead of dispatching unsigned.
	frame = strings.Replace(frame, "planned maintenance", strings.Repeat("r", 255), 1)
	header := mustSignFrame(t, &largeSigner, []byte(frame), testOperationID, testPortalOrigin)
	if len(header) > maxAttestationHeaderBytes {
		t.Fatalf("header = %d bytes, limit %d", len(header), maxAttestationHeaderBytes)
	}
}

func TestSignFrameRejectsOversizedArgsAndHeader(t *testing.T) {
	signer, _ := testSigner(t)
	const objectOverhead = len(`{"value":""}`)
	oversizedArgs := `{"value":"` + strings.Repeat("a", maxRawActionArgsBytes-objectOverhead+1) + `"}`
	if header, err := signer.signFrame(runActionFrame(oversizedArgs, []string{testRunnerRefA}), testOperationID, testPortalOrigin); err != nil || header != "" {
		t.Fatal("oversized action args were signed")
	}

	largeSigner := *signer
	// A chain far past the header budget: the signer must fail closed rather
	// than emit a header the portal will reject.
	largeSigner.certChain = []string{strings.Repeat("A", maxAttestationHeaderBytes)}
	if header, err := largeSigner.signFrame(runActionFrame(`{}`, []string{testRunnerRefA}), testOperationID, testPortalOrigin); err == nil || header != "" {
		t.Fatalf("oversized attestation result = header %d bytes, error %v", len(header), err)
	}
}

func TestDecodeAttestationHeaderRejectsUnsafeEncodings(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{name: "empty"},
		{name: "oversized", raw: strings.Repeat("A", maxAttestationHeaderBytes+1)},
		{name: "invalid base64url", raw: "***"},
		{name: "padded", raw: base64.RawURLEncoding.EncodeToString([]byte(`{}`)) + "="},
		{name: "duplicate field", raw: base64.RawURLEncoding.EncodeToString([]byte(`{"version":"a","version":"b"}`))},
		{name: "unknown field", raw: base64.RawURLEncoding.EncodeToString([]byte(`{"unknown":true}`))},
		{name: "invalid UTF-8", raw: base64.RawURLEncoding.EncodeToString([]byte{0xff})},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := decodeAttestationHeader(test.raw); err == nil {
				t.Fatal("unsafe attestation header was accepted")
			}
		})
	}
}

func TestSignFrameNonceAndIssuedAtAreFreshUTC(t *testing.T) {
	signer, _ := testSigner(t)
	frame := runActionFrame(`{}`, []string{testRunnerRefA})
	first, err := decodeAttestationHeader(mustSignFrame(t, signer, frame, testOperationID, testPortalOrigin))
	if err != nil {
		t.Fatal(err)
	}
	second, err := decodeAttestationHeader(mustSignFrame(t, signer, frame, testOperationID, testPortalOrigin))
	if err != nil {
		t.Fatal(err)
	}
	if first.Nonce == second.Nonce || len(first.Nonce) != 32 {
		t.Fatalf("nonces are not fresh 128-bit hex: %q / %q", first.Nonce, second.Nonce)
	}
	issuedAt, err := time.Parse(time.RFC3339, first.IssuedAt)
	if err != nil || !strings.HasSuffix(first.IssuedAt, "Z") || issuedAt.Location() != time.UTC {
		t.Fatalf("issued_at is not RFC3339 UTC: %q (%v)", first.IssuedAt, err)
	}
}

func TestForwardCarriesPrivateActionAttestationWithoutChangingBody(t *testing.T) {
	signer, _ := testSigner(t)
	frame := runActionFrame(`{ "job_id":9007199254740993 }`, []string{testRunnerRefA})
	var gotBody []byte
	var gotAttestation, gotOperationID string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		gotBody, _ = io.ReadAll(request.Body)
		gotAttestation = request.Header.Get(attestationHeader)
		gotOperationID = request.Header.Get(operationIDHeader)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":7,"result":{}}`))
	}))
	defer srv.Close()
	b := newTestBridge(srv)
	b.signer = signer

	if _, err := b.forward(frame); err != nil {
		t.Fatalf("forward: %v", err)
	}
	if !bytes.Equal(gotBody, frame) {
		t.Fatalf("HTTP body changed while signing:\n got %s\nwant %s", gotBody, frame)
	}
	if gotAttestation == "" || gotOperationID == "" {
		t.Fatalf("private headers missing: attestation=%q operation=%q", gotAttestation, gotOperationID)
	}
	envelope, err := decodeAttestationHeader(gotAttestation)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.OperationID != gotOperationID || envelope.PortalOrigin != srv.URL {
		t.Fatalf("signed transport bindings = operation %q origin %q, want %q / %q", envelope.OperationID, envelope.PortalOrigin, gotOperationID, srv.URL)
	}
}

func TestForwardFailsLocallyWhenActionAttestationCannotBeCreated(t *testing.T) {
	signer, _ := testSigner(t)
	signer.newNonce = func() (string, error) {
		return "", errors.New("entropy unavailable")
	}
	portalCalled := false
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		portalCalled = true
	}))
	defer srv.Close()
	b := newTestBridge(srv)
	b.signer = signer

	_, err := b.forward(runActionFrame(`{}`, []string{testRunnerRefA}))
	if err == nil || !strings.Contains(err.Error(), "generate attestation nonce") {
		t.Fatalf("forward error = %v, want local nonce failure", err)
	}
	if portalCalled {
		t.Fatal("run_action reached the portal without its configured attestation")
	}
}

// A signing refusal never left this process, so the client frame must not carry
// an operation id: the MCP server instructions tell the model that a transport
// error with one means the mutation MAY have reached Emisar and should be
// recovered. Reporting one sent the model chasing an operation that does not
// exist, while the real cause appeared nowhere.
func TestSigningRefusalIsNotReportedAsALostMutation(t *testing.T) {
	signer, _ := testSigner(t)
	signer.newNonce = func() (string, error) { return "", errors.New("entropy unavailable") }
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Error("portal was contacted despite a local signing refusal")
	}))
	defer srv.Close()

	b := newTestBridge(srv)
	b.signer = signer
	var diagnostics bytes.Buffer
	b.diagnostics = &diagnostics

	frame := runActionFrame(`{}`, []string{testRunnerRefA})
	meta := parseRequestMeta(frame)

	var out bytes.Buffer
	_, forwardErr := b.forward(frame)
	if err := b.writeForwardResult(&out, meta, "op_334NN9NMDZ1T76NARWCKM5A0D7", nil, forwardErr); err != nil {
		t.Fatal(err)
	}

	if strings.Contains(out.String(), "operation_id") {
		t.Fatalf("client frame offered an operation to recover: %s", out.String())
	}
	if !strings.Contains(diagnostics.String(), "entropy unavailable") {
		t.Fatalf("the real cause never reached stderr: %q", diagnostics.String())
	}
}

func TestForwardNeverSignsReadsOrOtherMutations(t *testing.T) {
	signer, _ := testSigner(t)
	var headers []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		headers = append(headers, request.Header.Get(attestationHeader))
		var envelope struct {
			ID json.RawMessage `json:"id"`
		}
		_ = json.NewDecoder(request.Body).Decode(&envelope)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%s,"result":{}}`, envelope.ID)
	}))
	defer srv.Close()
	b := newTestBridge(srv)
	b.signer = signer

	frames := []string{
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_action","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_runbook_draft","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"execute_runbook","arguments":{}}}`,
	}
	for _, frame := range frames {
		if _, err := b.forward([]byte(frame)); err != nil {
			t.Fatalf("forward %s: %v", frame, err)
		}
	}
	for i, header := range headers {
		if header != "" {
			t.Errorf("non-action request %d received attestation %q", i, header)
		}
	}
}

// The approver-facing narrative is bound by digest, so a control plane relaying
// the call cannot change WHY an action appears to be running — the half of the
// decision a human actually reads, which v4 left unsigned.
func TestSignFrameBindsTheApproverNarrative(t *testing.T) {
	signer, publicKey := testSigner(t)
	refs, _ := json.Marshal([]string{testRunnerRefA})
	frame := []byte(fmt.Sprintf(
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":%q,"pack_ref":%q,"runner_refs":%s,"args":{},"reason":"planned maintenance","evidence":"p99 write latency 40s since 12:10Z","expected":"writes resume within 60s"}}}`,
		testActionID, testPackRef, refs,
	))

	header := mustSignFrame(t, signer, frame, testOperationID, testPortalOrigin)
	envelope, err := decodeAttestationHeader(header)
	if err != nil {
		t.Fatal(err)
	}

	if envelope.EvidenceSHA256 != attest.TextSHA256("p99 write latency 40s since 12:10Z") {
		t.Fatalf("evidence digest = %q", envelope.EvidenceSHA256)
	}
	if envelope.ExpectedSHA256 == envelope.EvidenceSHA256 {
		t.Fatal("evidence and expected must not share a digest here, or a swap passes")
	}

	claim := attest.Claim{
		ActionID:     envelope.ActionID,
		PackRef:      envelope.PackRef,
		ArgsRaw:      json.RawMessage(`{}`),
		RunnerRefs:   envelope.RunnerRefs,
		Reason:       envelope.Reason,
		Evidence:     "p99 write latency 40s since 12:10Z",
		Expected:     "writes resume within 60s",
		OperationID:  envelope.OperationID,
		PortalOrigin: envelope.PortalOrigin,
		Nonce:        envelope.Nonce,
		IssuedAt:     envelope.IssuedAt,
	}
	if valid, err := attest.Verify(publicKey, claim, envelope.Signature); err != nil || !valid {
		t.Fatalf("the signed narrative did not verify: valid=%v err=%v", valid, err)
	}

	// A rewritten narrative breaks the signature. This is the whole point.
	for _, altered := range []attest.Claim{
		func() attest.Claim { c := claim; c.Evidence = "routine, nothing unusual"; return c }(),
		func() attest.Claim { c := claim; c.Expected = "no impact at all"; return c }(),
		func() attest.Claim { c := claim; c.Evidence = ""; return c }(),
	} {
		if valid, _ := attest.Verify(publicKey, altered, envelope.Signature); valid {
			t.Error("a rewritten approver narrative still verified")
		}
	}
}

// An absent narrative is signed as the digest of the empty string, so a control
// plane cannot ADD a justification to a call that carried none.
func TestSignFrameBindsAnAbsentNarrative(t *testing.T) {
	signer, publicKey := testSigner(t)
	header := mustSignFrame(t, signer, runActionFrame(`{}`, []string{testRunnerRefA}), testOperationID, testPortalOrigin)
	envelope, err := decodeAttestationHeader(header)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.EvidenceSHA256 != attest.TextSHA256("") {
		t.Fatalf("an absent evidence must still hash, got %q", envelope.EvidenceSHA256)
	}

	invented := attest.Claim{
		ActionID: envelope.ActionID, PackRef: envelope.PackRef,
		ArgsRaw: json.RawMessage(`{}`), RunnerRefs: envelope.RunnerRefs,
		Reason: envelope.Reason, Evidence: "the operator asked for this",
		OperationID: envelope.OperationID, PortalOrigin: envelope.PortalOrigin,
		Nonce: envelope.Nonce, IssuedAt: envelope.IssuedAt,
	}
	if valid, _ := attest.Verify(publicKey, invented, envelope.Signature); valid {
		t.Error("evidence invented for an unjustified call still verified")
	}
}
