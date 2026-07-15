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
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

const echoAction = `
schema_version: 1
id: t.echo
title: Echo
summary: Echo one validated message.
kind: exec
risk: low
description: d
side_effects: [none]
search_terms: [repeat, print]
args:
  - name: msg
    type: string
    required: true
    description: Message to echo.
execution:
  command:
    binary: echo
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
	if a.Summary != "Echo one validated message." || a.Description != "d" {
		t.Fatalf("model prose not advertised: summary=%q description=%q", a.Summary, a.Description)
	}
	if len(a.SideEffects) != 0 {
		t.Fatalf("canonical no-side-effects marker not advertised: %v", a.SideEffects)
	}
	if len(a.SearchTerms) != 2 || a.SearchTerms[0] != "repeat" {
		t.Fatalf("search terms not advertised: %v", a.SearchTerms)
	}
	if len(a.Args) != 1 || a.Args[0].Description != "Message to echo." {
		t.Fatalf("public args not advertised: %+v", a.Args)
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
// given CA ids (24h freshness window). The keys are random — these tests assert
// the advertised metadata, never verify a signature.
func enforcingVerifier(t *testing.T, caIDs ...string) *signing.Verifier {
	t.Helper()
	cas := make([]signing.CAConfig, len(caIDs))
	for i, id := range caIDs {
		pub, _, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatalf("GenerateKey: %v", err)
		}
		cas[i] = signing.CAConfig{CAID: id, PublicKeyHex: hex.EncodeToString(pub)}
	}
	v, err := signing.NewVerifier(true, cas, 24*time.Hour, "runner-state-test", "https://emisar.test", "", nil, signing.NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	return v
}

func TestStateBuilder_AdvertisesEnforceSignatures(t *testing.T) {
	reg := setupRegistry(t)

	// No verifier: enforcement off, omitted from the wire (omitempty) so older
	// clouds see nothing new.
	off := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if off.EnforceSignatures {
		t.Fatal("default state must not advertise enforcement")
	}
	if raw, _ := json.Marshal(off); strings.Contains(string(raw), "enforce_signatures") {
		t.Fatalf("enforce_signatures should be omitted when off: %s", raw)
	}

	// A present-but-non-enforcing verifier — the real "enforcement off" config
	// state, since the client always holds a verifier — also advertises nothing.
	nonEnforcing, err := signing.NewVerifier(false, nil, time.Hour, "", "", "", nil, signing.NewMemoryNonceStore())
	if err != nil {
		t.Fatalf("NewVerifier: %v", err)
	}
	offWithVerifier := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return nonEnforcing }}).Build()
	if offWithVerifier.EnforceSignatures {
		t.Fatal("a non-enforcing verifier must not advertise enforcement")
	}

	// An enforcing verifier advertises enforcement on the wire.
	v := enforcingVerifier(t, "mcp-prod")
	on := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return v }}).Build()
	if !on.EnforceSignatures {
		t.Fatal("enforcing builder must advertise enforcement")
	}
	if raw, _ := json.Marshal(on); !strings.Contains(string(raw), `"enforce_signatures":true`) {
		t.Fatalf("enforce_signatures should be on the wire when enabled: %s", raw)
	}
}

func TestStateBuilder_AdvertisesSigningCAIDsAndMaxAge(t *testing.T) {
	reg := setupRegistry(t)

	// Omitted from the wire when not enforcing (omitempty).
	off := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if raw, _ := json.Marshal(off); strings.Contains(string(raw), "signing_ca_ids") ||
		strings.Contains(string(raw), "max_attestation_age_seconds") {
		t.Fatalf("CA ids / max age must be omitted when unset: %s", raw)
	}

	v := enforcingVerifier(t, "ca-prod", "ca-staging")
	on := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }, GetVerifier: func() *signing.Verifier { return v }}).Build()

	// CAIDs() returns sorted ids; the 24h window is advertised as seconds.
	if got := on.SigningCAIDs; len(got) != 2 || got[0] != "ca-prod" {
		t.Fatalf("SigningCAIDs not advertised: %v", got)
	}
	if on.MaxAttestationAgeSeconds != 86400 {
		t.Fatalf("MaxAttestationAgeSeconds not advertised: %d", on.MaxAttestationAgeSeconds)
	}
	if raw, _ := json.Marshal(on); !strings.Contains(string(raw), `"signing_ca_ids":["ca-prod","ca-staging"]`) ||
		!strings.Contains(string(raw), `"max_attestation_age_seconds":86400`) {
		t.Fatalf("CA ids + max age should be on the wire: %s", raw)
	}
}

// Build reads the verifier live (via GetVerifier), so a SIGHUP that swaps the
// verifier re-advertises the new CA set on the next Build — no reconnect.
func TestStateBuilder_Build_ReflectsSwappedVerifier(t *testing.T) {
	reg := setupRegistry(t)
	current := enforcingVerifier(t, "old-ca")
	b := &StateBuilder{
		Version:     "v",
		GetRegistry: func() *packs.Registry { return reg },
		GetVerifier: func() *signing.Verifier { return current },
	}

	if got := b.Build().SigningCAIDs; len(got) != 1 || got[0] != "old-ca" {
		t.Fatalf("before swap: %v", got)
	}
	current = enforcingVerifier(t, "new-ca")
	if got := b.Build().SigningCAIDs; len(got) != 1 || got[0] != "new-ca" {
		t.Fatalf("after swap: %v", got)
	}
}

func TestStateBuilder_AdmissionDenylistHidesAction(t *testing.T) {
	reg := setupRegistry(t)
	pol, err := admission.New(nil, []string{"t.echo"}, "")
	if err != nil {
		t.Fatal(err)
	}
	b := &StateBuilder{
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

const highRiskAction = `
schema_version: 1
id: t.reboot
title: Reboot
kind: exec
risk: high
description: d
side_effects: [none]
args: []
execution:
  command:
    binary: true
    argv: []
  timeout: 5s
  timeout_min: 1s
  timeout_max: 30s
output:
  parser: text
  max_stdout_bytes: 1024
  max_stderr_bytes: 1024
`

// A risk ceiling hides actions above the tier from the advertised catalog,
// exactly like an allow/deny rule — the read-only-demo switch.
func TestStateBuilder_MaxRiskHidesActionsAboveCeiling(t *testing.T) {
	root := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	manifest := `schema_version: 1
id: t
name: t
version: 0.0.1
description: t
actions:
  - actions/echo.yaml
  - actions/reboot.yaml
`
	must(os.MkdirAll(filepath.Join(root, "p", "actions"), 0o755))
	must(os.WriteFile(filepath.Join(root, "p", "pack.yaml"), []byte(manifest), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "echo.yaml"), []byte(echoAction), 0o644))
	must(os.WriteFile(filepath.Join(root, "p", "actions", "reboot.yaml"), []byte(highRiskAction), 0o644))
	reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
	must(err)

	pol, err := admission.New(nil, nil, actionspec.RiskMedium)
	if err != nil {
		t.Fatal(err)
	}
	b := &StateBuilder{
		Version:     "0.2.0",
		GetRegistry: func() *packs.Registry { return reg },
		Admission:   pol,
	}
	msg := b.Build()
	if len(msg.Actions) != 1 || msg.Actions[0].ID != "t.echo" {
		t.Fatalf("expected only the low-risk t.echo under a medium ceiling, got %+v", msg.Actions)
	}
}

func TestStateBuilder_AdmissionAllowlistKeepsMatching(t *testing.T) {
	reg := setupRegistry(t)
	pol, err := admission.New([]string{"t.*"}, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	b := &StateBuilder{
		Version:     "0.2.0",
		GetRegistry: func() *packs.Registry { return reg },
		Admission:   pol,
	}
	msg := b.Build()
	if len(msg.Actions) != 1 || msg.Actions[0].ID != "t.echo" {
		t.Fatalf("expected t.echo to survive allowlist, got %+v", msg.Actions)
	}
}

func TestRunnerState_WireBudget(t *testing.T) {
	t.Run("oversized state rejected", func(t *testing.T) {
		msg := RunnerStateMsg{
			Envelope: Envelope{Type: MsgRunnerState, ProtocolVersion: ProtocolVersion},
			Version:  "test",
			Group:    "test",
			Labels:   map[string]string{"oversized": strings.Repeat("x", maxRunnerStateBytes)},
		}
		if err := validateRunnerStateSize(msg); err == nil {
			t.Fatal("oversized runner_state must be rejected before transport")
		}
	})

	t.Run("checked-in catalog fits", func(t *testing.T) {
		root, err := filepath.Abs(filepath.Join("..", "..", "..", "packs"))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(root, "AGENTS.md")); err != nil {
			t.Skipf("checked-in pack catalog unavailable: %v", err)
		}
		reg, err := packs.LoadAll([]string{root}, packs.LoadOptions{})
		if err != nil {
			t.Fatalf("load checked-in catalog: %v", err)
		}
		msg := (&StateBuilder{
			Version:     "test",
			Group:       "test",
			GetRegistry: func() *packs.Registry { return reg },
		}).Build()
		encoded, err := json.Marshal(msg)
		if err != nil {
			t.Fatal(err)
		}
		if err := validateRunnerStateSize(msg); err != nil {
			t.Fatalf("checked-in catalog is %d bytes: %v", len(encoded), err)
		}
	})
}

// An empty or nil registry still advertises runtime metadata with zero actions
// and no packs, so the cloud sees a connected-but-empty runner rather than a
// malformed or dropped state. Covers both no-GetRegistry and GetRegistry→nil.
func TestStateBuilder_Build_EmptyRegistryAdvertisesRuntimeState(t *testing.T) {
	cases := map[string]*StateBuilder{
		"nil GetRegistry": {
			Version:  "9.9.9",
			Hostname: "host-a",
			Group:    "g",
			Labels:   map[string]string{"role": "edge"},
		},
		"GetRegistry returns nil": {
			Version:     "9.9.9",
			Hostname:    "host-a",
			Group:       "g",
			Labels:      map[string]string{"role": "edge"},
			GetRegistry: func() *packs.Registry { return nil },
		},
	}
	for name, b := range cases {
		t.Run(name, func(t *testing.T) {
			msg := b.Build()
			if msg.Type != MsgRunnerState || msg.ProtocolVersion != ProtocolVersion {
				t.Fatalf("envelope wrong: type=%s pv=%d", msg.Type, msg.ProtocolVersion)
			}
			if msg.Version != "9.9.9" || msg.Hostname != "host-a" || msg.Group != "g" {
				t.Fatalf("runtime state not advertised: %+v", msg)
			}
			if msg.Labels["role"] != "edge" {
				t.Fatalf("labels not advertised: %v", msg.Labels)
			}
			// No catalog.
			if len(msg.Actions) != 0 {
				t.Fatalf("expected zero actions, got %d", len(msg.Actions))
			}
			if len(msg.Packs) != 0 {
				t.Fatalf("expected no packs, got %d", len(msg.Packs))
			}
		})
	}
}

// Hostname resolution: an explicit StateBuilder.Hostname is advertised verbatim
// (the os.Hostname() fallback is only consulted when it's empty). When empty,
// Build falls back to os.Hostname(); if that ever fails the field is simply
// omitted (omitempty) rather than crashing the advertisement.
func TestStateBuilder_Build_HostnameFallback(t *testing.T) {
	reg := setupRegistry(t)

	// Explicit hostname wins, even if it differs from the machine's.
	explicit := (&StateBuilder{Version: "v", Hostname: "pinned-host", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if explicit.Hostname != "pinned-host" {
		t.Fatalf("explicit hostname not used: %q", explicit.Hostname)
	}

	// Empty hostname falls back to os.Hostname(). On a healthy host that is a
	// non-empty value equal to what os.Hostname() reports.
	want, err := os.Hostname()
	if err != nil {
		t.Skipf("os.Hostname() unavailable on this host: %v", err)
	}
	fell := (&StateBuilder{Version: "v", GetRegistry: func() *packs.Registry { return reg }}).Build()
	if fell.Hostname != want {
		t.Fatalf("empty hostname should fall back to os.Hostname() %q, got %q", want, fell.Hostname)
	}
}

func TestPeekEnvelope(t *testing.T) {
	m := RunActionMsg{
		Envelope: Envelope{Type: MsgRunAction, ProtocolVersion: ProtocolVersion, RequestID: "r1"},
		ActionID: "x.y",
	}
	raw, err := marshalRunActionMsg(m)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := PeekEnvelope(raw)
	if err != nil {
		t.Fatal(err)
	}
	if envelope.Type != MsgRunAction || envelope.ProtocolVersion != ProtocolVersion || envelope.RequestID != "r1" {
		t.Fatalf("got %+v", envelope)
	}
}
