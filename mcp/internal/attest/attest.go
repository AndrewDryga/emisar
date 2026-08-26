// Package attest defines the canonical encoding of a dispatch attestation —
// the exact bytes the MCP bridge signs and the runner verifies. The bridge holds a
// certified Ed25519 or ECDSA P-256 leaf key; the runner trusts the customer's CA public key in
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
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"
)

// Version is the canonical-encoding revision, bound into every signature so a
// future format change can never be confused with this one.
const Version = "emisar-attestation-v5"

// Tool is fixed into every claim so a signature authorizing infrastructure
// execution cannot be replayed as authorization for another mutation type.
const Tool = "run_action"

// Wire bounds are shared so the bridge and runner accept the same target-set
// representation without duplicating transport-facing limits.
const (
	MaxRunnerRefs     = 16
	MaxRunnerRefBytes = 113
)

// Claim is the set of dispatch facts an attestation binds. A valid signature
// proves a customer-authorized MCP bridge used its certified key to bind THIS
// action from THIS portal with THESE exact args for THESE runner references at
// THIS time.
type Claim struct {
	ActionID   string
	PackRef    string
	ArgsRaw    json.RawMessage
	RunnerRefs []string
	Reason     string
	// Evidence and Expected are the narrative a HUMAN APPROVER reads. They are
	// bound by digest, not carried: together they run to 6,000 characters
	// against a 16 KiB envelope budget, and `ArgsRaw` already establishes that
	// a large field is signed as a hash of its exact bytes.
	//
	// Both are optional and both are ALWAYS hashed — an absent one signs as the
	// digest of the empty string. That is the load-bearing half: it binds "the
	// bridge sent no evidence", so a control plane cannot invent a
	// justification for an action the operator never justified.
	Evidence string
	Expected string
	// EvidenceSHA256 and ExpectedSHA256 are the VERIFIER's form of the two
	// fields above. A runner is bound by digest and never receives the
	// narrative text, so it fills these straight from the envelope; when set
	// they are signed as-is and the text form is ignored. A signer holds the
	// text, leaves these empty, and lets it hash.
	EvidenceSHA256 string
	ExpectedSHA256 string
	OperationID    string
	PortalOrigin   string
	Nonce          string
	IssuedAt       string // RFC3339 UTC, e.g. "2026-06-17T12:00:00Z"
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
	// Digests of the approver-facing narrative. See Claim.Evidence.
	EvidenceSHA256 string `json:"evidence_sha256"`
	ExpectedSHA256 string `json:"expected_sha256"`
	OperationID    string `json:"operation_id"`
	Signature      string `json:"sig"`
	Nonce          string `json:"nonce"`
	IssuedAt       string `json:"issued_at"`
	// CertChain is the leaf certificate, optionally followed by one
	// intermediate, each as standard-base64 DER. The trust anchor is never on
	// the wire: a runner trusts what its own config carries.
	CertChain []string `json:"cert_chain,omitempty"`
}

// TextSHA256 is the lower-hex SHA-256 of a UTF-8 string. Used for the
// approver-facing narrative fields, which are bound by digest rather than
// carried: the empty string hashes like any other, so "no evidence" is a signed
// fact rather than an absent one.
func TextSHA256(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// narrativeDigest resolves one narrative field to the digest that gets signed.
// A verifier holds only the digest; a signer holds only the text. Routing both
// through ONE resolver keeps a single encoding for the two sides — the
// alternative, hashing on the signer and comparing digests on the verifier, is
// two paths that can silently disagree, which is exactly how v5 first shipped:
// the runner built its claim without these fields and verified every signed
// narrative against the digest of the empty string.
func narrativeDigest(digest, text string) string {
	if digest != "" {
		return digest
	}
	return TextSHA256(text)
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
		EvidenceSHA256   string `json:"evidence_sha256"`
		ExpectedSHA256   string `json:"expected_sha256"`
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
		EvidenceSHA256:   narrativeDigest(c.EvidenceSHA256, c.Evidence),
		ExpectedSHA256:   narrativeDigest(c.ExpectedSHA256, c.Expected),
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

// CertProfile names the X.509 profile a dispatch certificate must satisfy. It
// is documentation, not a wire field: the profile is enforced structurally by
// VerifyChain, so there is no version string an issuer could get wrong.
const CertProfile = "emisar-x509-profile-v1"

// ScopeURI is the URI SAN every dispatch certificate must carry exactly once.
// It does two jobs. It carries the scope (in its query), and — more
// importantly — it is what marks the certificate as issued FOR emisar. A TLS
// server certificate from the same corporate CA has no such SAN, so a shared
// root cannot turn ordinary server certificates into signing authority for
// infrastructure actions.
const ScopeURI = "emisar://dispatch/v1"

// MaxScopeURIBytes bounds the SAN a runner will parse. Scope is a group plus a
// label subset, never a policy document.
const MaxScopeURIBytes = 512

// MaxChainCerts is the presented chain a runner accepts: the leaf, plus at
// most one intermediate. Deeper chains are refused even when they verify — a
// customer PKI that needs more depth pins the deeper issuer as the trust
// anchor instead.
const MaxChainCerts = 2

// Cert refusal codes. They travel to the operator as the run's refusal reason,
// so each one names a distinct remedy: a profile violation is an issuance bug,
// an untrusted chain is a distribution problem, expiry is a rotation problem,
// and scope is a targeting problem.
const (
	CodeCertProfile   = "cert_profile"
	CodeCertUntrusted = "cert_untrusted"
	CodeCertExpired   = "cert_expired"
	CodeCertScope     = "cert_scope"
)

// CertError carries the refusal code a certificate failure maps to, so the
// caller reports the operator's actual remedy rather than one generic
// "bad certificate".
type CertError struct {
	Code   string
	Reason string
}

func (e *CertError) Error() string { return e.Code + ": " + e.Reason }

func certErr(code, format string, args ...any) *CertError {
	return &CertError{Code: code, Reason: fmt.Sprintf(format, args...)}
}

// Scope is the optional targeting a CA binds into a certificate. It is matched
// ONLY against the runner's own locally-configured identity (runner.group /
// runner.labels), never against any value the control plane supplies — so a
// compromised portal cannot redirect a certified dispatch to a runner the CA
// did not scope it to. The matcher is deliberately tiny: exact group + a label
// subset, no glob or policy DSL.
type Scope struct {
	Group  string            // exact match vs runner.group; "" = any group
	Labels map[string]string // each k must equal runner.labels[k]; empty = no constraint
}

// EncodeScopeURI renders a scope as the canonical URI SAN an issuer must set.
// Canonical means one spelling per scope: parameters sorted bytewise, and
// every key and value percent-encoded minimally with uppercase hex. Keys are
// encoded on the same terms as values because a runner label key is free-form
// operator input — `runner.labels` is a bare YAML map and RUNNER_LABEL_<KEY>
// env, with no charset the config layer enforces.
func EncodeScopeURI(s Scope) (string, error) {
	params := make([]string, 0, len(s.Labels)+1)
	if s.Group != "" {
		params = append(params, "group="+encodeScopeComponent(s.Group))
	}
	for key, value := range s.Labels {
		if key == "" {
			return "", fmt.Errorf("attest: scope label key is empty")
		}
		params = append(params, "label."+encodeScopeComponent(key)+"="+encodeScopeComponent(value))
	}
	sort.Strings(params)

	uri := ScopeURI
	if len(params) > 0 {
		uri += "?" + strings.Join(params, "&")
	}
	if len(uri) > MaxScopeURIBytes {
		return "", fmt.Errorf("attest: scope URI exceeds %d bytes", MaxScopeURIBytes)
	}
	return uri, nil
}

// ParseScopeURI parses the canonical scope URI. A URI that parses but is not
// the canonical spelling of what it means is REFUSED rather than accepted
// leniently: two spellings of one scope would let an issuer and a verifier
// disagree about what was authorized.
func ParseScopeURI(raw string) (Scope, error) {
	if len(raw) > MaxScopeURIBytes {
		return Scope{}, certErr(CodeCertProfile, "scope URI exceeds %d bytes", MaxScopeURIBytes)
	}
	base, query, hasQuery := strings.Cut(raw, "?")
	if base != ScopeURI {
		return Scope{}, certErr(CodeCertProfile, "scope URI is not %s", ScopeURI)
	}

	scope := Scope{}
	if hasQuery {
		if query == "" {
			return Scope{}, certErr(CodeCertProfile, "scope URI has an empty query")
		}
		for _, param := range strings.Split(query, "&") {
			name, value, ok := strings.Cut(param, "=")
			if !ok {
				return Scope{}, certErr(CodeCertProfile, "scope parameter %q has no value", param)
			}
			decodedValue, err := decodeScopeComponent(value)
			if err != nil {
				return Scope{}, certErr(CodeCertProfile, "scope parameter %q: %s", name, err)
			}
			switch {
			case name == "group":
				if scope.Group != "" {
					return Scope{}, certErr(CodeCertProfile, "scope repeats group")
				}
				if decodedValue == "" {
					return Scope{}, certErr(CodeCertProfile, "scope group is empty")
				}
				scope.Group = decodedValue
			case strings.HasPrefix(name, "label."):
				key, err := decodeScopeComponent(strings.TrimPrefix(name, "label."))
				if err != nil {
					return Scope{}, certErr(CodeCertProfile, "scope label key: %s", err)
				}
				if key == "" {
					return Scope{}, certErr(CodeCertProfile, "scope label key is empty")
				}
				if _, exists := scope.Labels[key]; exists {
					return Scope{}, certErr(CodeCertProfile, "scope repeats label %q", key)
				}
				if scope.Labels == nil {
					scope.Labels = map[string]string{}
				}
				scope.Labels[key] = decodedValue
			default:
				return Scope{}, certErr(CodeCertProfile, "scope parameter %q is not recognised", name)
			}
		}
	}

	// Re-encoding is the canonical check: anything that round-trips to a
	// different string was spelled some other way — unsorted, over-encoded,
	// lowercase hex — and is refused rather than silently normalized.
	canonical, err := EncodeScopeURI(scope)
	if err != nil {
		return Scope{}, certErr(CodeCertProfile, "scope URI: %s", err)
	}
	if canonical != raw {
		return Scope{}, certErr(CodeCertProfile, "scope URI is not canonical (expected %q)", canonical)
	}
	return scope, nil
}

// Matches reports whether a runner with this group and labels is inside the
// scope. An empty scope matches any runner that trusts the CA.
func (s Scope) Matches(group string, labels map[string]string) bool {
	if s.Group != "" && s.Group != group {
		return false
	}
	for key, want := range s.Labels {
		// The presence check is load-bearing: a bare map read returns "" for an
		// ABSENT key, so a scope pinning a label to the empty string would
		// otherwise match every runner in the fleet rather than the ones that
		// actually carry it.
		got, ok := labels[key]
		if !ok || got != want {
			return false
		}
	}
	return true
}

func encodeScopeComponent(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if isUnreserved(c) {
			b.WriteByte(c)
			continue
		}
		b.WriteString(fmt.Sprintf("%%%02X", c))
	}
	return b.String()
}

func decodeScopeComponent(s string) (string, error) {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != '%' {
			if !isUnreserved(c) {
				return "", fmt.Errorf("byte %q must be percent-encoded", c)
			}
			b.WriteByte(c)
			continue
		}
		if i+2 >= len(s) {
			return "", fmt.Errorf("truncated percent-encoding")
		}
		decoded, err := hex.DecodeString(s[i+1 : i+3])
		if err != nil {
			return "", fmt.Errorf("invalid percent-encoding %q", s[i:i+3])
		}
		b.WriteByte(decoded[0])
		i += 2
	}
	return b.String(), nil
}

func isUnreserved(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	case c == '-', c == '.', c == '_', c == '~':
		return true
	default:
		return false
	}
}

// VerifyChain verifies a presented DER chain against the configured trust
// anchors and applies the emisar profile, returning the leaf and its scope.
//
// The profile is what keeps a general-purpose CA from becoming dispatch
// authority: a certificate reaches this far only by carrying exactly one
// emisar scope SAN, being a non-CA leaf, and holding a key algorithm the
// claim layer signs with.
func VerifyChain(roots *x509.CertPool, chain [][]byte, now time.Time) (*x509.Certificate, Scope, error) {
	if len(chain) == 0 {
		return nil, Scope{}, certErr(CodeCertProfile, "certificate chain is empty")
	}
	if len(chain) > MaxChainCerts {
		return nil, Scope{}, certErr(CodeCertProfile, "certificate chain has %d certificates, at most %d are accepted", len(chain), MaxChainCerts)
	}

	parsed := make([]*x509.Certificate, 0, len(chain))
	for i, der := range chain {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, Scope{}, certErr(CodeCertProfile, "certificate %d does not parse: %s", i, err)
		}
		parsed = append(parsed, cert)
	}

	leaf := parsed[0]
	intermediates := x509.NewCertPool()
	for _, cert := range parsed[1:] {
		intermediates.AddCert(cert)
	}

	// KeyUsageAny because the emisar SAN — not an EKU — is what marks a
	// certificate as ours. We own no OID arc to require here, and requiring a
	// borrowed EKU (serverAuth) would accept exactly the TLS certificates the
	// SAN exists to exclude.
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         roots,
		Intermediates: intermediates,
		CurrentTime:   now,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		var invalid x509.CertificateInvalidError
		if errors.As(err, &invalid) && invalid.Reason == x509.Expired {
			return nil, Scope{}, certErr(CodeCertExpired, "%s", err)
		}
		return nil, Scope{}, certErr(CodeCertUntrusted, "%s", err)
	}

	scope, err := leafScope(leaf)
	if err != nil {
		return nil, Scope{}, err
	}
	if err := checkLeafProfile(leaf); err != nil {
		return nil, Scope{}, err
	}
	return leaf, scope, nil
}

// leafScope returns the scope from the leaf's single emisar URI SAN. Exactly
// one is required: zero means the certificate was not issued for emisar, and
// several would leave the effective scope ambiguous.
func leafScope(leaf *x509.Certificate) (Scope, error) {
	var found *url.URL
	for _, uri := range leaf.URIs {
		if uri.Scheme != "emisar" {
			continue
		}
		if found != nil {
			return Scope{}, certErr(CodeCertProfile, "certificate carries several emisar scope URIs")
		}
		found = uri
	}
	if found == nil {
		return Scope{}, certErr(CodeCertProfile, "certificate carries no %s scope URI", ScopeURI)
	}
	return ParseScopeURI(found.String())
}

func checkLeafProfile(leaf *x509.Certificate) error {
	if leaf.BasicConstraintsValid && leaf.IsCA {
		return certErr(CodeCertProfile, "certificate is a CA certificate, not a signing leaf")
	}
	if leaf.KeyUsage != 0 && leaf.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return certErr(CodeCertProfile, "certificate key usage does not permit digital signature")
	}
	if _, err := claimVerifier(leaf.PublicKey); err != nil {
		return err
	}
	return nil
}

// claimVerifier resolves a leaf's public key to the claim-signature algorithm
// it verifies under. Ed25519 is the default; ECDSA P-256 exists because HSM
// and cloud-KMS custody is a first-class case for a customer CA and several
// major KMS products still do not offer Ed25519.
func claimVerifier(pub crypto.PublicKey) (func(msg, sig []byte) bool, error) {
	switch key := pub.(type) {
	case ed25519.PublicKey:
		return func(msg, sig []byte) bool { return ed25519.Verify(key, msg, sig) }, nil
	case *ecdsa.PublicKey:
		if key.Curve != elliptic.P256() {
			return nil, certErr(CodeCertProfile, "ECDSA key is not on P-256")
		}
		return func(msg, sig []byte) bool {
			digest := sha256.Sum256(msg)
			return ecdsa.VerifyASN1(key, digest[:], sig)
		}, nil
	default:
		return nil, certErr(CodeCertProfile, "key algorithm %T is not accepted for dispatch signing", pub)
	}
}

// SignClaim signs a claim with a certified leaf key. An Ed25519 key signs the
// claim bytes directly (RFC 8032, deterministic — which is what keeps the
// cross-implementation vectors stable); a P-256 key signs their SHA-256 and
// emits an ASN.1 signature.
func SignClaim(signer crypto.Signer, c Claim) (string, error) {
	msg, err := SigningBytes(c)
	if err != nil {
		return "", err
	}
	switch signer.Public().(type) {
	case ed25519.PublicKey:
		sig, err := signer.Sign(rand.Reader, msg, crypto.Hash(0))
		if err != nil {
			return "", fmt.Errorf("attest: sign claim: %w", err)
		}
		return hex.EncodeToString(sig), nil
	case *ecdsa.PublicKey:
		digest := sha256.Sum256(msg)
		sig, err := signer.Sign(rand.Reader, digest[:], crypto.SHA256)
		if err != nil {
			return "", fmt.Errorf("attest: sign claim: %w", err)
		}
		return hex.EncodeToString(sig), nil
	default:
		return "", fmt.Errorf("attest: key algorithm %T is not accepted for dispatch signing", signer.Public())
	}
}

// VerifyClaim reports whether sigHex is a valid signature over the claim under
// the leaf certificate's key. A malformed signature or claim is a
// (false, error); a cryptographically invalid one is (false, nil).
func VerifyClaim(leaf *x509.Certificate, c Claim, sigHex string) (bool, error) {
	verify, err := claimVerifier(leaf.PublicKey)
	if err != nil {
		return false, err
	}
	msg, err := SigningBytes(c)
	if err != nil {
		return false, err
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		return false, fmt.Errorf("attest: decode signature: %w", err)
	}
	return verify(msg, sig), nil
}
