package main

import (
	"os"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"testing"
)

// The runner hardcoded $HOME/.config/emisar and called it "a per-user XDG
// path" — while ignoring $XDG_CONFIG_HOME, the one variable XDG defines. The
// bridge uses os.UserConfigDir(), so on macOS the two binaries disagreed about
// where per-user config lives: one product writing one tree and reading
// another.
func TestDefaultConfigPathsCoverBothPerUserLocations(t *testing.T) {
	paths := defaultConfigPaths()

	if len(paths) == 0 || paths[0] != "/etc/emisar/config.yaml" {
		t.Fatalf("the canonical install location must come first, got %v", paths)
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		t.Skip("no user config dir on this platform")
	}
	want := filepath.Join(configDir, "emisar", "config.yaml")
	if !searchesFor(paths, want) {
		t.Errorf("the platform's own config dir %q is not searched: %v", want, paths)
	}

	// The literal ~/.config path stays a candidate: it is where an existing
	// config sits, and dropping a location a reader already finds would break
	// those hosts for nothing.
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		legacy := filepath.Join(home, ".config", "emisar", "config.yaml")
		if !searchesFor(paths, legacy) {
			t.Errorf("the existing ~/.config location is no longer searched: %v", paths)
		}
	}

	// On Linux without $XDG_CONFIG_HOME the two resolve to the same directory,
	// and a duplicate would print twice in the not-found message.
	seen := map[string]bool{}
	for _, p := range paths {
		if seen[p] {
			t.Errorf("duplicate candidate %q in %v", p, paths)
		}
		seen[p] = true
	}
	if goruntime.GOOS == "darwin" && len(paths) != 3 {
		t.Errorf("macOS should search /etc, Application Support and ~/.config, got %v", paths)
	}
}

// $XDG_CONFIG_HOME is the whole point of calling a path XDG, and the old
// hardcoded ~/.config ignored it everywhere.
//
// Only asserted where the PLATFORM says XDG applies. os.UserConfigDir consults
// it on Unix and deliberately does not on macOS or Windows, where the
// convention is Application Support and %AppData% — and following the platform
// is the whole reason to use that function rather than another hardcoded path.
func TestDefaultConfigPathsHonourXDGConfigHome(t *testing.T) {
	if goruntime.GOOS == "windows" || goruntime.GOOS == "darwin" {
		t.Skip("XDG_CONFIG_HOME is not this platform's convention")
	}
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)

	want := filepath.Join(dir, "emisar", "config.yaml")
	if !searchesFor(defaultConfigPaths(), want) {
		t.Errorf("XDG_CONFIG_HOME=%s is ignored: %v", dir, defaultConfigPaths())
	}
}

func searchesFor(values []string, want string) bool {
	for _, v := range values {
		if strings.EqualFold(v, want) {
			return true
		}
	}
	return false
}
