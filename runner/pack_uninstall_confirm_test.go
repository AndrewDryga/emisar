package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// `pack uninstall` recursively deletes a tree and asked nothing first, while
// every sibling does: `pack install` demands --force merely to OVERWRITE,
// install.sh prompts before uninstalling, and `emisar-mcp disconnect` refuses
// without confirmation. It is aliased rm, remove and delete.
//
// The friction itself is a breaking change for an unattended caller, which is
// why it had to land before these flags freeze.
func TestPackUninstallRequiresConfirmation(t *testing.T) {
	dest := t.TempDir()
	pack := filepath.Join(dest, "redis")
	if err := os.MkdirAll(pack, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pack, "pack.yaml"), []byte("schema_version: 1\nid: redis\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Run("refuses without a terminal rather than hanging", func(t *testing.T) {
		cmd := packUninstallCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis", "--dest", dest})
		// A script, a systemd unit or a CI job — anything that is not an
		// operator at a keyboard. Left unset, the test process still holds the
		// real terminal and would take the interactive path.
		cmd.SetIn(strings.NewReader(""))

		err := cmd.Execute()
		if err == nil {
			t.Fatal("uninstall deleted the pack with no confirmation")
		}
		if !strings.Contains(err.Error(), "--yes") {
			t.Errorf("the refusal must name the way through, got %v", err)
		}
		// A refusal that already deleted the tree would be worthless.
		if _, statErr := os.Stat(pack); statErr != nil {
			t.Errorf("the pack must survive a refused uninstall: %v", statErr)
		}
		// It is a usage mistake, so it exits 2 like the rest of them.
		if got := exitCode(t.Context(), err); got != exitUsage {
			t.Errorf("exit = %d, want %d", got, exitUsage)
		}
	})

	// The interactive prompt itself is not exercised here: it needs a real
	// character device, and a pipe is not one — so a test that "answered n"
	// would in fact be taking the non-terminal path above and proving nothing.
	t.Run("--yes removes it", func(t *testing.T) {
		cmd := packUninstallCmd()
		cmd.SilenceUsage, cmd.SilenceErrors = true, true
		cmd.SetArgs([]string{"redis", "--dest", dest, "--yes"})

		if err := cmd.Execute(); err != nil {
			t.Fatalf("uninstall --yes: %v", err)
		}
		if _, err := os.Stat(pack); !os.IsNotExist(err) {
			t.Errorf("the pack should be gone, stat err = %v", err)
		}
	})
}
