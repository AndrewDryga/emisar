package hostaccess

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiscoverRequiresEveryExactRecipe(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "fixture", "pack.yaml"), `id: fixture
setup:
  host_access:
    - actions: [fixture.read]
      recipes:
        - name: first
          commands: [grant first]
          verify: [verify first]
        - name: second
          commands: [grant second]
          verify: [verify second]
`)
	write(t, filepath.Join(dir, "fixture", "test", "host_access.yaml"), `recipes:
  - access: 0
    recipe: 0
    fixture: debian
    action: fixture.read
    prepare: [deny]
    probe: read
`)

	_, err := Discover(dir)
	if err == nil || !strings.Contains(err.Error(), "does not prove setup.host_access recipes: 0.1") {
		t.Fatalf("Discover error = %v", err)
	}
}

func TestDiscoverRejectsActionOutsideGroup(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "fixture", "pack.yaml"), `id: fixture
setup:
  host_access:
    - actions: [fixture.read]
      recipes:
        - name: first
          commands: [grant]
          verify: [verify]
`)
	write(t, filepath.Join(dir, "fixture", "test", "host_access.yaml"), `recipes:
  - access: 0
    recipe: 0
    fixture: debian
    action: fixture.write
    prepare: [deny]
    probe: read
`)

	_, err := Discover(dir)
	if err == nil || !strings.Contains(err.Error(), `action "fixture.write" is not mapped`) {
		t.Fatalf("Discover error = %v", err)
	}
}

func TestDiscoverCarriesManifestCommands(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "fixture", "pack.yaml"), `id: fixture
setup:
  host_access:
    - actions: [fixture.read]
      recipes:
        - name: exact
          commands: [manifest grant]
          verify: [manifest verify]
`)
	write(t, filepath.Join(dir, "fixture", "test", "host_access.yaml"), `recipes:
  - access: 0
    recipe: 0
    fixture: fedora
    action: fixture.read
    prepare: [deny]
    recreate: [replace]
    probe: read
`)

	rows, err := Discover(dir, "fixture")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Commands[0] != "manifest grant" || rows[0].Verify[0] != "manifest verify" {
		t.Fatalf("rows = %+v", rows)
	}
}

func TestRepositoryProofsCoverEveryPublishedRecipe(t *testing.T) {
	root := filepath.Clean(filepath.Join("..", "..", ".."))
	rows, err := Discover(filepath.Join(root, "packs"))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 46 {
		t.Fatalf("proved recipes = %d, want 46", len(rows))
	}
}

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}
