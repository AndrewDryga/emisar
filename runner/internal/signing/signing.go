// Package signing verifies client-attested dispatches on the runner. With
// enforcement on (config signing.enforce_signatures), the runner runs a dispatch
// only if it carries a valid Ed25519 attestation whose leaf key is vouched for by
// a still-valid, in-scope certificate from a trusted CA, is inside the freshness
// window, and uses a nonce not seen before. This is the runner's strongest
// defense: a compromised control plane can relay a real user's MCP-signed action
// but can neither forge, redirect, nor replay one.
//
// The v4 claim binds the exact public runner-reference set the operator selected.
// A cert's CA-authored scope is a second, coarser ceiling: even a correctly
// targeted claim is refused outside the allowed group/labels. The leaf public key
// the attestation verifies under comes from the CA-verified cert, never from config.
package signing

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/runnerref"
)

// CAConfig is one trusted certificate-authority public key as it comes from config.
type CAConfig struct {
	CAID         string
	PublicKeyHex string
}

// Attestation is the shared signed wire envelope. A nil *Attestation means the
// dispatch arrived unsigned; a nil Cert means it arrived without the certificate
// the CA model requires.
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

	cas      map[string]ed25519.PublicKey // ca_id -> CA public key
	runnerID string                       // durable local external id, for public-ref suffix binding
	origin   string                       // canonical local portal origin
	group    string                       // this runner's group, for cert scope matching
	labels   map[string]string            // this runner's labels, for cert scope matching
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
	ring := make(map[string]ed25519.PublicKey, len(cas))
	for _, ca := range cas {
		raw, err := hex.DecodeString(ca.PublicKeyHex)
		if err != nil {
			return nil, fmt.Errorf("signing: CA %q public_key is not valid hex: %w", ca.CAID, err)
		}
		if len(raw) != ed25519.PublicKeySize {
			return nil, fmt.Errorf(
				"signing: CA %q public_key is %d bytes, want %d (an Ed25519 public key)",
				ca.CAID, len(raw), ed25519.PublicKeySize)
		}
		ring[ca.CAID] = ed25519.PublicKey(raw)
	}
	if enforce && len(ring) == 0 {
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
		cas:      ring,
		runnerID: runnerID,
		origin:   portalOrigin,
		group:    group,
		labels:   labels,
	}, nil
}

// Enforces reports whether this runner enforces signatures — advertised to the
// cloud so it disables its own (operator/runbook) dispatch to this runner.
func (v *Verifier) Enforces() bool { return v.enforce }

// CAIDs returns the trusted CA ids in sorted order — advertised to the cloud so
// an operator can confirm which CA(s) this runner accepts. Safe metadata: the
// public-key bytes never leave the host, only their ids.
func (v *Verifier) CAIDs() []string {
	ids := make([]string, 0, len(v.cas))
	for id := range v.cas {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
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
	if att == nil || att.Cert == nil {
		return refuse("signature_required",
			"this runner runs only signed dispatches and this call carried no signed certificate")
	}
	cert := att.Cert
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
	// 3. The signer emits 16 random bytes as lowercase hex. Keeping that exact
	//    shape bounds replay keys and rejects delimiter/control-character input
	//    even though the v4 signed body is independently unambiguous.
	if !validNonce(att.Nonce) {
		return refuse("bad_nonce", "the attestation nonce is not 32 lowercase hex characters")
	}
	// 4. The cert's CA must be one this runner trusts.
	caPub, ok := v.cas[cert.CAID]
	if !ok {
		return refuse("cert_untrusted", fmt.Sprintf("no trusted CA with id %q", cert.CAID))
	}
	// 5. The CA's signature over the cert must verify.
	validCert, err := attest.VerifyCert(caPub, *cert)
	if err != nil {
		return refuse("cert_untrusted", "certificate signature is malformed")
	}
	if !validCert {
		return refuse("cert_untrusted", "certificate signature does not verify under the trusted CA")
	}
	// 6. The cert must be inside its own absolute validity window.
	from, err := time.Parse(time.RFC3339, cert.ValidFrom)
	if err != nil {
		return refuse("cert_expired", fmt.Sprintf("certificate valid_from %q is not RFC3339", cert.ValidFrom))
	}
	until, err := time.Parse(time.RFC3339, cert.ValidUntil)
	if err != nil {
		return refuse("cert_expired", fmt.Sprintf("certificate valid_until %q is not RFC3339", cert.ValidUntil))
	}
	now := v.now()
	if now.Before(from) || now.After(until) {
		return refuse("cert_expired",
			fmt.Sprintf("certificate is valid %s..%s, outside that window now", cert.ValidFrom, cert.ValidUntil))
	}
	// 7. The cert's scope must be satisfied by THIS runner's local group/labels
	//    (never any value the control plane supplies — that is the redirect guard).
	if !scopeSatisfied(cert.Scope, v.group, v.labels) {
		return refuse("cert_scope",
			"this runner's group/labels do not satisfy the certificate's scope")
	}
	// 8. The attestation must be fresh — an INDEPENDENT gate from the cert window.
	issued, err := time.Parse(time.RFC3339, att.IssuedAt)
	if err != nil {
		return refuse("bad_issued_at", fmt.Sprintf("issued_at %q is not RFC3339", att.IssuedAt))
	}
	if age := now.Sub(issued); age > v.maxAge || age < -v.maxAge {
		return refuse("stale",
			fmt.Sprintf("issued_at %s is outside the +/-%s freshness window", att.IssuedAt, v.maxAge))
	}
	// 9. The attestation signature must verify under the leaf key the CERT
	//    vouches for (validated hex/length before use), not anything from config.
	leaf, err := hex.DecodeString(cert.PublicKey)
	if err != nil || len(leaf) != ed25519.PublicKeySize {
		return refuse("bad_signature", "certificate public_key is not a valid Ed25519 key")
	}
	claim := attest.Claim{
		ActionID:     dispatch.ActionID,
		PackRef:      dispatch.PackRef,
		ArgsRaw:      dispatch.ArgsRaw,
		RunnerRefs:   att.RunnerRefs,
		Reason:       dispatch.Reason,
		OperationID:  dispatch.OperationID,
		PortalOrigin: v.origin,
		Nonce:        att.Nonce,
		IssuedAt:     att.IssuedAt,
	}
	valid, err := attest.Verify(ed25519.PublicKey(leaf), claim, att.Signature)
	if err != nil {
		return refuse("bad_signature", "signature is malformed")
	}
	if !valid {
		return refuse("bad_signature",
			"signature does not match the dispatched action intent")
	}
	// 10. The nonce must not have been seen — consuming it on success.
	ok, err = v.nonces.consume(att.Nonce, issued, v.now())
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

// scopeSatisfied reports whether this runner's local identity satisfies the
// cert's scope. Group: "" = any group; else an exact match. Labels: every k,v in
// the scope must equal this runner's label for k (a subset constraint). Matched
// ONLY against the runner's own group/labels — never any value the control plane
// supplies — so the offline CA, not the portal, decides where a cert is valid.
func scopeSatisfied(s attest.Scope, group string, labels map[string]string) bool {
	if s.Group != "" && s.Group != group {
		return false
	}
	for k, v := range s.Labels {
		if labels[k] != v {
			return false
		}
	}
	return true
}
