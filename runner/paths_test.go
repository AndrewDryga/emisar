package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWritePaths(t *testing.T) {
	restore := flagConfig
	t.Cleanup(func() { flagConfig = restore })

	t.Run("resolved config prints every location", func(t *testing.T) {
		dir := t.TempDir()
		packDir := filepath.Join(dir, "packs")
		if err := os.MkdirAll(packDir, 0o755); err != nil {
			t.Fatalf("mkdir packs: %v", err)
		}
		tokenPath := filepath.Join(dir, "token")
		cfgPath := writeDoctorConfig(t, dir, packDir, "wss://cloud.example", tokenPath)
		flagConfig = cfgPath

		var buf bytes.Buffer
		writePaths(&buf)
		out := buf.String()

		for _, want := range []string{
			"Paths:",
			"config", cfgPath,
			"packs", packDir,
			"data dir", filepath.Join(dir, "data"),
			"token", tokenPath,
			"dispatch log", filepath.Join(dir, "data", "dispatches.jsonl"),
			"events journal", filepath.Join(dir, "events.jsonl"),
		} {
			if !strings.Contains(out, want) {
				t.Errorf("paths output missing %q\n%s", want, out)
			}
		}
	})

	t.Run("an unreadable config still names the path", func(t *testing.T) {
		missing := filepath.Join(t.TempDir(), "nope.yaml")
		flagConfig = missing

		var buf bytes.Buffer
		writePaths(&buf)
		out := buf.String()

		if !strings.Contains(out, missing) || !strings.Contains(out, "failed to load") {
			t.Errorf("expected the failing config path to be named:\n%s", out)
		}
	})
}

func TestPluralCommandAliases(t *testing.T) {
	for _, tt := range []struct {
		name    string
		aliases []string
		want    string
	}{
		{"pack", packCmd().Aliases, "packs"},
		{"action", actionCmd().Aliases, "actions"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			found := false
			for _, alias := range tt.aliases {
				if alias == tt.want {
					found = true
				}
			}
			if !found {
				t.Errorf("%s aliases = %v, want to include %q", tt.name, tt.aliases, tt.want)
			}
		})
	}
}
