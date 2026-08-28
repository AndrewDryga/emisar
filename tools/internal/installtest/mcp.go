//go:build !windows

package installtest

import (
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
		{"install directory discovery", mcpInstallDirs},
		{"install confirmation prompt", mcpConfirmPrompt},
		{"GitHub token argv hygiene", func(h *harness) error { return githubTokenHygiene(h, "install-mcp.sh") }},
		{"attestation release epochs", mcpAttestationReleaseEpochs},
		{"latest release resolution", mcpLatestRelease},
		{"installation and rollback", mcpInstallRollback},
		{"staging integrity", mcpStagingIntegrity},
		{"atomic multi-target activation", mcpActivationTransaction},
		{"bridge runs as the invoking user", mcpCLISudoCredentialBoundary},
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

func mcpAttestationReleaseEpochs(h *harness) error {
	trace := h.path("mcp-attestation-argv")
	result := h.functions(h.repoPath("install-mcp.sh"), []string{"select_attestation_policy", "verify_attestation"}, `
log() { :; }
warn() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
gh() {
  if [ "${1:-}" = "auth" ]; then
    return 0
  fi
  printf '%s' "$1" >>"$TRACE"
  shift
  printf '|%s' "$@" >>"$TRACE"
  printf '\n' >>"$TRACE"
}

OFFICIAL_REPO=andrewdryga/emisar
REPO=$OFFICIAL_REPO
for VERSION in mcp-v0.10.1 mcp-v0.10.2 mcp-v0.9.99; do
  ATTESTATION_WORKFLOW=
  select_attestation_policy
  printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"
done
REPO=example/emisar
VERSION=mcp-v0.10.1
ATTESTATION_WORKFLOW=
select_attestation_policy
printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"

VERSION=mcp-v0.10.1
ATTESTATION_WORKFLOW=example/emisar/.github/workflows/release.yml
select_attestation_policy
printf '%s|%s|%s|%s\n' "$ATTESTATION_WORKFLOW" "$ATTESTATION_SIGNER_DIGEST" "$ATTESTATION_SOURCE_REF" "$ATTESTATION_DENY_SELF_HOSTED"

REPO=$OFFICIAL_REPO
for VERSION in mcp-v0.10.1 mcp-v0.10.2; do
  ATTESTATION_WORKFLOW=
  select_attestation_policy
  verify_attestation /verified/mcp.tar.gz mcp.tar.gz
done
REPO=example/emisar
VERSION=mcp-v0.10.1
ATTESTATION_WORKFLOW=example/emisar/.github/workflows/release.yml
select_attestation_policy
verify_attestation /verified/mcp.tar.gz mcp.tar.gz
`, map[string]string{"TRACE": trace})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	const expected = "AndrewDryga/emisar/.github/workflows/mcp-release.yml|642128eb48205405fd44ce845118e6a68737eea2|refs/tags/mcp-v0.10.1|1\n" +
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml||refs/tags/mcp-v0.10.2|1\n" +
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml||refs/tags/mcp-v0.9.99|1\n" +
		"|||0\n" +
		"example/emisar/.github/workflows/release.yml|||0\n"
	if string(output) != expected {
		return fmt.Errorf("attestation policies = %q, want %q", output, expected)
	}
	const expectedTrace = "attestation|verify|/verified/mcp.tar.gz|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/mcp-release.yml|--source-ref|refs/tags/mcp-v0.10.1|--signer-digest|642128eb48205405fd44ce845118e6a68737eea2|--deny-self-hosted-runners\n" +
		"attestation|verify|/verified/mcp.tar.gz|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml|--source-ref|refs/tags/mcp-v0.10.2|--deny-self-hosted-runners\n" +
		"attestation|verify|/verified/mcp.tar.gz|--repo|example/emisar|--signer-workflow|example/emisar/.github/workflows/release.yml\n"
	return exactFile(trace, expectedTrace)
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

func installMCP(h *harness, bin string) (string, error) {
	if err := h.mkdir(bin); err != nil {
		return "", err
	}
	installed, err := h.successful(h.root, map[string]string{"HOME": h.path("home")},
		"bash", h.repoPath("install-mcp.sh"), "--yes", "--install-dir", bin)
	if err != nil {
		return "", err
	}
	if err := h.requireAttestationOutcome(map[string]string{"HOME": h.path("home")}, installed); err != nil {
		return "", err
	}
	output, err := h.successful(h.root, nil, filepath.Join(bin, "emisar-mcp"), "--version")
	if err != nil {
		return "", err
	}
	return matchedVersion(mcpVersion, output)
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
	credential := h.path("home", ".config", "emisar", "mcp-credentials.json")
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

	if os.Geteuid() == 0 {
		userTemp := h.path("user-controlled-tmp")
		if err := h.mkdir(userTemp); err != nil {
			return err
		}
		result = h.functions(h.repoPath("install-mcp.sh"), []string{"make_temp_dir"},
			`make_temp_dir`+"\n", map[string]string{"TMPDIR": userTemp})
		output, err := requireOutput(result)
		if err != nil {
			return err
		}
		trusted := strings.TrimSpace(string(output))
		defer os.RemoveAll(trusted)
		if !strings.HasPrefix(trusted, "/tmp/emisar-mcp-install.") {
			return fmt.Errorf("privileged temp directory is %s, expected /tmp", trusted)
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
	appConfig := filepath.Join(home, ".config")
	if runtime.GOOS == "darwin" {
		appConfig = filepath.Join(home, "Library", "Application Support")
	}
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
	credentials := filepath.Join(home, ".config", "emisar", "credentials")
	vscodeConfig := filepath.Join(home, ".config", "Code", "User", "mcp.json")
	if runtime.GOOS == "darwin" {
		credentials = filepath.Join(home, "Library", "Application Support", "emisar", "credentials")
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
