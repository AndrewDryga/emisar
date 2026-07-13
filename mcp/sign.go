package main

// Client-attested dispatch — the one piece of real logic this bridge owns, and
// it earns its own file (the mcp CLAUDE.md's "strong reason" for a second file):
// the Ed25519 private key lives ONLY here, in the operator's local client, never
// on the control plane. That's the whole point — the portal can relay a signed
// dispatch but can't originate one. The bridge attaches a signature to each
// tools/call so an enforcing runner will run it.

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

// signer holds the leaf key + the CA-signed cert the bridge signs dispatches
// with. Nil = signing off. The cert is parsed once at construction and attached
// verbatim to every dispatch; the bridge never validates it (the runner does) —
// it only carries it.
type signer struct {
	priv ed25519.PrivateKey
	cert *attest.Cert
}

// reservedArgKeys are the control keys the portal strips from a tools/call's
// `arguments` to recover the action args (see the portal's split_call_args). The
// signer MUST drop the SAME set so the bytes it signs match the args the runner
// later verifies — this list is a shared contract with the portal.
var reservedArgKeys = []string{"runner", "runners", "reason", "wait", "idempotency_key", "attestation"}

// newSigner builds a signer from EMISAR_SIGNING_KEY (a 64-hex Ed25519 seed) and
// EMISAR_SIGNING_CERT (the CA-signed cert JSON the operator was given by
// `emisar cert new`). Returns (nil, nil) when neither is set (signing disabled);
// an error if only one is set, the seed is malformed, the cert is unparseable,
// or the cert vouches for a different key than the seed (a copy-paste mismatch
// that would make every dispatch fail at the runner).
func newSigner(keyHex, certJSON string) (*signer, error) {
	if keyHex == "" && certJSON == "" {
		return nil, nil
	}
	if keyHex == "" || certJSON == "" {
		return nil, fmt.Errorf(
			"both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT must be set to sign dispatches")
	}
	seed, err := hex.DecodeString(keyHex)
	if err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_KEY is not valid hex: %w", err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf(
			"EMISAR_SIGNING_KEY must be %d hex-encoded bytes (an Ed25519 seed), got %d",
			ed25519.SeedSize, len(seed))
	}
	priv := ed25519.NewKeyFromSeed(seed)

	var cert attest.Cert
	if err := json.Unmarshal([]byte(certJSON), &cert); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT is not valid JSON: %w", err)
	}
	if leafPub := hex.EncodeToString(priv.Public().(ed25519.PublicKey)); cert.PublicKey != leafPub {
		return nil, fmt.Errorf(
			"EMISAR_SIGNING_CERT vouches for a different key than EMISAR_SIGNING_KEY — " +
				"use the matching key+cert pair printed by `emisar cert new`")
	}
	return &signer{priv: priv, cert: &cert}, nil
}

// signFrame attaches an attestation to a tools/call frame so an enforcing runner
// will run it. It signs ONLY the action args (the control keys are dropped,
// matching the portal's split) plus a fresh nonce and timestamp. It returns the
// frame UNCHANGED on anything it can't cleanly sign (not a tools/call, no tool
// name, unparseable) — failing open is safe here: an unsigned dispatch to an
// enforcing runner is simply refused at the runner, and signing a non-dispatch
// frame would be pointless.
func (s *signer) signFrame(frame []byte) []byte {
	var req struct {
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(frame, &req); err != nil || req.Method != "tools/call" {
		return frame
	}

	var params struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil || params.Name == "" {
		return frame
	}
	if params.Arguments == nil {
		params.Arguments = map[string]any{}
	}

	actionArgs := map[string]any{}
	for k, v := range params.Arguments {
		actionArgs[k] = v
	}
	for _, k := range reservedArgKeys {
		delete(actionArgs, k)
	}

	nonce, err := newNonce()
	if err != nil {
		return frame
	}
	issuedAt := time.Now().UTC().Format(time.RFC3339)

	sig, err := attest.Sign(s.priv, attest.Claim{
		ActionID: params.Name,
		Args:     actionArgs,
		Nonce:    nonce,
		IssuedAt: issuedAt,
	})
	if err != nil {
		return frame
	}

	params.Arguments["attestation"] = map[string]any{
		"sig":       sig,
		"nonce":     nonce,
		"issued_at": issuedAt,
		"cert":      s.cert,
	}

	signed, err := withArguments(frame, params.Arguments)
	if err != nil {
		return frame
	}
	return signed
}

// withArguments rebuilds the frame with `params.arguments` replaced. The raw
// values of every other field (jsonrpc, id, method, params.name) are preserved;
// object key order may change when the enclosing maps are re-encoded. The
// envelope id the idempotency key derives from is untouched.
func withArguments(frame []byte, arguments map[string]any) ([]byte, error) {
	var full map[string]json.RawMessage
	if err := json.Unmarshal(frame, &full); err != nil {
		return nil, err
	}
	var params map[string]json.RawMessage
	if err := json.Unmarshal(full["params"], &params); err != nil {
		return nil, err
	}
	argsJSON, err := json.Marshal(arguments)
	if err != nil {
		return nil, err
	}
	params["arguments"] = argsJSON
	paramsJSON, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	full["params"] = paramsJSON
	return json.Marshal(full)
}

// newNonce returns a 16-byte random hex token bound into the signature so a
// relayed dispatch can't be replayed (the runner refuses a re-used nonce).
func newNonce() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
