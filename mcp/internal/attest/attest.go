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
	// A signed dispatch with no args carries nil Args (the wire frame omits
	// `args`), which json.Marshal renders as `null` — a different digest than
	// `{}`. Normalize nil to an empty map so a no-arg claim signs and verifies
	// identically to one with explicit `{}` on both sides (the cross-impl
	// contract); without this, every legitimately-signed no-arg dispatch is
	// refused as bad_signature.
	args := c.Args
	if args == nil {
		args = map[string]any{}
	}

	argsJSON, err := json.Marshal(args)
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

// CertVersion is the canonical-encoding revision of the certificate body — a
// SECOND canonical struct that composes with the v1 attestation above without
// changing it. The offline CA signs this; the runner verifies it to learn which
// leaf public key the attestation must verify under (and over which scope).
const CertVersion = "emisar-cert-v1"

// Scope is the optional targeting a CA binds into a cert. It is matched ONLY
// against the runner's own locally-configured identity (runner.group /
// runner.labels), never against any value the control plane supplies — so a
// compromised portal cannot redirect a certified dispatch to a runner the CA
// did not scope it to. The matcher is deliberately tiny: exact group + a label
// subset, no glob or policy DSL.
type Scope struct {
	Group  string            `json:"group,omitempty"`  // exact match vs runner.group; "" = any group
	Labels map[string]string `json:"labels,omitempty"` // each k must equal runner.labels[k]; empty = no constraint
}

// Cert is a CA-signed credential that vouches for a leaf signing key: the
// offline CA asserts "this public key, valid in this window, may sign dispatches
// within this scope". The operator carries it; the MCP client sends it inside
// the attestation. The runner trusts the CA (one key) instead of every leaf key,
// so onboarding is one signature and zero runner-config edits. The CA private
// key NEVER touches the portal — a compromised control plane can relay a cert
// but never mint one.
type Cert struct {
	CAID       string `json:"ca_id"`
	KeyID      string `json:"key_id"`
	PublicKey  string `json:"public_key"`  // hex, 32 bytes — the leaf pubkey the attestation must verify under
	ValidFrom  string `json:"valid_from"`  // RFC3339 UTC
	ValidUntil string `json:"valid_until"` // RFC3339 UTC
	Scope      Scope  `json:"scope"`
	Serial     string `json:"serial"` // ULID — audit + future revocation
	Sig        string `json:"sig"`    // hex Ed25519, CA over the body below
}

// CertSigningBytes is the exact byte string the CA signs and the runner
// verifies. Like SigningBytes it is newline-delimited and reduces the one
// variable-shaped field (Scope) to a SHA-256 hex digest of its canonical JSON,
// so no scope value can smuggle in the delimiter. Sig is NOT part of the body it
// signs over. Determinism rests on the same Go json key-sorting as the claim.
func CertSigningBytes(c Cert) ([]byte, error) {
	scopeJSON, err := json.Marshal(c.Scope)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal scope: %w", err)
	}
	digest := sha256.Sum256(scopeJSON)
	s := CertVersion + "\n" +
		c.CAID + "\n" +
		c.KeyID + "\n" +
		c.PublicKey + "\n" +
		c.ValidFrom + "\n" +
		c.ValidUntil + "\n" +
		hex.EncodeToString(digest[:]) + "\n" +
		c.Serial
	return []byte(s), nil
}

// SignCert returns the hex-encoded Ed25519 signature of the CA over the cert
// body. Deterministic (RFC 8032), which is what makes the cross-impl cert
// vectors stable.
func SignCert(caPriv ed25519.PrivateKey, c Cert) (string, error) {
	msg, err := CertSigningBytes(c)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(ed25519.Sign(caPriv, msg)), nil
}

// VerifyCert reports whether c.Sig is a valid Ed25519 signature by caPub over
// the cert body. A malformed signature or scope is a (false, error); a
// cryptographically invalid one is (false, nil).
func VerifyCert(caPub ed25519.PublicKey, c Cert) (bool, error) {
	msg, err := CertSigningBytes(c)
	if err != nil {
		return false, err
	}
	sig, err := hex.DecodeString(c.Sig)
	if err != nil {
		return false, fmt.Errorf("attest: decode cert signature: %w", err)
	}
	return ed25519.Verify(caPub, msg, sig), nil
}
