package ci

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// A real tiny Go ELF exercises the byte inspector; it is not qualification of
// upstream Compose. The Docker-bound qualifier runs the actual upstream build.
func composeBinaryFixture(t *testing.T, bundle string) {
	t.Helper()
	source := t.TempDir()
	writeFixture(t, source, "go.mod", "module github.com/docker/compose/v5\n\ngo 1.27.2\n")
	writeFixture(t, source, "cmd/main.go", "package main\nfunc main() {}\n")
	if err := os.MkdirAll(filepath.Join(bundle, "cli-plugins"), 0o700); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(bundle, "cli-plugins/docker-compose")
	command := exec.Command("go", "build", "-mod=readonly", "-trimpath", "-tags=e2e", "-ldflags=-w -X github.com/docker/compose/v5/internal.Version=v5.5.1", "-o", binary, "./cmd")
	command.Dir = source
	command.Env = append(os.Environ(), "GOTOOLCHAIN=local", "CGO_ENABLED=0", "GOOS=linux", "GOARCH=amd64")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build inspectable Go fixture: %v\n%s", err, output)
	}
	info, err := exec.Command("go", "version", "-m", binary).Output()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "compose-buildinfo.txt"), info, 0o600); err != nil {
		t.Fatal(err)
	}
	sealComposeBuildFixture(t, bundle)
}

func sealComposeBuildFixture(t *testing.T, bundle string) {
	t.Helper()
	binaryHash, err := hashFile(filepath.Join(bundle, "cli-plugins/docker-compose"))
	if err != nil {
		t.Fatal(err)
	}
	infoHash, err := hashFile(filepath.Join(bundle, "compose-buildinfo.txt"))
	if err != nil {
		t.Fatal(err)
	}
	data := fmt.Sprintf("%s\nbinary_sha256=%s\nbuild_info_sha256=%s\n", strings.Join(composeBuildInputs, "\n"), binaryHash, infoHash)
	if err := os.WriteFile(filepath.Join(bundle, "compose-build.txt"), []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestComposeRejectsFalseSourceCompilerAndResealedNonGoBytes(t *testing.T) {
	bundle := t.TempDir()
	composeBinaryFixture(t, bundle)
	component, err := diagnosticsComposeComponent(bundle)
	if err != nil {
		t.Fatal(err)
	}
	binaryHash, _ := hashFile(filepath.Join(bundle, "cli-plugins/docker-compose"))
	if component.Properties[0].Value != binaryHash {
		t.Fatal("SBOM does not identify actual rebuilt bytes")
	}
	path := filepath.Join(bundle, "compose-build.txt")
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, old, replacement string }{
		{"foreign source", composeSourceURL, "https://example.invalid/source"},
		{"old compiler", "toolchain_version=go1.27.2", "toolchain_version=go1.26.8"},
		{"changed source inputs", "go_mod_sha256=cdf5424", "go_mod_sha256=0000000"},
		{"extra provenance", "\nbinary_sha256=", "\nunknown=allowed\nbinary_sha256="},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(strings.Replace(string(original), tc.old, tc.replacement, 1)), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, err := diagnosticsComposeComponent(bundle); err == nil {
				t.Fatal("false source/compiler provenance accepted")
			}
		})
	}
	if err := os.WriteFile(filepath.Join(bundle, "cli-plugins/docker-compose"), []byte("not a patched Go ELF"), 0o600); err != nil {
		t.Fatal(err)
	}
	sealComposeBuildFixture(t, bundle)
	if _, err := diagnosticsComposeComponent(bundle); err == nil {
		t.Fatal("resealed non-Go bytes accepted as patched Compose")
	}
}
