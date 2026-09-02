package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/attest"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/signing"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestBuildVerifierRejectsMemoryOnlyEnforcement(t *testing.T) {
	_, caKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caDER, err := mintCA(caKey, "ca-prod", 365*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := encodeCertPEM(caDER)
	cfg := &config.Config{
		Runner: config.Runner{Group: "prod"},
		Signing: config.Signing{
			EnforceSignatures: true,
			MaxAttestationAge: actionspec.Duration(time.Hour),
			TrustedCAs:        []config.TrustedCA{{Name: "ca-prod", PEM: caPEM}},
		},
	}
	id := runnerIdentity{externalID: "runner-1", group: "prod"}
	if _, err := buildVerifier(cfg, id, signing.NewMemoryNonceStore()); err == nil {
		t.Fatal("production verifier accepted memory-only replay state")
	}
}

func TestBuildVerifierKeepsBootPortalOriginOnReload(t *testing.T) {
	_, caKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caDER, err := mintCA(caKey, "ca-prod", 365*24*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Cloud: config.Cloud{URL: "wss://portal-b.example/runner"},
		Paths: config.Paths{DataDir: t.TempDir()},
		Signing: config.Signing{
			EnforceSignatures: true,
			MaxAttestationAge: actionspec.Duration(time.Hour),
			TrustedCAs: []config.TrustedCA{
				{Name: "ca-prod", PEM: encodeCertPEM(caDER)},
			},
		},
	}
	store, err := openNonceStore(cfg)
	if err != nil {
		t.Fatalf("open nonce store: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	id := runnerIdentity{
		externalID: "runner-1",
		portalURL:  "wss://portal-a.example/runner",
		group:      "prod",
	}
	verifier, err := buildVerifier(cfg, id, store)
	if err != nil {
		t.Fatalf("build verifier: %v", err)
	}

	attestation := func(origin string) *signing.Attestation {
		return &signing.Attestation{
			Version:      attest.Version,
			Tool:         attest.Tool,
			PortalOrigin: origin,
			CertChain:    []string{"present so origin is the next gate"},
		}
	}
	if decision := verifier.Check(signing.Dispatch{}, attestation("https://portal-a.example")); decision.Code != "intent_mismatch" {
		t.Fatalf("boot portal decision = %+v, want origin accepted through the intent gate", decision)
	}
	if decision := verifier.Check(signing.Dispatch{}, attestation("https://portal-b.example")); decision.Code != "portal_mismatch" {
		t.Fatalf("edited portal decision = %+v, want portal_mismatch", decision)
	}
}

func TestOpenNonceStoreUsesDataDir(t *testing.T) {
	cfg := &config.Config{
		Paths:   config.Paths{DataDir: t.TempDir()},
		Signing: config.Signing{MaxAttestationAge: actionspec.Duration(time.Hour)},
	}
	durable, err := openNonceStore(cfg)
	if err != nil {
		t.Fatalf("open durable store: %v", err)
	}
	if !durable.Durable() {
		t.Fatal("configured data_dir did not create durable replay state")
	}
	if _, err := os.Stat(filepath.Join(cfg.Paths.DataDir, "signing", "nonce-cache.json")); err != nil {
		t.Fatalf("stat durable journal: %v", err)
	}
}

func TestOpenRuntimeNonceStoreIgnoresDisabledSigningState(t *testing.T) {
	dataDir := t.TempDir()
	journalDir := filepath.Join(dataDir, "signing")
	if err := os.MkdirAll(journalDir, 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(journalDir, "nonce-cache.json"), []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Paths:   config.Paths{DataDir: dataDir},
		Signing: config.Signing{MaxAttestationAge: actionspec.Duration(time.Hour)},
	}

	store, err := openRuntimeNonceStore(cfg)
	if err != nil {
		t.Fatalf("disabled signing opened unused durable state: %v", err)
	}
	if store.Durable() {
		t.Fatal("disabled signing unexpectedly opened durable replay state")
	}

	cfg.Signing.EnforceSignatures = true
	if _, err := openRuntimeNonceStore(cfg); err == nil {
		t.Fatal("enforcing signing accepted a corrupt nonce journal")
	}
}

func TestCanonicalPortalOrigin(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "websocket path", raw: "wss://Cloud.Example.COM:443/runner/v1", want: "https://cloud.example.com"},
		{name: "websocket custom port", raw: "wss://cloud.example.com:8443/runner/v1", want: "https://cloud.example.com:8443"},
		{name: "http development", raw: "http://localhost:4000", want: "http://localhost:4000"},
		{name: "ws default port", raw: "ws://localhost:80/socket", want: "http://localhost"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := canonicalPortalOrigin(test.raw)
			if err != nil {
				t.Fatalf("canonicalPortalOrigin: %v", err)
			}
			if got != test.want {
				t.Fatalf("canonicalPortalOrigin = %q, want %q", got, test.want)
			}
		})
	}
}

func TestCanonicalPortalOriginRejectsInvalidInput(t *testing.T) {
	for _, raw := range []string{"", "/relative", "ftp://example.com", "wss://user:pass@example.com/socket"} {
		if _, err := canonicalPortalOrigin(raw); err == nil {
			t.Fatalf("canonicalPortalOrigin(%q) unexpectedly succeeded", raw)
		}
	}
}
