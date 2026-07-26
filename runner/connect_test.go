package main

import (
	"errors"
	"path/filepath"
	"testing"

	"github.com/andrewdryga/emisar/runner/internal/cloud"
)

func TestReloadComponents_ReloadsSigningAfterPackFailure(t *testing.T) {
	packErr := errors.New("malformed pack")
	signingCalled := false
	changed, gotPackErr, signingErr := reloadComponents(
		func() error { return packErr },
		func() error {
			signingCalled = true
			return nil
		},
	)
	if !signingCalled {
		t.Fatal("signing reload was skipped after pack failure")
	}
	if !errors.Is(gotPackErr, packErr) || signingErr != nil {
		t.Fatalf("errors = (%v, %v), want (%v, nil)", gotPackErr, signingErr, packErr)
	}
	if !changed {
		t.Fatal("successful signing reload must trigger re-advertisement")
	}
}

func TestConnectRequiresDurableDataDir(t *testing.T) {
	for _, dataDir := range []string{"", "  ", "\n"} {
		if err := validateConnectDataDir(dataDir); err == nil {
			t.Fatalf("validateConnectDataDir(%q) accepted memory-only dispatch state", dataDir)
		}
	}
	if err := validateConnectDataDir(t.TempDir()); err != nil {
		t.Fatalf("validateConnectDataDir(valid): %v", err)
	}
}

func TestDispatchLogPaths(t *testing.T) {
	dataDir := t.TempDir()
	if got, want := cloud.DispatchLogPath(dataDir), filepath.Join(dataDir, "dispatches.jsonl"); got != want {
		t.Fatalf("DispatchLogPath = %q, want %q", got, want)
	}
	// The pre-v0.12 location the daemon adopts on first boot without a
	// current log.
	if got, want := cloud.LegacyDispatchLogPath(dataDir), filepath.Join(dataDir, "dedup.jsonl"); got != want {
		t.Fatalf("LegacyDispatchLogPath = %q, want %q", got, want)
	}
}

func TestResolveExternalIDUsesConfiguredIDOrHostname(t *testing.T) {
	tests := []struct {
		name       string
		configured string
		hostname   string
		want       string
		wantErr    bool
	}{
		{name: "hostname default", hostname: "emisar-07qx", want: "emisar-07qx"},
		{
			name:       "configured override",
			configured: "  operator-pinned  ",
			hostname:   "emisar-07qx",
			want:       "operator-pinned",
		},
		{name: "trimmed hostname", hostname: "  emisar-95qv  ", want: "emisar-95qv"},
		{name: "empty hostname", hostname: "  ", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := resolveExternalID(tt.configured, tt.hostname)
			if tt.wantErr {
				if err == nil || got != "" {
					t.Fatalf("resolveExternalID = %q, %v; want empty id and error", got, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("resolveExternalID: %v", err)
			}
			if got != tt.want {
				t.Fatalf("resolveExternalID = %q, want %q", got, tt.want)
			}
		})
	}
}
