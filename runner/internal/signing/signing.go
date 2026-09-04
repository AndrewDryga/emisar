// Package signing verifies bridge-attested dispatches on the runner. With
// enforcement on (config signing.enforce_signatures), the runner runs a dispatch
// only if it carries a valid attestation whose leaf key is vouched for by a
// still-valid, in-scope X.509 certificate chaining to a trusted anchor, is
// inside the freshness window, and uses a nonce not seen before. This is the
// runner's strongest defense: a compromised control plane can relay a
// customer-authorized bridge's signed action but can neither forge, redirect,
// nor replay one.
//
// The v5 claim binds the exact public runner-reference set the operator selected,
// plus digests of the evidence/expectation narrative a human approver reads.
// A cert's CA-authored scope is a second, coarser ceiling: even a correctly
// targeted claim is refused outside the allowed group/labels. The leaf public key
// the attestation verifies under comes from the CA-verified cert, never from config.
package signing

import (
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"slices"
	"sort"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/runnerref"
)

// sha256HexLen is the length of a lower-hex SHA-256 digest.
const sha256HexLen = 64

// CAConfig is one trusted certificate authority as it comes from config: a
// PEM certificate, plus an optional display name. The name is advertised so an
// operator can confirm which anchors a host accepts; it carries no trust of
// its own, and defaults to the certificate's Subject common name.
type CAConfig struct {
	Name string
	PEM  string
}

// Attestation is the shared signed wire envelope. A nil *Attestation means the
// dispatch arrived unsigned; an empty CertChain means it arrived without the
// certificate the CA model requires.
type Attestation = attest.Envelope

// Dispatch is the runner-observed action intent. ArgsRaw is the exact JSON
// object token from the WSS message, preserved separately from the decoded map
// used by the execution engine.
type Dispatch struct {
	ActionID    string
	PackRef     string
	ArgsRaw     json.RawMessage
	Reason      string
	OperationID string
}

// Decision is the outcome of a check. When Allowed is false, Code is a short
// machine reason and Detail a human sentence — both surfaced to the operator
// (logs) and the cloud (the refusal result).
type Decision struct {
	Allowed bool
	Code    string
	Detail  string
}

var allow = Decision{Allowed: true}

func refuse(code, detail string) Decision { return Decision{Code: code, Detail: detail} }

// Verifier holds immutable trust policy and a reference to separately owned
// replay state. It is safe for concurrent use: the keyring is read-only after
// construction and NonceStore serializes nonce consumption. SIGHUP replaces a
// verifier but shares its store, so policy reloads cannot snapshot stale replay
// state or reopen an already consumed nonce.
type Verifier struct {
	enforce bool
	maxAge  time.Duration
	now     func() time.Time
	nonces  *NonceStore

	roots    *x509.CertPool    // trusted anchors; never contains a control-plane key
	caNames  []string          // advertised anchor labels, sorted
	runnerID string            // durable local external id, for public-ref suffix binding
	origin   string            // canonical local portal origin
	group    string            // this runner's group, for cert scope matching
	labels   map[string]string // this runner's labels, for cert scope matching
}

// NewVerifier parses the trusted CA keys and builds a verifier. enforce mirrors
// config.signing.enforce_signatures; maxAge must be positive. runnerID is the
// durable local identity checked against every claim target; group/labels are
// matched against the cert's scope. An enforcing
// verifier with no usable CAs is rejected (config validation already guards the
// empty case, but a CA key that fails to parse must not silently leave a runner
// enforcing with nothing to verify against).
//
// nonces is owned by the process-level caller and must be shared across every
// verifier replacement. OpenNonceStore handles startup durability failures.
func NewVerifier(enforce bool, cas []CAConfig, maxAge time.Duration, runnerID, portalOrigin, group string, labels map[string]string, nonces *NonceStore) (*Verifier, error) {
	if maxAge <= 0 {
		return nil, fmt.Errorf("signing: max attestation age must be positive")
	}
	if nonces == nil {
		return nil, fmt.Errorf("signing: nonce store is required")
	}
	roots := x509.NewCertPool()
	names := make([]string, 0, len(cas))
	for i, ca := range cas {
		block, _ := pem.Decode([]byte(ca.PEM))
		if block == nil || block.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("signing: trusted_cas[%d] is not a PEM CERTIFICATE block", i)
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("signing: trusted_cas[%d] does not parse: %w", i, err)
		}
		if !cert.BasicConstraintsValid || !cert.IsCA {
			return nil, fmt.Errorf("signing: trusted_cas[%d] (%s) is not a CA certificate", i, cert.Subject.CommonName)
		}
		roots.AddCert(cert)
		name := ca.Name
		if name == "" {
			name = cert.Subject.CommonName
		}
		names = append(names, name)
	}
	sort.Strings(names)
	if enforce && len(names) == 0 {
		return nil, fmt.Errorf("signing: enforcement is on with no trusted CAs")
	}
	if enforce && runnerID == "" {
		return nil, fmt.Errorf("signing: enforcement is on with no runner id")
	}
	if enforce && portalOrigin == "" {
		return nil, fmt.Errorf("signing: enforcement is on with no portal origin")
	}
	if enforce {
		if err := nonces.bindRetention(maxAge); err != nil {
			return nil, err
		}
	}

	return &Verifier{
		enforce:  enforce,
		maxAge:   maxAge,
		now:      time.Now,
		nonces:   nonces,
		roots:    roots,
		caNames:  names,
		runnerID: runnerID,
		origin:   portalOrigin,
		group:    group,
		labels:   labels,
	}, nil
}

// Enforces reports whether this runner enforces signatures — advertised to the
// cloud so it disables its own (operator/runbook) dispatch to this runner.
func (v *Verifier) Enforces() bool { return v.enforce }

// CAIDs returns the configured trusted-CA labels in sorted order. The runner
// advertises only these labels so an operator can confirm which anchors it
// accepts; the anchor certificates themselves remain local.
func (v *Verifier) CAIDs() []string {
	return slices.Clone(v.caNames)
}

// MaxAge is the attestation freshness window — advertised so the cloud can warn
// before dispatching a run that would be refused as stale (e.g. a slow approval).
func (v *Verifier) MaxAge() time.Duration { return v.maxAge }

// Check decides whether a dispatch may run. Enforcement off allows every
// dispatch. Enforcement on uses the single CA trust path, in this exact
// order: a present cert, a trusted + valid CA signature over it, the cert inside
// its own validity window, its scope satisfied by THIS runner's local identity,
// the attestation inside the (independent) freshness window, the leaf signature
// valid under the CERT's public key, and a never-seen nonce. The cert-validity
// and attestation-freshness windows are SEPARATE gates — a long cert TTL must not
// widen the replay window. A passing check CONSUMES the nonce so an identical
// replay is refused; a failing check never burns one.
func (v *Verifier) Check(dispatch Dispatch, att *Attestation) Decision {
	if !v.enforce {
		return allow
	}
	// 1. A signed dispatch must carry both the attestation and its certificate.
	if att == nil || len(att.CertChain) == 0 {
		return refuse("signature_required",
			"this runner runs only signed dispatches and this call carried no signed certificate")
	}
	// 2. The claim format and exact per-call target set are explicit. Certificate
	//    scope remains an additional CA-authored ceiling, not a replacement for
	//    binding the operator's selected runner identities.
	if att.Version != attest.Version {
		return refuse("attestation_version",
			fmt.Sprintf("attestation version %q is not supported", att.Version))
	}
	if att.Tool != attest.Tool {
		return refuse("attestation_tool",
			fmt.Sprintf("attestation tool %q is not supported", att.Tool))
	}
	if att.PortalOrigin != v.origin {
		return refuse("portal_mismatch", "the signed portal origin does not match this runner's control plane")
	}
	if dispatch.ActionID == "" || dispatch.PackRef == "" || dispatch.Reason == "" || dispatch.OperationID == "" {
		return refuse("intent_mismatch", "the delivered action intent is missing a required signed field")
	}
	if att.ActionID != dispatch.ActionID || att.PackRef != dispatch.PackRef ||
		att.Reason != dispatch.Reason || att.OperationID != dispatch.OperationID {
		return refuse("intent_mismatch", "the signed action intent does not match the delivered dispatch")
	}
	argsDigest, err := attest.ArgsSHA256(dispatch.ArgsRaw)
	if err != nil {
		return refuse("invalid_args", "the delivered action arguments are not one valid JSON object")
	}
	if att.ArgsSHA256 != argsDigest {
		return refuse("intent_mismatch", "the signed argument digest does not match the delivered arguments")
	}
	canonicalRunnerRefs, err := attest.CanonicalRunnerRefs(att.RunnerRefs)
	if err != nil || !slices.Equal(canonicalRunnerRefs, att.RunnerRefs) {
		return refuse("target_mismatch", "the signed runner reference set is invalid")
	}
	if !runnerref.ContainsLocal(att.RunnerRefs, v.runnerID) {
		return refuse("target_mismatch",
			"this runner generation is not named exactly once in the signed target set")
	}
	// 3. The signer emits 16 random bytes as lowercase hex, and step 7 journals
	//    every accepted nonce. The nonce journal reloads only that shape, within
	//    a 256-byte record, so accepting another one here would persist a record
	//    the next boot reads as a corrupt journal and refuse signed dispatch.
	if !validNonce(att.Nonce) {
		return refuse("bad_nonce", "the attestation nonce is not 32 lowercase hex characters")
	}
	// 4. The chain must verify to a configured anchor and satisfy the emisar
	//    profile — the profile is what stops a general-purpose CA in the same
	//    trust store from vouching for dispatch signing.
	chain, decodeErr := decodeCertChain(att.CertChain)
	if decodeErr != nil {
		return refuse(attest.CodeCertProfile, decodeErr.Error())
	}
	now := v.now()
	leaf, scope, err := attest.VerifyChain(v.roots, chain, now)
	if err != nil {
		var certErr *attest.CertError
		if errors.As(err, &certErr) {
			return refuse(certErr.Code, certErr.Reason)
		}
		return refuse(attest.CodeCertUntrusted, err.Error())
	}
	// 5. The cert's scope must be satisfied by THIS runner's local group/labels
	//    (never any value the control plane supplies — that is the redirect guard).
	if !scope.Matches(v.group, v.labels) {
		return refuse(attest.CodeCertScope,
			"this runner's group/labels do not satisfy the certificate's scope")
	}
	// 6. The attestation must be fresh — an INDEPENDENT gate from the cert window.
	issued, err := time.Parse(time.RFC3339, att.IssuedAt)
	if err != nil {
		return refuse("bad_issued_at", fmt.Sprintf("issued_at %q is not RFC3339", att.IssuedAt))
	}
	if age := now.Sub(issued); age > v.maxAge || age < -v.maxAge {
		return refuse("stale",
			fmt.Sprintf("issued_at %s is outside the +/-%s freshness window", att.IssuedAt, v.maxAge))
	}
	// 7. The attestation signature must verify under the leaf key the CERT
	//    vouches for, never anything from config.
	// The approver-facing narrative is bound by digest and never relayed to us,
	// so the envelope's digests ARE our copy of it. Taking them unchecked would
	// let a control plane pick the bytes we verify against; requiring the
	// canonical shape means a tampered digest fails as a bad signature rather
	// than as a malformed field.
	// An ABSENT digest is legitimate — it means the bridge sent no narrative, and
	// the claim then binds the digest of the empty string. A PRESENT one must be
	// canonical: a stripped or reshaped digest simply fails the signature below,
	// which is the outcome we want, but rejecting a malformed one here keeps the
	// refusal honest about what went wrong.
	if !narrativeDigestWellFormed(att.EvidenceSHA256) || !narrativeDigestWellFormed(att.ExpectedSHA256) {
		return refuse("bad_signature", "attestation narrative digest is not lower-hex SHA-256")
	}
	claim := attest.Claim{
		ActionID:       dispatch.ActionID,
		PackRef:        dispatch.PackRef,
		EvidenceSHA256: att.EvidenceSHA256,
		ExpectedSHA256: att.ExpectedSHA256,
		ArgsRaw:        dispatch.ArgsRaw,
		RunnerRefs:     att.RunnerRefs,
		Reason:         dispatch.Reason,
		OperationID:    dispatch.OperationID,
		PortalOrigin:   v.origin,
		Nonce:          att.Nonce,
		IssuedAt:       att.IssuedAt,
	}
	valid, err := attest.VerifyClaim(leaf, claim, att.Signature)
	if err != nil {
		return refuse("bad_signature", "signature is malformed")
	}
	if !valid {
		return refuse("bad_signature",
			"signature does not match the dispatched action intent")
	}
	// 8. The nonce must not have been seen — consuming it on success.
	ok, err := v.nonces.consume(att.Nonce, issued, v.now())
	if err != nil {
		return refuse("nonce_store_unavailable",
			"could not durably record the attestation nonce; refusing rather than risk a replay")
	}
	if !ok {
		return refuse("replayed", "this attestation nonce was already used")
	}
	return allow
}

func validNonce(nonce string) bool {
	if len(nonce) != 32 {
		return false
	}
	for _, char := range nonce {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

// narrativeDigestWellFormed reports whether a relayed narrative digest is either
// absent or exactly 64 lower-hex characters. Upper-case is rejected on purpose:
// the signed body carries one spelling, so accepting another would verify a
// digest that can never have been signed.
func narrativeDigestWellFormed(s string) bool {
	if s == "" {
		return true
	}
	if len(s) != sha256HexLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// decodeCertChain turns the wire's standard-base64 DER entries into raw DER.
// The count bound is applied here as well as in VerifyChain so an oversized
// chain is refused before any parsing work.
func decodeCertChain(encoded []string) ([][]byte, error) {
	if len(encoded) > attest.MaxChainCerts {
		return nil, fmt.Errorf("certificate chain has %d certificates, at most %d are accepted",
			len(encoded), attest.MaxChainCerts)
	}
	chain := make([][]byte, 0, len(encoded))
	for i, entry := range encoded {
		der, err := base64.StdEncoding.DecodeString(entry)
		if err != nil {
			return nil, fmt.Errorf("certificate %d is not valid base64", i)
		}
		chain = append(chain, der)
	}
	return chain, nil
}
