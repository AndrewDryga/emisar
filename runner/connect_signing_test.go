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
	cfg := &config.Config{Signing: config.Signing{MaxAttestationAge: actionspec.Duration(time.Hour)}}
	memory, err := openNonceStore(cfg)
	if err != nil {
		t.Fatalf("open memory store: %v", err)
	}
	if memory.Durable() {
		t.Fatal("empty data_dir unexpectedly created durable state")
	}

	cfg.Paths.DataDir = t.TempDir()
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
