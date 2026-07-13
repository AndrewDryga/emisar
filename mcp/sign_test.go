package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const (
	testSeedHex   = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
	testCASeedHex = "2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40"
)

// certJSONFor mints a CA-signed cert vouching for the public key of leafSeedHex
// and returns it as the JSON the operator would set as EMISAR_SIGNING_CERT.
func certJSONFor(t *testing.T, leafSeedHex string) string {
	t.Helper()
	seed, err := hex.DecodeString(leafSeedHex)
	if err != nil {
		t.Fatalf("decode leaf seed: %v", err)
	}
	leafPub := hex.EncodeToString(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	caSeed, _ := hex.DecodeString(testCASeedHex)
	caPriv := ed25519.NewKeyFromSeed(caSeed)
	cert := attest.Cert{
		CAID: "ca-test", KeyID: "op", PublicKey: leafPub,
		ValidFrom: "2026-01-01T00:00:00Z", ValidUntil: "2030-01-01T00:00:00Z",
		Serial: "01MCPSIGNTEST00000000000000",
	}
	sig, err := attest.SignCert(caPriv, cert)
	if err != nil {
		t.Fatalf("SignCert: %v", err)
	}
	cert.Sig = sig
	b, err := json.Marshal(cert)
	if err != nil {
		t.Fatalf("marshal cert: %v", err)
	}
	return string(b)
}

func testSigner(t *testing.T) (*signer, ed25519.PublicKey) {
	t.Helper()
	s, err := newSigner(testSeedHex, certJSONFor(t, testSeedHex))
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	return s, s.priv.Public().(ed25519.PublicKey)
}

func TestNewSigner(t *testing.T) {
	cert := certJSONFor(t, testSeedHex)
	if s, err := newSigner("", ""); err != nil || s != nil {
		t.Fatalf("no key set should disable signing: signer=%v err=%v", s, err)
	}
	if _, err := newSigner(testSeedHex, ""); err == nil {
		t.Fatal("key without cert should error")
	}
	if _, err := newSigner("", cert); err == nil {
		t.Fatal("cert without key should error")
	}
	if _, err := newSigner("zz", cert); err == nil {
		t.Fatal("non-hex key should error")
	}
	if _, err := newSigner("00", cert); err == nil {
		t.Fatal("wrong-length key should error")
	}
	if _, err := newSigner(testSeedHex, "{not valid json"); err == nil {
		t.Fatal("unparseable cert should error")
	}
	// A cert that vouches for a DIFFERENT key than the seed is a config mismatch.
	otherCert := certJSONFor(t, "2102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	if _, err := newSigner(testSeedHex, otherCert); err == nil {
		t.Fatal("a cert for a different key than EMISAR_SIGNING_KEY should error")
	}
	if s, err := newSigner(testSeedHex, cert); err != nil || s == nil {
		t.Fatalf("valid key+cert should build a signer: %v", err)
	}
}

func TestSignFrameLeavesNonDispatchAlone(t *testing.T) {
	s, _ := testSigner(t)
	for _, frame := range []string{
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"arguments":{}}}`, // no name
		`not json`,
	} {
		if got := string(s.signFrame([]byte(frame))); got != frame {
			t.Fatalf("frame should be unchanged:\n in:  %s\n out: %s", frame, got)
		}
	}
}

// The whole contract: a frame the bridge signs verifies under the matching
// public key with EXACTLY the reconstruction the runner does — action args
// recovered by dropping the control keys, nonce + issued_at from the
// attestation. If this passes, the signer and the runner's verifier agree.
func TestSignFrameProducesRunnerVerifiableAttestation(t *testing.T) {
	s, pub := testSigner(t)

	frame := `{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{` +
		`"name":"docker.restart","arguments":{"container":"web","force":true,` +
		`"runner":"prod-1","reason":"rotate","wait":"0"}}}`

	signed := s.signFrame([]byte(frame))

	var parsed struct {
		ID     json.RawMessage `json:"id"`
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &parsed); err != nil {
		t.Fatalf("signed frame is not valid JSON: %v", err)
	}

	// The envelope id is preserved byte-for-byte (idempotency keys off it).
	if string(parsed.ID) != "7" {
		t.Fatalf("id not preserved: %s", parsed.ID)
	}

	att, ok := parsed.Params.Arguments["attestation"].(map[string]any)
	if !ok {
		t.Fatalf("no attestation attached: %#v", parsed.Params.Arguments)
	}
	if _, ok := att["cert"].(map[string]any); !ok {
		t.Fatalf("no cert attached to the attestation: %#v", att)
	}

	// Reconstruct the action args exactly as the portal/runner do.
	actionArgs := map[string]any{}
	for k, v := range parsed.Params.Arguments {
		actionArgs[k] = v
	}
	for _, k := range reservedArgKeys {
		delete(actionArgs, k)
	}
	// Control keys must not be in the signed args.
	for _, k := range []string{"runner", "reason", "wait", "attestation"} {
		if _, leaked := actionArgs[k]; leaked {
			t.Fatalf("control key %q leaked into signed args", k)
		}
	}

	claim := attest.Claim{
		ActionID: parsed.Params.Name,
		Args:     actionArgs,
		Nonce:    att["nonce"].(string),
		IssuedAt: att["issued_at"].(string),
	}
	valid, err := attest.Verify(pub, claim, att["sig"].(string))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !valid {
		t.Fatal("the bridge's signature did not verify under the runner's reconstruction")
	}
}

// A nil signer (signing disabled) is never invoked; the forward path guards on
// it. This documents that signFrame is only reached when configured.
func TestSignerDisabledIsNil(t *testing.T) {
	s, err := newSigner("", "")
	if err != nil {
		t.Fatalf("newSigner: %v", err)
	}
	if s != nil {
		t.Fatal("expected nil signer when no key configured")
	}
}

func TestNonceIsRandomHex(t *testing.T) {
	a, err := newNonce()
	if err != nil {
		t.Fatalf("newNonce: %v", err)
	}
	b, _ := newNonce()
	if a == b {
		t.Fatal("nonces must differ")
	}
	if _, err := hex.DecodeString(a); err != nil {
		t.Fatalf("nonce not hex: %v", err)
	}
}

// jsonrpc / method / params.name values are preserved through signing;
// withArguments replaces only params.arguments. (T03 already pins the id; this
// pins the rest of the envelope so the portal still routes the same tools/call.)
func TestSignFramePreservesEnvelopeFieldValues(t *testing.T) {
	s, _ := testSigner(t)
	frame := []byte(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{` +
		`"name":"docker.restart","arguments":{"container":"web"}}}`)

	signed := s.signFrame(frame)

	var got struct {
		JSONRPC json.RawMessage `json:"jsonrpc"`
		Method  json.RawMessage `json:"method"`
		Params  struct {
			Name json.RawMessage `json:"name"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &got); err != nil {
		t.Fatalf("signed frame not valid JSON: %v", err)
	}
	if string(got.JSONRPC) != `"2.0"` {
		t.Errorf("jsonrpc changed: %s", got.JSONRPC)
	}
	if string(got.Method) != `"tools/call"` {
		t.Errorf("method changed: %s", got.Method)
	}
	if string(got.Params.Name) != `"docker.restart"` {
		t.Errorf("params.name changed: %s", got.Params.Name)
	}
}

// a tools/call with NO `arguments` key is treated as an empty args
// map and still gets an attestation injected (signFrame defaults a nil Arguments
// to {} before signing), so a no-arg action is still client-attested.
func TestSignFrameAbsentArgumentsGetsAttestation(t *testing.T) {
	s, pub := testSigner(t)
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"linux.uptime"}}`)

	signed := s.signFrame(frame)
	if bytes.Equal(signed, frame) {
		t.Fatal("frame with a tool name but no arguments should be signed, not passed through")
	}

	var parsed struct {
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &parsed); err != nil {
		t.Fatalf("signed frame not valid JSON: %v", err)
	}
	att, ok := parsed.Params.Arguments["attestation"].(map[string]any)
	if !ok {
		t.Fatalf("no attestation injected over empty args: %#v", parsed.Params.Arguments)
	}
	// The only key is the attestation — the action args were the empty map.
	if len(parsed.Params.Arguments) != 1 {
		t.Errorf("expected only the injected attestation key, got %v", parsed.Params.Arguments)
	}
	// And it verifies as a claim over empty action args.
	claim := attest.Claim{
		ActionID: parsed.Params.Name,
		Args:     map[string]any{},
		Nonce:    att["nonce"].(string),
		IssuedAt: att["issued_at"].(string),
	}
	valid, err := attest.Verify(pub, claim, att["sig"].(string))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !valid {
		t.Fatal("attestation over empty args did not verify")
	}
}

// a pre-existing `attestation` arg is EXCLUDED from the signed
// claim (it is a reserved key) and then OVERWRITTEN with a fresh one, so a frame
// can never be made to self-sign a forged attestation an attacker pre-seeded.
func TestSignFrameStripsAndReplacesPreexistingAttestation(t *testing.T) {
	s, pub := testSigner(t)
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{` +
		`"name":"docker.restart","arguments":{"container":"web",` +
		`"attestation":{"key_id":"forged","sig":"deadbeef","nonce":"replayed","issued_at":"1999-01-01T00:00:00Z"}}}}`)

	signed := s.signFrame(frame)

	var parsed struct {
		Params struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &parsed); err != nil {
		t.Fatalf("signed frame not valid JSON: %v", err)
	}
	att, ok := parsed.Params.Arguments["attestation"].(map[string]any)
	if !ok {
		t.Fatalf("no attestation present: %#v", parsed.Params.Arguments)
	}
	// The forged attestation must be gone — a fresh one carrying our cert.
	if _, ok := att["cert"].(map[string]any); !ok {
		t.Errorf("attestation not replaced with our cert: %#v", att)
	}
	if att["sig"] == "deadbeef" || att["nonce"] == "replayed" {
		t.Fatalf("pre-seeded attestation survived: %#v", att)
	}

	// Reconstruct action args the way the runner does. The signed claim must NOT
	// include the (old) attestation — only the real action arg(s).
	actionArgs := map[string]any{}
	for k, v := range parsed.Params.Arguments {
		actionArgs[k] = v
	}
	for _, k := range reservedArgKeys {
		delete(actionArgs, k)
	}
	if _, leaked := actionArgs["attestation"]; leaked {
		t.Fatal("attestation leaked into the signed action args")
	}
	claim := attest.Claim{
		ActionID: parsed.Params.Name,
		Args:     actionArgs,
		Nonce:    att["nonce"].(string),
		IssuedAt: att["issued_at"].(string),
	}
	valid, err := attest.Verify(pub, claim, att["sig"].(string))
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if !valid {
		t.Fatal("fresh attestation (over args sans the forged attestation) did not verify")
	}
}

// the injected `issued_at` is an RFC3339 timestamp in UTC (ends in
// "Z"), matching the canonical encoding the runner re-signs.
func TestSignFrameIssuedAtIsRFC3339UTC(t *testing.T) {
	s, _ := testSigner(t)
	frame := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"linux.uptime","arguments":{}}}`)

	signed := s.signFrame(frame)
	var parsed struct {
		Params struct {
			Arguments map[string]any `json:"arguments"`
		} `json:"params"`
	}
	if err := json.Unmarshal(signed, &parsed); err != nil {
		t.Fatalf("signed frame not valid JSON: %v", err)
	}
	att := parsed.Params.Arguments["attestation"].(map[string]any)
	issued := att["issued_at"].(string)

	ts, err := time.Parse(time.RFC3339, issued)
	if err != nil {
		t.Fatalf("issued_at %q is not RFC3339: %v", issued, err)
	}
	if !strings.HasSuffix(issued, "Z") {
		t.Errorf("issued_at must be UTC (…Z), got %q", issued)
	}
	if loc := ts.Location(); loc != time.UTC {
		t.Errorf("issued_at parsed to a non-UTC location %v", loc)
	}
}

// the bridge's reservedArgKeys MUST match the portal's
// split_call_args contract exactly. The portal drops
// ["runner","runners","reason","wait","idempotency_key","attestation"] to recover
// the action args (mcp_rpc_controller.ex split_call_args); any drift would make
// the bridge sign over a different arg set than the runner reconstructs, breaking
// every signed dispatch. This is the source-of-truth assertion — when the portal
// list changes, this test must be updated in lockstep.
func TestReservedArgKeysMatchPortalSplitContract(t *testing.T) {
	portalSplit := []string{"runner", "runners", "reason", "wait", "idempotency_key", "attestation"}
	if !slices.Equal(reservedArgKeys, portalSplit) {
		t.Fatalf("reservedArgKeys drifted from the portal split_call_args contract:\n bridge: %v\n portal: %v", reservedArgKeys, portalSplit)
	}
}
