// Package signing verifies client-attested dispatches on the runner. With
// enforcement on (config signing.enforce_signatures), the runner runs a dispatch
// only if it carries a valid Ed25519 signature from a trusted key, is inside the
// freshness window, and uses a nonce not seen before. This is the runner's
// strongest defense: a compromised control plane can relay a real user's
// MCP-signed action but can neither forge nor replay one.
//
// The runner-target binding is the KEY itself — the runner trusts only the
// key_id(s) in its config — so a dispatch signed for a different trust domain
// fails here. The signed claim therefore binds the action, args, nonce, and
// time, not a runner identity the signer and runner can't agree on.
package signing

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"sync"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
)

// KeyConfig is one trusted public key as it comes from config.
type KeyConfig struct {
	KeyID        string
	PublicKeyHex string
}

// Attestation is the runner's view of the signed envelope a dispatch carries.
// A nil *Attestation means the dispatch arrived unsigned.
type Attestation struct {
	KeyID     string
	Signature string
	Nonce     string
	IssuedAt  string
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

// Verifier holds the trusted keyring and replay state. Safe for concurrent use:
// the keyring is read-only after construction and the nonce cache is mutex-guarded.
type Verifier struct {
	enforce bool
	maxAge  time.Duration
	now     func() time.Time

	keys map[string]ed25519.PublicKey // key_id -> public key

	mu   sync.Mutex
	seen map[string]time.Time // nonce -> issued_at, pruned by maxAge
}

// NewVerifier parses the trusted keys and builds a verifier. enforce mirrors
// config.signing.enforce_signatures; maxAge must be positive. An enforcing
// verifier with no usable keys is rejected (config validation already guards
// the empty-keys case, but a key that fails to parse must not silently leave a
// runner enforcing with nothing to verify against).
func NewVerifier(enforce bool, keys []KeyConfig, maxAge time.Duration) (*Verifier, error) {
	if maxAge <= 0 {
		return nil, fmt.Errorf("signing: max attestation age must be positive")
	}
	ring := make(map[string]ed25519.PublicKey, len(keys))
	for _, k := range keys {
		raw, err := hex.DecodeString(k.PublicKeyHex)
		if err != nil {
			return nil, fmt.Errorf("signing: key %q public_key is not valid hex: %w", k.KeyID, err)
		}
		if len(raw) != ed25519.PublicKeySize {
			return nil, fmt.Errorf(
				"signing: key %q public_key is %d bytes, want %d (an Ed25519 public key)",
				k.KeyID, len(raw), ed25519.PublicKeySize)
		}
		ring[k.KeyID] = ed25519.PublicKey(raw)
	}
	if enforce && len(ring) == 0 {
		return nil, fmt.Errorf("signing: enforcement is on with no trusted keys")
	}
	return &Verifier{
		enforce: enforce,
		maxAge:  maxAge,
		now:     time.Now,
		keys:    ring,
		seen:    make(map[string]time.Time),
	}, nil
}

// Enforces reports whether this runner enforces signatures — advertised to the
// cloud so it disables its own (operator/runbook) dispatch to this runner.
func (v *Verifier) Enforces() bool { return v.enforce }

// Check decides whether a dispatch may run. Enforcement off → always allow
// (legacy trust). Enforcement on → require a present, in-window, non-replayed,
// validly-signed attestation. A passing check CONSUMES the nonce so an identical
// replay is refused; a failing check never burns one.
func (v *Verifier) Check(actionID string, args map[string]any, att *Attestation) Decision {
	if !v.enforce {
		return allow
	}
	if att == nil {
		return refuse("signature_required",
			"this runner runs only signed dispatches and this call carried no signature")
	}
	if att.Nonce == "" {
		return refuse("bad_nonce", "the attestation carried no nonce")
	}
	pub, ok := v.keys[att.KeyID]
	if !ok {
		return refuse("unknown_key", fmt.Sprintf("no trusted key with id %q", att.KeyID))
	}
	issued, err := time.Parse(time.RFC3339, att.IssuedAt)
	if err != nil {
		return refuse("bad_issued_at", fmt.Sprintf("issued_at %q is not RFC3339", att.IssuedAt))
	}
	if age := v.now().Sub(issued); age > v.maxAge || age < -v.maxAge {
		return refuse("stale",
			fmt.Sprintf("issued_at %s is outside the +/-%s freshness window", att.IssuedAt, v.maxAge))
	}

	// Verify the signature over the EXACT issued_at/nonce strings (the parse
	// above is only for the freshness comparison; the signed bytes use the raw
	// strings the signer sent).
	claim := attest.Claim{ActionID: actionID, Args: args, Nonce: att.Nonce, IssuedAt: att.IssuedAt}
	valid, err := attest.Verify(pub, claim, att.Signature)
	if err != nil {
		return refuse("bad_signature", "signature is malformed")
	}
	if !valid {
		return refuse("bad_signature",
			"signature does not match the dispatched action, args, nonce, or time")
	}

	if !v.consumeNonce(att.Nonce, issued) {
		return refuse("replayed", "this attestation nonce was already used")
	}
	return allow
}

// consumeNonce records the nonce, returning false if it was already used. It
// prunes entries whose issued_at predates the window first, so the cache stays
// bounded by the dispatch rate over maxAge.
func (v *Verifier) consumeNonce(nonce string, issued time.Time) bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	cutoff := v.now().Add(-v.maxAge)
	for n, t := range v.seen {
		if t.Before(cutoff) {
			delete(v.seen, n)
		}
	}
	if _, used := v.seen[nonce]; used {
		return false
	}
	v.seen[nonce] = issued
	return true
}
