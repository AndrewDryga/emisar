package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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

func certJSONFor(t *testing.T, leafSeedHex string) string {
	t.Helper()
	seed, err := hex.DecodeString(leafSeedHex)
	if err != nil {
		t.Fatalf("decode leaf seed: %v", err)
	}
	leafPub := hex.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	caSeed, err := hex.DecodeString(testCASeedHex)
	if err != nil {
		t.Fatalf("decode CA seed: %v", err)
	}
	cert := attest.Cert{
		CAID:       "ca-test",
		KeyID:      "operator",
		PublicKey:  leafPub,
		ValidFrom:  "2026-01-01T00:00:00Z",
		ValidUntil: "2030-01-01T00:00:00Z",
		Serial:     "01MCPSIGNTEST00000000000000",
	}
	cert.Sig, err = attest.SignCert(ed25519.NewKeyFromSeed(caSeed), cert)
	if err != nil {
		t.Fatalf("sign cert: %v", err)
	}
	encoded, err := json.Marshal(cert)
	if err != nil {
		t.Fatalf("marshal cert: %v", err)
	}
	return string(encoded)
}

func testSigner(t *testing.T) (*signer, ed25519.PublicKey) {
	t.Helper()
	signer, err := newSigner(testSeedHex, certJSONFor(t, testSeedHex))
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	return signer, signer.priv.Public().(ed25519.PublicKey)
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
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":%q,"pack_ref":%q,"contract_ref":"receipt.payload.signature","runner_refs":%s,"args":%s,"reason":"planned maintenance","wait":"60s"}}}`,
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
	cert := certJSONFor(t, testSeedHex)
	var oversizedCert attest.Cert
	if err := json.Unmarshal([]byte(cert), &oversizedCert); err != nil {
		t.Fatal(err)
	}
	oversizedCert.Scope.Labels = map[string]string{"oversized": strings.Repeat("a", maxSigningCertBytes)}
	oversizedCertJSON, err := json.Marshal(oversizedCert)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		key  string
		cert string
	}{
		{name: "key only", key: testSeedHex},
		{name: "cert only", cert: cert},
		{name: "invalid hex", key: "zz", cert: cert},
		{name: "short seed", key: "00", cert: cert},
		{name: "invalid cert JSON", key: testSeedHex, cert: "{"},
		{name: "duplicate cert field", key: testSeedHex, cert: strings.Replace(cert, `"ca_id":"ca-test"`, `"ca_id":"ca-test","ca_id":"other"`, 1)},
		{name: "case alias cert field", key: testSeedHex, cert: strings.Replace(cert, `"ca_id":"ca-test"`, `"ca_id":"ca-test","CA_ID":"other"`, 1)},
		{name: "unknown cert field", key: testSeedHex, cert: strings.TrimSuffix(cert, "}") + `,"unknown":true}`},
		{name: "oversized cert", key: testSeedHex, cert: string(oversizedCertJSON)},
		{name: "mismatched key", key: "1102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20", cert: cert},
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
	if signer, err := newSigner(testSeedHex, cert); err != nil || signer == nil {
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
	if envelope.Cert == nil || envelope.Cert.PublicKey != hex.EncodeToString(publicKey) {
		t.Fatalf("attestation cert = %#v, want leaf public key", envelope.Cert)
	}
	encodedEnvelope, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encodedEnvelope, []byte("contract_ref")) || bytes.Contains(encodedEnvelope, []byte("receipt.payload.signature")) {
		t.Fatal("contract_ref leaked into the action attestation")
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
	valid, err := attest.Verify(publicKey, claim, envelope.Signature)
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
	validPrefix := fmt.Sprintf(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_action","arguments":{"action_id":%q,"pack_ref":%q,"contract_ref":"receipt.payload.signature","runner_refs":%s,`, testActionID, testPackRef, validRefs)
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
	overlongReason := strings.Replace(string(runActionFrame(`{}`, []string{testRunnerRefA})), "planned maintenance", strings.Repeat("r", 256), 1)
	if header, err := signer.signFrame([]byte(overlongReason), testOperationID, testPortalOrigin); err != nil || header != "" {
		t.Fatal("oversized reason was signed")
	}
}

func TestSignFrameMaximumSupportedEnvelopeFitsPortalHeader(t *testing.T) {
	signer, _ := testSigner(t)
	largeSigner := *signer
	largeCert := *signer.cert
	largeCert.Scope.Labels = map[string]string{"scope": strings.Repeat("s", maxSigningCertBytes-700)}
	encodedCert, err := json.Marshal(largeCert)
	if err != nil {
		t.Fatal(err)
	}
	if len(encodedCert) > maxSigningCertBytes {
		t.Fatalf("test certificate = %d bytes, budget %d", len(encodedCert), maxSigningCertBytes)
	}
	largeSigner.cert = &largeCert

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
	frame = strings.Replace(frame, testPackRef, strings.Repeat("p", 256), 1)
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
	largeCert := *signer.cert
	largeCert.Scope.Labels = map[string]string{"oversized": strings.Repeat("a", maxAttestationHeaderBytes)}
	largeSigner.cert = &largeCert
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
