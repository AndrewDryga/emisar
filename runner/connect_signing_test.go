package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/signing"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

func TestBuildVerifierRejectsMemoryOnlyEnforcement(t *testing.T) {
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &config.Config{
		Runner: config.Runner{Group: "prod"},
		Signing: config.Signing{
			EnforceSignatures: true,
			MaxAttestationAge: actionspec.Duration(time.Hour),
			TrustedCAs: []config.TrustedCA{{
				CAID:      "ca-prod",
				PublicKey: hex.EncodeToString(publicKey),
			}},
		},
	}
	if _, err := buildVerifier(cfg, "runner-1", signing.NewMemoryNonceStore()); err == nil {
		t.Fatal("production verifier accepted memory-only replay state")
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
