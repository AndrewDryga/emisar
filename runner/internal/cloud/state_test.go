package cloud

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/signing"
)

const echoAction = `
schema_version: 1
id: t.echo
title: Echo
kind: exec
risk: low
description: d
side_effects: [none]
args:
  - name: msg
    type: string
    required: true
execution:
  command:
    binary: /bin/echo
    argv: ["{{ args.msg }}"]
  timeout: 5s
  timeout_min: 1s
  timeout_max: 30s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

const packManifest = `schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
`

func setupRegistry(t *testing.T) *packs.Registry {
	t.Helper()
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(packManifest), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoAction), 0o644))
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	must(err)
	return reg
}

func TestStateBuilder_AdvertisesActionsAndPacks(t *testing.T) {
	reg := setupRegistry(t)
	b := &StateBuilder{
		AgentID:     "agt_test",
		Version:     "0.2.0",
		Labels:      map[string]string{"role": "test"},
		GetRegistry: func() *packs.Registry { return reg },
	}
	msg := b.Build()
	if msg.Type != MsgRunnerState {
		t.Fatalf("type=%s", msg.Type)
	}
	if msg.ProtocolVersion != ProtocolVersion {
		t.Fatalf("protocol version=%d", msg.ProtocolVersion)
	}
	if len(msg.Actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(msg.Actions))
	}
	a := msg.Actions[0]
	if a.ID != "t.echo" {
		t.Fatalf("action id=%q", a.ID)
	}
	if a.Limits.DefaultTimeout.String() != "5s" {
		t.Fatalf("default timeout=%s", a.Limits.DefaultTimeout)
	}
	if a.Limits.TimeoutMin.String() != "1s" || a.Limits.TimeoutMax.String() != "30s" {
		t.Fatalf("timeout bounds: min=%s max=%s", a.Limits.TimeoutMin, a.Limits.TimeoutMax)
	}
	if pi, ok := msg.Packs["t"]; !ok || pi.Hash == "" {
		t.Fatalf("pack info missing or no hash: %+v", msg.Packs)
	}
}

// enforcingVerifier builds a signature verifier that enforces and trusts the
// given key ids (24h freshness window). The keys are random — these tests
// assert the advertised metadata, never verify a signature.
func enforcingVerifier(t *testing.T, keyIDs ...string) *signing.Verifier {
	t.Helper()
	keys := make([]signing.KeyConfig, len(keyIDs))
	for i, id := range keyIDs {
		pub, _, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatalf("GenerateKey: %v", err)
		}
		keys[i] = signing.KeyConfig{KeyID: id, PublicKeyHex: hex.EncodeToString(pub)}
	}
	v, err := signing.NewVerifier(true, keys, 24*time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return v
}

func TestStateBuilder_AdvertisesEnforceSignatures(t *testing.T) {
	reg := setupRegistry(t)

	// No verifier: enforcement off, omitted from the wire (omitempty) so older
	// clouds see nothing new.
	off := (&StateBuilder{AgentID: "a", Version: "v", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if off.EnforceSignatures {
		t.Fatal("default state must not advertise enforcement")
	}
	if raw, _ := json.Marshal(off); strings.Contains(string(raw), "enforce_signatures") {
		t.Fatalf("enforce_signatures should be omitted when off: %s", raw)
	}

	// A present-but-non-enforcing verifier — the real "enforcement off" config
	// state, since the client always holds a verifier — also advertises nothing.
	nonEnforcing, err := signing.NewVerifier(false, nil, time.Hour)
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	offWithVerifier := (&StateBuilder{AgentID: "a", Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return nonEnforcing }}).Build()
	if offWithVerifier.EnforceSignatures {
		t.Fatal("a non-enforcing verifier must not advertise enforcement")
	}

	// An enforcing verifier advertises enforcement on the wire.
	v := enforcingVerifier(t, "mcp-prod")
	on := (&StateBuilder{AgentID: "a", Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return v }}).Build()
	if !on.EnforceSignatures {
		t.Fatal("enforcing builder must advertise enforcement")
	}
	if raw, _ := json.Marshal(on); !strings.Contains(string(raw), `"enforce_signatures":true`) {
		t.Fatalf("enforce_signatures should be on the wire when enabled: %s", raw)
	}
}

func TestStateBuilder_AdvertisesSigningKeyIDsAndMaxAge(t *testing.T) {
	reg := setupRegistry(t)

	// Omitted from the wire when not enforcing (omitempty).
	off := (&StateBuilder{AgentID: "a", Version: "v", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if raw, _ := json.Marshal(off); strings.Contains(string(raw), "signing_key_ids") ||
		strings.Contains(string(raw), "max_attestation_age_seconds") {
		t.Fatalf("key ids / max age must be omitted when unset: %s", raw)
	}

	v := enforcingVerifier(t, "mcp-prod", "mcp-staging")
	on := (&StateBuilder{AgentID: "a", Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return v }}).Build()

	// KeyIDs() returns sorted ids; the 24h window is advertised as seconds.
	if got := on.SigningKeyIDs; len(got) != 2 || got[0] != "mcp-prod" {
		t.Fatalf("SigningKeyIDs not advertised: %v", got)
	}
	if on.MaxAttestationAgeSeconds != 86400 {
		t.Fatalf("MaxAttestationAgeSeconds not advertised: %d", on.MaxAttestationAgeSeconds)
	}
	if raw, _ := json.Marshal(on); !strings.Contains(string(raw), `"signing_key_ids":["mcp-prod","mcp-staging"]`) ||
		!strings.Contains(string(raw), `"max_attestation_age_seconds":86400`) {
		t.Fatalf("key ids + max age should be on the wire: %s", raw)
	}
}

// Build reads the verifier live (via GetVerifier), so a SIGHUP that swaps the
// verifier re-advertises the new key set on the next Build — no reconnect.
func TestStateBuilder_Build_ReflectsSwappedVerifier(t *testing.T) {
	reg := setupRegistry(t)
	current := enforcingVerifier(t, "old-key")
	b := &StateBuilder{
		AgentID:     "a",
		Version:     "v",
		GetRegistry: func() *packs.Registry { return reg },
		GetVerifier: func() *signing.Verifier { return current },
	}

	if got := b.Build().SigningKeyIDs; len(got) != 1 || got[0] != "old-key" {
		t.Fatalf("before swap: %v", got)
	}
	current = enforcingVerifier(t, "new-key")
	if got := b.Build().SigningKeyIDs; len(got) != 1 || got[0] != "new-key" {
		t.Fatalf("after swap: %v", got)
	}
}

func TestStateBuilder_AdmissionDenylistHidesAction(t *testing.T) {
	reg := setupRegistry(t)
	pol, err := admission.New(nil, []string{"t.echo"})
	if err != nil {
		t.Fatal(err)
	}
	b := &StateBuilder{
		AgentID:     "agt_test",
		Version:     "0.2.0",
		GetRegistry: func() *packs.Registry { return reg },
		Admission:   pol,
	}
	msg := b.Build()
	if len(msg.Actions) != 0 {
		t.Fatalf("expected denied action to be hidden, got %d actions", len(msg.Actions))
	}
	// The pack itself still advertises (for hash tracking) — the
	// filter is per-action, not per-pack.
	if _, ok := msg.Packs["t"]; !ok {
		t.Fatalf("pack should still advertise even when all its actions are blocked")
	}
}

func TestStateBuilder_AdmissionAllowlistKeepsMatching(t *testing.T) {
	reg := setupRegistry(t)
	pol, err := admission.New([]string{"t.*"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	b := &StateBuilder{
		AgentID:     "agt_test",
		Version:     "0.2.0",
		GetRegistry: func() *packs.Registry { return reg },
		Admission:   pol,
	}
	msg := b.Build()
	if len(msg.Actions) != 1 || msg.Actions[0].ID != "t.echo" {
		t.Fatalf("expected t.echo to survive allowlist, got %+v", msg.Actions)
	}
}

func TestPeekType_AndEnvelope(t *testing.T) {
	m := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "r1"},
		ActionID: "x.y",
	}
	raw, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	mt, err := PeekType(raw)
	if err != nil {
		t.Fatal(err)
	}
	if mt != MsgRunAction {
		t.Fatalf("got %q", mt)
	}
}
