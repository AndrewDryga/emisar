package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestHermesAndGoosePlatformConfigPaths(t *testing.T) {
	for _, platformDirs := range []bool{false, true} {
		name := "home fallback"
		if platformDirs {
			name = "platform directories"
		}
		t.Run(name, func(t *testing.T) {
			home := t.TempDir()
			appData := filepath.Join(home, "AppData", "Roaming")
			localAppData := filepath.Join(home, "AppData", "Local")
			t.Setenv("APPDATA", "")
			t.Setenv("LOCALAPPDATA", "")
			t.Setenv("HERMES_HOME", " \t ")
			t.Setenv("GOOSE_PATH_ROOT", "")
			t.Setenv("XDG_CONFIG_HOME", "")
			if platformDirs {
				appData = filepath.Join(t.TempDir(), "roaming data")
				localAppData = filepath.Join(t.TempDir(), "local data")
				t.Setenv("APPDATA", appData)
				t.Setenv("LOCALAPPDATA", localAppData)
			}

			want := map[string]string{
				"hermes": filepath.Join(home, ".hermes", "config.yaml"),
				"goose":  filepath.Join(home, ".config", "goose", "config.yaml"),
			}
			if runtime.GOOS == "windows" {
				want["hermes"] = filepath.Join(localAppData, "hermes", "config.yaml")
				want["goose"] = filepath.Join(appData, "Block", "goose", "config", "config.yaml")
			}
			for id, path := range want {
				assertClientConfigPathRoundTrip(t, resolveConfigRoots(home), id, path)
			}
		})
	}
}

func TestHermesAndGooseConfigOverrides(t *testing.T) {
	home := t.TempDir()
	hermesHome := filepath.Join(t.TempDir(), "hermes profile")
	gooseRoot := filepath.Join(t.TempDir(), "goose root")
	t.Setenv("HERMES_HOME", " \t"+hermesHome+" \t")
	t.Setenv("GOOSE_PATH_ROOT", gooseRoot)
	t.Setenv("APPDATA", filepath.Join(home, "roaming"))
	t.Setenv("LOCALAPPDATA", filepath.Join(home, "local"))

	roots := resolveConfigRoots(home)
	assertClientConfigPathRoundTrip(t, roots, "hermes", filepath.Join(hermesHome, "config.yaml"))
	assertClientConfigPathRoundTrip(t, roots, "goose", filepath.Join(gooseRoot, "config", "config.yaml"))
	for _, path := range []string{
		filepath.Join(home, ".hermes", "config.yaml"),
		filepath.Join(home, ".config", "goose", "config.yaml"),
		filepath.Join(home, "local", "hermes", "config.yaml"),
		filepath.Join(home, "roaming", "Block", "goose", "config", "config.yaml"),
	} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("overridden client wrote to default %s: %v", path, err)
		}
	}
}

func TestGooseIgnoresNonAbsolutePathRoot(t *testing.T) {
	home := t.TempDir()
	appData := filepath.Join(home, "roaming")
	t.Setenv("APPDATA", appData)
	want := filepath.Join(home, ".config", "goose", "config.yaml")
	if runtime.GOOS == "windows" {
		want = filepath.Join(appData, "Block", "goose", "config", "config.yaml")
	}
	pathRoots := []string{"", " ", "relative-goose", "./goose"}
	if runtime.GOOS == "windows" {
		pathRoots = append(pathRoots, `C:goose`, `\goose`)
	}
	for _, pathRoot := range pathRoots {
		t.Run(pathRoot, func(t *testing.T) {
			t.Setenv("GOOSE_PATH_ROOT", pathRoot)
			adapter, _ := lookupClientAdapter("goose")
			if got := adapter.resolve(resolveConfigRoots(home)).ConfigFile; got != want {
				t.Errorf("config path = %q, want %q", got, want)
			}
		})
	}
}

func assertClientConfigPathRoundTrip(t *testing.T, roots configRoots, id, want string) {
	t.Helper()
	adapter, ok := lookupClientAdapter(id)
	if !ok {
		t.Fatalf("unknown client %q", id)
	}
	client := adapter.resolve(roots)
	if client.ConfigFile != want {
		t.Fatalf("%s config path = %q, want %q", id, client.ConfigFile, want)
	}
	if err := os.MkdirAll(filepath.Dir(want), 0o700); err != nil {
		t.Fatal(err)
	}
	const original = "model: existing-model\n"
	if err := os.WriteFile(want, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := client.install(testEntryRequest(filepath.Join(roots.home, "emisar-mcp"), id)); err != nil {
		t.Fatal(err)
	}
	if !client.configured(want) {
		t.Fatalf("%s is not configured at its client-owned path", id)
	}
	if err := client.remove(); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(want)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contents), original) || strings.Contains(string(contents), "emk-key") {
		t.Fatalf("%s removal lost existing configuration or retained the key", id)
	}
}
