package main

// Bridge-attested dispatch is the bridge's one semantic exception. The
// operator's Ed25519 key lives only here, so the portal can relay an authorized
// run_action intent but cannot manufacture one. HTTPS and the API key already
// authenticate every ordinary bridge request; reads and other mutations are
// deliberately never signed.

import (
	"crypto"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const (
	attestationHeader = "Emisar-Attestation"
	// The header budget grew with the X.509 switch: a DER chain is larger than
	// the JSON certificate it replaced, and an RSA-issued leaf plus one
	// intermediate is the worst realistic case. The portal enforces the same
	// bound, and its HTTP stack is configured above it.
	maxAttestationHeaderBytes = 16 << 10
	maxSigningCertBytes       = 8 << 10

	// Mirror the run_action tool schema. A bound narrower than the schema turns
	// a valid call into "invalid input" and forwards it UNSIGNED.
	maxSignedReasonRunes = 2000
	// The portal's ActionRun changeset bounds these at 4,000 and 2,000. Matching
	// it exactly matters: a NARROWER bound here would forward a schema-valid
	// call unsigned, which is the same failure the reason bound already carries
	// a comment about.
	maxSignedEvidenceRunes = 4000
	maxSignedExpectedRunes = 2000
	maxSignedPackRefBytes  = 256
)

var operationPattern = regexp.MustCompile(`^op_[0-7][0-9A-HJKMNP-TV-Z]{25}$`)

// signer holds the leaf key and its certificate chain. The runner validates
// certificate trust, profile, and scope; the bridge only checks that the local
// key and certificate match before carrying the chain in an attestation.
type signer struct {
	key       crypto.Signer
	certChain []string // base64 DER, leaf first
	newNonce  func() (string, error)
}

// newSigner builds a signer from EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT.
// Both must be configured together. The key is base64 PKCS#8 and the chain is
// base64 of the PEM certificate text — both one line, so they paste into an env
// var or a secret manager without a heredoc.
//
// Everything checkable locally is checked here: an unusable key algorithm, a
// certificate that is not for emisar, or a key/certificate mismatch fails at
// startup rather than as an opaque refusal at an enforcing runner.
func newSigner(keyEncoded, certEncoded string) (*signer, error) {
	if keyEncoded == "" && certEncoded == "" {
		return nil, nil
	}
	if keyEncoded == "" || certEncoded == "" {
		return nil, fmt.Errorf(
			"both EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT must be set to sign dispatches")
	}
	key, err := parseSigningKey(keyEncoded)
	if err != nil {
		return nil, err
	}
	chain, leaf, err := parseSigningCertChain(certEncoded)
	if err != nil {
		return nil, err
	}
	signerPublic, ok := key.Public().(interface{ Equal(crypto.PublicKey) bool })
	if !ok || !signerPublic.Equal(leaf.PublicKey) {
		return nil, fmt.Errorf(
			"EMISAR_SIGNING_CERT vouches for a different key than EMISAR_SIGNING_KEY - " +
				"use the matching key+cert pair printed by `emisar signing new-cert`")
	}
	return &signer{key: key, certChain: chain, newNonce: newNonce}, nil
}

// parseSigningKey accepts only the algorithms the certificate profile signs
// with, so an unusable key is refused where the operator can act on it.
func parseSigningKey(encoded string) (crypto.Signer, error) {
	der, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_KEY is not valid base64: %w", err)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(der)
	if err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_KEY is not a PKCS#8 private key: %w", err)
	}
	key, ok := parsed.(crypto.Signer)
	if !ok {
		return nil, fmt.Errorf("EMISAR_SIGNING_KEY cannot sign")
	}
	if _, err := attest.SignClaim(key, probeClaim()); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_KEY: %w", err)
	}
	return key, nil
}

// probeClaim is a throwaway claim used only to prove the configured key can
// sign under this build's accepted algorithms.
func probeClaim() attest.Claim {
	return attest.Claim{
		ActionID: "probe", PackRef: "probe", ArgsRaw: json.RawMessage(`{}`),
		RunnerRefs: []string{"probe"}, Reason: "probe", OperationID: "probe",
		PortalOrigin: "probe", Nonce: "probe", IssuedAt: "2026-01-01T00:00:00Z",
	}
}

// parseSigningCertChain decodes the one-line chain into wire entries and the
// parsed leaf. The leaf must satisfy the parts of the profile a bridge can
// check without trust anchors — the runner still applies the whole profile.
func parseSigningCertChain(encoded string) ([]string, *x509.Certificate, error) {
	pemText, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil, nil, fmt.Errorf("EMISAR_SIGNING_CERT is not valid base64: %w", err)
	}
	if len(pemText) > maxSigningCertBytes {
		return nil, nil, fmt.Errorf(
			"EMISAR_SIGNING_CERT is %d bytes, limit is %d", len(pemText), maxSigningCertBytes)
	}
	var chain []string
	var leaf *x509.Certificate
	rest := pemText
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			return nil, nil, fmt.Errorf("EMISAR_SIGNING_CERT holds a %q block, want CERTIFICATE", block.Type)
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, nil, fmt.Errorf("EMISAR_SIGNING_CERT does not parse: %w", err)
		}
		if leaf == nil {
			leaf = cert
		}
		chain = append(chain, base64.StdEncoding.EncodeToString(block.Bytes))
	}
	if leaf == nil {
		return nil, nil, fmt.Errorf("EMISAR_SIGNING_CERT holds no PEM CERTIFICATE block")
	}
	if len(chain) > attest.MaxChainCerts {
		return nil, nil, fmt.Errorf(
			"EMISAR_SIGNING_CERT holds %d certificates, at most %d are accepted", len(chain), attest.MaxChainCerts)
	}
	if _, err := leafScopeURI(leaf); err != nil {
		return nil, nil, err
	}
	return chain, leaf, nil
}

// leafScopeURI checks the leaf carries exactly one canonical emisar scope SAN.
// A certificate without it is not for emisar, and an enforcing runner would
// refuse every dispatch it signed.
func leafScopeURI(leaf *x509.Certificate) (attest.Scope, error) {
	var found string
	for _, uri := range leaf.URIs {
		if uri.Scheme != "emisar" {
			continue
		}
		if found != "" {
			return attest.Scope{}, fmt.Errorf("EMISAR_SIGNING_CERT carries several emisar scope URIs")
		}
		found = uri.String()
	}
	if found == "" {
		return attest.Scope{}, fmt.Errorf(
			"EMISAR_SIGNING_CERT carries no %s scope URI - it was not issued for emisar dispatch signing",
			attest.ScopeURI)
	}
	scope, err := attest.ParseScopeURI(found)
	if err != nil {
		return attest.Scope{}, fmt.Errorf("EMISAR_SIGNING_CERT scope: %w", err)
	}
	return scope, nil
}

// couldBeRunActionCall cheaply rules a frame out before signFrame pays
// parseProtocolJSON's full strict re-validation for it. It mirrors the exact
// per-key extraction the authoritative parse performs (envelope "method",
// params "name"), so on a serve-validated frame the skip decision can never
// disagree with it: any frame this rejects is one parseProtocolJSON would
// answer with a non-run_action result or an error — both of which signFrame
// already forwards unsigned for the portal's own validation.
func couldBeRunActionCall(frame []byte) bool {
	var envelope map[string]json.RawMessage
	if json.Unmarshal(frame, &envelope) != nil || envelope == nil {
		return false
	}
	method, err := exactJSONString(envelope, "method")
	if err != nil || method != "tools/call" {
		return false
	}
	var params map[string]json.RawMessage
	if json.Unmarshal(envelope["params"], &params) != nil {
		return false
	}
	name, err := exactJSONString(params, "name")
	return err == nil && name == attest.Tool
}

// signFrame returns a private action-attestation header for one valid
// tools/call name=run_action. It never changes frame. Invalid action input
// returns no header so the portal can return its normal schema error. Once a
// valid action reaches cryptographic signing, however, an internal failure is
// returned and the request is not sent unsigned.
func (s *signer) signFrame(frame []byte, operationID, portalOrigin string) (string, error) {
	if !couldBeRunActionCall(frame) {
		return "", nil
	}
	parsed, err := parseProtocolJSON(frame)
	if err != nil || parsed.Method != "tools/call" || parsed.ToolName != attest.Tool {
		return "", nil
	}
	canonicalOrigin, err := parseEndpoint(portalOrigin, true)
	if !operationPattern.MatchString(operationID) {
		return "", fmt.Errorf("invalid bridge operation ID")
	}
	if err != nil || canonicalOrigin != portalOrigin {
		return "", fmt.Errorf("invalid canonical portal origin")
	}

	var arguments map[string]json.RawMessage
	if err := json.Unmarshal(parsed.Arguments, &arguments); err != nil {
		return "", nil
	}
	actionID, actionErr := exactJSONString(arguments, "action_id")
	packRef, packErr := exactJSONString(arguments, "pack_ref")
	reason, reasonErr := exactJSONString(arguments, "reason")
	// Optional, so an absent field is not an error — but a PRESENT one that is
	// not a string is, because signing over "" would bind the wrong fact.
	evidence, evidenceOK := optionalJSONString(arguments, "evidence")
	expected, expectedOK := optionalJSONString(arguments, "expected")
	var requestedRunnerRefs []string
	refsErr := json.Unmarshal(arguments["runner_refs"], &requestedRunnerRefs)
	if actionErr != nil || packErr != nil || reasonErr != nil || refsErr != nil ||
		!evidenceOK || !expectedOK ||
		!validSignedAction(actionID, packRef, reason, evidence, expected) {
		return "", nil
	}
	runnerRefs, ok := signedRunnerRefs(requestedRunnerRefs)
	if !ok {
		return "", nil
	}

	nonce, err := s.newNonce()
	if err != nil {
		return "", fmt.Errorf("generate attestation nonce: %w", err)
	}
	issuedAt := time.Now().UTC().Format(time.RFC3339)
	claim := attest.Claim{
		ActionID:     actionID,
		PackRef:      packRef,
		ArgsRaw:      parsed.ActionArgs,
		RunnerRefs:   runnerRefs,
		Reason:       reason,
		Evidence:     evidence,
		Expected:     expected,
		OperationID:  operationID,
		PortalOrigin: portalOrigin,
		Nonce:        nonce,
		IssuedAt:     issuedAt,
	}
	sig, err := attest.SignClaim(s.key, claim)
	if err != nil {
		return "", fmt.Errorf("sign action attestation: %w", err)
	}

	argsDigest, err := attest.ArgsSHA256(parsed.ActionArgs)
	if err != nil {
		return "", fmt.Errorf("digest action arguments: %w", err)
	}
	envelope, err := json.Marshal(attest.Envelope{
		Version:        attest.Version,
		Tool:           attest.Tool,
		PortalOrigin:   portalOrigin,
		ActionID:       actionID,
		PackRef:        packRef,
		ArgsSHA256:     argsDigest,
		RunnerRefs:     runnerRefs,
		Reason:         reason,
		EvidenceSHA256: attest.TextSHA256(evidence),
		ExpectedSHA256: attest.TextSHA256(expected),
		OperationID:    operationID,
		Nonce:          nonce,
		IssuedAt:       issuedAt,
		Signature:      sig,
		CertChain:      s.certChain,
	})
	if err != nil {
		return "", fmt.Errorf("encode action attestation: %w", err)
	}
	header := base64.RawURLEncoding.EncodeToString(envelope)
	if len(header) > maxAttestationHeaderBytes {
		return "", fmt.Errorf("action attestation is %d bytes, limit is %d", len(header), maxAttestationHeaderBytes)
	}
	return header, nil
}

// optionalJSONString reads a field that may be absent. Absent is ("", true);
// present-but-not-a-string is ("", false), which refuses the signature rather
// than binding the empty string over a value we could not read.
func optionalJSONString(arguments map[string]json.RawMessage, key string) (string, bool) {
	raw, present := arguments[key]
	if !present || string(raw) == "null" {
		return "", true
	}
	value, err := exactJSONString(arguments, key)
	if err != nil {
		return "", false
	}
	return value, true
}

func validSignedAction(actionID, packRef, reason, evidence, expected string) bool {
	// The portal and runner own field syntax and schema validation. The bridge
	// checks only the presence and wire budgets needed to form an unambiguous,
	// bounded claim, avoiding a third copy of catalog validation rules.
	//
	// These bounds must not be NARROWER than the tool schema, or a
	// schema-valid call reads as invalid input here and is forwarded unsigned.
	// reason is maxLength 2000 in the registry and bounded in CHARACTERS by the
	// portal's verifier, so count runes: a byte bound put ~90 CJK characters
	// over the line. The 8 KiB header check at the end of signFrame is the real
	// budget, and it fails closed.
	return actionID != "" && len(actionID) <= 128 &&
		packRef != "" && len(packRef) <= maxSignedPackRefBytes &&
		utf8.RuneCountInString(reason) <= maxSignedReasonRunes &&
		strings.TrimSpace(reason) != "" &&
		utf8.RuneCountInString(evidence) <= maxSignedEvidenceRunes &&
		utf8.RuneCountInString(expected) <= maxSignedExpectedRunes
}

// signedRunnerRefs copies and sorts the exact public runner generation refs.
// Fan-out order is not semantic, and duplicates would make the target set
// ambiguous, so they are rejected rather than silently deduplicated.
func signedRunnerRefs(input []string) ([]string, bool) {
	refs, err := attest.CanonicalRunnerRefs(input)
	if err != nil {
		return nil, false
	}
	return refs, true
}

// newNonce returns a 16-byte random token bound into the signature. Runner-local
// durable replay protection refuses reuse even if the portal replays a header.
func newNonce() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}
