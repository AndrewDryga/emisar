package selfupdate

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

func TestRunVerifiesReleaseAndHandsItToInstaller(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	name := fmt.Sprintf("emisar-0.24.1-%s-%s", runtime.GOOS, runtime.GOARCH)
	archive := releaseArchive(t, name, map[string]archiveEntry{
		name + "/emisar":     {body: "runner-binary", mode: 0o755},
		name + "/install.sh": {body: "#!/usr/bin/env bash\n", mode: 0o755},
	})
	digest := sha256.Sum256(archive)
	archiveName := name + ".tar.gz"
	checksums := hex.EncodeToString(digest[:]) + "  " + archiveName + "\n"

	var githubCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest.json":
			fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.24.1","version":"0.24.1","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
		case strings.HasSuffix(r.URL.Path, "/"+archiveName):
			w.Write(archive)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
			fmt.Fprint(w, checksums)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
			fmt.Fprint(w, "signed checksum bundle")
		case strings.Contains(r.URL.Path, "/repos/"):
			githubCalls++
			http.Error(w, "GitHub fallback must not run", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	t.Setenv("EMISAR_GITHUB_TOKEN", "secret-update-token")
	t.Setenv("EMISAR_ENROLLMENT_KEY", "must-not-reach-installer")
	t.Setenv("BASH_ENV", "/tmp/must-not-reach-installer")
	var commandName string
	var commandArgs, commandEnv []string
	var attestationSubjects []string
	deps := testDependencies(executable)
	deps.releaseBase = server.URL
	deps.apiBase = server.URL
	deps.downloadBase = server.URL
	deps.httpClient = server.Client()
	deps.tempRoot = root
	deps.runCommand = func(_ context.Context, name string, args, env []string, _ io.Writer, _ io.Writer) error {
		if len(args) > 2 && args[0] == "attestation" && args[1] == "verify" {
			attestationSubjects = append(attestationSubjects, args[2])
			return nil
		}
		commandName = name
		commandArgs = append([]string(nil), args...)
		commandEnv = append([]string(nil), env...)
		return nil
	}

	var stdout, stderr bytes.Buffer
	err := run(context.Background(), Options{
		CurrentVersion: "0.24.0",
		Stdout:         &stdout,
		Stderr:         &stderr,
	}, deps)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if githubCalls != 0 {
		t.Errorf("GitHub fallback calls = %d, want 0", githubCalls)
	}
	if commandName != "/bin/bash" {
		t.Fatalf("command = %q, want /bin/bash", commandName)
	}
	joined := strings.Join(commandArgs, "\n")
	for _, want := range []string{
		"--version\nrunner-v0.24.1", "--bin-dir\n" + filepath.Dir(executable),
		"--etc-dir\n" + filepath.Join(root, "etc"), "--preverified-bundle",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("installer arguments missing %q:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "--packs") {
		t.Errorf("installer arguments carry --packs; the pack set travels as EMISAR_PACKS:\n%s", joined)
	}
	if !containsEnvironment(commandEnv, "EMISAR_PACKS=") {
		t.Errorf("installer environment does not make the empty pack set explicit: %q", commandEnv)
	}
	for _, item := range append(commandArgs, commandEnv...) {
		if strings.Contains(item, "secret-update-token") || strings.Contains(item, "must-not-reach-installer") {
			t.Errorf("credential reached installer handoff: %q", item)
		}
	}
	if !containsEnvironment(commandEnv, "PATH=/usr/sbin:/usr/bin:/sbin:/bin") {
		t.Errorf("installer environment does not pin a system PATH: %q", commandEnv)
	}
	if !strings.Contains(stdout.String(), "Verified checksum") || !strings.Contains(stdout.String(), "Updating emisar 0.24.0 to 0.24.1") {
		t.Errorf("stdout does not explain the verified update:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "Verified release checksum signature") {
		t.Errorf("checksum signature verification was not surfaced: %s", stdout.String())
	}
	if len(attestationSubjects) != 1 || !strings.HasSuffix(attestationSubjects[0], "/SHA256SUMS") {
		t.Errorf("attestation subjects = %q, want SHA256SUMS", attestationSubjects)
	}
}

// checksumOnlyRelease serves one immutable release with its checksum file and
// counts the requests the update must not make once the verifier is settled.
type checksumOnlyRelease struct {
	server         *httptest.Server
	archiveHits    int
	bundleHits     int
	installerRuns  int
	attestationRun int
}

func newChecksumOnlyRelease(t *testing.T) *checksumOnlyRelease {
	t.Helper()
	name := fmt.Sprintf("emisar-0.24.1-%s-%s", runtime.GOOS, runtime.GOARCH)
	archive := releaseArchive(t, name, map[string]archiveEntry{
		name + "/emisar":     {body: "runner-binary", mode: 0o755},
		name + "/install.sh": {body: "#!/usr/bin/env bash\n", mode: 0o755},
	})
	digest := sha256.Sum256(archive)
	archiveName := name + ".tar.gz"
	checksums := hex.EncodeToString(digest[:]) + "  " + archiveName + "\n"
	fixture := &checksumOnlyRelease{}
	fixture.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest.json":
			fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.24.1","version":"0.24.1","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
		case strings.HasSuffix(r.URL.Path, "/"+archiveName):
			fixture.archiveHits++
			w.Write(archive)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
			fmt.Fprint(w, checksums)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
			fixture.bundleHits++
			fmt.Fprint(w, "signed checksum bundle")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(fixture.server.Close)
	return fixture
}

func (f *checksumOnlyRelease) dependencies(t *testing.T, root, executable string) dependencies {
	t.Helper()
	deps := testDependencies(executable)
	deps.releaseBase = f.server.URL
	deps.apiBase = f.server.URL
	deps.downloadBase = f.server.URL
	deps.httpClient = f.server.Client()
	deps.tempRoot = root
	deps.runCommand = func(_ context.Context, name string, args, _ []string, _ io.Writer, _ io.Writer) error {
		if len(args) > 1 && args[0] == "attestation" {
			f.attestationRun++
			return nil
		}
		if name == "/bin/bash" {
			f.installerRuns++
		}
		return nil
	}
	return deps
}

func TestRunWithoutVerifierWarnsAndContinuesOnChecksumAloneUnattended(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	fixture := newChecksumOnlyRelease(t)
	deps := fixture.dependencies(t, root, executable)
	deps.lookPath = func(string) (string, error) { return "", &exec.Error{Name: "gh", Err: exec.ErrNotFound} }

	var stdout, stderr bytes.Buffer
	err := run(context.Background(), Options{CurrentVersion: "0.24.0", Stdout: &stdout, Stderr: &stderr}, deps)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(stderr.String(), "gh is not installed") {
		t.Errorf("stderr does not warn about the missing verifier:\n%s", stderr.String())
	}
	if strings.Contains(stdout.String(), "[y/N]") {
		t.Errorf("an unattended update prompted:\n%s", stdout.String())
	}
	if fixture.bundleHits != 0 || fixture.attestationRun != 0 {
		t.Errorf("bundle downloads = %d, attestation runs = %d, want none without a verifier", fixture.bundleHits, fixture.attestationRun)
	}
	if !strings.Contains(stdout.String(), "Verified checksum") || strings.Contains(stdout.String(), "Verified release checksum signature") {
		t.Errorf("stdout must report the checksum and not a signature check:\n%s", stdout.String())
	}
	if fixture.installerRuns != 1 {
		t.Errorf("installer runs = %d, want 1", fixture.installerRuns)
	}
}

func TestRunRefusesAnUntrustedVerifierBeforeDownloading(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	fixture := newChecksumOnlyRelease(t)
	deps := fixture.dependencies(t, root, executable)
	deps.lookPath = func(string) (string, error) { return "", errors.New("/usr/local/bin/gh is not root-owned") }

	err := run(context.Background(), Options{CurrentVersion: "0.24.0"}, deps)
	if err == nil || !strings.Contains(err.Error(), "not root-owned") {
		t.Fatalf("error = %v, want the trusted-path refusal", err)
	}
	if fixture.archiveHits != 0 || fixture.installerRuns != 0 {
		t.Errorf("archive downloads = %d, installer runs = %d, want none after a refusal", fixture.archiveHits, fixture.installerRuns)
	}
}

func TestRunStripsIdentityOverridesFromTheInstallerHandoff(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	name := fmt.Sprintf("emisar-0.19.0-%s-%s", runtime.GOOS, runtime.GOARCH)
	archive := releaseArchive(t, name, map[string]archiveEntry{
		name + "/emisar":     {body: "runner-binary", mode: 0o755},
		name + "/install.sh": {body: "#!/usr/bin/env bash\n", mode: 0o755},
	})
	digest := sha256.Sum256(archive)
	archiveName := name + ".tar.gz"
	checksums := hex.EncodeToString(digest[:]) + "  " + archiveName + "\n"

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest.json":
			fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.19.0","version":"0.19.0","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
		case strings.HasSuffix(r.URL.Path, "/"+archiveName):
			w.Write(archive)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
			fmt.Fprint(w, checksums)
		case strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
			fmt.Fprint(w, "signed checksum bundle")
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	t.Setenv("EMISAR_GROUP", "hijacked-group")
	t.Setenv("EMISAR_RUNNER_ID", "hijacked-id")
	t.Setenv("EMISAR_RUNNER_LABEL_ROLE", "hijacked-label")

	var commandEnv []string
	deps := testDependencies(executable)
	deps.releaseBase = server.URL
	deps.apiBase = server.URL
	deps.downloadBase = server.URL
	deps.httpClient = server.Client()
	deps.tempRoot = root
	deps.runCommand = func(_ context.Context, _ string, _ []string, env []string, _ io.Writer, _ io.Writer) error {
		commandEnv = append([]string(nil), env...)
		return nil
	}

	var stdout, stderr bytes.Buffer
	err := run(context.Background(), Options{
		CurrentVersion: "0.18.0",
		Stdout:         &stdout,
		Stderr:         &stderr,
	}, deps)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	for _, item := range commandEnv {
		if strings.Contains(item, "hijacked-") {
			t.Errorf("identity override reached the installer handoff: %q", item)
		}
	}
}

func TestRunFallsBackToImmutableGitHubMirrorWhenEmisarDownloadFails(t *testing.T) {
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	name := fmt.Sprintf("emisar-0.19.0-%s-%s", runtime.GOOS, runtime.GOARCH)
	archive := releaseArchive(t, name, map[string]archiveEntry{
		name + "/emisar":     {body: "runner-binary", mode: 0o755},
		name + "/install.sh": {body: "#!/usr/bin/env bash\n", mode: 0o755},
	})
	digest := sha256.Sum256(archive)
	archiveName := name + ".tar.gz"
	checksums := hex.EncodeToString(digest[:]) + "  " + archiveName + "\n"

	var apiToken string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/latest.json":
			fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.19.0","version":"0.19.0","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
		case strings.Contains(r.URL.Path, "/repos/"):
			apiToken = r.Header.Get("Authorization")
			fmt.Fprint(w, `{"tag_name":"runner-v0.19.0","immutable":true}`)
		case strings.Contains(r.URL.Path, "/releases/download/") && strings.HasSuffix(r.URL.Path, "/"+archiveName):
			_, _ = w.Write(archive)
		case strings.Contains(r.URL.Path, "/releases/download/") && strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
			fmt.Fprint(w, checksums)
		case strings.Contains(r.URL.Path, "/releases/download/") && strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
			fmt.Fprint(w, "signed checksum bundle")
		case strings.HasSuffix(r.URL.Path, "/"+archiveName):
			http.Error(w, "mirror unavailable", http.StatusServiceUnavailable)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	t.Setenv("EMISAR_GITHUB_TOKEN", "secret-update-token")
	deps := testDependencies(executable)
	deps.releaseBase = server.URL
	deps.apiBase = server.URL
	deps.downloadBase = server.URL
	deps.httpClient = server.Client()
	deps.tempRoot = root
	deps.runCommand = func(_ context.Context, _ string, _ []string, _ []string, _ io.Writer, _ io.Writer) error {
		return nil
	}
	var stderr bytes.Buffer
	if err := run(context.Background(), Options{
		CurrentVersion: "0.18.0",
		Stderr:         &stderr,
	}, deps); err != nil {
		t.Fatalf("run: %v", err)
	}
	if apiToken != "Bearer secret-update-token" {
		t.Errorf("API authorization = %q", apiToken)
	}
	if !strings.Contains(stderr.String(), "GitHub release mirror") {
		t.Fatalf("fallback was not surfaced: %s", stderr.String())
	}
}

func TestRunFailsClosedBeforeNetworkWithoutTrustedReceipt(t *testing.T) {
	root := t.TempDir()
	executable := filepath.Join(root, "bin", "emisar")
	if err := os.MkdirAll(filepath.Dir(executable), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(executable, []byte("runner"), 0o755); err != nil {
		t.Fatal(err)
	}
	called := false
	deps := testDependencies(executable)
	deps.httpClient = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		called = true
		return nil, errors.New("network should not be called")
	})}

	err := run(context.Background(), Options{CurrentVersion: "0.18.0"}, deps)
	if err == nil || !strings.Contains(err.Error(), "official installer receipt locator is missing") {
		t.Fatalf("error = %v", err)
	}
	if called {
		t.Fatal("release network was called before install ownership was proven")
	}
}

func TestRunRequiresRootBeforeReadingInstallState(t *testing.T) {
	deps := testDependencies("/does/not/matter")
	deps.effectiveID = func() int { return 501 }
	err := run(context.Background(), Options{}, deps)
	if err == nil || !strings.Contains(err.Error(), "sudo emisar update") {
		t.Fatalf("error = %v", err)
	}
}

func TestResolveReleaseSelectsHighestStableImmutableVersion(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/latest.json" {
			http.NotFound(w, r)
			return
		}
		fmt.Fprint(w, `[
			{"tag_name":"runner-v0.20.0","immutable":false},
			{"tag_name":"runner-v0.19.1","immutable":true,"prerelease":true},
			{"tag_name":"runner-v0.9.9","immutable":true},
			{"tag_name":"runner-v0.19.0","immutable":true},
			{"tag_name":"mcp-v9.0.0","immutable":true}
		]`)
	}))
	defer server.Close()
	deps := testDependencies("/unused")
	deps.releaseBase = server.URL
	deps.apiBase = server.URL
	deps.httpClient = server.Client()

	got, err := resolveRelease(context.Background(), "", deps)
	if err != nil {
		t.Fatal(err)
	}
	if got.TagName != "runner-v0.19.0" {
		t.Fatalf("tag = %q, want runner-v0.19.0", got.TagName)
	}
}

func TestResolveReleaseRequiresExactImmutableVersion(t *testing.T) {
	tests := []struct {
		name     string
		version  string
		response string
		want     string
	}{
		{name: "bare accepted", version: "0.19.0", response: `{"tag_name":"runner-v0.19.0","immutable":true}`, want: "runner-v0.19.0"},
		{name: "tag accepted", version: "runner-v0.18.1", response: `{"tag_name":"runner-v0.18.1","immutable":true}`, want: "runner-v0.18.1"},
		{name: "mutable refused", version: "0.17.0", response: `{"tag_name":"runner-v0.17.0","immutable":false}`},
		{name: "invalid refused before request", version: "latest", response: `{}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.Contains(r.URL.Path, "/manifest.json") {
					http.NotFound(w, r)
					return
				}
				fmt.Fprint(w, test.response)
			}))
			defer server.Close()
			deps := testDependencies("/unused")
			deps.releaseBase = server.URL
			deps.apiBase = server.URL
			deps.httpClient = server.Client()
			got, err := resolveRelease(context.Background(), test.version, deps)
			if test.want == "" {
				if err == nil {
					t.Fatalf("expected refusal, got %+v", got)
				}
				return
			}
			if err != nil || got.TagName != test.want {
				t.Fatalf("release = %+v, err = %v", got, err)
			}
		})
	}
}

func TestResolveReleaseRejectsInvalidMirrorWithoutGitHubFallback(t *testing.T) {
	var githubCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/latest.json" {
			fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.19.0","version":"0.19.0","source_revision":"not-a-commit"}`)
			return
		}
		githubCalls++
		fmt.Fprint(w, `[{"tag_name":"runner-v0.19.0","immutable":true}]`)
	}))
	defer server.Close()
	deps := testDependencies("/unused")
	deps.releaseBase = server.URL
	deps.apiBase = server.URL
	deps.httpClient = server.Client()

	_, err := resolveRelease(context.Background(), "", deps)
	if err == nil || !strings.Contains(err.Error(), "invalid runner manifest") {
		t.Fatalf("error = %v", err)
	}
	if githubCalls != 0 {
		t.Fatalf("GitHub fallback calls = %d, want 0", githubCalls)
	}
}

func testDependencies(executable string) dependencies {
	return dependencies{
		executable:   func() (string, error) { return executable, nil },
		effectiveID:  func() int { return 0 },
		trustPath:    func(string, fs.FileInfo) error { return nil },
		lookPath:     func(string) (string, error) { return "/usr/bin/gh", nil },
		runCommand:   func(context.Context, string, []string, []string, io.Writer, io.Writer) error { return nil },
		httpClient:   http.DefaultClient,
		releaseBase:  releaseBaseURL,
		apiBase:      apiBaseURL,
		downloadBase: downloadBaseURL,
	}
}

func writeReceiptFixture(t *testing.T, root, repository string) string {
	t.Helper()
	bin := filepath.Join(root, "bin")
	etc := filepath.Join(root, "etc")
	for _, directory := range []string{bin, etc} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	executable := filepath.Join(bin, "emisar")
	if err := os.WriteFile(executable, []byte("runner"), 0o755); err != nil {
		t.Fatal(err)
	}
	receiptPath := filepath.Join(etc, "install-receipt")
	receipt := fmt.Sprintf(`schema=1
manager=install.sh
repository=%s
binary=%s
etc_dir=%s
data_dir=%s
log_dir=%s
service_user=emisar
service_group=emisar
init=systemd
`, repository, executable, etc, filepath.Join(root, "data"), filepath.Join(root, "log"))
	if err := os.WriteFile(receiptPath, []byte(receipt), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, receiptLocatorName), []byte(receiptPath+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return executable
}

type archiveEntry struct {
	body string
	mode int64
	kind byte
}

func releaseArchive(t *testing.T, _ string, entries map[string]archiveEntry) []byte {
	t.Helper()
	var compressed bytes.Buffer
	gzipWriter := gzip.NewWriter(&compressed)
	tarWriter := tar.NewWriter(gzipWriter)
	names := make([]string, 0, len(entries))
	for name := range entries {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		entry := entries[name]
		kind := entry.kind
		if kind == 0 {
			kind = tar.TypeReg
		}
		header := &tar.Header{Name: name, Mode: entry.mode, Size: int64(len(entry.body)), Typeflag: kind}
		if kind != tar.TypeReg {
			header.Size = 0
		}
		if err := tarWriter.WriteHeader(header); err != nil {
			t.Fatal(err)
		}
		if kind == tar.TypeReg {
			if _, err := io.WriteString(tarWriter, entry.body); err != nil {
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
	return compressed.Bytes()
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

// repoInstaller is the install.sh this checkout ships in every release bundle.
// The runner module also builds outside the repository, where there is nothing
// to parse against, so the test skips there rather than fail.
func repoInstaller(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("..", "..", "..", "install.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Skipf("install.sh is not in this tree: %v", err)
	}
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash is unavailable: %v", err)
	}
	return path
}

// The installer that parses the handoff ships inside the release bundle, and a
// fake that only records argv cannot see a flag the real script rejects: the
// runner passed `--packs ""` for four releases while install.sh answered
// "flag --packs requires a value" to every update. So the real script parses
// the real argv here. --help goes last so the script parses the handoff and
// exits before installing anything.
func TestReleaseInstallerParsesTheHandoff(t *testing.T) {
	installer := repoInstaller(t)
	root := t.TempDir()
	executable := writeReceiptFixture(t, root, officialRepository)
	bundle := filepath.Join(root, "bundle")
	if err := os.MkdirAll(bundle, 0o755); err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile(installer)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bundle, "install.sh"), script, 0o755); err != nil {
		t.Fatal(err)
	}
	current := receipt{
		Binary: executable, EtcDir: filepath.Join(root, "etc"), DataDir: filepath.Join(root, "data"),
		LogDir: filepath.Join(root, "log"), ServiceUser: "emisar", ServiceGroup: "emisar", Init: "systemd",
	}
	args, env := installerInvocation(bundle, "runner-v0.24.1", current)

	// Runners 0.20.0 through 0.24.0 add `--packs ""` after --yes, and every one
	// of them downloads the current installer, so that shape must parse too.
	fielded := make([]string, 0, len(args)+2)
	for _, arg := range args {
		fielded = append(fielded, arg)
		if arg == "--yes" {
			fielded = append(fielded, "--packs", "")
		}
	}
	for name, argv := range map[string][]string{"current runner": args, "runners 0.20.0 through 0.24.0": fielded} {
		probe := append(append([]string(nil), argv...), "--help")
		cmd := exec.Command("/bin/bash", probe...)
		cmd.Env = env
		output, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(output), "emisar installer") {
			t.Errorf("%s handoff was not parsed by install.sh: err=%v\n%s", name, err, output)
		}
	}
}
