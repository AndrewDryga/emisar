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

	err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir))
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

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "bash")); err != nil {
		t.Fatalf("declared bash should pass, got %v", err)
	}
}

// /bin/sh is on every host we support, so it is not a declarable dependency —
// requiring it would put noise in 178 actions and teach nothing.
func TestValidatePackInterpreterBinaries_PosixShellNeedsNoDeclaration(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"b.yaml": shAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir)); err != nil {
		t.Fatalf("/bin/sh should need no declaration, got %v", err)
	}
}

const execAction = `id: p.c
execution:
  command:
    binary: smartctl
    argv: ["--scan"]
`

const coreutilAction = `id: p.d
execution:
  command:
    binary: cat
    argv: ["/proc/meminfo"]
`

const absoluteAction = `id: p.e
execution:
  command:
    binary: /bin/sh
    argv: ["-c", "echo hi"]
`

// The exec half of the same gap: `emisar pack info` LookPaths exactly what
// requires.binaries names, so an undeclared smartctl fails at dispatch with no
// pre-flight signal. Eighteen packs sat here.
func TestValidatePackInterpreterBinaries_FlagsUndeclaredExecBinary(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"c.yaml": execAction})

	err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "curl"))
	if err == nil || !strings.Contains(err.Error(), "smartctl") || !strings.Contains(err.Error(), "c.yaml") {
		t.Fatalf("error should name the binary and the action file, got %v", err)
	}
}

func TestValidatePackInterpreterBinaries_AcceptsDeclaredExecBinary(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - smartctl\n",
		map[string]string{"c.yaml": execAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "smartctl")); err != nil {
		t.Fatalf("declared smartctl should pass, got %v", err)
	}
}

// Coreutils are on every host, and /bin/sh is the one sanctioned absolute
// path — declaring either would be noise in hundreds of actions.
func TestValidatePackInterpreterBinaries_UbiquitousAndAbsoluteBinariesAreExempt(t *testing.T) {
	dir := writePackInterpreterFixture(t,
		"requires:\n  binaries:\n    - curl\n",
		map[string]string{"d.yaml": coreutilAction, "e.yaml": absoluteAction})

	if err := validatePackInterpreterBinaries(fixturePackActionLintInput(t, dir, "curl")); err != nil {
		t.Fatalf("coreutils and /bin/sh should need no declaration, got %v", err)
	}
}

func TestExecBinaryLintCoversTheShippedCatalog(t *testing.T) {
	manifests, err := filepath.Glob(filepath.Join("..", "..", "..", "packs", "*", "pack.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	if len(manifests) == 0 {
		t.Fatal("no pack manifests found")
	}
	for _, manifest := range manifests {
		packDir := filepath.Dir(manifest)
		if err := validatePackInterpreterBinaries(mustLoadPackActionLintInput(t, packDir)); err != nil {
			t.Errorf("%s: %v", filepath.Base(packDir), err)
		}
	}
}
