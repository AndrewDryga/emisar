package installtest

import (
	"path/filepath"
	"testing"
)

func TestWindowsClientFixturesUseNativeConfigPaths(t *testing.T) {
	root := t.TempDir()
	home := filepath.Join(root, "home")
	appData := filepath.Join(root, "roaming")
	localAppData := filepath.Join(root, "local")
	want := map[string]string{
		"hermes": filepath.Join(localAppData, "hermes", "config.yaml"),
		"goose":  filepath.Join(appData, "Block", "goose", "config", "config.yaml"),
	}
	for _, fixture := range windowsClientFixtures(home, appData, localAppData) {
		if path, ok := want[fixture.id]; ok {
			if fixture.path != path {
				t.Errorf("%s fixture path = %q, want %q", fixture.id, fixture.path, path)
			}
			delete(want, fixture.id)
		}
	}
	if len(want) != 0 {
		t.Errorf("missing client fixtures: %v", want)
	}
}

func TestWindowsEnvironmentIsolatesUserProfileAndMixedCaseOverrides(t *testing.T) {
	home := t.TempDir()
	t.Setenv("hermes_home", filepath.Join(t.TempDir(), "real hermes"))
	t.Setenv("goose_path_root", filepath.Join(t.TempDir(), "real goose"))
	t.Setenv("localappdata", filepath.Join(t.TempDir(), "real local"))
	assertEnvironmentValues(t, environment(map[string]string{"USERPROFILE": home}), map[string]string{
		"HERMES_HOME":     "",
		"GOOSE_PATH_ROOT": "",
		"APPDATA":         filepath.Join(home, "AppData", "Roaming"),
		"LOCALAPPDATA":    filepath.Join(home, "AppData", "Local"),
	})
}
