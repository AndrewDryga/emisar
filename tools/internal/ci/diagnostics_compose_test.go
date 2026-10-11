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
		{"unpatched module selection", "module_update=go get golang.org/x/net@v0.60.0", "module_update=go get golang.org/x/net@v0.58.0"},
		{"unpatched containerd selection", "github.com/containerd/containerd/v2@v2.3.6", "github.com/containerd/containerd/v2@v2.3.4"},
		{"changed derived module graph", "derived_go_mod_sha256=b0d21d7", "derived_go_mod_sha256=0000000"},
		{"changed derived checksums", "derived_go_sum_sha256=bedd903", "derived_go_sum_sha256=0000000"},
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

// Exercise the production host's actual receipt parser, not only the Go
// inspector. This fixture tests receipt binding, not native Compose behavior.
func TestHostComposeReceiptRejectsStaleAndTamperedProvenance(t *testing.T) {
	bundle := t.TempDir()
	composeBinaryFixture(t, bundle)
	source, err := os.ReadFile(filepath.Join("..", "..", "..", "infra", "runtime", "admin-runner", "verify-diagnostics.sh"))
	if err != nil {
		t.Fatal(err)
	}
	start := strings.Index(string(source), "{\n  read -r line; [ \"$line\" = source_url=")
	if start < 0 {
		t.Fatal("host Compose receipt parser not found")
	}
	endMarker := "} < compose-build.txt"
	end := strings.Index(string(source[start:]), endMarker)
	if end < 0 {
		t.Fatal("host Compose receipt parser is not bounded")
	}
	parser := string(source[start : start+end+len(endMarker)])
	check := func() error {
		command := exec.Command("bash", "-euo", "pipefail", "-c", parser)
		command.Dir = bundle
		output, err := command.CombinedOutput()
		if err != nil {
			return fmt.Errorf("host receipt parser: %w\n%s", err, output)
		}
		return nil
	}
	if err := check(); err != nil {
		t.Fatalf("host rejects current builder/CI receipt: %v", err)
	}
	path := filepath.Join(bundle, "compose-build.txt")
	original, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, old, replacement string }{
		{"old module selection", "module_update=go get golang.org/x/net@v0.60.0", "module_update=go get golang.org/x/net@v0.58.0"},
		{"old containerd selection", "github.com/containerd/containerd/v2@v2.3.6", "github.com/containerd/containerd/v2@v2.3.4"},
		{"foreign derived graph", "derived_go_mod_sha256=b0d21d7", "derived_go_mod_sha256=0000000"},
		{"foreign derived sums", "derived_go_sum_sha256=bedd903", "derived_go_sum_sha256=0000000"},
		{"unbound workspace setting", "build_flags=GOWORK=off ", "build_flags="},
		{"extra provenance", "\nbinary_sha256=", "\nunknown=allowed\nbinary_sha256="},
		{"reordered provenance", "build_info_sha256=", "unexpected=allowed\nbuild_info_sha256="},
	} {
		t.Run(tc.name, func(t *testing.T) {
			modified := strings.Replace(string(original), tc.old, tc.replacement, 1)
			if modified == string(original) {
				t.Fatal("negative control did not change the receipt")
			}
			if err := os.WriteFile(path, []byte(modified), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := check(); err == nil {
				t.Fatal("host accepted tampered Compose receipt")
			}
		})
	}
	if err := os.WriteFile(path, append(append([]byte(nil), original...), []byte("unknown=allowed\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := check(); err == nil {
		t.Fatal("host accepted trailing provenance")
	}
	if err := os.WriteFile(path, original, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"cli-plugins/docker-compose", "compose-buildinfo.txt"} {
		path := filepath.Join(bundle, name)
		original, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("changed measured bytes"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := check(); err == nil {
			t.Fatalf("host accepted changed %s bytes", name)
		}
		if err := os.WriteFile(path, original, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := check(); err != nil {
		t.Fatalf("host rejects restored current receipt: %v", err)
	}
}
