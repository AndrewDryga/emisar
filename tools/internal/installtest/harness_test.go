package installtest

import (
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestEnvironmentIsolatesClientConfigOverrides(t *testing.T) {
	home := t.TempDir()
	for _, name := range []string{"XDG_CONFIG_HOME", "HERMES_HOME", "GOOSE_PATH_ROOT", "APPDATA", "LOCALAPPDATA"} {
		t.Setenv(name, filepath.Join(t.TempDir(), "outside sandbox"))
	}
	overrides := map[string]string{"HOME": home}
	want := map[string]string{
		"XDG_CONFIG_HOME": filepath.Join(home, ".config"),
		"HERMES_HOME":     "",
		"GOOSE_PATH_ROOT": "",
	}
	if runtime.GOOS == "windows" {
		want["APPDATA"] = filepath.Join(home, "AppData", "Roaming")
		want["LOCALAPPDATA"] = filepath.Join(home, "AppData", "Local")
	}
	assertEnvironmentValues(t, environment(overrides), want)
	if len(overrides) != 1 {
		t.Fatalf("environment mutated its caller's overrides: %v", overrides)
	}
}

func TestEnvironmentPreservesExplicitClientConfigOverrides(t *testing.T) {
	home := t.TempDir()
	overrides := map[string]string{"HOME": home}
	for _, name := range []string{"XDG_CONFIG_HOME", "HERMES_HOME", "GOOSE_PATH_ROOT", "APPDATA", "LOCALAPPDATA"} {
		overrides[name] = filepath.Join(home, name)
	}
	assertEnvironmentValues(t, environment(overrides), overrides)
}

func TestEnvironmentWithoutSandboxPreservesClientConfig(t *testing.T) {
	want := map[string]string{
		"HERMES_HOME":     filepath.Join(t.TempDir(), "hermes"),
		"GOOSE_PATH_ROOT": filepath.Join(t.TempDir(), "goose"),
	}
	for name, value := range want {
		t.Setenv(name, value)
	}
	assertEnvironmentValues(t, environment(nil), want)
}

func assertEnvironmentValues(t *testing.T, env []string, want map[string]string) {
	t.Helper()
	for name, value := range want {
		matches := 0
		for _, entry := range env {
			key, got, _ := strings.Cut(entry, "=")
			if key == name || runtime.GOOS == "windows" && strings.EqualFold(key, name) {
				matches++
				if got != value {
					t.Errorf("%s = %q, want %q", name, got, value)
				}
			}
		}
		if matches != 1 {
			t.Errorf("environment has %d entries for %s, want one", matches, name)
		}
	}
}
