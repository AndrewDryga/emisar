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

func TestVerifyProvenanceUsesTargetReleasePolicyAndFailsClosed(t *testing.T) {
	tests := []struct {
		name     string
		tag      string
		workflow string
		digest   string
	}{
		{name: "supported pre-split release", tag: legacyRunnerTag, workflow: legacySignerWorkflow, digest: legacySignerDigest},
		{name: "future trusted release", tag: "runner-v0.23.0", workflow: signerWorkflow},
		{name: "unused older tag", tag: "runner-v0.21.99", workflow: signerWorkflow},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			deps := testDependencies("/unused")
			deps.lookPath = func(string) (string, error) { return "/usr/bin/gh", nil }
			var calls int
			var verifyArgs []string
			deps.runCommand = func(_ context.Context, _ string, args, _ []string, _, _ io.Writer) error {
				calls++
				if strings.Join(args, " ") == "auth status" {
					return nil
				}
				verifyArgs = append([]string(nil), args...)
				return errors.New("bad provenance")
			}
			err := verifyProvenance(context.Background(), "/verified/archive", test.tag, deps, io.Discard, io.Discard)
			if err == nil || !strings.Contains(err.Error(), "did not verify") {
				t.Fatalf("error = %v", err)
			}
			if calls != 2 {
				t.Fatalf("command calls = %d, want 2", calls)
			}
			wantArgs := []string{
				"attestation", "verify", "/verified/archive",
				"--repo", officialRepository,
				"--signer-workflow", test.workflow,
				"--source-ref", "refs/tags/" + test.tag,
			}
			if test.digest != "" {
				wantArgs = append(wantArgs, "--signer-digest", test.digest)
			}
			wantArgs = append(wantArgs, "--deny-self-hosted-runners")
			if strings.Join(verifyArgs, "\n") != strings.Join(wantArgs, "\n") {
				t.Fatalf("verify args = %q, want %q", verifyArgs, wantArgs)
			}
		})
	}
}

func TestVerifyProvenanceUsesUpdateTokenWithoutPuttingItInArguments(t *testing.T) {
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
		if !containsEnvironment(env, "GH_TOKEN=test-update-token") {
			t.Fatal("update token was not provided to the authenticated verifier")
		}
		return nil
	}
	if err := verifyProvenance(context.Background(), "/verified/archive", "runner-v0.23.0", deps, io.Discard, io.Discard); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("command calls = %d, want 2", calls)
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
