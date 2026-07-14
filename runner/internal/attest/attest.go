// Package attest defines the canonical encoding of a dispatch attestation —
// the exact bytes the MCP client signs and the runner verifies. The MCP holds a
// certified Ed25519 leaf key; the runner trusts the customer's CA public key in
// local config. The control plane only RELAYS the attestation: it can neither
// forge a signature nor alter its action, pack, exact args, public runner refs,
// reason, operation, origin, nonce, or time without verification failing.
//
// This package is duplicated VERBATIM in the runner and mcp modules — they are
// separate Go modules with no shared dependency, so coupling them through an
// import is worse than keeping each self-contained. The cross-impl vectors in
// attest_test.go are IDENTICAL in both copies and are the contract: any drift
// between the two implementations fails the vector test on one side.
package attest

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
)

// Version is the canonical-encoding revision, bound into every signature so a
// future format change can never be confused with this one.
const Version = "emisar-attestation-v4"

// Tool is fixed into every claim so a signature authorizing infrastructure
// execution cannot be replayed as authorization for another mutation type.
const Tool = "run_action"

// Wire bounds are shared so the bridge and runner accept the same target-set
// representation without duplicating transport-facing limits.
const (
	MaxRunnerRefs     = 16
	MaxRunnerRefBytes = 113
)

// Claim is the set of dispatch facts an attestation binds. A signature over
// these proves a real user authorized THIS action from THIS portal with THESE
// exact args for THESE runner references at THIS time.
type Claim struct {
	ActionID     string
	PackRef      string
	ArgsRaw      json.RawMessage
	RunnerRefs   []string
	Reason       string
	OperationID  string
	PortalOrigin string
	Nonce        string
	IssuedAt     string // RFC3339 UTC, e.g. "2026-06-17T12:00:00Z"
}

// Envelope is the relayed wire representation of a signed claim. The bridge
// emits it and the runner consumes it without either component redefining the
// field names or accidentally dropping a signed fact. ArgsSHA256 is redundant
// with the signature by design: it lets the runner compare the delivered exact
// argument bytes before doing public-key work.
type Envelope struct {
	Version      string   `json:"version"`
	Tool         string   `json:"tool"`
	PortalOrigin string   `json:"portal_origin"`
	ActionID     string   `json:"action_id"`
	PackRef      string   `json:"pack_ref"`
	ArgsSHA256   string   `json:"args_sha256"`
	RunnerRefs   []string `json:"runner_refs"`
	Reason       string   `json:"reason"`
	OperationID  string   `json:"operation_id"`
	Signature    string   `json:"sig"`
	Nonce        string   `json:"nonce"`
	IssuedAt     string   `json:"issued_at"`
	Cert         *Cert    `json:"cert,omitempty"`
}

// SigningBytes is the exact byte string that is signed and verified. A fixed
// JSON struct makes field boundaries unambiguous. Args are reduced to a digest
// of their exact JSON bytes: the bridge and runner therefore agree without
// passing large integers or decimals through a lossy native-number type.
// Runner refs are sorted before hashing so fan-out order is not semantic.
func SigningBytes(c Claim) ([]byte, error) {
	argsDigest, err := ArgsSHA256(c.ArgsRaw)
	if err != nil {
		return nil, err
	}

	runnerRefs, err := CanonicalRunnerRefs(c.RunnerRefs)
	if err != nil {
		return nil, err
	}
	runnerRefsJSON, err := json.Marshal(runnerRefs)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal runner refs: %w", err)
	}
	runnerRefsDigest := sha256.Sum256(runnerRefsJSON)

	body := struct {
		Version          string `json:"version"`
		Tool             string `json:"tool"`
		PortalOrigin     string `json:"portal_origin"`
		ActionID         string `json:"action_id"`
		PackRef          string `json:"pack_ref"`
		ArgsSHA256       string `json:"args_sha256"`
		RunnerRefsSHA256 string `json:"runner_refs_sha256"`
		Reason           string `json:"reason"`
		OperationID      string `json:"operation_id"`
		Nonce            string `json:"nonce"`
		IssuedAt         string `json:"issued_at"`
	}{
		Version:          Version,
		Tool:             Tool,
		PortalOrigin:     c.PortalOrigin,
		ActionID:         c.ActionID,
		PackRef:          c.PackRef,
		ArgsSHA256:       argsDigest,
		RunnerRefsSHA256: hex.EncodeToString(runnerRefsDigest[:]),
		Reason:           c.Reason,
		OperationID:      c.OperationID,
		Nonce:            c.Nonce,
		IssuedAt:         c.IssuedAt,
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal claim body: %w", err)
	}
	return encoded, nil
}

// ArgsSHA256 returns the digest bound into a claim and carried in the private
// attestation envelope. Empty input is the no-argument object {}. All other
// input must be one valid JSON object; its exact bytes, including insignificant
// whitespace and numeric spelling, are hashed.
func ArgsSHA256(raw json.RawMessage) (string, error) {
	if len(raw) == 0 {
		raw = json.RawMessage(`{}`)
	}
	if !json.Valid(raw) || len(bytes.TrimSpace(raw)) == 0 || bytes.TrimSpace(raw)[0] != '{' {
		return "", fmt.Errorf("attest: args must be one valid JSON object")
	}
	digest := sha256.Sum256(raw)
	return hex.EncodeToString(digest[:]), nil
}

// CanonicalRunnerRefs returns a sorted copy of refs. Empty and duplicate refs
// are rejected because either makes target-set intent ambiguous.
func CanonicalRunnerRefs(refs []string) ([]string, error) {
	if len(refs) == 0 {
		return nil, fmt.Errorf("attest: runner ref set is empty")
	}
	if len(refs) > MaxRunnerRefs {
		return nil, fmt.Errorf("attest: runner ref set exceeds %d entries", MaxRunnerRefs)
	}
	canonical := append([]string(nil), refs...)
	sort.Strings(canonical)
	for i, ref := range canonical {
		if ref == "" {
			return nil, fmt.Errorf("attest: runner ref is empty")
		}
		if len(ref) > MaxRunnerRefBytes {
			return nil, fmt.Errorf("attest: runner ref exceeds %d bytes", MaxRunnerRefBytes)
		}
		if i > 0 && ref == canonical[i-1] {
			return nil, fmt.Errorf("attest: runner ref %q is duplicated", ref)
		}
	}
	return canonical, nil
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
// SECOND canonical struct that composes with the v4 attestation above without
// changing it. The offline CA signs this; the runner verifies it to learn which
// leaf public key the attestation must verify under (and over which scope).
const CertVersion = "emisar-cert-v2"

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
// verifies. Like SigningBytes it uses a fixed JSON struct and reduces the one
// variable-shaped field (Scope) to a SHA-256 hex digest of its canonical JSON.
// Sig is NOT part of the body it signs over. Determinism rests on Go's stable
// struct-field order and JSON map-key sorting for the scope digest.
func CertSigningBytes(c Cert) ([]byte, error) {
	scopeJSON, err := json.Marshal(c.Scope)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal scope: %w", err)
	}
	digest := sha256.Sum256(scopeJSON)
	body := struct {
		Version     string `json:"version"`
		CAID        string `json:"ca_id"`
		KeyID       string `json:"key_id"`
		PublicKey   string `json:"public_key"`
		ValidFrom   string `json:"valid_from"`
		ValidUntil  string `json:"valid_until"`
		ScopeSHA256 string `json:"scope_sha256"`
		Serial      string `json:"serial"`
	}{
		Version:     CertVersion,
		CAID:        c.CAID,
		KeyID:       c.KeyID,
		PublicKey:   c.PublicKey,
		ValidFrom:   c.ValidFrom,
		ValidUntil:  c.ValidUntil,
		ScopeSHA256: hex.EncodeToString(digest[:]),
		Serial:      c.Serial,
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal certificate body: %w", err)
	}
	return encoded, nil
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
