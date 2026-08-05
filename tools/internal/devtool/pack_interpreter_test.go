package devtool

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writePackInterpreterFixture(t *testing.T, manifest string, actions map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "pack.yaml"), []byte(manifest), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "actions"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range actions {
		if err := os.WriteFile(filepath.Join(dir, "actions", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const bashAction = `id: p.a
execution:
  script:
    path: scripts/a.sh
    interpreter: /bin/bash
`

const shAction = `id: p.b
execution:
  script:
    path: scripts/b.sh
    interpreter: /bin/sh
`

func TestValidatePackInterpreterBinaries_FlagsUndeclaredBash(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"a.yaml": bashAction})

	err := validatePackInterpreterBinaries(dir)
	if err == nil {
		t.Fatal("an action running /bin/bash with bash undeclared must fail")
	}
	if !strings.Contains(err.Error(), "bash") || !strings.Contains(err.Error(), "a.yaml") {
		t.Fatalf("error should name the binary and the action file, got %v", err)
	}
}

func TestValidatePackInterpreterBinaries_AcceptsDeclaredBash(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n    - bash\n",
		map[string]string{"a.yaml": bashAction})

	if err := validatePackInterpreterBinaries(dir); err != nil {
		t.Fatalf("declared bash should pass, got %v", err)
	}
}

// /bin/sh is on every host we support, so it is not a declarable dependency —
// requiring it would put noise in 178 actions and teach nothing.
func TestValidatePackInterpreterBinaries_PosixShellNeedsNoDeclaration(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"b.yaml": shAction})

	if err := validatePackInterpreterBinaries(dir); err != nil {
		t.Fatalf("/bin/sh should need no declaration, got %v", err)
	}
}
