package main

// Client-attested dispatch is the bridge's one semantic exception. The
// operator's Ed25519 key lives only here, so the portal can relay an authorized
// run_action intent but cannot manufacture one. HTTPS and the API key already
// authenticate every ordinary bridge request; reads and other mutations are
// deliberately never signed.

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/andrewdryga/emisar/mcp/internal/attest"
)

const (
	attestationHeader         = "Emisar-Attestation"
	maxAttestationHeaderBytes = 8 << 10
	maxSigningCertBytes       = 2 << 10
)

var operationPattern = regexp.MustCompile(`^op_[0-7][0-9A-HJKMNP-TV-Z]{25}$`)

// signer holds the leaf key and CA-signed certificate. The runner validates
// certificate trust and scope; the bridge only checks that local key and cert
// match before carrying the certificate in an action attestation.
type signer struct {
	priv     ed25519.PrivateKey
	cert     *attest.Cert
	newNonce func() (string, error)
}

// newSigner builds a signer from EMISAR_SIGNING_KEY and EMISAR_SIGNING_CERT.
// Both must be configured together. The certificate JSON is decoded strictly
// so duplicate or unknown fields cannot disguise the credential being carried.
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

	if err := validateStrictJSON([]byte(certJSON)); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT is not valid JSON: %w", err)
	}
	if err := validateCertFieldNames([]byte(certJSON)); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT is not valid JSON: %w", err)
	}
	decoder := json.NewDecoder(strings.NewReader(certJSON))
	decoder.DisallowUnknownFields()
	var cert attest.Cert
	if err := decoder.Decode(&cert); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT is not valid JSON: %w", err)
	}
	if err := ensureJSONEOF(decoder); err != nil {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT must contain one JSON object: %w", err)
	}
	wireCert, err := json.Marshal(cert)
	if err != nil {
		return nil, fmt.Errorf("encode EMISAR_SIGNING_CERT: %w", err)
	}
	if len(wireCert) > maxSigningCertBytes {
		return nil, fmt.Errorf("EMISAR_SIGNING_CERT is %d bytes, limit is %d", len(wireCert), maxSigningCertBytes)
	}
	if leafPub := hex.EncodeToString(priv.Public().(ed25519.PublicKey)); cert.PublicKey != leafPub {
		return nil, fmt.Errorf(
			"EMISAR_SIGNING_CERT vouches for a different key than EMISAR_SIGNING_KEY - " +
				"use the matching key+cert pair printed by `emisar signing new-cert`")
	}
	return &signer{priv: priv, cert: &cert, newNonce: newNonce}, nil
}

func validateCertFieldNames(raw []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil || fields == nil {
		return errors.New("certificate must be a JSON object")
	}
	for key := range fields {
		switch key {
		case "ca_id", "key_id", "public_key", "valid_from", "valid_until", "serial", "sig":
		case "scope":
			var scope map[string]json.RawMessage
			if err := json.Unmarshal(fields[key], &scope); err != nil || scope == nil {
				return errors.New("certificate scope must be a JSON object")
			}
			for scopeKey := range scope {
				if scopeKey != "group" && scopeKey != "labels" {
					return fmt.Errorf("unknown certificate scope field %q", scopeKey)
				}
			}
		default:
			return fmt.Errorf("unknown certificate field %q", key)
		}
	}
	return nil
}

// signFrame returns a private action-attestation header for one valid
// tools/call name=run_action. It never changes frame. Invalid action input
// returns no header so the portal can return its normal schema error. Once a
// valid action reaches cryptographic signing, however, an internal failure is
// returned and the request is not sent unsigned.
func (s *signer) signFrame(frame []byte, operationID, portalOrigin string) (string, error) {
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
	var requestedRunnerRefs []string
	refsErr := json.Unmarshal(arguments["runner_refs"], &requestedRunnerRefs)
	if actionErr != nil || packErr != nil || reasonErr != nil || refsErr != nil ||
		!validSignedAction(actionID, packRef, reason) {
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
		OperationID:  operationID,
		PortalOrigin: portalOrigin,
		Nonce:        nonce,
		IssuedAt:     issuedAt,
	}
	sig, err := attest.Sign(s.priv, claim)
	if err != nil {
		return "", fmt.Errorf("sign action attestation: %w", err)
	}

	argsDigest, err := attest.ArgsSHA256(parsed.ActionArgs)
	if err != nil {
		return "", fmt.Errorf("digest action arguments: %w", err)
	}
	envelope, err := json.Marshal(attest.Envelope{
		Version:      attest.Version,
		Tool:         attest.Tool,
		PortalOrigin: portalOrigin,
		ActionID:     actionID,
		PackRef:      packRef,
		ArgsSHA256:   argsDigest,
		RunnerRefs:   runnerRefs,
		Reason:       reason,
		OperationID:  operationID,
		Nonce:        nonce,
		IssuedAt:     issuedAt,
		Signature:    sig,
		Cert:         s.cert,
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

func validSignedAction(actionID, packRef, reason string) bool {
	// The portal and runner own field syntax and schema validation. The bridge
	// checks only the presence and wire budgets needed to form an unambiguous,
	// bounded claim, avoiding a third copy of catalog validation rules.
	return actionID != "" && len(actionID) <= 128 &&
		packRef != "" && len(packRef) <= 256 &&
		len(reason) <= 255 && strings.TrimSpace(reason) != ""
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
