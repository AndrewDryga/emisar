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
	"time"
)

func TestExecuteLetsInstallerRollbackBeforeCancellationReturns(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "emisar")
	backup := filepath.Join(root, "emisar.previous")
	ready := filepath.Join(root, "ready")
	restored := filepath.Join(root, "restored")
	script := filepath.Join(root, "installer.sh")
	if err := os.WriteFile(target, []byte("old runner\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	contents := `#!/usr/bin/env bash
set -eu
target=$1
backup=$2
ready=$3
restored=$4
mv "$target" "$backup"
printf 'new runner\n' >"$target"
trap 'mv -f "$backup" "$target"; printf done >"$restored"; exit 143' TERM INT
printf ready >"$ready"
while :; do sleep 1; done
`
	if err := os.WriteFile(script, []byte(contents), 0o700); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- execute(ctx, "/bin/bash", []string{script, target, backup, ready, restored},
			[]string{"PATH=/usr/bin:/bin"}, io.Discard, io.Discard)
	}()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(ready); err == nil {
			break
		} else if !errors.Is(err, fs.ErrNotExist) {
			t.Fatal(err)
		}
		if time.Now().After(deadline) {
			t.Fatal("installer did not reach its activation boundary")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("execute cancellation = %v, want context canceled", err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "old runner\n" {
		t.Fatalf("target after cancellation = %q err=%v, want restored old runner", data, err)
	}
	if _, err := os.Stat(restored); err != nil {
		t.Fatalf("installer rollback did not finish before execute returned: %v", err)
	}
}

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
	deps.runCommand = func(_ context.Context, name string, args, env []string, stdout, _ io.Writer) error {
		if len(args) > 2 && args[0] == "attestation" && args[1] == "verify" {
			attestationSubjects = append(attestationSubjects, args[2])
			return nil
		}
		if handled, err := handleSafeTargetPreflight(name, args, stdout,
			filepath.Join(root, "etc"), filepath.Join(root, "data")); handled {
			return err
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
	if !strings.Contains(stdout.String(), "Verified release checksum signature") ||
		!strings.Contains(stdout.String(), "Verified GitHub build provenance") {
		t.Errorf("both checksum and archive provenance were not surfaced: %s", stdout.String())
	}
	if len(attestationSubjects) != 2 || !strings.HasSuffix(attestationSubjects[0], "/SHA256SUMS") ||
		!strings.HasSuffix(attestationSubjects[1], "/"+archiveName) {
		t.Errorf("attestation subjects = %q, want checksum then archive", attestationSubjects)
	}
}

func TestRunRefusesTargetWithoutManagedUpdateBoundary(t *testing.T) {
	tests := []struct {
		name        string
		help        string
		contract    string
		contractErr error
		checkErr    error
		wantError   string
	}{
		{
			name:      "missing offline reader",
			help:      "State commands:\n  inspect\n",
			wantError: "cannot verify the existing durable dispatch state",
		},
		{
			name:        "historical installer has no managed-update contract",
			help:        "State commands:\n  check-dispatch-log\n",
			contractErr: errors.New("unknown flag"),
			wantError:   "too old for a safe managed update",
		},
		{
			name:      "wrong installer contract",
			help:      "State commands:\n  check-dispatch-log\n",
			contract:  "different-contract\n",
			wantError: "too old for a safe managed update",
		},
		{
			name:      "reader rejects config and receipt mapping",
			help:      "State commands:\n  check-dispatch-log\n",
			contract:  "emisar-managed-update-v1\n",
			checkErr:  errors.New("configured data directory mismatch"),
			wantError: "cannot reconcile the configured and receipt-owned durable dispatch state",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			executable := writeReceiptFixture(t, root, officialRepository)
			dataDir := filepath.Join(root, "data")

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
					_, _ = w.Write(archive)
				case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
					fmt.Fprint(w, checksums)
				case strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
					fmt.Fprint(w, "signed checksum bundle")
				default:
					http.NotFound(w, r)
				}
			}))
			defer server.Close()

			installerCalled := false
			deps := testDependencies(executable)
			deps.releaseBase = server.URL
			deps.apiBase = server.URL
			deps.downloadBase = server.URL
			deps.httpClient = server.Client()
			deps.tempRoot = root
			deps.runCommand = func(_ context.Context, command string, args, _ []string, stdout, _ io.Writer) error {
				switch {
				case strings.Join(args, " ") == "auth status":
					return nil
				case len(args) > 1 && args[0] == "attestation" && args[1] == "verify":
					return nil
				case command == "/bin/bash" && len(args) == 2 && args[1] == "--managed-update-contract":
					_, _ = io.WriteString(stdout, test.contract)
					return test.contractErr
				case command == "/bin/bash":
					installerCalled = true
					return nil
				case strings.Join(args, " ") == "state --help":
					_, _ = io.WriteString(stdout, test.help)
					return nil
				case strings.Join(args, "\x00") == strings.Join([]string{
					"--config", filepath.Join(root, "etc", "config.yaml"),
					"state", "check-dispatch-log", "--data-dir", dataDir,
				}, "\x00"):
					return test.checkErr
				default:
					return fmt.Errorf("unexpected command %s %q", command, args)
				}
			}

			err := run(context.Background(), Options{CurrentVersion: "0.18.0"}, deps)
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("error = %v, want %q", err, test.wantError)
			}
			if installerCalled {
				t.Fatal("incompatible target installer was invoked")
			}
		})
	}
}

// A runner's group, id and labels decide where dispatch reaches it. They are
// install-time inputs, so an ambient value in root's environment must not
// silently re-target the host on `sudo emisar update` — the update re-runs the
// installer, which would bake whatever it inherits into config.yaml.
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
	deps.runCommand = func(_ context.Context, command string, args, env []string, stdout, _ io.Writer) error {
		if handled, err := handleSafeTargetPreflight(command, args, stdout,
			filepath.Join(root, "etc"), filepath.Join(root, "data")); handled {
			return err
		}
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
	deps.runCommand = func(_ context.Context, command string, args, _ []string, stdout, _ io.Writer) error {
		if handled, err := handleSafeTargetPreflight(command, args, stdout,
			filepath.Join(root, "etc"), filepath.Join(root, "data")); handled {
			return err
		}
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

func TestRunRetriesAnInvalidChecksumSidecarAndFailsClosedWhenBothMirrorsFail(t *testing.T) {
	for _, test := range []struct {
		name              string
		fallbackAvailable bool
		wantError         string
	}{
		{name: "fallback accepts the publisher size limit", fallbackAvailable: true},
		{name: "both mirrors fail", wantError: "release checksum signature is required"},
	} {
		t.Run(test.name, func(t *testing.T) {
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

			var bundleRequests int
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/latest.json":
					fmt.Fprint(w, `{"schema_version":1,"component":"runner","tag":"runner-v0.24.1","version":"0.24.1","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
				case strings.HasSuffix(r.URL.Path, "/"+archiveName):
					_, _ = w.Write(archive)
				case strings.HasSuffix(r.URL.Path, "/SHA256SUMS"):
					fmt.Fprint(w, checksums)
				case strings.HasSuffix(r.URL.Path, "/SHA256SUMS.sigstore.jsonl"):
					bundleRequests++
					if strings.Contains(r.URL.Path, "/releases/download/") {
						if !test.fallbackAvailable {
							http.Error(w, "fallback unavailable", http.StatusServiceUnavailable)
							return
						}
						_, _ = w.Write(bytes.Repeat([]byte{'b'}, int(maxChecksumBundleBytes)))
						return
					}
					// A 200 response that overruns the limit creates a partial file;
					// fallback must remove it before opening the same path again.
					_, _ = w.Write(bytes.Repeat([]byte{'a'}, int(maxChecksumBundleBytes+1)))
				default:
					http.NotFound(w, r)
				}
			}))
			defer server.Close()

			installerCalled := false
			deps := testDependencies(executable)
			deps.releaseBase = server.URL
			deps.apiBase = server.URL
			deps.downloadBase = server.URL
			deps.httpClient = server.Client()
			deps.tempRoot = root
			deps.runCommand = func(_ context.Context, command string, args, _ []string, stdout, _ io.Writer) error {
				if handled, err := handleSafeTargetPreflight(command, args, stdout,
					filepath.Join(root, "etc"), filepath.Join(root, "data")); handled {
					return err
				}
				if command == "/bin/bash" {
					installerCalled = true
				}
				return nil
			}

			var stderr bytes.Buffer
			err := run(context.Background(), Options{
				CurrentVersion: "0.24.0",
				Stderr:         &stderr,
			}, deps)
			if test.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantError) {
					t.Fatalf("error = %v, want %q", err, test.wantError)
				}
				if installerCalled {
					t.Fatal("installer ran without a verified checksum signature")
				}
			} else if err != nil {
				t.Fatalf("run: %v", err)
			} else if !installerCalled {
				t.Fatal("installer did not run after verified sidecar fallback")
			}
			if bundleRequests != 2 {
				t.Fatalf("bundle requests = %d, want primary plus fallback", bundleRequests)
			}
			if !strings.Contains(stderr.String(), "checksum signature unavailable") {
				t.Fatalf("sidecar fallback was not surfaced: %s", stderr.String())
			}
		})
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

func handleSafeTargetPreflight(command string, args []string, stdout io.Writer, etcDir, dataDir string) (bool, error) {
	switch {
	case strings.Join(args, " ") == "auth status":
		return true, nil
	case len(args) > 1 && args[0] == "attestation" && args[1] == "verify":
		return true, nil
	case strings.Join(args, " ") == "state --help":
		_, _ = io.WriteString(stdout, "  check-dispatch-log\n")
		return true, nil
	case command == "/bin/bash" && len(args) == 2 && args[1] == "--managed-update-contract":
		_, _ = io.WriteString(stdout, "emisar-managed-update-v1\n")
		return true, nil
	case strings.Join(args, "\x00") == strings.Join([]string{
		"--config", filepath.Join(etcDir, "config.yaml"),
		"state", "check-dispatch-log", "--data-dir", dataDir,
	}, "\x00"):
		return true, nil
	default:
		return false, nil
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
// the real argv here. --managed-update-contract goes last on purpose:
// install.sh parses flags in order and answers the probe only once every flag
// before it has been accepted, so the answer proves the whole handoff parses
// without installing anything.
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
	args, env := installerInvocation(bundle, "runner-v0.24.1", current, acceptedIdentities("runner-v0.24.1")[0])

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
		probe := append(append([]string(nil), argv...), "--managed-update-contract")
		cmd := exec.Command("/bin/bash", probe...)
		cmd.Env = env
		output, err := cmd.CombinedOutput()
		if err != nil || strings.TrimSpace(string(output)) != "emisar-managed-update-v1" {
			t.Errorf("%s handoff was not parsed by install.sh: err=%v\n%s", name, err, output)
		}
	}
}
