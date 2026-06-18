package signing

import (
	"crypto/ed25519"
	"encoding/hex"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
)

const fixedNow = "2026-06-17T12:00:00Z"

func mustParse(t *testing.T, s string) time.Time {
	t.Helper()
	ts, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatalf("parse %q: %v", s, err)
	}
	return ts
}

// newTestVerifier returns an enforcing verifier whose clock is pinned to
// fixedNow, plus the private key callers sign vectors with.
func newTestVerifier(t *testing.T) (*Verifier, ed25519.PrivateKey) {
	t.Helper()
	seed, _ := hex.DecodeString("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
	priv := ed25519.NewKeyFromSeed(seed)
	pub := priv.Public().(ed25519.PublicKey)

	v, err := NewVerifier(true, []KeyConfig{{KeyID: "k1", PublicKeyHex: hex.EncodeToString(pub)}}, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	v.now = func() time.Time { return mustParse(t, fixedNow) }
	return v, priv
}

// sign produces a valid attestation for the given dispatch at issuedAt.
func sign(t *testing.T, priv ed25519.PrivateKey, actionID string, args map[string]any, nonce, issuedAt string) *Attestation {
	t.Helper()
	sig, err := attest.Sign(priv, attest.Claim{ActionID: actionID, Args: args, Nonce: nonce, IssuedAt: issuedAt})
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	return &Attestation{KeyID: "k1", Signature: sig, Nonce: nonce, IssuedAt: issuedAt}
}

func TestNewVerifierRejectsBadKeys(t *testing.T) {
	if _, err := NewVerifier(true, []KeyConfig{{KeyID: "k", PublicKeyHex: "zz"}}, time.Hour); err == nil {
		t.Fatal("expected error for non-hex public key")
	}
	if _, err := NewVerifier(true, []KeyConfig{{KeyID: "k", PublicKeyHex: "00"}}, time.Hour); err == nil {
		t.Fatal("expected error for wrong-length public key")
	}
	if _, err := NewVerifier(true, nil, time.Hour); err == nil {
		t.Fatal("expected error for enforcement with no keys")
	}
	if _, err := NewVerifier(false, nil, time.Hour); err != nil {
		t.Fatalf("non-enforcing verifier with no keys should be fine: %v", err)
	}
}

func TestCheckEnforcementOffAlwaysAllows(t *testing.T) {
	v, err := NewVerifier(false, nil, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	if d := v.Check("a.b", map[string]any{"x": 1}, nil); !d.Allowed {
		t.Fatalf("non-enforcing runner must allow an unsigned dispatch, got %+v", d)
	}
}

func TestCheckHappyPath(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"container": "web", "force": true}
	att := sign(t, priv, "docker.restart", args, "n1", fixedNow)
	if d := v.Check("docker.restart", args, att); !d.Allowed {
		t.Fatalf("valid signed dispatch refused: %+v", d)
	}
}

func TestCheckRefusals(t *testing.T) {
	args := map[string]any{"container": "web"}

	tests := []struct {
		name string
		att  func(t *testing.T, priv ed25519.PrivateKey) *Attestation
		code string
	}{
		{"missing attestation", func(*testing.T, ed25519.PrivateKey) *Attestation { return nil }, "signature_required"},
		{"empty nonce", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "", fixedNow)
		}, "bad_nonce"},
		{"unknown key", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "n1", fixedNow)
			a.KeyID = "other"
			return a
		}, "unknown_key"},
		{"bad issued_at", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "n1", "not-a-time")
			a.IssuedAt = "not-a-time"
			return a
		}, "bad_issued_at"},
		{"stale (past)", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "n1", "2026-06-17T10:00:00Z")
		}, "stale"},
		{"stale (future skew)", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			return sign(t, priv, "docker.restart", args, "n1", "2026-06-17T14:00:00Z")
		}, "stale"},
		{"malformed signature", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			a := sign(t, priv, "docker.restart", args, "n1", fixedNow)
			a.Signature = "not-hex!!"
			return a
		}, "bad_signature"},
		{"signature over different args", func(t *testing.T, priv ed25519.PrivateKey) *Attestation {
			// Signed for {container: db} but dispatched with {container: web}.
			return sign(t, priv, "docker.restart", map[string]any{"container": "db"}, "n1", fixedNow)
		}, "bad_signature"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			v, priv := newTestVerifier(t)
			d := v.Check("docker.restart", args, tc.att(t, priv))
			if d.Allowed {
				t.Fatalf("expected refusal, got allowed")
			}
			if d.Code != tc.code {
				t.Fatalf("code = %q, want %q (detail: %s)", d.Code, tc.code, d.Detail)
			}
		})
	}
}

func TestCheckReplayRefused(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}
	att := sign(t, priv, "a.b", args, "once", fixedNow)

	if d := v.Check("a.b", args, att); !d.Allowed {
		t.Fatalf("first use must pass: %+v", d)
	}
	d := v.Check("a.b", args, att)
	if d.Allowed || d.Code != "replayed" {
		t.Fatalf("replay must be refused as 'replayed', got %+v", d)
	}
}

func TestRefusalDoesNotBurnNonce(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{"x": float64(1)}

	// A tampered dispatch (signature over different args) is refused...
	bad := sign(t, priv, "a.b", map[string]any{"x": float64(2)}, "n1", fixedNow)
	if d := v.Check("a.b", args, bad); d.Allowed {
		t.Fatal("tampered dispatch should be refused")
	}
	// ...and must not have consumed nonce "n1": a later legitimate dispatch
	// that happens to reuse it still works.
	good := sign(t, priv, "a.b", args, "n1", fixedNow)
	if d := v.Check("a.b", args, good); !d.Allowed {
		t.Fatalf("a refused dispatch must not burn its nonce: %+v", d)
	}
}

func TestNoncePruning(t *testing.T) {
	v, priv := newTestVerifier(t)
	args := map[string]any{}

	// Consume a nonce at the fixed now.
	att := sign(t, priv, "a.b", args, "old", fixedNow)
	if d := v.Check("a.b", args, att); !d.Allowed {
		t.Fatalf("first use must pass: %+v", d)
	}

	// Advance the clock past the window and consume a fresh nonce — the prune
	// pass should evict "old", keeping the cache bounded.
	later := mustParse(t, fixedNow).Add(2 * time.Hour)
	v.now = func() time.Time { return later }
	fresh := sign(t, priv, "a.b", args, "new", later.Format(time.RFC3339))
	if d := v.Check("a.b", args, fresh); !d.Allowed {
		t.Fatalf("fresh nonce at the new time must pass: %+v", d)
	}

	v.mu.Lock()
	_, oldStillThere := v.seen["old"]
	size := len(v.seen)
	v.mu.Unlock()
	if oldStillThere {
		t.Fatal("expired nonce was not pruned")
	}
	if size != 1 {
		t.Fatalf("nonce cache size = %d, want 1 (only the fresh nonce)", size)
	}
}
