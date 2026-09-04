package selfupdate

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadReceiptRejectsUntrustedOrForeignOwnership(t *testing.T) {
	tests := []struct {
		name       string
		repository string
		trust      func(string, fs.FileInfo) error
		want       string
	}{
		{name: "foreign installer", repository: "example/emisar", trust: func(string, fs.FileInfo) error { return nil }, want: "official installer"},
		{name: "unsafe ownership", repository: officialRepository, trust: func(path string, _ fs.FileInfo) error { return fmt.Errorf("%s is not root-owned", path) }, want: "not root-owned"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			executable := writeReceiptFixture(t, t.TempDir(), test.repository)
			_, err := loadReceipt(executable, test.trust)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestLoadReceiptAcceptsCaseInsensitiveRepository(t *testing.T) {
	// GitHub owner/repo slugs are case-insensitive, so a receipt an installer
	// wrote from a display-cased EMISAR_REPO must pass the repository check
	// rather than be rejected as unofficial — the whole of what this asserts.
	// The fixture is otherwise valid and its binary matches the executable, so
	// loadReceipt may legitimately accept it outright; on a host where the temp
	// path resolves through a symlink it stops later on binary identity instead.
	// Either way it must never draw the "official installer" rejection a
	// mixed-case repo hit before the fix — asserting a later binary-identity
	// failure would only be re-testing the symlink resolution of t.TempDir(),
	// which is why this used to pass on macOS and fail on Linux CI.
	for _, repository := range []string{"AndrewDryga/emisar"} {
		t.Run(repository, func(t *testing.T) {
			executable := writeReceiptFixture(t, t.TempDir(), repository)
			_, err := loadReceipt(executable, func(string, fs.FileInfo) error { return nil })
			if err != nil && strings.Contains(err.Error(), "official installer") {
				t.Fatalf("loadReceipt(%q) = %v, want the mixed-case repository accepted, not rejected as unofficial", repository, err)
			}
		})
	}
}

func TestLoadReceiptRequiresTrustedLocator(t *testing.T) {
	executable := writeReceiptFixture(t, t.TempDir(), officialRepository)
	locator := filepath.Join(filepath.Dir(executable), receiptLocatorName)
	_, err := loadReceipt(executable, func(path string, _ fs.FileInfo) error {
		if path == locator {
			return errors.New("locator is not root-owned")
		}
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "locator is not root-owned") {
		t.Fatalf("error = %v", err)
	}
}

func TestLoadReceiptRejectsLocatorAndReceiptSymlinks(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	locator := filepath.Join(filepath.Dir(executable), receiptLocatorName)
	receiptPathData, err := os.ReadFile(locator)
	if err != nil {
		t.Fatal(err)
	}
	receiptPath := strings.TrimSpace(string(receiptPathData))

	if err := os.Remove(locator); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(receiptPath, locator); err != nil {
		t.Fatal(err)
	}
	if _, err := loadReceipt(executable, func(string, fs.FileInfo) error { return nil }); err == nil || !strings.Contains(err.Error(), "not a link") {
		t.Fatalf("locator symlink error = %v", err)
	}

	if err := os.Remove(locator); err != nil {
		t.Fatal(err)
	}
	realReceipt := receiptPath + ".real"
	if err := os.Rename(receiptPath, realReceipt); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realReceipt, receiptPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(locator, []byte(receiptPath+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := loadReceipt(executable, func(string, fs.FileInfo) error { return nil }); err == nil || !strings.Contains(err.Error(), "not a link") {
		t.Fatalf("receipt symlink error = %v", err)
	}
}

func TestVerifyChecksumRejectsMismatchAndDuplicateEntry(t *testing.T) {
	root := t.TempDir()
	archive := filepath.Join(root, "release.tar.gz")
	if err := os.WriteFile(archive, []byte("archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name string
		body string
		want string
	}{
		{name: "mismatch", body: strings.Repeat("0", 64) + "  release.tar.gz\n", want: "checksum verification failed"},
		{name: "duplicate", body: strings.Repeat("0", 64) + "  release.tar.gz\n" + strings.Repeat("1", 64) + "  release.tar.gz\n", want: "duplicate entries"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			checksums := filepath.Join(root, test.name)
			if err := os.WriteFile(checksums, []byte(test.body), 0o600); err != nil {
				t.Fatal(err)
			}
			_, err := verifyChecksum(archive, checksums, "release.tar.gz")
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestExtractBundleRejectsExecutableLinksAndDuplicateFiles(t *testing.T) {
	name := "emisar-0.19.0-linux-amd64"
	tests := []struct {
		name    string
		entries []tar.Header
		bodies  []string
		want    string
	}{
		{
			name: "installer symlink",
			entries: []tar.Header{
				{Name: name + "/emisar", Mode: 0o755, Size: 6, Typeflag: tar.TypeReg},
				{Name: name + "/install.sh", Mode: 0o755, Typeflag: tar.TypeSymlink, Linkname: "/tmp/evil"},
			},
			bodies: []string{"binary", ""}, want: "invalid",
		},
		{
			name: "duplicate binary",
			entries: []tar.Header{
				{Name: name + "/emisar", Mode: 0o755, Size: 3, Typeflag: tar.TypeReg},
				{Name: name + "/emisar", Mode: 0o755, Size: 3, Typeflag: tar.TypeReg},
				{Name: name + "/install.sh", Mode: 0o755, Size: 6, Typeflag: tar.TypeReg},
			},
			bodies: []string{"one", "two", "script"}, want: "repeats",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), "release.tar.gz")
			writeRawArchive(t, archive, test.entries, test.bodies)
			_, err := extractBundle(archive, t.TempDir(), name)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestVerifyChecksumProvenanceUsesOfficialPolicyAndFailsClosed(t *testing.T) {
	deps := testDependencies("/unused")
	deps.lookPath = func(string) (string, error) { return "/usr/bin/gh", nil }

	var got []string
	deps.runCommand = func(_ context.Context, _ string, args, _ []string, _, _ io.Writer) error {
		got = append([]string(nil), args...)
		return errors.New("bad signature")
	}

	err := verifyChecksumProvenance(
		context.Background(),
		"/verified/SHA256SUMS",
		"/verified/SHA256SUMS.sigstore.jsonl",
		"runner-v0.24.1",
		deps,
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "did not verify") {
		t.Fatalf("error = %v", err)
	}
	want := []string{
		"attestation", "verify", "/verified/SHA256SUMS",
		"--bundle", "/verified/SHA256SUMS.sigstore.jsonl",
		"--repo", "andrewdryga/emisar",
		"--signer-workflow", "AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml",
		"--source-ref", "refs/tags/runner-v0.24.1",
		"--deny-self-hosted-runners",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("verify args = %q, want %q", got, want)
	}
}

func TestVerifyChecksumProvenanceRequiresTheBundleVerifier(t *testing.T) {
	deps := testDependencies("/unused")
	deps.lookPath = func(string) (string, error) { return "", errors.New("not found") }
	err := verifyChecksumProvenance(
		context.Background(),
		"/verified/SHA256SUMS",
		"/verified/SHA256SUMS.sigstore.jsonl",
		"runner-v0.24.1",
		deps,
		io.Discard,
	)
	if err == nil || !strings.Contains(err.Error(), "gh is not installed") {
		t.Fatalf("error = %v, want missing-verifier refusal", err)
	}
}

func TestInstallerInvocationUsesOfficialReleaseIdentity(t *testing.T) {
	receipt := receipt{
		Binary: "/usr/local/bin/emisar", EtcDir: "/etc/emisar",
		DataDir: "/var/lib/emisar", LogDir: "/var/log/emisar",
		ServiceUser: "emisar", ServiceGroup: "emisar", Init: "systemd",
	}
	_, env := installerInvocation("/tmp/bundle", "runner-v0.24.1", receipt)
	if !containsEnvironment(env, "EMISAR_REPO="+officialRepository) {
		t.Fatal("installer environment does not carry the official repository")
	}
	if !containsEnvironment(env, "EMISAR_ATTESTATION_WORKFLOW="+signerWorkflow) {
		t.Fatal("installer environment does not carry the official signer workflow")
	}
}

// `emisar update` re-execs install.sh as root, so nothing the ambient
// environment says may reach it: not the installer's own options (which the
// updater reconstructs from the receipt), and not a code-injection vector that
// would land inside a root bash. The table is the denylist itself plus the
// prefix families, so a name added to installerEnvNames is covered the day it
// is added.
func TestInstallerEnvironmentStripsEveryDeniedVariable(t *testing.T) {
	receipt := receipt{
		Binary: "/usr/local/bin/emisar", EtcDir: "/etc/emisar",
		DataDir: "/var/lib/emisar", LogDir: "/var/log/emisar",
		ServiceUser: "emisar", ServiceGroup: "emisar", Init: "systemd",
	}
	denied := make([]string, 0, len(installerEnvNames)+16)
	for name := range installerEnvNames {
		denied = append(denied, name)
	}
	denied = append(denied,
		// The prefix families the repo's canonical hijack test covers, each
		// spelled with a name the old enumerated list missed.
		"LD_AUDIT", "LD_PRELOAD", "LD_LIBRARY_PATH",
		"DYLD_INSERT_LIBRARIES", "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
		// The interpreter-option set, shared with packs and inherit_env.
		"BASH_ENV", "NODE_OPTIONS", "RUBYOPT", "PERL5OPT", "GIT_SSH_COMMAND",
		// Runner identity: the updater upgrades the install on THIS host.
		"EMISAR_GROUP", "EMISAR_RUNNER_ID", "EMISAR_RUNNER_LABEL_ROLE",
	)
	for _, name := range denied {
		t.Setenv(name, "hostile-"+name)
	}

	_, env := installerInvocation("/tmp/bundle", "runner-v0.23.0", receipt)
	for _, name := range denied {
		if containsEnvironment(env, name+"=hostile-"+name) {
			t.Errorf("%s reached the root installer environment", name)
		}
	}
	// The four values the updater sets itself must still arrive, so the sweep
	// above cannot pass by stripping everything.
	for _, want := range []string{
		"PATH=/usr/sbin:/usr/bin:/sbin:/bin",
		"EMISAR_REPO=" + officialRepository,
		"EMISAR_ATTESTATION_WORKFLOW=" + signerWorkflow,
		"EMISAR_PACKS=",
	} {
		if !containsEnvironment(env, want) {
			t.Errorf("installer environment is missing %q", want)
		}
	}
}

func containsEnvironment(env []string, want string) bool {
	for _, item := range env {
		if item == want {
			return true
		}
	}
	return false
}

func writeRawArchive(t *testing.T, path string, headers []tar.Header, bodies []string) {
	t.Helper()
	var compressed bytes.Buffer
	gzipWriter := gzip.NewWriter(&compressed)
	tarWriter := tar.NewWriter(gzipWriter)
	for index := range headers {
		header := headers[index]
		if err := tarWriter.WriteHeader(&header); err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg {
			if _, err := io.WriteString(tarWriter, bodies[index]); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, compressed.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}
}
