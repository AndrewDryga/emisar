//go:build !windows

package installtest

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
)

// MCP exercises install-mcp.sh, including atomic multi-target activation and
// the interactive direct-CLI and LLM-client configuration flow.
func MCP(root string, out io.Writer) error {
	h, err := newHarness(root, out)
	if err != nil {
		return err
	}
	defer h.close()

	checks := []struct {
		name string
		run  func(*harness) error
	}{
		{"help contract", mcpHelpContract},
		{"portal origin display safety", mcpPortalOrigin},
		{"install directory discovery", mcpInstallDirs},
		{"install confirmation prompt", mcpConfirmPrompt},
		{"interactive connection handoff", mcpInteractiveConnect},
		{"GitHub token argv hygiene", func(h *harness) error { return githubTokenHygiene(h, "install-mcp.sh") }},
		{"signed checksum", mcpChecksumSignature},
		{"download checksum mismatch", mcpDownloadChecksum},
		{"latest release resolution", mcpLatestRelease},
		{"installation and rollback", mcpInstallRollback},
		{"temporary directory privilege boundary", mcpTempDirectoryPrivilegeBoundary},
		{"staging integrity", mcpStagingIntegrity},
		{"atomic multi-target activation", mcpActivationTransaction},
		{"bridge runs as the invoking user", mcpCLISudoCredentialBoundary},
		{"uninstall bridge privilege boundary", mcpUninstallSudoBoundary},
		{"connect and disconnect", mcpConnectCommand},
		{"uninstall", mcpUninstall},
		{"uninstall with an older bridge", mcpUninstallWithAnOlderBridge},
	}
	for _, check := range checks {
		if err := check.run(h); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
	}
	fmt.Fprintln(out, "ok: mcp installer smoke test passed")
	return nil
}

func mcpHelpContract(h *harness) error {
	output, err := requireOutput(h.command(h.root, nil, "bash", h.repoPath("install-mcp.sh"), "--help"))
	if err != nil {
		return err
	}
	for _, want := range []string{"EMISAR_ATTESTATION_WORKFLOW"} {
		if !strings.Contains(string(output), want) {
			return fmt.Errorf("installer help omits %s:\n%s", want, output)
		}
	}
	return nil
}

func mcpPortalOrigin(h *harness) error {
	for _, origin := range []string{
		"https://control.example",
		"http://[::1]:4000",
		"https://[fd00::1234]:4443",
		`https://control.example/";$(touch should-not-exist)`,
	} {
		// No installed bridge or client data: exercise the complete script's
		// validation and display path without installing or connecting anywhere.
		output, err := requireOutput(h.command(h.temp, map[string]string{
			"EMISAR_URL": origin,
			"HOME":       h.path("origin-home"),
		}, "bash", h.repoPath("install-mcp.sh"), "--uninstall", "--yes", "--install-dir", h.path("origin-bin")))
		if err != nil {
			return fmt.Errorf("origin %q: %w", origin, err)
		}
		if !strings.Contains(string(output), origin+"/app/agents") {
			return fmt.Errorf("origin did not reach literal display: %q", output)
		}
	}
	if err := requireAbsent(h.path("should-not-exist")); err != nil {
		return fmt.Errorf("origin was evaluated as shell code: %w", err)
	}
	for _, control := range []byte{'\n', '\r', '\t', '\x1b', '\x7f'} {
		origin := "https://control.example/" + string(control) + "hostile"
		result := h.command(h.temp, map[string]string{"EMISAR_URL": origin},
			"bash", h.repoPath("install-mcp.sh"), "--uninstall", "--yes", "--install-dir", h.path("origin-bin"))
		if err := expectFailure(result, "contain no control characters"); err != nil {
			return fmt.Errorf("control byte %x: %w", control, err)
		}
		if bytes.Contains(result.output, []byte(origin)) {
			return fmt.Errorf("error echoed an unsafe origin: %q", result.output)
		}
	}
	return nil
}

func mcpChecksumSignature(h *harness) error {
	return checksumSignatureContract(h, "install-mcp.sh", "SHA256SUMS-MCP", "mcp-v0.11.0",
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml")
}

func checksumSignatureContract(h *harness, installer, checksums, version, workflow string) error {
	path := h.repoPath(installer)
	trace := h.path(installer + "-checksum-signature-argv")
	bundlePath := trace + ".bundle"
	names := []string{"verify_checksum_attestation"}
	preamble := `
log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
curl() {
  [ "$BUNDLE_DOWNLOAD_FAIL" = "0" ] || return 1
  local output=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o) output="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$output" ] || return 1
  printf 'bundle\n' >"$output"
}
gh() {
  printf '%s' "$1" >>"$TRACE"
  shift
  printf '|%s' "$@" >>"$TRACE"
  printf '\n' >>"$TRACE"
  [ "$VERIFY_FAIL" = "0" ]
}
command() {
  if [ "${1:-}" = "-v" ] && [ "${2:-}" = "gh" ] && [ "$MISSING_GH" = "1" ]; then
    return 1
  fi
  builtin command "$@"
}
REPO=andrewdryga/emisar
VERSION=` + version + `
ATTESTATION_WORKFLOW=` + workflow + `
ATTESTATION_SOURCE_REF=refs/tags/` + version + `
ATTESTATION_DENY_SELF_HOSTED=1
BUNDLE_DOWNLOAD_FAIL=0
MISSING_GH=0
VERIFY_FAIL=0
BUNDLE_PATH="$TRACE.bundle"
`
	invoke := `verify_checksum_attestation /verified/` + checksums + ` https://example.invalid/` + checksums + `.sigstore.jsonl "$BUNDLE_PATH"
`

	success := h.functions(path, names, preamble+invoke, map[string]string{"TRACE": trace})
	output, err := requireOutput(success)
	if err != nil {
		return fmt.Errorf("valid downloaded signature: %w", err)
	}
	if !strings.Contains(string(output), "checksum signature verified") {
		return fmt.Errorf("successful downloaded signature was not surfaced:\n%s", output)
	}
	expectedTrace := "attestation|verify|/verified/" + checksums + "|--bundle|" + bundlePath +
		"|--repo|andrewdryga/emisar|--signer-workflow|" + workflow +
		"|--source-ref|refs/tags/" + version + "|--deny-self-hosted-runners\n"
	if err := exactFile(trace, expectedTrace); err != nil {
		return err
	}

	badSignature := h.functions(path, names, preamble+"VERIFY_FAIL=1\n"+invoke, map[string]string{"TRACE": trace})
	if err := expectFailure(badSignature, "did not verify"); err != nil {
		return fmt.Errorf("bad checksum signature did not fail closed: %w", err)
	}
	missingVerifier := h.functions(path, names, preamble+"MISSING_GH=1\n"+invoke, map[string]string{"TRACE": trace})
	if err := expectFailure(missingVerifier, "GitHub CLI is required"); err != nil {
		return fmt.Errorf("missing verifier did not fail closed: %w", err)
	}
	missingBundle := h.functions(path, names, preamble+"BUNDLE_DOWNLOAD_FAIL=1\n"+invoke, map[string]string{"TRACE": trace})
	if err := expectFailure(missingBundle, "could not download the checksum signature"); err != nil {
		return fmt.Errorf("missing checksum signature did not fail closed: %w", err)
	}
	fork := h.functions(path, names, preamble+"REPO=example/emisar\nATTESTATION_WORKFLOW=\n"+invoke, map[string]string{"TRACE": trace})
	output, err = requireOutput(fork)
	if err != nil {
		return fmt.Errorf("fork checksum policy: %w", err)
	}
	if !strings.Contains(string(output), "operator-selected repository's checksum policy") {
		return fmt.Errorf("fork checksum policy was not surfaced:\n%s", output)
	}
	return nil
}

func mcpLatestRelease(h *harness) error {
	const releases = `[` +
		`{"tag_name":"mcp-v0.11.0","draft":true,"prerelease":false},` +
		`{"tag_name":"mcp-v0.10.1","draft":false,"prerelease":true},` +
		`{"tag_name":"mcp-v0.2.9","draft":false,"prerelease":false},` +
		`{"tag_name":"mcp-v0.10.0","draft":false,"prerelease":false},` +
		`{"tag_name":"runner-v9.9.9","draft":false,"prerelease":false}]`
	const manifest = `{"schema_version":1,"component":"mcp","tag":"mcp-v0.12.0","version":"0.12.0","source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`

	parsed := h.functions(h.repoPath("install-mcp.sh"), []string{"release_manifest_tag"}, `
curl() { printf '%s' "$MANIFEST"; }
release_manifest_tag https://example.invalid/latest.json mcp
`, map[string]string{"MANIFEST": manifest})
	output, err := requireOutput(parsed)
	if err != nil {
		return fmt.Errorf("parse valid mirror manifest: %w", err)
	}
	if got := strings.TrimSpace(string(output)); got != "mcp-v0.12.0" {
		return fmt.Errorf("parsed mirror tag = %q", got)
	}
	malformed := h.functions(h.repoPath("install-mcp.sh"), []string{"release_manifest_tag"}, `
curl() { printf '%s' "$MANIFEST"; }
release_manifest_tag https://example.invalid/latest.json mcp || {
  status=$?
  printf 'invalid manifest status %s\n' "$status" >&2
  exit "$status"
}
`, map[string]string{"MANIFEST": strings.Replace(manifest, `"source_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`, `"source_revision":"not-a-commit"`, 1)})
	if err := expectFailure(malformed, "invalid manifest status 2"); err != nil {
		return fmt.Errorf("malformed mirror manifest did not fail closed: %w", err)
	}

	result := h.functions(h.repoPath("install-mcp.sh"), []string{"resolve_latest_from_github", "resolve_latest_version"}, `
die() { printf '%s\n' "$1" >&2; exit 1; }
warn() { :; }
release_manifest_tag() { printf 'mcp-v0.12.0\n'; }
github_api() { printf 'unexpected GitHub request\n' >&2; exit 9; }
OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
RELEASE_BASE_URL=https://emisar.dev/releases/mcp
resolve_latest_version

REPO=example/emisar
github_api() { printf '%s' "$RELEASES"; }
resolve_latest_version
`, map[string]string{"RELEASES": releases})

	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if got := strings.TrimSpace(string(output)); got != "mcp-v0.12.0\nmcp-v0.10.0" {
		return fmt.Errorf("resolved latest = %q, want mirror then GitHub fallback", got)
	}
	invalid := h.functions(h.repoPath("install-mcp.sh"), []string{"resolve_latest_version"}, `
die() { printf '%s\n' "$1" >&2; exit 1; }
warn() { :; }
release_manifest_tag() { return 2; }
resolve_latest_from_github() { printf 'GitHub fallback must not run\n' >&2; exit 9; }
OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
RELEASE_BASE_URL=https://emisar.dev/releases/mcp
resolve_latest_version
`, nil)
	if err := expectFailure(invalid, "invalid MCP latest.json"); err != nil {
		return fmt.Errorf("invalid mirror manifest did not fail closed: %w", err)
	}
	return nil
}

func mcpInstallDirs(h *harness) error {
	homeBin := h.path("home", ".local", "bin")
	systemBin := h.path("system-bin")
	if err := h.mkdir(homeBin, systemBin); err != nil {
		return err
	}
	for _, path := range []string{filepath.Join(homeBin, "emisar-mcp"), filepath.Join(systemBin, "emisar-mcp")} {
		if err := writeFile(path, "", 0o755); err != nil {
			return err
		}
	}
	result := h.functions(h.repoPath("install-mcp.sh"), []string{"resolve_install_dirs"},
		`resolve_install_dirs "$HOME_DIR" "$SYSTEM_BIN"`+"\n",
		map[string]string{"HOME_DIR": h.path("home"), "SYSTEM_BIN": systemBin})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	expected := homeBin + "\n" + systemBin + "\n"
	if string(output) != expected {
		return fmt.Errorf("resolved directories = %q, expected %q", output, expected)
	}
	return nil
}

// mcpConfirmPrompt proves the install confirmation cannot default to yes:
// with no stdin TTY and no /dev/tty there is nobody who can consent, so
// confirm() must refuse, while --yes/ASSUME_YES still short-circuits to
// accept for intended unattended installs. The harness runs bash in its
// own session, so /dev/tty is unopenable here by construction.
func mcpConfirmPrompt(h *harness) error {
	result := h.functions(h.repoPath("install-mcp.sh"), []string{"confirm"}, `
if confirm "install emisar-mcp?"; then
  printf 'confirm accepted without a TTY\n' >&2
  exit 1
fi
ASSUME_YES=1
confirm "install emisar-mcp?"
`, map[string]string{"ASSUME_YES": "0"})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != "" {
		return fmt.Errorf("confirm was not silent without a TTY: %q", output)
	}
	return nil
}

// mcpInteractiveConnect pins the same yes/no contract at the final connection
// handoff. Every documented affirmative value means unattended and therefore
// must skip the browser flow; a terminal is necessary for every other value.
func mcpInteractiveConnect(h *harness) error {
	result := h.functions(h.repoPath("install-mcp.sh"), []string{"interactive_connect_available"}, `
tty_available() { [ "$TTY_AVAILABLE" = "1" ]; }
TTY_AVAILABLE=1
for value in 1 true yes y on TRUE TrUe YeS Y On; do
  ASSUME_YES="$value"
  if interactive_connect_available; then
    printf 'interactive connect allowed for affirmative value %s\n' "$value" >&2
    exit 1
  fi
done
for value in "" 0 false no off maybe; do
  ASSUME_YES="$value"
  if ! interactive_connect_available; then
    printf 'interactive connect refused for false value %s\n' "$value" >&2
    exit 1
  fi
done
TTY_AVAILABLE=0
ASSUME_YES=0
if interactive_connect_available; then
  printf 'interactive connect allowed without a TTY\n' >&2
  exit 1
fi
`, nil)
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(output)) != "" {
		return fmt.Errorf("interactive connection check was not silent: %q", output)
	}
	return nil
}

func installMCP(h *harness, bin string) (string, error) {
	if err := h.mkdir(bin); err != nil {
		return "", err
	}
	installed, err := h.successful(h.root, map[string]string{"HOME": h.path("home")},
		"bash", h.repoPath("install-mcp.sh"), "--yes", "--install-dir", bin)
	if err != nil {
		return "", err
	}
	if err := requireChecksumVerification(installed); err != nil {
		return "", err
	}
	output, err := h.successful(h.root, nil, filepath.Join(bin, "emisar-mcp"), "--version")
	if err != nil {
		return "", err
	}
	return matchedVersion(mcpVersion, output)
}

func mcpUserConfigDir(home string) string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support")
	}
	return filepath.Join(home, ".config")
}

func mcpInstallRollback(h *harness) error {
	bin := h.path("bin")
	version, err := installMCP(h, bin)
	if err != nil {
		return err
	}
	installedOutput, err := h.successful(h.root, nil, filepath.Join(bin, "emisar-mcp"), "--version")
	if err != nil {
		return err
	}

	for _, flag := range []string{"--version", "--install-dir"} {
		result := h.command(h.root, nil, "bash", h.repoPath("install-mcp.sh"), flag)
		if result.err == nil || exitCode(result.err) != 2 {
			return fmt.Errorf("%s without a value exited %d, expected 2", flag, exitCode(result.err))
		}
		for _, expected := range []string{"flag " + flag + " requires a value", "Usage: install-mcp.sh"} {
			if !strings.Contains(string(result.output), expected) {
				return fmt.Errorf("%s output does not contain %q:\n%s", flag, expected, result.output)
			}
		}
	}
	result := h.command(h.root, nil, "bash", h.repoPath("install-mcp.sh"), "--version", "--yes")
	if result.err == nil || exitCode(result.err) != 2 ||
		!strings.Contains(string(result.output), "flag --version requires a value") {
		return fmt.Errorf("ambiguous --version parsing was accepted:\n%s", result.output)
	}
	credential := filepath.Join(mcpUserConfigDir(h.path("home")), "emisar", "credentials", "rollback-proof.json")
	if err := h.mkdir(filepath.Dir(credential)); err != nil {
		return err
	}
	if err := writeFile(credential, `{"bootstrap":{"api_key":"preserve-me"}}`+"\n", 0o600); err != nil {
		return err
	}
	credentialBefore, err := fileSHA(credential)
	if err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(bin, "emisar-mcp"), `
if [ "${1:-}" = "--version" ]; then
  printf 'emisar-mcp 0.0.0\n'
fi
`); err != nil {
		return err
	}
	realMove, err := exec.LookPath("mv")
	if err != nil {
		return err
	}
	fakeBin := h.path("interrupt-bin")
	if err := h.mkdir(fakeBin); err != nil {
		return err
	}
	if err := fakeExecutable(filepath.Join(fakeBin, "mv"),
		fmt.Sprintf(`%q "$@"`+"\n"+`kill -KILL "$PPID"`, realMove)); err != nil {
		return err
	}
	result = h.command(h.root, map[string]string{
		"HOME": h.path("home"),
		"PATH": fakeBin + string(os.PathListSeparator) + os.Getenv("PATH"),
	}, "bash", h.repoPath("install-mcp.sh"), "--yes",
		"--version", "mcp-v"+version, "--install-dir", bin)
	if result.err == nil {
		return fmt.Errorf("interrupted upgrade unexpectedly succeeded")
	}
	output, err := h.successful(h.root, nil, filepath.Join(bin, "emisar-mcp"), "--version")
	if err != nil {
		return err
	}
	if string(output) != string(installedOutput) {
		return fmt.Errorf("interrupted upgrade left version %q, expected %q", output, installedOutput)
	}
	credentialAfter, err := fileSHA(credential)
	if err != nil {
		return err
	}
	if credentialBefore != credentialAfter {
		return fmt.Errorf("interrupted upgrade changed MCP credentials")
	}
	return nil
}

func mcpStagingIntegrity(h *harness) error {
	bin := h.path("staging-bin")
	version, err := installMCP(h, bin)
	if err != nil {
		return err
	}
	realInstall, err := exec.LookPath("install")
	if err != nil {
		return err
	}
	hostileBin := h.path("hostile-bin")
	target := h.path("hostile-target")
	if err := h.mkdir(hostileBin, target); err != nil {
		return err
	}
	hostileExecuted := h.path("hostile-executed")
	hostile := fmt.Sprintf(`
%q "$@"
destination="${!#}"
cat >"$destination" <<'PAYLOAD'
#!/usr/bin/env bash
touch %q
printf 'emisar-mcp %s\n' %q
PAYLOAD
chmod +x "$destination"
`, realInstall, hostileExecuted, version, version)
	if err := fakeExecutable(filepath.Join(hostileBin, "install"), hostile); err != nil {
		return err
	}
	result := h.command(h.root, map[string]string{
		"HOME": h.path("home"),
		"PATH": hostileBin + string(os.PathListSeparator) + os.Getenv("PATH"),
	}, "bash", h.repoPath("install-mcp.sh"), "--yes",
		"--version", "mcp-v"+version, "--install-dir", target)
	if err := expectFailure(result, "staged binary checksum changed"); err != nil {
		return err
	}
	if err := requireAbsent(hostileExecuted); err != nil {
		return err
	}
	return nil
}

func mcpTempDirectoryPrivilegeBoundary(h *harness) error {
	callerTemp := h.path("user-controlled-tmp")
	if err := h.mkdir(callerTemp); err != nil {
		return err
	}

	cases := []struct {
		name       string
		uid        string
		wantParent string
	}{
		{name: "root", uid: "0", wantParent: "/tmp"},
		{name: "non-root", uid: "1000", wantParent: callerTemp},
	}
	for _, test := range cases {
		result := h.functions(h.repoPath("install-mcp.sh"), []string{"make_temp_dir"}, `
id() {
  [ "${1:-}" = -u ] || return 9
  printf '%s\n' "$FIXTURE_UID"
}
make_temp_dir
`, map[string]string{
			"FIXTURE_UID": test.uid,
			"TMPDIR":      callerTemp,
		})
		output, err := requireOutput(result)
		if err != nil {
			return fmt.Errorf("%s case: %w", test.name, err)
		}
		path := strings.TrimSpace(string(output))
		if filepath.Dir(path) != test.wantParent {
			return fmt.Errorf("%s case: temporary directory parent = %q, want %q", test.name, filepath.Dir(path), test.wantParent)
		}
		if !strings.HasPrefix(filepath.Base(path), "emisar-mcp-install.") {
			return fmt.Errorf("%s case: temporary directory basename = %q", test.name, filepath.Base(path))
		}
		info, err := os.Lstat(path)
		if err != nil {
			return fmt.Errorf("%s case: inspect temporary directory: %w", test.name, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("%s case: temporary path is not a directory: %s", test.name, path)
		}
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("%s case: remove temporary directory: %w", test.name, err)
		}
	}
	return nil
}

func shellSHAFunction() string {
	return `
warn() { printf '%s\n' "$*" >&2; }
sha_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
`
}

func mcpActivationTransaction(h *harness) error {
	installer := h.repoPath("install-mcp.sh")
	names := []string{"rollback_installations", "activate_installations"}

	linkTarget := h.path("link-target")
	linkDir := h.path("link-dir")
	if err := h.mkdir(linkDir); err != nil {
		return err
	}
	if err := writeFile(linkTarget, "linked-old\n", 0o755); err != nil {
		return err
	}
	if err := os.Symlink(linkTarget, filepath.Join(linkDir, "emisar-mcp")); err != nil {
		return err
	}
	result := h.functions(installer, names, shellSHAFunction()+`
printf 'new\n' >"$INSTALL_DIR/.emisar-mcp.new.$$"
source_sha=$(sha_value "$INSTALL_DIR/.emisar-mcp.new.$$")
backup_paths=""
activated_paths=""
installed_paths=""
transaction_active=0
activate_installations
`, map[string]string{
		"INSTALL_DIR": linkDir, "install_dirs": linkDir,
	})
	if err := expectFailure(result, "is not a regular file; refusing to replace it"); err != nil {
		return fmt.Errorf("symlink destination: %w", err)
	}
	info, err := os.Lstat(filepath.Join(linkDir, "emisar-mcp"))
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink == 0 {
		return fmt.Errorf("activation replaced the symlink destination")
	}
	if err := exactFile(linkTarget, "linked-old\n"); err != nil {
		return err
	}

	txA := h.path("tx-a")
	txB := h.path("tx-b")
	if err := h.mkdir(txA, txB); err != nil {
		return err
	}
	for _, entry := range []struct {
		path    string
		content string
	}{
		{filepath.Join(txA, "emisar-mcp"), "old-a\n"},
		{filepath.Join(txB, "emisar-mcp"), "old-b\n"},
	} {
		if err := writeFile(entry.path, entry.content, 0o755); err != nil {
			return err
		}
	}
	realMove, err := exec.LookPath("mv")
	if err != nil {
		return err
	}
	failingBin := h.path("failing-mv")
	if err := h.mkdir(failingBin); err != nil {
		return err
	}
	counter := h.path("mv-count")
	if err := fakeExecutable(filepath.Join(failingBin, "mv"), fmt.Sprintf(`
src="${@: -2:1}"
if [[ "$src" == */.emisar-mcp.new* ]]; then
  count=0
  test ! -e %q || read -r count <%q
  count=$((count + 1))
  printf '%%s\n' "$count" >%q
  if [ "$count" -eq 2 ]; then exit 1; fi
fi
exec %q "$@"
`, counter, counter, counter, realMove)); err != nil {
		return err
	}
	installDirs := txA + "\n" + txB
	result = h.functions(installer, names, shellSHAFunction()+`
while IFS= read -r dir; do
  printf 'new\n' >"$dir/.emisar-mcp.new.$$"
done <<<"$install_dirs"
source_sha=$(sha_value "$TX_A/.emisar-mcp.new.$$")
backup_paths=""
activated_paths=""
installed_paths=""
transaction_active=0
if activate_installations; then
  printf 'activation unexpectedly succeeded\n' >&2
  exit 1
fi
rollback_installations
test "$transaction_active" -eq 0
	`, map[string]string{
		"PATH":         failingBin + string(os.PathListSeparator) + os.Getenv("PATH"),
		"install_dirs": installDirs, "TX_A": txA,
	})
	output, err := requireOutput(result)
	if err != nil {
		return fmt.Errorf("rollback transaction: %w", err)
	}
	if !strings.Contains(string(output), "could not atomically activate "+filepath.Join(txB, "emisar-mcp")) {
		return fmt.Errorf("transaction did not report the second-target failure:\n%s", output)
	}
	if err := exactFile(filepath.Join(txA, "emisar-mcp"), "old-a\n"); err != nil {
		return err
	}
	if err := exactFile(filepath.Join(txB, "emisar-mcp"), "old-b\n"); err != nil {
		return err
	}

	for _, dir := range []string{txA, txB} {
		matches, err := filepath.Glob(filepath.Join(dir, ".emisar-mcp.old.*"))
		if err != nil {
			return err
		}
		for _, path := range matches {
			if err := os.Remove(path); err != nil {
				return err
			}
		}
	}
	result = h.functions(installer, names, shellSHAFunction()+`
while IFS= read -r dir; do
  printf 'new\n' >"$dir/.emisar-mcp.new.$$"
done <<<"$install_dirs"
source_sha=$(sha_value "$TX_A/.emisar-mcp.new.$$")
backup_paths=""
activated_paths=""
installed_paths=""
transaction_active=0
activate_installations
printf 'INSTALLED=%s\n' "$installed_paths"
`, map[string]string{
		"install_dirs": installDirs, "TX_A": txA,
	})
	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	for _, dir := range []string{txA, txB} {
		if err := exactFile(filepath.Join(dir, "emisar-mcp"), "new\n"); err != nil {
			return err
		}
		matches, err := filepath.Glob(filepath.Join(dir, ".emisar-mcp.old.*"))
		if err != nil {
			return err
		}
		if len(matches) != 0 {
			return fmt.Errorf("successful activation left backups in %s", dir)
		}
	}
	expectedInstalled := filepath.Join(txA, "emisar-mcp") + "\n" + filepath.Join(txB, "emisar-mcp")
	if !strings.Contains(string(output), "INSTALLED="+expectedInstalled) {
		return fmt.Errorf("installed paths = %q, expected %q", output, expectedInstalled)
	}
	return nil
}

func mcpCLISudoCredentialBoundary(h *harness) error {
	bin := h.path("sudo-boundary-emisar-mcp")
	trace := h.path("sudo-boundary-trace")
	sudoTrace := h.path("sudo-boundary-argv")
	invokingHome := h.path("sudo-boundary-home")
	if err := h.mkdir(invokingHome); err != nil {
		return err
	}
	if err := writeFile(bin, `#!/bin/sh
set -eu
IFS= read -r key
case "$*" in *"${key}"*) exit 91;; esac
if env | grep -Fq "${key}"; then exit 92; fi
printf 'HOME=%s\nARGS=%s\nKEY=%s\n' "$HOME" "$*" "$key" >"$CLI_TRACE"
`, 0o755); err != nil {
		return err
	}

	result := h.functions(h.repoPath("install-mcp.sh"), []string{"run_cli_as_invoking_user"}, `
id() {
  [ "${1:-}" = -u ] || return 9
  printf '0\n'
}

sudo() {
  printf '%s\n' "$@" >"$SUDO_TRACE"
  [ "$1" = -H ] && [ "$2" = -u ] && [ "$3" = "$SUDO_USER" ] || return 9
  shift 3
  HOME="$INVOKING_HOME" "$@"
}
first_bin="$CLI_BIN"
secret='emk-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq'
printf '%s\n' "$secret" | run_cli_as_invoking_user auth status https://control.example
`, map[string]string{
		"CLI_BIN":       bin,
		"CLI_TRACE":     trace,
		"SUDO_TRACE":    sudoTrace,
		"SUDO_USER":     "alice",
		"INVOKING_HOME": invokingHome,
	})
	if _, err := requireOutput(result); err != nil {
		return err
	}
	if err := exactFile(sudoTrace, strings.Join([]string{
		"-H", "-u", "alice", bin, "auth", "status", "https://control.example", "",
	}, "\n")); err != nil {
		return err
	}
	return exactFile(trace, "HOME="+invokingHome+"\nARGS=auth status https://control.example\nKEY=emk-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq\n")
}

func mcpUninstallSudoBoundary(h *harness) error {
	dir := h.path("uninstall-sudo-bin")
	trace := h.path("uninstall-sudo-trace")
	if err := h.mkdir(dir); err != nil {
		return err
	}
	bin := filepath.Join(dir, "emisar-mcp")
	if err := writeFile(bin, `#!/bin/sh
printf '%s|%s\n' "$TEST_EFFECTIVE_USER" "$*" >>"$CLI_TRACE"
`, 0o755); err != nil {
		return err
	}

	result := h.functions(h.repoPath("install-mcp.sh"),
		[]string{"installed_bridge", "run_cli_as_invoking_user", "do_uninstall"}, `
id() { printf '0\n'; }
sudo() {
  [ "$1" = -H ] && [ "$2" = -u ] && [ "$3" = alice ] || return 9
  shift 3
  TEST_EFFECTIVE_USER=alice "$@"
}
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf '%s\n' "$*" >&2; exit 1; }
confirm() { return 0; }
OS=linux
ARCH=amd64
EMISAR_URL=https://control.example
install_dirs="$INSTALL_DIR"
do_uninstall
`, map[string]string{
			"INSTALL_DIR":         dir,
			"CLI_TRACE":           trace,
			"SUDO_USER":           "alice",
			"TEST_EFFECTIVE_USER": "root",
		})
	if _, err := requireOutput(result); err != nil {
		return err
	}
	if err := exactFile(trace, "alice|disconnect --help\nalice|disconnect --all --forget --yes\n"); err != nil {
		return err
	}
	return requireAbsent(bin)
}

// buildBridge compiles the bridge from THIS checkout into dir. The connect and
// uninstall paths run the binary that ships beside the script under test, not
// whatever the release mirror currently serves.
func buildBridge(h *harness, dir string) (string, error) {
	bridge := filepath.Join(dir, "emisar-mcp")
	build := exec.Command("go", "build", "-trimpath", "-o", bridge, ".")
	build.Dir = filepath.Join(h.root, "mcp")
	build.Env = environment(map[string]string{"GOTOOLCHAIN": "local", "CGO_ENABLED": "0"})
	if output, err := build.CombinedOutput(); err != nil {
		return "", fmt.Errorf("build the bridge under test: %w\n%s", err, output)
	}
	return bridge, nil
}

// mcpConnectCommand drives the shipped binary end to end against a fake
// device-authorization portal: one approval covering the direct CLI and every
// detected client, each client's own configuration shape written on a real
// filesystem, then a clean removal. The per-client shapes themselves are
// table-tested in mcp/clientconfig_test.go; what only this harness can prove is
// that the INSTALLED binary does it, under a real HOME, with real file modes.
func mcpConnectCommand(h *harness) error {
	bin := h.path("connect-bin")
	if err := h.mkdir(bin); err != nil {
		return err
	}
	bridge, err := buildBridge(h, bin)
	if err != nil {
		return err
	}
	home := h.path("connect-home")
	appConfig := mcpUserConfigDir(home)
	// One marker directory per client, which is how the bridge decides a client
	// is installed. Every advertised client is present, so a client dropped from
	// the table stops being connected here.
	markers := []string{
		filepath.Join(home, ".claude"),
		filepath.Join(appConfig, "Claude"),
		filepath.Join(home, ".cursor"),
		filepath.Join(appConfig, "Code"),
		filepath.Join(home, ".gemini"),
		filepath.Join(home, ".codex"),
		filepath.Join(home, ".openclaw"),
		filepath.Join(home, ".config", "opencode"),
		filepath.Join(home, ".codeium", "windsurf"),
		filepath.Join(home, ".pi"),
		filepath.Join(home, ".copilot"),
		filepath.Join(home, ".config", "zed"),
		filepath.Join(home, ".hermes"),
		filepath.Join(home, ".config", "goose"),
		filepath.Join(home, ".grok"),
	}
	if err := h.mkdir(markers...); err != nil {
		return err
	}
	// One client already carries an unrelated server: connecting must not
	// disturb it, and the file must stay valid JSON.
	cursorConfig := filepath.Join(home, ".cursor", "mcp.json")
	if err := writeFile(cursorConfig, "{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"other-mcp\"}\n  }\n}\n", 0o600); err != nil {
		return err
	}

	server := newDeviceServer("")
	defer server.close()
	environment := map[string]string{"HOME": home, "USERPROFILE": home, "APPDATA": appConfig}
	if _, err := h.successful(h.root, environment, bridge,
		"connect", "--all", "--url", server.server.URL); err != nil {
		return err
	}

	requested := server.requestedClients()
	if !slices.Contains(requested, "emisar-mcp-cli") {
		return fmt.Errorf("the direct CLI was not part of the approval: %v", requested)
	}
	for _, client := range []string{"claude-code", "cursor", "vscode", "codex", "zed", "goose", "grok"} {
		if !slices.Contains(requested, client) {
			return fmt.Errorf("%s was not part of the approval: %v", client, requested)
		}
	}

	cursor, err := jsonFile(cursorConfig)
	if err != nil {
		return err
	}
	if err := requireNestedString(cursor, "other-mcp", "mcpServers", "other", "command"); err != nil {
		return fmt.Errorf("connect disturbed an unrelated server: %w", err)
	}
	if err := requireNestedString(cursor, fixtureAPIKey("cursor"), "mcpServers", "emisar", "env", "EMISAR_API_KEY"); err != nil {
		return err
	}
	if err := requireNestedString(cursor, bridge, "mcpServers", "emisar", "command"); err != nil {
		return fmt.Errorf("the config does not point at the installed binary: %w", err)
	}

	// VS Code can sync its user config, so its key belongs beside the bridge's
	// own credential state instead.
	vscodeConfig := filepath.Join(appConfig, "Code", "User", "mcp.json")
	raw, err := os.ReadFile(vscodeConfig)
	if err != nil {
		return err
	}
	if strings.Contains(string(raw), fixtureAPIKey("vscode")) {
		return fmt.Errorf("the VS Code key reached a config it may sync:\n%s", raw)
	}
	envFile := filepath.Join(appConfig, "emisar", "credentials", "vscode.env")
	envContents, err := os.ReadFile(envFile)
	if err != nil {
		return err
	}
	if !strings.Contains(string(envContents), "EMISAR_API_KEY="+fixtureAPIKey("vscode")) {
		return fmt.Errorf("the VS Code env file has no key:\n%s", envContents)
	}
	if err := requirePrivateMode(envFile); err != nil {
		return err
	}

	// The direct CLI credential landed in the bridge's own owner-only state.
	credentials := filepath.Join(appConfig, "emisar", "credentials")
	entries, err := os.ReadDir(credentials)
	if err != nil {
		return err
	}
	if len(entries) < 2 {
		return fmt.Errorf("expected a stored CLI credential beside the env file, found %d entries", len(entries))
	}

	if _, err := h.successful(h.root, environment, bridge, "disconnect", "--all", "--forget", "--yes"); err != nil {
		return err
	}
	after, err := jsonFile(cursorConfig)
	if err != nil {
		return err
	}
	if _, err := nested(after, "mcpServers", "emisar"); err == nil {
		return fmt.Errorf("the emisar entry survived disconnect")
	}
	if err := requireNestedString(after, "other-mcp", "mcpServers", "other", "command"); err != nil {
		return fmt.Errorf("disconnect disturbed an unrelated server: %w", err)
	}
	if err := requireAbsent(credentials); err != nil {
		return fmt.Errorf("--forget left stored credentials behind: %w", err)
	}
	return requireAbsent(cursorConfig + ".emisar-bak")
}

// mcpUninstallWithAnOlderBridge covers real version skew: the script is always
// fetched fresh, while the installed binary is whatever the operator has. A
// bridge with no `disconnect` verb cannot clean the client configs, so the
// uninstall must SAY the entries were left behind rather than report success.
func mcpUninstallWithAnOlderBridge(h *harness) error {
	home := h.path("skew-home")
	bin := h.path("skew-bin")
	cursor := filepath.Join(home, ".cursor", "mcp.json")
	if err := h.mkdir(bin, filepath.Dir(cursor)); err != nil {
		return err
	}
	entry := "{\n  \"mcpServers\": {\n    \"emisar\": {\"command\": \"/usr/local/bin/emisar-mcp\"}\n  }\n}\n"
	if err := writeFile(cursor, entry, 0o600); err != nil {
		return err
	}
	// A bridge from before the verb existed: every unknown command is a usage error.
	if err := writeFile(filepath.Join(bin, "emisar-mcp"), "#!/bin/sh\nexit 2\n", 0o755); err != nil {
		return err
	}

	result := h.command(h.root, map[string]string{
		"HOME":            home,
		"XDG_CONFIG_HOME": filepath.Join(home, ".config"),
	}, "bash", h.repoPath("install-mcp.sh"), "--uninstall", "--yes", "--install-dir", bin)
	if result.err != nil {
		return fmt.Errorf("uninstall failed outright: %w\n%s", result.err, result.output)
	}
	if !strings.Contains(string(result.output), "older than this script") {
		return fmt.Errorf("the skew was not reported:\n%s", result.output)
	}
	if err := requireAbsent(filepath.Join(bin, "emisar-mcp")); err != nil {
		return fmt.Errorf("the binary was not removed: %w", err)
	}
	// The entry is still there — which is exactly what the warning said.
	config, err := jsonFile(cursor)
	if err != nil {
		return err
	}
	if _, err := nested(config, "mcpServers", "emisar"); err != nil {
		return fmt.Errorf("the entry was removed by something that cannot do it: %w", err)
	}
	return nil
}

func mcpUninstall(h *harness) error {
	home := h.path("uninstall-home")
	bin := h.path("uninstall-bin")
	// The bridge stores the CLI credential and rotation state under Go's
	// os.UserConfigDir (mcp/rotate.go), which ignores XDG on darwin — the fixture must live
	// where the script's darwin branch actually looks, or the removal is
	// only ever tested on Linux.
	credentials := filepath.Join(mcpUserConfigDir(home), "emisar", "credentials")
	vscodeConfig := filepath.Join(home, ".config", "Code", "User", "mcp.json")
	if runtime.GOOS == "darwin" {
		vscodeConfig = filepath.Join(home, "Library", "Application Support", "Code", "User", "mcp.json")
	}
	if err := h.mkdir(bin, credentials, filepath.Dir(vscodeConfig),
		filepath.Join(home, ".cursor"), filepath.Join(home, ".codex"),
		filepath.Join(home, ".config", "zed"), filepath.Join(home, ".hermes"),
		filepath.Join(home, ".config", "goose"), filepath.Join(home, ".grok")); err != nil {
		return err
	}
	files := map[string]string{
		".cursor/mcp.json": `{
  "mcpServers": {
    "other": { "command": "other-mcp" },
    "emisar": { "command": "/usr/local/bin/emisar-mcp", "env": { "EMISAR_API_KEY": "emk-cur" } }
  }
}
`,
		".cursor/mcp.json.emisar-bak": "{}\n",
		".codex/config.toml": "[model]\nname = \"gpt\"\n\n[mcp_servers.emisar]\n" +
			"command = \"/usr/local/bin/emisar-mcp\"\n" +
			"env = { EMISAR_URL = \"https://emisar.dev\", EMISAR_API_KEY = \"emk-cod\", EMISAR_CLIENT = \"codex\" }\n",
		".grok/config.toml": "[mcp_servers.emisar]\n" +
			"command = \"/usr/local/bin/emisar-mcp\"\n" +
			"enabled = true\n\n[mcp_servers.emisar.env]\n" +
			"EMISAR_URL = \"https://emisar.dev\"\nEMISAR_API_KEY = \"emk-grok\"\n" +
			"EMISAR_CLIENT = \"grok\"\n\n[permission]\nallow = [\"MCPTool(other__*)\"]\n",
		".config/zed/settings.json": `{
  // my editor
  "theme": "One Dark",
  "context_servers": {
    "emisar": {
      "source": "custom",
      "command": "/usr/local/bin/emisar-mcp",
      "env": { "EMISAR_API_KEY": "emk-zed" }
    },
    "other": { "source": "custom", "command": "other-mcp" },
  },
}
`,
		".hermes/config.yaml": "model: hermes-4\n\nmcp_servers:\n  emisar:\n" +
			"    command: /usr/local/bin/emisar-mcp\n    env:\n      EMISAR_API_KEY: \"emk-her\"\n",
		".config/goose/config.yaml": "extensions:\n  developer:\n    enabled: true\n" +
			"  emisar:\n    name: emisar\n    cmd: /usr/local/bin/emisar-mcp\n    enabled: true\n    type: stdio\n",
	}
	for relative, contents := range files {
		if err := writeFile(filepath.Join(home, filepath.FromSlash(relative)), contents, 0o600); err != nil {
			return err
		}
	}
	vscodeContents := `{
  // synced editor config
  "inputs": [],
  "servers": {
    "emisar": {
      "type": "stdio",
      "command": "/usr/local/bin/emisar-mcp",
      "args": [],
      "envFile": "/home/operator/.config/emisar/credentials/vscode.env"
    },
    "other": { "type": "stdio", "command": "other-mcp" },
  },
}
`
	if err := writeFile(vscodeConfig, vscodeContents, 0o600); err != nil {
		return err
	}
	if err := writeFile(vscodeConfig+".emisar-bak", "{}\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(credentials, "state.json"), "{}\n", 0o600); err != nil {
		return err
	}
	if _, err := buildBridge(h, bin); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(bin, ".emisar-mcp.old.123"), "stale\n", 0o644); err != nil {
		return err
	}

	environment := map[string]string{
		"HOME":            home,
		"XDG_CONFIG_HOME": filepath.Join(home, ".config"),
	}
	if _, err := h.successful(h.root, environment,
		"bash", h.repoPath("install-mcp.sh"), "--uninstall", "--yes", "--install-dir", bin); err != nil {
		return err
	}

	for _, path := range []string{
		filepath.Join(bin, "emisar-mcp"),
		filepath.Join(bin, ".emisar-mcp.old.123"),
		filepath.Join(home, ".cursor", "mcp.json.emisar-bak"),
		vscodeConfig + ".emisar-bak",
		credentials,
	} {
		if err := requireAbsent(path); err != nil {
			return err
		}
	}

	cursor, err := jsonFile(filepath.Join(home, ".cursor", "mcp.json"))
	if err != nil {
		return err
	}
	if err := requireNestedString(cursor, "other-mcp", "mcpServers", "other", "command"); err != nil {
		return err
	}
	if _, err := nested(cursor, "mcpServers", "emisar"); err == nil {
		return fmt.Errorf("cursor config still carries emisar")
	}

	for _, text := range []string{"// synced editor config", `"inputs": []`, `"other"`} {
		if err := containsFile(vscodeConfig, text); err != nil {
			return err
		}
	}
	if err := lacksFile(vscodeConfig, `"emisar"`); err != nil {
		return err
	}

	codex := filepath.Join(home, ".codex", "config.toml")
	if err := containsFile(codex, `name = "gpt"`); err != nil {
		return err
	}
	if err := lacksFile(codex, "mcp_servers.emisar"); err != nil {
		return err
	}

	grok := filepath.Join(home, ".grok", "config.toml")
	for _, text := range []string{`[permission]`, `allow = ["MCPTool(other__*)"]`} {
		if err := containsFile(grok, text); err != nil {
			return err
		}
	}
	if err := lacksFile(grok, "mcp_servers.emisar"); err != nil {
		return err
	}

	zed := filepath.Join(home, ".config", "zed", "settings.json")
	for _, text := range []string{"// my editor", `"theme": "One Dark"`, `"other"`} {
		if err := containsFile(zed, text); err != nil {
			return err
		}
	}
	if err := lacksFile(zed, `"emisar"`); err != nil {
		return err
	}

	hermes := filepath.Join(home, ".hermes", "config.yaml")
	if err := containsFile(hermes, "model: hermes-4"); err != nil {
		return err
	}
	// The emptied mcp_servers key goes too, so a later install can append again.
	for _, text := range []string{"emisar", "mcp_servers:"} {
		if err := lacksFile(hermes, text); err != nil {
			return err
		}
	}

	goose := filepath.Join(home, ".config", "goose", "config.yaml")
	for _, text := range []string{"extensions:", "developer:"} {
		if err := containsFile(goose, text); err != nil {
			return err
		}
	}
	if err := lacksFile(goose, "emisar"); err != nil {
		return err
	}

	// A second run has nothing left to remove and still succeeds.
	if _, err := h.successful(h.root, environment,
		"bash", h.repoPath("install-mcp.sh"), "--uninstall", "--yes", "--install-dir", bin); err != nil {
		return err
	}
	return nil
}

// Same reasoning as the runner lane: without `gh` the attestation degrades to a
// warning, so this comparison is the only control between a tampered download
// and execution — and no case drove it. Exercises the installer's own
// verify_release_checksum, with a matching-sums control so the refusal cannot
// pass for an unrelated reason.
func mcpDownloadChecksum(h *harness) error {
	const wrongDigest = "0000000000000000000000000000000000000000000000000000000000000000"
	preamble := `
die() { printf '%s\n' "$*" >&2; exit 1; }
tarball=emisar-mcp-9.9.9-linux-amd64.tar.gz
tmp="$(mktemp -d)"
printf 'payload\n' >"${tmp}/${tarball}"
digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
`
	names := []string{"verify_release_checksum"}

	tampered := h.functions(h.repoPath("install-mcp.sh"), names, preamble+`
printf '%s  %s\n' "`+wrongDigest+`" "$tarball" >"${tmp}/SHA256SUMS-MCP"
verify_release_checksum "$tmp" "$tarball"
printf 'CONTINUED\n' >&2
`, nil)
	if err := expectFailure(tampered, "checksum verification failed"); err != nil {
		return fmt.Errorf("a tampered tarball was not refused: %w", err)
	}
	if bytes.Contains(tampered.output, []byte("CONTINUED")) {
		return fmt.Errorf("install continued past the checksum mismatch:\n%s", tampered.output)
	}

	missing := h.functions(h.repoPath("install-mcp.sh"), names, preamble+`
printf '%s  %s\n' "`+wrongDigest+`" "emisar-mcp-9.9.9-linux-arm64.tar.gz" >"${tmp}/SHA256SUMS-MCP"
verify_release_checksum "$tmp" "$tarball"
printf 'CONTINUED\n' >&2
`, nil)
	if err := expectFailure(missing, "checksum manifest does not list emisar-mcp-9.9.9-linux-amd64.tar.gz"); err != nil {
		return fmt.Errorf("a manifest missing the selected tarball was not refused: %w", err)
	}
	if bytes.Contains(missing.output, []byte("CONTINUED")) {
		return fmt.Errorf("install continued past the missing checksum entry:\n%s", missing.output)
	}

	honest := h.functions(h.repoPath("install-mcp.sh"), names, preamble+`
printf '%s  %s\n' "$(digest_of "${tmp}/${tarball}")" "$tarball" >"${tmp}/SHA256SUMS-MCP"
verify_release_checksum "$tmp" "$tarball"
printf 'CONTINUED\n' >&2
`, nil)
	output, err := requireOutput(honest)
	if err != nil {
		return fmt.Errorf("a matching checksum was refused: %w", err)
	}
	if !bytes.Contains(output, []byte("CONTINUED")) {
		return fmt.Errorf("the verified path did not continue:\n%s", output)
	}
	return nil
}
