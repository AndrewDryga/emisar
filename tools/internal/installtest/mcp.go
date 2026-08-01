package installtest

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// MCP exercises install-mcp.sh, including atomic multi-target activation and
// the interactive LLM-client configuration flow.
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
		{"installation and rollback", mcpInstallRollback},
		{"staging integrity", mcpStagingIntegrity},
		{"atomic multi-target activation", mcpActivationTransaction},
		{"device grant response validation", mcpDeviceGrantValidation},
		{"LLM client configuration", mcpClientConfiguration},
		{"uninstall", mcpUninstall},
	}
	for _, check := range checks {
		if err := check.run(h); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
	}
	fmt.Fprintln(out, "ok: mcp installer smoke test passed")
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
	if _, err := h.successful(h.root, map[string]string{"HOME": h.path("home")},
		"bash", h.repoPath("install-mcp.sh"), "--yes", "--install-dir", bin); err != nil {
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

var clientFunctions = []string{
	"tty_available", "ask_tty", "json_config_has_emisar",
	"toml_config_has_emisar", "yaml_config_has_emisar", "file_has_content",
	"write_fresh_json_config", "merge_json_config", "append_codex_toml",
	"append_yaml_config", "own_config_file", "install_client_config",
	"json_string_field", "json_client_key", "json_has_client_keys",
	"bounded_decimal_field", "request_device_grant",
	"await_device_approval", "scan_client", "scan_llm_clients", "out", "hdr",
	"ok", "dim", "client_row", "open_browser", "configure_llm_clients",
}

func clientOverrides(extra string) string {
	return `
log() { :; }
warn() { printf '%s\n' "$*" >&2; }
tty_available() { return 0; }
ask_tty() { return 0; }
sleep() { :; }
out() { :; }
ok() { :; }
dim() { :; }
client_row() { :; }
hdr() { :; }
open_browser() { return 1; }
` + extra
}

func clientEnvironment(home, portal string, assumeYes bool) map[string]string {
	yes := "0"
	if assumeYes {
		yes = "1"
	}
	return map[string]string{
		"CLIENT_HOME": home, "EMISAR_URL": portal, "ASSUME_YES": yes,
		"OS": "linux", "first_bin": "/usr/local/bin/emisar-mcp",
		"tmp": home, "DEVICE_RESP": filepath.Join(home, "device-authorization.json"),
		"TOKEN_RESP": filepath.Join(home, "device-token.json"),
	}
}

func runClientFlow(h *harness, home, portal string, assumeYes bool, overrides string) commandResult {
	body := clientOverrides(overrides) + `
CONFIGURED_CLIENTS=""
clients_phase_ran=0
CLIENTS_FOUND=0
SCANNED=""
CONSENTED=""
DEVICE_CODE=""
DEVICE_USER_CODE=""
DEVICE_VERIFY_URI=""
DEVICE_INTERVAL=5
DEVICE_EXPIRES_IN=900
configure_llm_clients "$CLIENT_HOME"
printf '\nCONFIGURED_BEGIN\n%s\nCONFIGURED_END\n' "$CONFIGURED_CLIENTS"
`
	return h.functions(h.repoPath("install-mcp.sh"), clientFunctions, body,
		clientEnvironment(home, portal, assumeYes))
}

func configuredClients(output string) string {
	start := strings.Index(output, "CONFIGURED_BEGIN\n")
	end := strings.Index(output, "\nCONFIGURED_END")
	if start < 0 || end < start {
		return ""
	}
	return strings.TrimSpace(output[start+len("CONFIGURED_BEGIN\n") : end])
}

// mcpDeviceGrantValidation proves the device-grant response's interval and
// expires_in cannot reach bash arithmetic or sleep unvalidated: an
// expression-shaped value from the portal response falls back to the 5/900
// defaults without executing its payload, and every out-of-shape or
// out-of-bounds value falls back the same way.
func mcpDeviceGrantValidation(h *harness) error {
	home := h.path("grant-home")
	if err := h.mkdir(home); err != nil {
		return err
	}
	marker := h.path("grant-arith-marker")
	payload := fmt.Sprintf("x[$(touch %s)]", marker)
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/mcp/device_authorization" {
			http.NotFound(response, request)
			return
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(response, fmt.Sprintf(
			`{"device_code":"emdg-hostile","user_code":"HHHH-0000",`+
				`"verification_uri":"%s/activate","verification_uri_complete":"%s/activate?code=HHHH-0000",`+
				`"expires_in":%q,"interval":%q}`, server.URL, server.URL, payload, payload))
	}))
	defer server.Close()

	result := h.functions(h.repoPath("install-mcp.sh"),
		[]string{"json_string_field", "bounded_decimal_field", "request_device_grant"}, `
DEVICE_RESP="$CLIENT_HOME/device-authorization.json"
DEVICE_CODE=""
DEVICE_USER_CODE=""
DEVICE_VERIFY_URI=""
DEVICE_INTERVAL=5
DEVICE_EXPIRES_IN=900
request_device_grant "claude-code"
printf 'INTERVAL=%s EXPIRES=%s\n' "$DEVICE_INTERVAL" "$DEVICE_EXPIRES_IN"
deadline=$(($(date +%s) + DEVICE_EXPIRES_IN))
test "$deadline" -gt "$(date +%s)"

test "$(bounded_decimal_field 7 1 120 5)" = 7
test "$(bounded_decimal_field 007 1 120 5)" = 7
test "$(bounded_decimal_field 0 1 120 5)" = 5
test "$(bounded_decimal_field 121 1 120 5)" = 5
test "$(bounded_decimal_field 3600 60 3600 900)" = 3600
test "$(bounded_decimal_field 59 60 3600 900)" = 900
test "$(bounded_decimal_field 18446744073709551616 60 3600 900)" = 900
test "$(bounded_decimal_field '' 60 3600 900)" = 900
test "$(bounded_decimal_field '5.5' 1 120 5)" = 5
test "$(bounded_decimal_field '-5' 1 120 5)" = 5
test "$(bounded_decimal_field '1 -a -x /bin/sh' 1 120 5)" = 5
`, map[string]string{"CLIENT_HOME": home, "EMISAR_URL": server.URL})
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if !strings.Contains(string(output), "INTERVAL=5 EXPIRES=900") {
		return fmt.Errorf("hostile grant fields were not replaced by defaults:\n%s", output)
	}
	if err := requireAbsent(marker); err != nil {
		return fmt.Errorf("arithmetic payload executed: %w", err)
	}
	return nil
}

func mcpClientConfiguration(h *harness) error {
	home := h.path("clients-home")
	directories := []string{
		".cursor", ".codex", ".claude", ".openclaw", ".config/opencode",
		".codeium/windsurf", ".pi", ".copilot", ".config/zed", ".hermes",
		".config/goose",
	}
	for _, directory := range directories {
		if err := h.mkdir(filepath.Join(home, filepath.FromSlash(directory))); err != nil {
			return err
		}
	}
	files := map[string]string{
		".cursor/mcp.json": `{
  "mcpServers": {
    "other": { "command": "other-mcp" }
  }
}
`,
		".codex/config.toml": "[model]\nname = \"gpt\"\n",
		".config/opencode/opencode.json": `{
  "mcp": {
    "other": { "type": "local", "command": ["other-mcp"] }
  }
}
`,
		".config/zed/settings.json": `{
  // my editor
  "theme": "One Dark",
  "context_servers": {
    "other": { "source": "custom", "command": "other-mcp" },
  },
}
`,
		".hermes/config.yaml":       "model: hermes-4\n",
		".config/goose/config.yaml": "extensions:\n  developer:\n    enabled: true\n",
	}
	for relative, contents := range files {
		if err := writeFile(filepath.Join(home, filepath.FromSlash(relative)), contents, 0o600); err != nil {
			return err
		}
	}
	goose := filepath.Join(home, ".config", "goose", "config.yaml")
	gooseBefore, err := fileSHA(goose)
	if err != nil {
		return err
	}

	server := newDeviceServer("")
	defer server.close()
	result := runClientFlow(h, home, server.server.URL, false, "")
	output, err := requireOutput(result)
	if err != nil {
		return err
	}
	if countLines(configuredClients(string(output))) != 10 {
		return fmt.Errorf("configured clients = %q, expected 10", configuredClients(string(output)))
	}
	if !strings.Contains(string(output), "Goose") {
		return fmt.Errorf("the Goose merge refusal was not reported:\n%s", output)
	}
	gooseAfter, err := fileSHA(goose)
	if err != nil {
		return err
	}
	if gooseBefore != gooseAfter {
		return fmt.Errorf("the Goose configuration changed despite an existing extensions key")
	}
	if err := inspectClientConfigs(home, server.server.URL); err != nil {
		return err
	}

	cursor := filepath.Join(home, ".cursor", "mcp.json")
	codex := filepath.Join(home, ".codex", "config.toml")
	cursorBefore, err := fileSHA(cursor)
	if err != nil {
		return err
	}
	codexBefore, err := fileSHA(codex)
	if err != nil {
		return err
	}
	if err := os.RemoveAll(filepath.Join(home, ".config", "goose")); err != nil {
		return err
	}
	result = runClientFlow(h, home, server.server.URL, false, `
ask_tty() { printf 'unexpected client prompt on rerun\n' >&2; exit 9; }
curl() { printf 'unexpected network call on rerun\n' >&2; exit 9; }
`)
	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if configuredClients(string(output)) != "" {
		return fmt.Errorf("rerun reconfigured clients: %q", configuredClients(string(output)))
	}
	cursorAfter, _ := fileSHA(cursor)
	codexAfter, _ := fileSHA(codex)
	if cursorBefore != cursorAfter || codexBefore != codexAfter {
		return fmt.Errorf("hands-off rerun changed existing client configuration")
	}

	deniedHome := h.path("denied-home")
	if err := h.mkdir(filepath.Join(deniedHome, ".cursor")); err != nil {
		return err
	}
	denied := newDeviceServer("access_denied")
	defer denied.close()
	result = runClientFlow(h, deniedHome, denied.server.URL, false, "")
	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if configuredClients(string(output)) != "" {
		return fmt.Errorf("denied flow configured clients")
	}
	if err := requireAbsent(filepath.Join(deniedHome, ".cursor", "mcp.json")); err != nil {
		return err
	}

	// An unknown 400 error code exercises the terminal catchall: any poll
	// error other than authorization_pending must stop after a single poll,
	// not retry until the grant expires.
	strandedHome := h.path("stranded-home")
	if err := h.mkdir(filepath.Join(strandedHome, ".cursor")); err != nil {
		return err
	}
	stranded := newDeviceServer("quota_exhausted")
	defer stranded.close()
	result = runClientFlow(h, strandedHome, stranded.server.URL, false, "")
	output, err = requireOutput(result)
	if err != nil {
		return err
	}
	if configuredClients(string(output)) != "" {
		return fmt.Errorf("terminal poll error configured clients")
	}
	if !strings.Contains(string(output), "quota_exhausted") {
		return fmt.Errorf("terminal poll error was not reported to the operator:\n%s", output)
	}
	if got := stranded.polls.Load(); got != 1 {
		return fmt.Errorf("terminal poll error polled %d times, expected exactly one", got)
	}
	if err := requireAbsent(filepath.Join(strandedHome, ".cursor", "mcp.json")); err != nil {
		return err
	}

	escaped := h.path("escaped-claude.json")
	real := h.path("real-claude.json")
	if err := writeFile(escaped, `{"history":["say \"emisar\" now"],"projects":{"/u/os/emisar":{}}}`+"\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(real, `{"mcpServers":{"emisar":{"command":"emisar-mcp"}}}`+"\n", 0o600); err != nil {
		return err
	}
	result = h.functions(h.repoPath("install-mcp.sh"), clientFunctions, `
if json_config_has_emisar "$ESCAPED"; then
  printf 'escaped JSON text misread as configured\n' >&2
  exit 1
fi
json_config_has_emisar "$REAL"
`, map[string]string{"ESCAPED": escaped, "REAL": real})
	if _, err := requireOutput(result); err != nil {
		return err
	}

	if jq, lookupErr := exec.LookPath("jq"); lookupErr == nil {
		probe := h.path("jq-probe.json")
		jqBin := h.path("jq-only-bin")
		if err := h.mkdir(jqBin); err != nil {
			return err
		}
		if err := os.Symlink(jq, filepath.Join(jqBin, "jq")); err != nil {
			return err
		}
		if err := writeFile(probe,
			`{"device_code":"emdg-x","interval":7,"client_keys":{"claude-code":"emk-jq"}}`, 0o600); err != nil {
			return err
		}
		noKeys := h.path("jq-no-keys.json")
		if err := writeFile(noKeys, `{"status":"ok"}`, 0o600); err != nil {
			return err
		}
		htmlPage := h.path("jq-proxy-page.html")
		if err := writeFile(htmlPage, "<html><body>Signed in</body></html>", 0o600); err != nil {
			return err
		}
		result = h.functions(h.repoPath("install-mcp.sh"),
			[]string{"json_string_field", "json_client_key", "json_has_client_keys"}, `
test "$(json_string_field "$PROBE" device_code)" = emdg-x
test "$(json_string_field "$PROBE" interval)" = 7
test "$(json_client_key "$PROBE" claude-code)" = emk-jq
if json_string_field "$PROBE" missing_key; then exit 1; fi
json_has_client_keys "$PROBE"
if json_has_client_keys "$NO_KEYS"; then exit 1; fi
if json_has_client_keys "$HTML_PAGE"; then exit 1; fi
`, map[string]string{"PATH": jqBin, "PROBE": probe, "NO_KEYS": noKeys, "HTML_PAGE": htmlPage})
		if _, err := requireOutput(result); err != nil {
			return fmt.Errorf("jq response readers: %w", err)
		}
	}

	quietHome := h.path("quiet-home")
	if err := h.mkdir(filepath.Join(quietHome, ".cursor")); err != nil {
		return err
	}
	result = runClientFlow(h, quietHome, server.server.URL, true, `
ask_tty() { printf 'unexpected prompt under ASSUME_YES\n' >&2; exit 9; }
curl() { printf 'unexpected network call under ASSUME_YES\n' >&2; exit 9; }
`)
	if _, err := requireOutput(result); err != nil {
		return err
	}
	return requireAbsent(filepath.Join(quietHome, ".cursor", "mcp.json"))
}

func mcpUninstall(h *harness) error {
	home := h.path("uninstall-home")
	bin := h.path("uninstall-bin")
	// The bridge stores rotated-key state under Go's os.UserConfigDir
	// (mcp/rotate.go), which ignores XDG on darwin — the fixture must live
	// where the script's darwin branch actually looks, or the removal is
	// only ever tested on Linux.
	credentials := filepath.Join(home, ".config", "emisar", "credentials")
	if runtime.GOOS == "darwin" {
		credentials = filepath.Join(home, "Library", "Application Support", "emisar", "credentials")
	}
	if err := h.mkdir(bin, credentials,
		filepath.Join(home, ".cursor"), filepath.Join(home, ".codex"),
		filepath.Join(home, ".config", "zed"), filepath.Join(home, ".hermes"),
		filepath.Join(home, ".config", "goose")); err != nil {
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
	if err := writeFile(filepath.Join(credentials, "state.json"), "{}\n", 0o600); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(bin, "emisar-mcp"), "#!/bin/sh\n", 0o755); err != nil {
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

	codex := filepath.Join(home, ".codex", "config.toml")
	if err := containsFile(codex, `name = "gpt"`); err != nil {
		return err
	}
	if err := lacksFile(codex, "mcp_servers.emisar"); err != nil {
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

func inspectClientConfigs(home, portal string) error {
	cursor, err := jsonFile(filepath.Join(home, ".cursor", "mcp.json"))
	if err != nil {
		return err
	}
	if err := requireNestedString(cursor, "other-mcp", "mcpServers", "other", "command"); err != nil {
		return err
	}
	for expected, keys := range map[string][]string{
		"emk-cur": {"mcpServers", "emisar", "env", "EMISAR_API_KEY"},
		portal:    {"mcpServers", "emisar", "env", "EMISAR_URL"},
	} {
		if err := requireNestedString(cursor, expected, keys...); err != nil {
			return err
		}
	}

	claude, err := jsonFile(filepath.Join(home, ".claude.json"))
	if err != nil {
		return err
	}
	if err := requireNestedString(claude, "emk-cc", "mcpServers", "emisar", "env", "EMISAR_API_KEY"); err != nil {
		return err
	}
	if err := requireNestedString(claude, "claude-code", "mcpServers", "emisar", "env", "EMISAR_CLIENT"); err != nil {
		return err
	}

	openClaw, err := jsonFile(filepath.Join(home, ".openclaw", "openclaw.json"))
	if err != nil {
		return err
	}
	if err := requireNestedString(openClaw, "/usr/local/bin/emisar-mcp", "mcp", "servers", "emisar", "command"); err != nil {
		return err
	}
	if err := requireNestedString(openClaw, "emk-claw", "mcp", "servers", "emisar", "env", "EMISAR_API_KEY"); err != nil {
		return err
	}

	openCode, err := jsonFile(filepath.Join(home, ".config", "opencode", "opencode.json"))
	if err != nil {
		return err
	}
	if err := requireNestedString(openCode, "opencode", "mcp", "emisar", "environment", "EMISAR_CLIENT"); err != nil {
		return err
	}
	if err := requireNestedString(openCode, "other-mcp", "mcp", "other", "command", "0"); err == nil {
		return fmt.Errorf("array traversal unexpectedly used object keys")
	}
	command, err := nested(openCode, "mcp", "emisar", "command")
	if err != nil {
		return err
	}
	commandList, ok := command.([]any)
	if !ok || len(commandList) != 1 || commandList[0] != "/usr/local/bin/emisar-mcp" {
		return fmt.Errorf("OpenCode command = %#v", command)
	}

	for path, client := range map[string]string{
		".codeium/windsurf/mcp_config.json": "windsurf",
		".pi/agent/mcp.json":                "pi",
		".copilot/mcp-config.json":          "copilot-cli",
	} {
		config, err := jsonFile(filepath.Join(home, filepath.FromSlash(path)))
		if err != nil {
			return err
		}
		if err := requireNestedString(config, client, "mcpServers", "emisar", "env", "EMISAR_CLIENT"); err != nil {
			return err
		}
	}

	zed := filepath.Join(home, ".config", "zed", "settings.json")
	for _, text := range []string{
		"// my editor", `"theme": "One Dark"`, `"other"`,
		`"source": "custom"`, `"EMISAR_CLIENT": "zed"`,
	} {
		if err := containsFile(zed, text); err != nil {
			return err
		}
	}
	hermes := filepath.Join(home, ".hermes", "config.yaml")
	for _, text := range []string{
		"model: hermes-4", "mcp_servers:",
		"command: /usr/local/bin/emisar-mcp", `EMISAR_API_KEY: "emk-her"`,
	} {
		if err := containsFile(hermes, text); err != nil {
			return err
		}
	}
	codex := filepath.Join(home, ".codex", "config.toml")
	for _, text := range []string{
		`[mcp_servers.emisar]`, `EMISAR_API_KEY = "emk-cod"`, `name = "gpt"`,
	} {
		if err := containsFile(codex, text); err != nil {
			return err
		}
	}
	return nil
}
