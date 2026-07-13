// Package attest defines the canonical encoding of a dispatch attestation —
// the exact bytes the MCP client signs and the runner verifies. The MCP holds
// the Ed25519 private key; the runner holds the trusted public key in its local
// config. The control plane only RELAYS the attestation: it can neither forge a
// signature (no private key) nor alter the signed facts (action_id, args,
// target runner ids, nonce, issued_at) without the runner's verification
// failing.
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
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
)

// Version is the canonical-encoding revision, bound into every signature so a
// future format change can never be confused with this one.
const Version = "emisar-attestation-v3"

// Claim is the set of dispatch facts an attestation binds. A signature over
// these proves a real user authorized THIS action with THESE args for THESE
// runner identities at THIS time. Targets are durable runner external ids, not
// portal-owned display names.
type Claim struct {
	ActionID string
	Args     map[string]any
	Targets  []string
	Nonce    string
	IssuedAt string // RFC3339 UTC, e.g. "2026-06-17T12:00:00Z"
}

// SigningBytes is the exact byte string that is signed and verified. A fixed
// JSON struct makes field boundaries unambiguous even when a string contains
// control characters. Args and targets are reduced to SHA-256 hex digests of
// their canonical JSON. Numbers are normalized by mathematical value before
// hashing: 1000, 1e3, and 1.000e+3 produce the same bytes, while integers beyond
// float64's exact range are never rounded. Targets are sorted before hashing so
// fan-out order is not semantic.
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

	argsJSON, err := canonicalJSON(args)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal args: %w", err)
	}
	argsDigest := sha256.Sum256(argsJSON)

	targets, err := canonicalTargets(c.Targets)
	if err != nil {
		return nil, fmt.Errorf("attest: targets: %w", err)
	}
	targetsJSON, err := json.Marshal(targets)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal targets: %w", err)
	}
	targetsDigest := sha256.Sum256(targetsJSON)

	body := struct {
		Version       string `json:"version"`
		ActionID      string `json:"action_id"`
		ArgsSHA256    string `json:"args_sha256"`
		TargetsSHA256 string `json:"targets_sha256"`
		Nonce         string `json:"nonce"`
		IssuedAt      string `json:"issued_at"`
	}{
		Version:       Version,
		ActionID:      c.ActionID,
		ArgsSHA256:    hex.EncodeToString(argsDigest[:]),
		TargetsSHA256: hex.EncodeToString(targetsDigest[:]),
		Nonce:         c.Nonce,
		IssuedAt:      c.IssuedAt,
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("attest: marshal claim body: %w", err)
	}
	return encoded, nil
}

func canonicalTargets(targets []string) ([]string, error) {
	canonical := append([]string(nil), targets...)
	sort.Strings(canonical)
	for i, target := range canonical {
		if target == "" {
			return nil, fmt.Errorf("target id is empty")
		}
		if i > 0 && target == canonical[i-1] {
			return nil, fmt.Errorf("target id %q is duplicated", target)
		}
	}
	return canonical, nil
}

// canonicalJSON preserves JSON types and object/array structure while replacing
// every numeric value with one stable base-10 spelling. encoding/json then owns
// string escaping and recursive object-key ordering.
func canonicalJSON(value any) ([]byte, error) {
	canonical, err := canonicalValue(value)
	if err != nil {
		return nil, err
	}
	return json.Marshal(canonical)
}

type canonicalNumber string

func (n canonicalNumber) MarshalJSON() ([]byte, error) { return []byte(n), nil }

func canonicalValue(value any) (any, error) {
	switch value := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(value))
		for key, nested := range value {
			canonical, err := canonicalValue(nested)
			if err != nil {
				return nil, err
			}
			out[key] = canonical
		}
		return out, nil
	case []any:
		out := make([]any, len(value))
		for i, nested := range value {
			canonical, err := canonicalValue(nested)
			if err != nil {
				return nil, err
			}
			out[i] = canonical
		}
		return out, nil
	case json.Number:
		return canonicalJSONNumber(value.String())
	case int:
		return canonicalJSONNumber(strconv.FormatInt(int64(value), 10))
	case int8:
		return canonicalJSONNumber(strconv.FormatInt(int64(value), 10))
	case int16:
		return canonicalJSONNumber(strconv.FormatInt(int64(value), 10))
	case int32:
		return canonicalJSONNumber(strconv.FormatInt(int64(value), 10))
	case int64:
		return canonicalJSONNumber(strconv.FormatInt(value, 10))
	case uint:
		return canonicalJSONNumber(strconv.FormatUint(uint64(value), 10))
	case uint8:
		return canonicalJSONNumber(strconv.FormatUint(uint64(value), 10))
	case uint16:
		return canonicalJSONNumber(strconv.FormatUint(uint64(value), 10))
	case uint32:
		return canonicalJSONNumber(strconv.FormatUint(uint64(value), 10))
	case uint64:
		return canonicalJSONNumber(strconv.FormatUint(value, 10))
	case float32:
		return canonicalJSONNumber(strconv.FormatFloat(float64(value), 'g', -1, 32))
	case float64:
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return nil, fmt.Errorf("unsupported JSON number %v", value)
		}
		return canonicalJSONNumber(strconv.FormatFloat(value, 'g', -1, 64))
	default:
		return value, nil
	}
}

// canonicalJSONNumber converts a valid JSON number into coefficient/exponent
// form without evaluating it through float64. The exponent is arbitrary
// precision, so a hostile but frame-bounded value such as 1e999999 cannot
// overflow or force a gigantic expanded allocation.
func canonicalJSONNumber(raw string) (canonicalNumber, error) {
	sign := ""
	if strings.HasPrefix(raw, "-") {
		sign = "-"
		raw = raw[1:]
	}

	mantissa, exponentText, hasExponent := strings.Cut(raw, "e")
	if !hasExponent {
		mantissa, exponentText, hasExponent = strings.Cut(raw, "E")
	}
	exponent := new(big.Int)
	if hasExponent {
		exponentText = strings.TrimPrefix(exponentText, "+")
		if _, ok := exponent.SetString(exponentText, 10); !ok {
			return "", fmt.Errorf("invalid JSON number %q", sign+raw)
		}
	}

	integer, fraction, hasFraction := strings.Cut(mantissa, ".")
	if integer == "" || !decimalDigits(integer) ||
		(len(integer) > 1 && integer[0] == '0') ||
		(hasFraction && (fraction == "" || !decimalDigits(fraction))) {
		return "", fmt.Errorf("invalid JSON number %q", sign+raw)
	}
	digits := strings.TrimLeft(integer+fraction, "0")
	if digits == "" {
		return canonicalNumber("0"), nil
	}

	adjustment := -len(fraction)
	trimmed := strings.TrimRight(digits, "0")
	adjustment += len(digits) - len(trimmed)
	digits = trimmed
	exponent.Add(exponent, big.NewInt(int64(adjustment)))

	if exponent.Sign() == 0 {
		return canonicalNumber(sign + digits), nil
	}
	return canonicalNumber(sign + digits + "e" + exponent.String()), nil
}

func decimalDigits(value string) bool {
	for _, digit := range value {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
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
// SECOND canonical struct that composes with the v3 attestation above without
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
