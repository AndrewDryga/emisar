// Package attest defines the canonical encoding of a dispatch attestation —
// the exact bytes the MCP client signs and the runner verifies. The MCP holds
// the Ed25519 private key; the runner holds the trusted public key in its local
// config. The control plane only RELAYS the attestation: it can neither forge a
// signature (no private key) nor alter the signed facts (action_id, args,
// nonce, issued_at) without the runner's verification failing.
//
// This package is duplicated VERBATIM in the runner and mcp modules — they are
// separate Go modules with no shared dependency, so coupling them through an
// import is worse than keeping each self-contained. The cross-impl vectors in
// attest_test.go are IDENTICAL in both copies and are the contract: any drift
// between the two implementations fails the vector test on one side.
package attest

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

// Version is the canonical-encoding revision, bound into every signature so a
// future format change can never be confused with this one.
const Version = "emisar-attestation-v1"

// Claim is the set of dispatch facts an attestation binds. A signature over
// these proves a real user authorized THIS action with THESE args at THIS time;
// the runner-target binding comes from the key itself (the runner trusts only
// the key_id(s) in its local config), so it is not part of the claim.
type Claim struct {
	ActionID string
	Args     map[string]any
	Nonce    string
	IssuedAt string // RFC3339 UTC, e.g. "2026-06-17T12:00:00Z"
}

// SigningBytes is the exact byte string that is signed and verified. It is
// newline-delimited; the args are reduced to a SHA-256 hex digest of their
// canonical JSON so no field value can smuggle in the delimiter. Determinism
// rests on Go's encoding/json sorting map keys at every level, so the same
// logical args always produce the same digest on both sides — even after the
// control plane round-trips them through jsonb (it preserves values, and both
// ends re-marshal through Go's json, which normalizes number formatting).
func SigningBytes(c Claim) ([]byte, error) {
	argsJSON, err := json.Marshal(c.Args)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal args: %w", err)
	}
	digest := sha256.Sum256(argsJSON)
	s := Version + "\n" +
		c.ActionID + "\n" +
		hex.EncodeToString(digest[:]) + "\n" +
		c.Nonce + "\n" +
		c.IssuedAt
	return []byte(s), nil
}

// Sign returns the hex-encoded Ed25519 signature over the claim. Ed25519 is
// deterministic (RFC 8032), so a given (key, claim) always yields the same
// signature — which is what makes the cross-impl vectors stable.
func Sign(priv ed25519.PrivateKey, c Claim) (string, error) {
	msg, err := SigningBytes(c)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(ed25519.Sign(priv, msg)), nil
}

// Verify reports whether sigHex is a valid Ed25519 signature over the claim
// under pub. A malformed signature or args is a (false, error); a
// cryptographically invalid one is (false, nil).
func Verify(pub ed25519.PublicKey, c Claim, sigHex string) (bool, error) {
	msg, err := SigningBytes(c)
	if err != nil {
		return false, err
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		return false, fmt.Errorf("attest: decode signature: %w", err)
	}
	return ed25519.Verify(pub, msg, sig), nil
}
