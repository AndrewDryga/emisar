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
	for _, repository := range []string{"AndrewDryga/emisar", "EmisarHQ/emisar"} {
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

// The accepted identities are restated literally so a typo in the constants
// fails here instead of shipping a fleet that verifies against nothing.
var (
	testCurrentIdentity = releaseIdentity{
		repository: "andrewdryga/emisar",
		workflow:   "AndrewDryga/emisar/.github/workflows/runner-release-trusted.yml",
	}
	testSuccessorIdentity = releaseIdentity{
		repository: "emisarhq/emisar",
		workflow:   "EmisarHQ/emisar/.github/workflows/runner-release-trusted.yml",
	}
	testLegacyIdentity = releaseIdentity{
		repository: "andrewdryga/emisar",
		workflow:   "AndrewDryga/emisar/.github/workflows/runner-release.yml",
		digest:     "642128eb48205405fd44ce845118e6a68737eea2",
	}
)

func wantChecksumVerifyArgs(identity releaseIdentity, checksums, bundle, tag string) []string {
	args := []string{
		"attestation", "verify", checksums,
		"--bundle", bundle,
		"--repo", identity.repository,
		"--signer-workflow", identity.workflow,
		"--source-ref", "refs/tags/" + tag,
	}
	if identity.digest != "" {
		args = append(args, "--signer-digest", identity.digest)
	}
	return append(args, "--deny-self-hosted-runners")
}

func TestVerifyChecksumProvenanceUsesTargetReleasePolicyAndFailsClosed(t *testing.T) {
	tests := []struct {
		name     string
		tag      string
		attempts []releaseIdentity
	}{
		{name: "current trusted release", tag: "runner-v0.23.1", attempts: []releaseIdentity{testCurrentIdentity, testSuccessorIdentity}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			deps := testDependencies("/unused")
			deps.lookPath = func(string) (string, error) { return "/usr/bin/gh", nil }
			var calls int
			var verifyArgs [][]string
			deps.runCommand = func(_ context.Context, _ string, args, _ []string, _, _ io.Writer) error {
				calls++
				verifyArgs = append(verifyArgs, append([]string(nil), args...))
				return errors.New("bad provenance")
			}
			_, err := verifyChecksumProvenance(context.Background(), "/verified/checksums", "/verified/bundle", test.tag, deps, io.Discard)
			if err == nil || !strings.Contains(err.Error(), "did not verify") {
				t.Fatalf("error = %v", err)
			}
			if calls != len(test.attempts) {
				t.Fatalf("command calls = %d, want %d", calls, len(test.attempts))
			}
			if len(verifyArgs) != len(test.attempts) {
				t.Fatalf("verify attempts = %d, want %d", len(verifyArgs), len(test.attempts))
			}
			for index, identity := range test.attempts {
				want := wantChecksumVerifyArgs(identity, "/verified/checksums", "/verified/bundle", test.tag)
				if strings.Join(verifyArgs[index], "\n") != strings.Join(want, "\n") {
					t.Fatalf("verify args[%d] = %q, want %q", index, verifyArgs[index], want)
				}
			}
		})
	}
}

func TestVerifyChecksumProvenanceRequiresTheBundleVerifier(t *testing.T) {
	deps := testDependencies("/unused")
	deps.lookPath = func(string) (string, error) { return "", errors.New("not found") }
	_, err := verifyChecksumProvenance(context.Background(), "/verified/checksums", "/verified/bundle",
		"runner-v0.24.0", deps, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "gh is not installed") {
		t.Fatalf("error = %v, want missing-verifier refusal", err)
	}
}

func TestVerifyChecksumProvenanceAcceptsTheSuccessorIdentityDuringTheTransfer(t *testing.T) {
	deps := testDependencies("/unused")
	deps.lookPath = func(string) (string, error) { return "/usr/bin/gh", nil }
	var verifyArgs [][]string
	deps.runCommand = func(_ context.Context, _ string, args, _ []string, _, _ io.Writer) error {
		verifyArgs = append(verifyArgs, append([]string(nil), args...))
		if len(verifyArgs) == 1 {
			return errors.New("certificate SAN names the successor workflow")
		}
		return nil
	}
	identity, err := verifyChecksumProvenance(context.Background(), "/verified/checksums", "/verified/bundle", "runner-v0.23.1", deps, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if identity != testSuccessorIdentity {
		t.Fatalf("identity = %+v, want %+v", identity, testSuccessorIdentity)
	}
	if len(verifyArgs) != 2 {
		t.Fatalf("verify attempts = %d, want 2", len(verifyArgs))
	}
	wantFirst := wantChecksumVerifyArgs(testCurrentIdentity, "/verified/checksums", "/verified/bundle", "runner-v0.23.1")
	if strings.Join(verifyArgs[0], "\n") != strings.Join(wantFirst, "\n") {
		t.Fatalf("first attempt = %q, want the current identity %q", verifyArgs[0], wantFirst)
	}
}

func TestInstallerInvocationCarriesTheVerifiedIdentity(t *testing.T) {
	t.Setenv("EMISAR_ALLOW_UNSIGNED_CHECKSUM", "true")
	receipt := receipt{
		Binary: "/usr/local/bin/emisar", EtcDir: "/etc/emisar",
		DataDir: "/var/lib/emisar", LogDir: "/var/log/emisar",
		ServiceUser: "emisar", ServiceGroup: "emisar", Init: "systemd",
	}
	_, env := installerInvocation("/tmp/bundle", "runner-v0.23.1", receipt, testSuccessorIdentity)
	if !containsEnvironment(env, "EMISAR_REPO=emisarhq/emisar") {
		t.Fatal("installer environment does not carry the verified repository")
	}
	if !containsEnvironment(env, "EMISAR_ATTESTATION_WORKFLOW="+testSuccessorIdentity.workflow) {
		t.Fatal("installer environment does not carry the verified signer workflow")
	}
	for _, item := range env {
		if strings.HasPrefix(item, "EMISAR_ALLOW_UNSIGNED_CHECKSUM=") {
			t.Fatalf("self-update handed the installer a break-glass override: %q", item)
		}
	}
}

func TestVerifyChecksumProvenanceNeedsNoGitHubToken(t *testing.T) {
	t.Setenv("GH_TOKEN", "")
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("EMISAR_GITHUB_TOKEN", "test-update-token")
	deps := testDependencies("/unused")
	deps.lookPath = func(string) (string, error) { return "/usr/bin/gh", nil }
	var calls int
	deps.runCommand = func(_ context.Context, _ string, args, env []string, _, _ io.Writer) error {
		calls++
		if strings.Contains(strings.Join(args, "\n"), "test-update-token") {
			t.Fatal("update token reached verifier arguments")
		}
		for _, item := range env {
			if strings.HasPrefix(item, "GH_TOKEN=") || strings.HasPrefix(item, "GITHUB_TOKEN=") ||
				strings.HasPrefix(item, "EMISAR_GITHUB_TOKEN=") {
				t.Fatalf("bundle verifier received a GitHub token: %q", item)
			}
		}
		return nil
	}
	if _, err := verifyChecksumProvenance(context.Background(), "/verified/checksums", "/verified/bundle", "runner-v0.23.1", deps, io.Discard); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("command calls = %d, want 1", calls)
	}
}

func TestVerifyArtifactProvenanceUsesVerifiedIdentityAndFailsClosed(t *testing.T) {
	deps := testDependencies("/unused")
	var calls int
	var verifyArgs []string
	deps.runCommand = func(_ context.Context, _ string, args, _ []string, _, _ io.Writer) error {
		calls++
		if strings.Join(args, " ") == "auth status" {
			return nil
		}
		verifyArgs = append([]string(nil), args...)
		return errors.New("bad archive provenance")
	}
	err := verifyArtifactProvenance(context.Background(), "/verified/archive", "runner-v0.24.0",
		testSuccessorIdentity, false, deps, io.Discard, io.Discard)
	if err == nil || !strings.Contains(err.Error(), "release attestation did not verify") {
		t.Fatalf("error = %v, want archive-attestation refusal", err)
	}
	if calls != 2 {
		t.Fatalf("command calls = %d, want auth plus verification", calls)
	}
	want := []string{
		"attestation", "verify", "/verified/archive",
		"--repo", testSuccessorIdentity.repository,
		"--signer-workflow", testSuccessorIdentity.workflow,
		"--source-ref", "refs/tags/runner-v0.24.0",
		"--deny-self-hosted-runners",
	}
	if strings.Join(verifyArgs, "\n") != strings.Join(want, "\n") {
		t.Fatalf("verify args = %q, want %q", verifyArgs, want)
	}
}

func TestVerifyArtifactProvenanceRequiresAuthenticationBeforeSignedChecksums(t *testing.T) {
	tests := []struct {
		name     string
		lookPath func(string) (string, error)
		run      func(context.Context, string, []string, []string, io.Writer, io.Writer) error
		want     string
	}{
		{
			name:     "missing gh",
			lookPath: func(string) (string, error) { return "", fs.ErrNotExist },
			want:     "gh is not installed",
		},
		{
			name:     "unauthenticated gh",
			lookPath: func(string) (string, error) { return "/usr/bin/gh", nil },
			run: func(context.Context, string, []string, []string, io.Writer, io.Writer) error {
				return errors.New("not authenticated")
			},
			want: "gh is not authenticated",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			deps := testDependencies("/unused")
			deps.lookPath = test.lookPath
			if test.run != nil {
				deps.runCommand = test.run
			}
			err := verifyArtifactProvenance(context.Background(), "/verified/archive", legacyRunnerTag,
				testLegacyIdentity, true, deps, io.Discard, io.Discard)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestVerifyArtifactProvenanceMaySkipAuthenticationAfterSignedChecksums(t *testing.T) {
	deps := testDependencies("/unused")
	deps.runCommand = func(context.Context, string, []string, []string, io.Writer, io.Writer) error {
		return errors.New("not authenticated")
	}
	var stderr bytes.Buffer
	if err := verifyArtifactProvenance(context.Background(), "/verified/archive", "runner-v0.24.0",
		testCurrentIdentity, false, deps, io.Discard, &stderr); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stderr.String(), "not authenticated") {
		t.Fatalf("missing optional-check warning: %s", stderr.String())
	}
}

func TestVerifyArtifactProvenanceUsesUpdateTokenWithoutPuttingItInArguments(t *testing.T) {
	t.Setenv("GH_TOKEN", "")
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("EMISAR_GITHUB_TOKEN", "test-update-token")
	deps := testDependencies("/unused")
	var calls int
	deps.runCommand = func(_ context.Context, _ string, args, env []string, _, _ io.Writer) error {
		calls++
		if strings.Contains(strings.Join(args, "\n"), "test-update-token") {
			t.Fatal("update token reached verifier arguments")
		}
		if !containsEnvironment(env, "GH_TOKEN=test-update-token") {
			t.Fatal("update token was not provided to the authenticated verifier")
		}
		return nil
	}
	if err := verifyArtifactProvenance(context.Background(), "/verified/archive", "runner-v0.24.0",
		testCurrentIdentity, false, deps, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("command calls = %d, want auth plus verification", calls)
	}
}

func TestSignedChecksumPublishedStartsAtBootstrapRelease(t *testing.T) {
	for _, test := range []struct {
		tag  string
		want bool
	}{
		{tag: "runner-v0.23.0", want: false},
		{tag: "runner-v0.23.1", want: true},
		{tag: "runner-v0.24.0", want: true},
		{tag: "runner-v1.0.0", want: true},
	} {
		if got := signedChecksumPublished(test.tag); got != test.want {
			t.Errorf("signedChecksumPublished(%q) = %v, want %v", test.tag, got, test.want)
		}
	}
}

func TestLoadReceiptAcceptsEitherTransferSpelling(t *testing.T) {
	for _, repository := range []string{"andrewdryga/emisar", "emisarhq/emisar"} {
		t.Run(repository, func(t *testing.T) {
			executable, err := filepath.EvalSymlinks(writeReceiptFixture(t, t.TempDir(), repository))
			if err != nil {
				t.Fatal(err)
			}
			if _, err := loadReceipt(executable, func(string, fs.FileInfo) error { return nil }); err != nil {
				t.Fatalf("loadReceipt error = %v", err)
			}
		})
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
