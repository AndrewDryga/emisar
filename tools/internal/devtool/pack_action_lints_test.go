package devtool

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func fixturePackActionLintInput(t *testing.T, packDir string, required ...string) packActionLintInput {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(packDir, "actions", "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(paths)
	binaries := make(map[string]bool, len(required))
	for _, binary := range required {
		binaries[binary] = true
	}
	return packActionLintInput{
		packDir:          packDir,
		actionPaths:      paths,
		requiredBinaries: binaries,
	}
}

func mustLoadPackActionLintInput(t *testing.T, packDir string) packActionLintInput {
	t.Helper()
	input, err := loadPackActionLintInput(packDir)
	if err != nil {
		t.Fatal(err)
	}
	return input
}

func writePackActionLintFile(t *testing.T, packDir, relative, body string) {
	t.Helper()
	path := filepath.Join(packDir, filepath.FromSlash(relative))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

const safePackLintAction = `id: fixture.safe
execution:
  command:
    binary: printf
    argv: ["%s", "ok"]
`

const unsafePackLintCurlAction = `id: fixture.unsafe_curl
execution:
  command:
    binary: curl
    argv: [-fsS, https://service.example/resource]
`

func TestPackActionLintsFollowManifest(t *testing.T) {
	t.Run("declared nested action is linted", func(t *testing.T) {
		packDir := t.TempDir()
		writePackActionLintFile(t, packDir, "pack.yaml", "actions:\n  - checks/request.yaml\n")
		writePackActionLintFile(t, packDir, "checks/request.yaml", unsafePackLintCurlAction)

		err := validatePackActionLints(t.Context(), packDir)
		if err == nil || !strings.Contains(err.Error(), "fixture.unsafe_curl (no --globoff)") {
			t.Fatalf("error = %v, want the declared nested curl action rejected", err)
		}
	})

	t.Run("unreferenced action-shaped YAML is ignored", func(t *testing.T) {
		packDir := t.TempDir()
		writePackActionLintFile(t, packDir, "pack.yaml", "actions:\n  - checks/safe.yaml\n")
		writePackActionLintFile(t, packDir, "checks/safe.yaml", safePackLintAction)
		writePackActionLintFile(t, packDir, "actions/stray.yaml", unsafePackLintCurlAction)

		if err := validatePackActionLints(t.Context(), packDir); err != nil {
			t.Fatalf("unreferenced YAML affected action lints: %v", err)
		}
	})
}

func TestLoadPackActionLintInputRejectsInvalidManifestPaths(t *testing.T) {
	tests := []struct {
		name     string
		manifest string
		want     string
	}{
		{name: "invalid YAML", manifest: "actions: [", want: "parse"},
		{name: "no actions", manifest: "actions: []\n", want: "declares no actions"},
		{name: "missing action", manifest: "actions:\n  - actions/missing.yaml\n", want: "not readable"},
		{name: "escaping action", manifest: "actions:\n  - ../outside.yaml\n", want: "escapes the pack root"},
		{name: "absolute action", manifest: "actions:\n  - /tmp/outside.yaml\n", want: "must be relative"},
		{name: "duplicate action", manifest: "actions:\n  - actions/a.yaml\n  - actions/./a.yaml\n", want: "same action path twice"},
		{name: "multiple documents", manifest: "actions:\n  - actions/a.yaml\n---\nactions:\n  - actions/a.yaml\n", want: "multiple YAML documents"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			packDir := t.TempDir()
			writePackActionLintFile(t, packDir, "pack.yaml", test.manifest)
			writePackActionLintFile(t, packDir, "actions/a.yaml", safePackLintAction)
			writePackActionLintFile(t, filepath.Dir(packDir), "outside.yaml", safePackLintAction)

			_, err := loadPackActionLintInput(packDir)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want containing %q", err, test.want)
			}
		})
	}
}

func TestLoadPackActionLintInputRejectsNonRegularAndSymlinkEscapes(t *testing.T) {
	t.Run("directory", func(t *testing.T) {
		packDir := t.TempDir()
		writePackActionLintFile(t, packDir, "pack.yaml", "actions:\n  - actions/not-a-file.yaml\n")
		if err := os.MkdirAll(filepath.Join(packDir, "actions", "not-a-file.yaml"), 0o755); err != nil {
			t.Fatal(err)
		}

		_, err := loadPackActionLintInput(packDir)
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("error = %v, want a non-regular-file rejection", err)
		}
	})

	t.Run("symlink escape", func(t *testing.T) {
		root := t.TempDir()
		packDir := filepath.Join(root, "pack")
		writePackActionLintFile(t, packDir, "pack.yaml", "actions:\n  - actions/linked.yaml\n")
		writePackActionLintFile(t, root, "outside.yaml", safePackLintAction)
		if err := os.MkdirAll(filepath.Join(packDir, "actions"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, "outside.yaml"), filepath.Join(packDir, "actions", "linked.yaml")); err != nil {
			t.Skipf("create symlink fixture: %v", err)
		}

		_, err := loadPackActionLintInput(packDir)
		if err == nil || !strings.Contains(err.Error(), "escapes the pack root through a symlink") {
			t.Fatalf("error = %v, want a resolved symlink escape rejection", err)
		}
	})
}

func TestLoadPackActionLintInputSortsPathsAndCarriesRequirements(t *testing.T) {
	packDir := t.TempDir()
	writePackActionLintFile(t, packDir, "pack.yaml", `requires:
  binaries: [jq, bash]
actions:
  - nested/z.yaml
  - actions/a.yaml
`)
	writePackActionLintFile(t, packDir, "nested/z.yaml", safePackLintAction)
	writePackActionLintFile(t, packDir, "actions/a.yaml", safePackLintAction)

	input := mustLoadPackActionLintInput(t, packDir)
	if !sort.StringsAreSorted(input.actionPaths) {
		t.Fatalf("action paths are not sorted: %q", input.actionPaths)
	}
	if !input.requiredBinaries["bash"] || !input.requiredBinaries["jq"] {
		t.Fatalf("required binaries = %v", input.requiredBinaries)
	}
}
