package installtest

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
)

func environmentWithout(overrides map[string]string, names ...string) []string {
	env := environment(overrides)
	filtered := env[:0]
	for _, entry := range env {
		name, _, _ := strings.Cut(entry, "=")
		remove := false
		for _, removed := range names {
			if strings.EqualFold(name, removed) {
				remove = true
				break
			}
		}
		if !remove {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

const windowsMCPVersion = "1.2.3"

type windowsClientFixture struct {
	id       string
	kind     string
	path     string
	original string
	marker   string
}

func windowsClientFixtures(home, appData string) []windowsClientFixture {
	return []windowsClientFixture{
		{"claude-code", "json", filepath.Join(home, ".claude.json"), "{\"fixture\":\"claude-code\"}\r\n", `"fixture":"claude-code"`},
		{"claude-desktop", "json", filepath.Join(appData, "Claude", "claude_desktop_config.json"), "{\"fixture\":\"claude-desktop\"}\r\n", `"fixture":"claude-desktop"`},
		{"cursor", "json", filepath.Join(home, ".cursor", "mcp.json"), "{\"fixture\":\"cursor\",\"theme\":\"dark\",\"mcpServers\":{\"other\":{\"command\":\"other-mcp\"}}}\r\n", `"fixture":"cursor"`},
		{"vscode", "vscode", filepath.Join(appData, "Code", "User", "mcp.json"), "{\r\n  // synced editor config\r\n  \"fixture\": \"vscode\",\r\n  \"servers\": {\r\n    \"other\": { \"type\": \"stdio\", \"command\": \"other-mcp\" }\r\n  }\r\n}\r\n", `"fixture": "vscode"`},
		{"gemini", "json", filepath.Join(home, ".gemini", "settings.json"), "{\"fixture\":\"gemini\",\"mcpServers\":{\"other\":{\"command\":\"other-mcp\"}}}\r\n", `"fixture":"gemini"`},
		{"codex", "toml", filepath.Join(home, ".codex", "config.toml"), "[model]\r\nname = \"windows-codex\"\r\n", `name = "windows-codex"`},
		{"openclaw", "openclaw", filepath.Join(home, ".openclaw", "openclaw.json"), "{\"fixture\":\"openclaw\",\"mcp\":{\"servers\":{\"other\":{\"command\":\"other-mcp\"}}}}\r\n", `"fixture":"openclaw"`},
		{"opencode", "opencode", filepath.Join(home, ".config", "opencode", "opencode.json"), "{\"fixture\":\"opencode\",\"mcp\":{\"other\":{\"type\":\"local\",\"command\":[\"other-mcp\"]}}}\r\n", `"fixture":"opencode"`},
		{"windsurf", "json", filepath.Join(home, ".codeium", "windsurf", "mcp_config.json"), "{\"fixture\":\"windsurf\"}\r\n", `"fixture":"windsurf"`},
		{"pi", "json", filepath.Join(home, ".pi", "agent", "mcp.json"), "{\"fixture\":\"pi\"}\r\n", `"fixture":"pi"`},
		{"copilot-cli", "copilot", filepath.Join(home, ".copilot", "mcp-config.json"), "{\"fixture\":\"copilot-cli\"}\r\n", `"fixture":"copilot-cli"`},
		{"zed", "zed", filepath.Join(appData, "Zed", "settings.json"), "{\"fixture\":\"zed\",\"context_servers\":{\"other\":{\"source\":\"custom\",\"command\":\"other-mcp\"}}}\r\n", `"fixture":"zed"`},
		{"hermes", "hermes", filepath.Join(home, ".hermes", "config.yaml"), "model: windows-hermes\r\n", "model: windows-hermes"},
		{"goose", "goose", filepath.Join(home, ".config", "goose", "config.yaml"), "provider: windows-goose\r\n", "provider: windows-goose"},
		{"grok", "toml", filepath.Join(home, ".grok", "config.toml"), "[permission]\r\nallow = [\"MCPTool(other__*)\"]\r\n", `allow = ["MCPTool(other__*)"]`},
	}
}

func windowsClientIDs() []string {
	return []string{
		"emisar-mcp-cli", "claude-code", "claude-desktop", "cursor", "vscode",
		"gemini", "codex", "openclaw", "opencode", "windsurf", "pi",
		"copilot-cli", "zed", "hermes", "goose", "grok",
	}
}

// MCPWindows exercises the native PowerShell installer with both the stock
// Windows PowerShell host and current pwsh. It uses a loopback release mirror
// and device-grant server, but runs the real bridge binary and installer.
func MCPWindows(root string, out io.Writer) error {
	if runtime.GOOS != "windows" {
		return fmt.Errorf("mcp-windows installer tests require Windows")
	}
	for _, shell := range []string{"powershell.exe", "pwsh.exe"} {
		path, err := exec.LookPath(shell)
		if err != nil {
			return fmt.Errorf("required PowerShell host %s is unavailable: %w", shell, err)
		}
		if err := testWindowsMCPInstaller(root, path); err != nil {
			return fmt.Errorf("%s: %w", shell, err)
		}
		fmt.Fprintf(out, "ok: Windows MCP installer passed with %s\n", shell)
	}
	return nil
}

func testWindowsMCPInstaller(root, shell string) error {
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		return fmt.Errorf("unsupported Windows test architecture %s", runtime.GOARCH)
	}
	temp, err := os.MkdirTemp("", "emisar-mcp-windows-installtest-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	if err := testWindowsEndpointOptInContract(root, shell, temp); err != nil {
		return err
	}
	if err := testWindowsAttestationPolicies(root, shell, temp); err != nil {
		return err
	}
	if err := testWindowsArchivePathGuard(root, shell, temp); err != nil {
		return err
	}
	if err := testWindowsRedirectChain(root, shell, temp); err != nil {
		return err
	}

	releaseDir := filepath.Join(temp, "release")
	archiveRoot := "emisar-mcp-" + windowsMCPVersion + "-windows-" + runtime.GOARCH
	stagedRoot := filepath.Join(temp, archiveRoot)
	if err := os.MkdirAll(stagedRoot, 0o700); err != nil {
		return err
	}
	binary := filepath.Join(stagedRoot, "emisar-mcp.exe")
	build := exec.Command("go", "build", "-trimpath", "-ldflags", "-s -w -X main.Version="+windowsMCPVersion, "-o", binary, ".")
	build.Dir = filepath.Join(root, "mcp")
	build.Env = environment(map[string]string{"GOTOOLCHAIN": "local", "CGO_ENABLED": "0"})
	if output, err := build.CombinedOutput(); err != nil {
		return fmt.Errorf("build Windows MCP fixture: %w\n%s", err, output)
	}
	archiveName := archiveRoot + ".zip"
	archivePath := filepath.Join(releaseDir, archiveName)
	if err := os.MkdirAll(releaseDir, 0o700); err != nil {
		return err
	}
	if err := zipWindowsMCPFixture(archivePath, archiveRoot, binary); err != nil {
		return err
	}
	archiveBytes, err := os.ReadFile(archivePath)
	if err != nil {
		return err
	}
	archiveHash := sha256.Sum256(archiveBytes)
	checksums := hex.EncodeToString(archiveHash[:]) + "  " + archiveName + "\n"
	servedChecksums := checksums

	requested := []string(nil)
	cliKey := windowsInstallerAPIKey(1)
	cliReplacementKey := windowsInstallerAPIKey(3)
	explicitKey := windowsInstallerAPIKey(4)
	clientKeys := make(map[string]string)
	for index, id := range windowsClientIDs()[1:] {
		clientKeys[id] = windowsInstallerAPIKey(byte(index + 10))
	}
	activeCLIKey := cliKey
	deviceGrants := 0
	var serverMu sync.Mutex
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/latest.json", "/mcp-v" + windowsMCPVersion + "/manifest.json":
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"schema_version":  1,
				"component":       "mcp",
				"tag":             "mcp-v" + windowsMCPVersion,
				"version":         windowsMCPVersion,
				"source_revision": strings.Repeat("a", 40),
			})
		case "/mcp-v" + windowsMCPVersion + "/" + archiveName:
			writer.Header().Set("Content-Type", "application/zip")
			_, _ = writer.Write(archiveBytes)
		case "/mcp-v" + windowsMCPVersion + "/SHA256SUMS-MCP":
			serverMu.Lock()
			response := servedChecksums
			serverMu.Unlock()
			_, _ = io.WriteString(writer, response)
		case "/api/mcp/device_authorization":
			var body struct {
				RequestedClients []string `json:"requested_clients"`
			}
			if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
				http.Error(writer, "invalid", http.StatusBadRequest)
				return
			}
			serverMu.Lock()
			requested = append([]string(nil), body.RequestedClients...)
			deviceGrants++
			serverMu.Unlock()
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"device_code":               "emdg-0123456789abcdef",
				"user_code":                 "ABCD-2345",
				"verification_uri":          "http://" + request.Host + "/activate",
				"verification_uri_complete": "http://" + request.Host + "/activate?code=ABCD-2345",
				"expires_in":                60,
				"interval":                  1,
			})
		case "/api/mcp/device_token":
			serverMu.Lock()
			key := activeCLIKey
			requestedNow := append([]string(nil), requested...)
			serverMu.Unlock()
			keys := make(map[string]string, len(requestedNow))
			for _, id := range requestedNow {
				if id == "emisar-mcp-cli" {
					keys[id] = key
				} else if clientKey, ok := clientKeys[id]; ok {
					keys[id] = clientKey
				}
			}
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"account_id":   "018f0000-0000-7000-8000-000000000003",
				"account_slug": "windows-installer-test",
				"account_name": "Windows installer test",
				"client_keys":  keys,
			})
		case "/api/mcp/rpc":
			serverMu.Lock()
			key := activeCLIKey
			serverMu.Unlock()
			authorization := request.Header.Get("Authorization")
			if authorization != "Bearer "+key && authorization != "Bearer "+explicitKey {
				http.Error(writer, "unauthorized", http.StatusUnauthorized)
				return
			}
			var rpc struct {
				ID any `json:"id"`
			}
			_ = json.NewDecoder(request.Body).Decode(&rpc)
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"jsonrpc": "2.0",
				"id":      rpc.ID,
				"result":  map[string]any{"tools": []any{}},
			})
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()

	home := filepath.Join(temp, "home")
	appData := filepath.Join(temp, "appdata")
	localAppData := filepath.Join(temp, "localappdata")
	fixtures := windowsClientFixtures(home, appData)
	for _, fixture := range fixtures {
		if err := os.MkdirAll(filepath.Dir(fixture.path), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(fixture.path, []byte(fixture.original), 0o600); err != nil {
			return err
		}
	}
	// The installer reads the real Windows directory variables, so the harness
	// sets those rather than a parallel test-only spelling — the same shape the
	// Unix installers' harness already uses. EMISAR_MCP_TEST_BASE_URL has no
	// real-variable equivalent and stays; the installer accepts it only for a
	// loopback origin with an affirmative EMISAR_ALLOW_INSECURE value.
	env := map[string]string{
		"APPDATA":                  appData,
		"LOCALAPPDATA":             localAppData,
		"USERPROFILE":              home,
		"HOME":                     home,
		"EMISAR_ALLOW_INSECURE":    " TrUe ",
		"EMISAR_MCP_TEST_BASE_URL": server.URL,
	}
	installer := filepath.Join(root, "install-mcp.ps1")
	checksumInstallDir := filepath.Join(temp, "checksum-install")
	checksumExecutable := filepath.Join(checksumInstallDir, "emisar-mcp.exe")
	assertChecksumFailure := func(name, sums, want string) error {
		serverMu.Lock()
		servedChecksums = sums
		beforeGrants := deviceGrants
		serverMu.Unlock()

		failureOutput, failureErr := runPowerShellInstaller(
			shell,
			installer,
			environmentWithout(env, "EMISAR_URL", "EMISAR_API_KEY"),
			"-PortalOrigin",
			server.URL,
			"-InstallDir",
			checksumInstallDir,
			"-Yes",
			"-ConnectAll",
		)
		if failureErr == nil || !bytes.Contains(failureOutput, []byte(want)) {
			return fmt.Errorf("%s checksum was not refused: %v\n%s", name, failureErr, failureOutput)
		}
		if _, statErr := os.Stat(checksumExecutable); !os.IsNotExist(statErr) {
			return fmt.Errorf("%s checksum activated %s: %v", name, checksumExecutable, statErr)
		}
		serverMu.Lock()
		afterGrants := deviceGrants
		serverMu.Unlock()
		if afterGrants != beforeGrants {
			return fmt.Errorf("%s checksum reached device authorization: grants %d -> %d", name, beforeGrants, afterGrants)
		}
		for _, fixture := range fixtures {
			data, readErr := os.ReadFile(fixture.path)
			if readErr != nil || string(data) != fixture.original {
				return fmt.Errorf("%s checksum changed %s before verification: %v", name, fixture.id, readErr)
			}
		}
		return nil
	}
	if err := assertChecksumFailure(
		"mismatched",
		strings.Repeat("0", 64)+"  "+archiveName+"\n",
		"checksum verification failed for "+archiveName,
	); err != nil {
		return err
	}
	if err := assertChecksumFailure(
		"missing-entry",
		hex.EncodeToString(archiveHash[:])+"  another.zip\n",
		"SHA256SUMS-MCP does not list "+archiveName,
	); err != nil {
		return err
	}
	serverMu.Lock()
	servedChecksums = checksums
	serverMu.Unlock()

	output, err := runPowerShellInstaller(
		shell,
		installer,
		environmentWithout(env, "EMISAR_URL", "EMISAR_API_KEY"),
		"-PortalOrigin",
		server.URL,
		"-Yes",
		"-ConnectAll",
	)
	if err != nil {
		return fmt.Errorf("install: %w\n%s", err, output)
	}
	if !bytes.Contains(output, []byte("install target: windows/"+runtime.GOARCH)) {
		return fmt.Errorf("installer did not select windows/%s\n%s", runtime.GOARCH, output)
	}
	if outputContainsWindowsKey(output, cliKey, clientKeys) {
		return fmt.Errorf("installer output disclosed a delivered API key")
	}
	serverMu.Lock()
	firstRequested := append([]string(nil), requested...)
	firstDeviceGrants := deviceGrants
	serverMu.Unlock()
	if firstDeviceGrants != 1 || !slicesEqual(firstRequested, windowsClientIDs()) {
		return fmt.Errorf(
			"device grants = %d, requested clients = %v; want one grant for every supported client\n%s",
			firstDeviceGrants,
			firstRequested,
			output,
		)
	}
	installed := filepath.Join(localAppData, "Programs", "Emisar", "bin", "emisar-mcp.exe")
	versionOutput, err := exec.Command(installed, "--version").CombinedOutput()
	if err != nil || strings.TrimSpace(string(versionOutput)) != "emisar-mcp "+windowsMCPVersion {
		return fmt.Errorf("installed version: %w, %q", err, versionOutput)
	}
	if err := validateWindowsClientConfigs(fixtures, installed, server.URL, appData, clientKeys); err != nil {
		return err
	}
	verify := exec.Command(installed, "list_tools", "--json")
	verify.Env = environmentWithout(map[string]string{
		"APPDATA":               appData,
		"LOCALAPPDATA":          localAppData,
		"USERPROFILE":           home,
		"HOME":                  home,
		"EMISAR_ALLOW_INSECURE": "1",
	}, "EMISAR_URL", "EMISAR_API_KEY")
	if result, err := verify.CombinedOutput(); err != nil {
		return fmt.Errorf("stored CLI credential or Windows ACL is unusable: %w\n%s", err, result)
	}

	// A rerun must verify the stored account, not an inherited explicit pair.
	// Revoke the stored key while keeping the inherited pair valid: the installer
	// should request fresh browser approval and replace the account credential.
	serverMu.Lock()
	activeCLIKey = cliReplacementKey
	serverMu.Unlock()
	rerunEnv := make(map[string]string, len(env))
	for name, value := range env {
		rerunEnv[name] = value
	}
	rerunEnv["EMISAR_URL"] = server.URL
	rerunEnv["EMISAR_API_KEY"] = explicitKey
	output, err = runPowerShellInstaller(
		shell,
		installer,
		environment(rerunEnv),
		"-PortalOrigin",
		server.URL,
		"-Yes",
		"-ConnectAll",
	)
	if err != nil {
		return fmt.Errorf("rerun with inherited environment: %w\n%s", err, output)
	}
	if outputContainsWindowsKey(output, cliReplacementKey, clientKeys) || bytes.Contains(output, []byte(explicitKey)) {
		return errors.New("rerun output disclosed an API key")
	}
	serverMu.Lock()
	rerunRequested := append([]string(nil), requested...)
	rerunDeviceGrants := deviceGrants
	serverMu.Unlock()
	if rerunDeviceGrants != 2 || !slicesEqual(rerunRequested, []string{"emisar-mcp-cli"}) {
		return fmt.Errorf("rerun used inherited auth: grants=%d clients=%v", rerunDeviceGrants, rerunRequested)
	}
	verify = exec.Command(installed, "list_tools", "--json")
	verify.Env = environmentWithout(map[string]string{
		"APPDATA":               appData,
		"LOCALAPPDATA":          localAppData,
		"USERPROFILE":           home,
		"HOME":                  home,
		"EMISAR_ALLOW_INSECURE": "1",
	}, "EMISAR_URL", "EMISAR_API_KEY")
	if result, err := verify.CombinedOutput(); err != nil {
		return fmt.Errorf("replacement stored credential is unusable: %w\n%s", err, result)
	}
	credentials := filepath.Join(appData, "emisar", "credentials")
	savedCredentials := filepath.Join(appData, "emisar", "credentials.saved")
	if err := os.Rename(credentials, savedCredentials); err != nil {
		return fmt.Errorf("stage credential junction test: %w", err)
	}
	credentialTarget := filepath.Join(temp, "credential-target")
	if err := os.MkdirAll(credentialTarget, 0o700); err != nil {
		return err
	}
	sentinel := filepath.Join(credentialTarget, "keep.txt")
	if err := os.WriteFile(sentinel, []byte("keep\n"), 0o600); err != nil {
		return err
	}
	junction := exec.Command("cmd.exe", "/c", "mklink", "/J", credentials, credentialTarget)
	if result, err := junction.CombinedOutput(); err != nil {
		return fmt.Errorf("create credential junction: %w\n%s", err, result)
	}
	blocked, blockedErr := runPowerShellInstaller(
		shell,
		installer,
		environmentWithout(env, "EMISAR_URL", "EMISAR_API_KEY"),
		"-PortalOrigin",
		server.URL,
		"-Uninstall",
		"-Yes",
	)
	if blockedErr == nil || !bytes.Contains(blocked, []byte("credential directory is a reparse point")) {
		return fmt.Errorf("credential junction uninstall was not refused: %v\n%s", blockedErr, blocked)
	}
	if data, err := os.ReadFile(sentinel); err != nil || string(data) != "keep\n" {
		return fmt.Errorf("credential junction target changed: %q, %v", data, err)
	}
	if err := os.Remove(credentials); err != nil {
		return fmt.Errorf("remove credential junction: %w", err)
	}
	if err := os.Rename(savedCredentials, credentials); err != nil {
		return fmt.Errorf("restore credentials after junction test: %w", err)
	}

	output, err = runPowerShellInstaller(
		shell,
		installer,
		environmentWithout(env, "EMISAR_URL", "EMISAR_API_KEY"),
		"-PortalOrigin",
		server.URL,
		"-Uninstall",
		"-Yes",
	)
	if err != nil {
		return fmt.Errorf("uninstall: %w\n%s", err, output)
	}
	if _, err := os.Stat(installed); !os.IsNotExist(err) {
		return fmt.Errorf("uninstall left executable: %v", err)
	}
	if err := validateWindowsClientUninstall(fixtures, clientKeys); err != nil {
		return err
	}
	if _, err := os.Stat(credentials); !os.IsNotExist(err) {
		return fmt.Errorf("uninstall left CLI credentials: %v", err)
	}
	return nil
}

func testWindowsEndpointOptInContract(root, shell, temp string) error {
	installer := filepath.Join(root, "install-mcp.ps1")
	truthyFunction, err := powershellFunction(installer, "Test-Truthy")
	if err != nil {
		return err
	}
	safeOriginFunction, err := powershellFunction(installer, "Test-SafePortalOrigin")
	if err != nil {
		return err
	}
	script := truthyFunction + safeOriginFunction + `
foreach ($value in @("1", "true", "yes", "y", "on", "TRUE", "TrUe", "YeS", "Y", "On", " true ")) {
    if (-not (Test-Truthy $value)) { throw "affirmative value refused: '$value'" }
}
foreach ($value in @($null, "", " ", "0", "false", "no", "off", "maybe", "2", "truthy")) {
    if (Test-Truthy $value) { throw "unknown value accepted: '$value'" }
}

$env:EMISAR_ALLOW_INSECURE = ""
if (-not (Test-SafePortalOrigin "https://portal.example")) { throw "HTTPS origin refused" }
if (-not (Test-SafePortalOrigin "http://127.0.0.1:4000")) { throw "loopback HTTP origin refused" }
if (Test-SafePortalOrigin "http://portal.example") { throw "non-loopback HTTP origin accepted without opt-in" }
$env:EMISAR_ALLOW_INSECURE = "YeS"
if (-not (Test-SafePortalOrigin "http://portal.example")) { throw "opted-in HTTP origin refused" }
if (Test-SafePortalOrigin "http://portal.example/path") { throw "HTTP origin with a path accepted" }
`
	path := filepath.Join(temp, "endpoint-opt-in-contract.ps1")
	if err := os.WriteFile(path, []byte(script), 0o600); err != nil {
		return err
	}
	output, err := runPowerShellInstaller(shell, path, environment(nil))
	if err != nil {
		return fmt.Errorf("endpoint opt-in contract: %w\n%s", err, output)
	}
	if len(bytes.TrimSpace(output)) != 0 {
		return fmt.Errorf("endpoint opt-in contract wrote unexpected output: %q", output)
	}
	return nil
}

func testWindowsAttestationPolicies(root, shell, temp string) error {
	installer := filepath.Join(root, "install-mcp.ps1")
	policyFunction, err := powershellFunction(installer, "Get-AttestationPolicy")
	if err != nil {
		return err
	}
	verifyFunction, err := powershellFunction(installer, "Test-Attestation")
	if err != nil {
		return err
	}
	trace := filepath.Join(temp, "attestation-argv.txt")
	script := policyFunction + verifyFunction + `
function Write-WarningLine([string]$Message) {}
function Write-Info([string]$Message) {}
function Stop-Install([string]$Message) { throw $Message }
function gh {
    $commandArgs = @($args)
    $global:LASTEXITCODE = 0
    if ($commandArgs.Count -gt 0 -and $commandArgs[0] -eq "auth") { return }
    [IO.File]::AppendAllText($env:EMISAR_ATTESTATION_TRACE, (($commandArgs -join "|") + [Environment]::NewLine))
}
function Set-TestAttestationPolicy($Policy) {
    $script:AttestationWorkflow = $Policy.Workflow
    $script:AttestationSignerDigest = $Policy.SignerDigest
    $script:AttestationSourceRef = $Policy.SourceRef
    $script:AttestationDenySelfHosted = $Policy.DenySelfHosted
}

$script:Repository = "andrewdryga/emisar"
foreach ($tag in @("mcp-v0.10.1", "mcp-v0.10.2", "mcp-v0.9.99", "MCP-V0.10.1")) {
    $policy = Get-AttestationPolicy "andrewdryga/emisar" $tag ""
    Write-Output ("{0}|{1}|{2}|{3}" -f $policy.Workflow, $policy.SignerDigest, $policy.SourceRef, $policy.DenySelfHosted)
}
$policy = Get-AttestationPolicy "example/emisar" "mcp-v0.10.1" ""
Write-Output ("{0}|{1}|{2}|{3}" -f $policy.Workflow, $policy.SignerDigest, $policy.SourceRef, $policy.DenySelfHosted)
$policy = Get-AttestationPolicy "example/emisar" "mcp-v0.10.1" "example/emisar/.github/workflows/release.yml"
Write-Output ("{0}|{1}|{2}|{3}" -f $policy.Workflow, $policy.SignerDigest, $policy.SourceRef, $policy.DenySelfHosted)

foreach ($tag in @("mcp-v0.10.1", "mcp-v0.10.2")) {
    Set-TestAttestationPolicy (Get-AttestationPolicy "andrewdryga/emisar" $tag "")
    Test-Attestation "C:\verified\mcp.zip" $false
}
$script:Repository = "example/emisar"
Set-TestAttestationPolicy (Get-AttestationPolicy "example/emisar" "mcp-v0.10.1" "example/emisar/.github/workflows/release.yml")
Test-Attestation "C:\verified\mcp.zip" $false
`
	path := filepath.Join(temp, "attestation-policy.ps1")
	if err := os.WriteFile(path, []byte(script), 0o600); err != nil {
		return err
	}
	output, err := runPowerShellInstaller(shell, path, environment(map[string]string{"EMISAR_ATTESTATION_TRACE": trace}))
	if err != nil {
		return fmt.Errorf("attestation policy: %w\n%s", err, output)
	}
	expected := "AndrewDryga/emisar/.github/workflows/mcp-release.yml|642128eb48205405fd44ce845118e6a68737eea2|refs/tags/mcp-v0.10.1|True\n" +
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml||refs/tags/mcp-v0.10.2|True\n" +
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml||refs/tags/mcp-v0.9.99|True\n" +
		"AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml||refs/tags/MCP-V0.10.1|True\n" +
		"|||False\n" +
		"example/emisar/.github/workflows/release.yml|||False\n"
	actual := strings.ReplaceAll(string(output), "\r\n", "\n")
	if actual != expected {
		return fmt.Errorf("attestation policies = %q, want %q", output, expected)
	}
	traceData, err := os.ReadFile(trace)
	if err != nil {
		return fmt.Errorf("read attestation argv: %w", err)
	}
	expectedTrace := "attestation|verify|C:\\verified\\mcp.zip|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/mcp-release.yml|--source-ref|refs/tags/mcp-v0.10.1|--signer-digest|642128eb48205405fd44ce845118e6a68737eea2|--deny-self-hosted-runners\n" +
		"attestation|verify|C:\\verified\\mcp.zip|--repo|andrewdryga/emisar|--signer-workflow|AndrewDryga/emisar/.github/workflows/mcp-release-trusted.yml|--source-ref|refs/tags/mcp-v0.10.2|--deny-self-hosted-runners\n" +
		"attestation|verify|C:\\verified\\mcp.zip|--repo|example/emisar|--signer-workflow|example/emisar/.github/workflows/release.yml\n"
	actualTrace := strings.ReplaceAll(string(traceData), "\r\n", "\n")
	if actualTrace != expectedTrace {
		return fmt.Errorf("attestation argv = %q, want %q", traceData, expectedTrace)
	}
	return nil
}

// The archive guard is the layer that still holds when the release itself is
// the thing that is wrong, so it is tested against the separator spellings a
// hostile zip actually carries — including the mixed form that survived a
// single-quoted '\\' normalization and reached Expand-Archive.
func testWindowsArchivePathGuard(root, shell, temp string) error {
	installer := filepath.Join(root, "install-mcp.ps1")
	guard, err := powershellFunction(installer, "Assert-SafeArchive")
	if err != nil {
		return err
	}
	const expectedRoot = "emisar-mcp-1.2.3-windows-amd64"
	unsafe := []string{
		expectedRoot + `/..\..\evil.exe`,
		expectedRoot + `\..\evil.exe`,
		expectedRoot + "/../evil.exe",
		"/" + expectedRoot + "/emisar-mcp.exe",
		"C:/evil.exe",
		"other-root/emisar-mcp.exe",
	}
	archives := map[string]string{}
	for index, name := range unsafe {
		archivePath := filepath.Join(temp, fmt.Sprintf("unsafe-%d.zip", index))
		if err := zipWindowsEntryNames(archivePath, name); err != nil {
			return err
		}
		archives[archivePath] = name
	}
	safePath := filepath.Join(temp, "safe.zip")
	if err := zipWindowsEntryNames(safePath, expectedRoot+"/emisar-mcp.exe"); err != nil {
		return err
	}

	var script strings.Builder
	script.WriteString("function Stop-Install([string]$Message) { throw $Message }\n")
	script.WriteString(guard)
	for archivePath, name := range archives {
		fmt.Fprintf(&script, `
$refused = $false
try { Assert-SafeArchive %s %s } catch { $refused = $true }
if (-not $refused) { throw ('unsafe archive entry accepted: ' + %s) }
`, powershellLiteral(archivePath), powershellLiteral(expectedRoot), powershellLiteral(name))
	}
	fmt.Fprintf(&script, "\nAssert-SafeArchive %s %s\n",
		powershellLiteral(safePath), powershellLiteral(expectedRoot))

	scriptPath := filepath.Join(temp, "archive-path-guard.ps1")
	if err := os.WriteFile(scriptPath, []byte(script.String()), 0o600); err != nil {
		return err
	}
	output, err := runPowerShellInstaller(shell, scriptPath, environment(nil))
	if err != nil {
		return fmt.Errorf("archive path guard: %w\n%s", err, output)
	}
	return nil
}

// Only the first and the final URI were checked while the handler followed the
// chain itself, so an intermediate cleartext hop was never seen. Redirects are
// followed by hand now: every hop faces the same trust check, and the chain is
// bounded.
func testWindowsRedirectChain(root, shell, temp string) error {
	installer := filepath.Join(root, "install-mcp.ps1")
	var parts strings.Builder
	for _, name := range []string{"Test-Truthy", "Test-TrustedWebUri", "New-WebClient", "Get-WebBytes"} {
		function, err := powershellFunction(installer, name)
		if err != nil {
			return err
		}
		parts.WriteString(function)
	}

	var loops int32
	mux := http.NewServeMux()
	mux.HandleFunc("/payload", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("payload"))
	})
	mux.HandleFunc("/one-hop", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/payload", http.StatusFound)
	})
	// A trusted origin redirecting off-loopback in cleartext: the hop an
	// on-path attacker rewrites, and the one the old code never validated.
	mux.HandleFunc("/offsite", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://198.51.100.7/evil", http.StatusFound)
	})
	mux.HandleFunc("/loop", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&loops, 1)
		http.Redirect(w, r, "/loop", http.StatusFound)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	script := parts.String() + fmt.Sprintf(`
$script:MaximumRedirects = 5
function Stop-Install([string]$Message) { throw $Message }
$env:EMISAR_ALLOW_INSECURE = "1"

$bytes = Get-WebBytes "%[1]s/one-hop"
if ([Text.Encoding]::UTF8.GetString($bytes) -ne "payload") { throw "a loopback redirect was not followed" }

$refused = $false
try { [void](Get-WebBytes "%[1]s/offsite") } catch { $refused = $true }
if (-not $refused) { throw "an intermediate redirect to a non-loopback cleartext host was followed" }

$bounded = $false
try { [void](Get-WebBytes "%[1]s/loop") } catch { $bounded = $true }
if (-not $bounded) { throw "a redirect loop was not bounded" }
`, server.URL)

	scriptPath := filepath.Join(temp, "redirect-chain.ps1")
	if err := os.WriteFile(scriptPath, []byte(script), 0o600); err != nil {
		return err
	}
	output, err := runPowerShellInstaller(shell, scriptPath, environment(nil))
	if err != nil {
		return fmt.Errorf("redirect chain: %w\n%s", err, output)
	}
	if got := atomic.LoadInt32(&loops); got > int32(8) {
		return fmt.Errorf("redirect loop was followed %d times, want a bounded chain", got)
	}
	return nil
}

// powershellLiteral renders a value as a single-quoted PowerShell string, where
// nothing is an escape except a doubled quote. Go's %q would emit Go escapes,
// and a Windows path's backslashes would arrive doubled.
func powershellLiteral(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func zipWindowsEntryNames(destination string, names ...string) error {
	output, err := os.Create(destination)
	if err != nil {
		return err
	}
	archive := zip.NewWriter(output)
	for _, name := range names {
		var entry io.Writer
		// Create sanitizes nothing, which is the point: the guard must judge the
		// exact bytes a hostile producer wrote into the central directory.
		if entry, err = archive.CreateHeader(&zip.FileHeader{Name: name}); err != nil {
			break
		}
		if _, err = entry.Write([]byte("x")); err != nil {
			break
		}
	}
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if closeErr := output.Close(); err == nil {
		err = closeErr
	}
	return err
}

func powershellFunction(path, name string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	lines := strings.Split(string(data), "\n")
	start := -1
	depth := 0
	for index, line := range lines {
		if start == -1 {
			if !strings.HasPrefix(line, "function "+name+"(") {
				continue
			}
			start = index
		}
		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if start >= 0 && depth == 0 {
			return strings.Join(lines[start:index+1], "\n") + "\n", nil
		}
	}
	return "", fmt.Errorf("%s does not define a complete %s function", path, name)
}

func outputContainsWindowsKey(output []byte, cliKey string, clientKeys map[string]string) bool {
	if bytes.Contains(output, []byte(cliKey)) {
		return true
	}
	for _, key := range clientKeys {
		if bytes.Contains(output, []byte(key)) {
			return true
		}
	}
	return false
}

func validateWindowsClientConfigs(fixtures []windowsClientFixture, installed, portal, appData string, clientKeys map[string]string) error {
	installedInfo, err := os.Stat(installed)
	if err != nil {
		return err
	}
	for _, fixture := range fixtures {
		backup, err := os.ReadFile(fixture.path + ".emisar-bak")
		if err != nil || string(backup) != fixture.original {
			return fmt.Errorf("%s config backup did not preserve the original file: %w", fixture.id, err)
		}
		data, err := os.ReadFile(fixture.path)
		if err != nil {
			return err
		}
		key := clientKeys[fixture.id]
		switch fixture.kind {
		case "toml":
			if !bytes.Contains(data, []byte(fixture.marker)) {
				return fmt.Errorf("%s config lost its unrelated fixture setting:\n%s", fixture.id, data)
			}
			for _, text := range []string{
				"[mcp_servers.emisar]", "emisar-mcp.exe", `EMISAR_URL = "` + portal + `"`,
				`EMISAR_API_KEY = "` + key + `"`, `EMISAR_CLIENT = "` + fixture.id + `"`,
			} {
				if !bytes.Contains(data, []byte(text)) {
					return fmt.Errorf("%s config lacks %q:\n%s", fixture.id, text, data)
				}
			}
			continue
		case "hermes", "goose":
			if !bytes.Contains(data, []byte(fixture.marker)) {
				return fmt.Errorf("%s config lost its unrelated fixture setting:\n%s", fixture.id, data)
			}
			for _, text := range []string{"emisar:", "emisar-mcp.exe", "EMISAR_URL:", portal, "EMISAR_API_KEY:", key} {
				if !bytes.Contains(data, []byte(text)) {
					return fmt.Errorf("%s config lacks %q:\n%s", fixture.id, text, data)
				}
			}
			continue
		}

		config, err := decodeWindowsClientJSON(fixture, data)
		if err != nil {
			return err
		}
		entry, err := windowsClientEntry(config, fixture.kind)
		if err != nil {
			return fmt.Errorf("%s config: %w", fixture.id, err)
		}
		configuredCommand := ""
		switch command := entry["command"].(type) {
		case string:
			configuredCommand = command
		case []any:
			if len(command) == 1 {
				configuredCommand, _ = command[0].(string)
			}
		}
		configuredInfo, configuredErr := os.Stat(configuredCommand)
		if configuredErr != nil || !os.SameFile(configuredInfo, installedInfo) {
			return fmt.Errorf("%s configured command %q is not the installed bridge", fixture.id, configuredCommand)
		}
		if fixture.kind == "vscode" {
			envPath := filepath.Join(appData, "emisar", "credentials", "vscode.env")
			if entry["type"] != "stdio" || entry["envFile"] != envPath {
				return fmt.Errorf("VS Code entry = %#v", entry)
			}
			if bytes.Contains(data, []byte(key)) {
				return errors.New("VS Code mcp.json disclosed its API key")
			}
			// The bridge writes this file with LF on every platform — one
			// format, no branch — and VS Code's envFile parser reads it the
			// same way on Windows. The seeded fixtures above use CRLF because
			// they stand in for files Windows editors really wrote; what we
			// produce ourselves is not one of those.
			expected := "EMISAR_URL=" + portal + "\n" +
				"EMISAR_API_KEY=" + key + "\n" +
				"EMISAR_CLIENT=vscode\n"
			environment, err := os.ReadFile(envPath)
			if err != nil {
				return fmt.Errorf("reading the VS Code private environment: %w", err)
			}
			if string(environment) != expected {
				return fmt.Errorf("VS Code private environment = %q, want %q", environment, expected)
			}
			continue
		}
		environmentName := "env"
		if fixture.kind == "opencode" {
			environmentName = "environment"
		}
		clientEnvironment, ok := entry[environmentName].(map[string]any)
		if !ok || clientEnvironment["EMISAR_URL"] != portal ||
			clientEnvironment["EMISAR_API_KEY"] != key ||
			clientEnvironment["EMISAR_CLIENT"] != fixture.id {
			return fmt.Errorf("%s environment = %#v", fixture.id, entry[environmentName])
		}
	}
	return nil
}

func validateWindowsClientUninstall(fixtures []windowsClientFixture, clientKeys map[string]string) error {
	for _, fixture := range fixtures {
		if _, err := os.Stat(fixture.path + ".emisar-bak"); !os.IsNotExist(err) {
			return fmt.Errorf("uninstall left %s config backup: %v", fixture.id, err)
		}
		data, err := os.ReadFile(fixture.path)
		if err != nil {
			return err
		}
		if bytes.Contains(data, []byte(clientKeys[fixture.id])) {
			return fmt.Errorf("uninstall left %s's API key", fixture.id)
		}
		if fixture.kind == "toml" || fixture.kind == "hermes" || fixture.kind == "goose" {
			if !bytes.Contains(data, []byte(fixture.marker)) {
				return fmt.Errorf("uninstall removed %s's unrelated setting:\n%s", fixture.id, data)
			}
			if bytes.Contains(data, []byte("emisar")) {
				return fmt.Errorf("uninstall left the Emisar entry in %s:\n%s", fixture.id, data)
			}
			continue
		}
		config, err := decodeWindowsClientJSON(fixture, data)
		if err != nil {
			return err
		}
		container, err := windowsClientContainer(config, fixture.kind)
		if err != nil {
			return fmt.Errorf("%s config: %w", fixture.id, err)
		}
		if _, exists := container["emisar"]; exists {
			return fmt.Errorf("uninstall left the Emisar entry in %s", fixture.id)
		}
	}
	return nil
}

func decodeWindowsClientJSON(fixture windowsClientFixture, data []byte) (map[string]any, error) {
	if fixture.kind == "vscode" {
		data = bytes.ReplaceAll(data, []byte("  // synced editor config\r\n"), nil)
		data = bytes.ReplaceAll(data, []byte("  // synced editor config\n"), nil)
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("decode %s config: %w\n%s", fixture.id, err, data)
	}
	if config["fixture"] != fixture.id {
		return nil, fmt.Errorf("%s fixture marker = %#v", fixture.id, config["fixture"])
	}
	return config, nil
}

func windowsClientEntry(config map[string]any, kind string) (map[string]any, error) {
	container, err := windowsClientContainer(config, kind)
	if err != nil {
		return nil, err
	}
	entry, ok := container["emisar"].(map[string]any)
	if !ok {
		return nil, errors.New("no Emisar server object")
	}
	return entry, nil
}

func windowsClientContainer(config map[string]any, kind string) (map[string]any, error) {
	keys := []string{"mcpServers"}
	switch kind {
	case "openclaw":
		keys = []string{"mcp", "servers"}
	case "opencode":
		keys = []string{"mcp"}
	case "zed":
		keys = []string{"context_servers"}
	case "vscode":
		keys = []string{"servers"}
	}
	var current any = config
	for _, key := range keys {
		object, ok := current.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%s parent is not an object", key)
		}
		current, ok = object[key]
		if !ok {
			return nil, fmt.Errorf("missing %s object", key)
		}
	}
	container, ok := current.(map[string]any)
	if !ok {
		return nil, errors.New("MCP container is not an object")
	}
	return container, nil
}

func runPowerShellInstaller(shell, installer string, env []string, args ...string) ([]byte, error) {
	commandArgs := []string{"-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", installer}
	commandArgs = append(commandArgs, args...)
	command := exec.Command(shell, commandArgs...)
	command.Env = env
	return command.CombinedOutput()
}

func zipWindowsMCPFixture(destination, root, binary string) error {
	output, err := os.Create(destination)
	if err != nil {
		return err
	}
	archive := zip.NewWriter(output)
	entry, err := archive.Create(root + "/emisar-mcp.exe")
	if err == nil {
		var source *os.File
		source, err = os.Open(binary)
		if err == nil {
			_, err = io.Copy(entry, source)
			_ = source.Close()
		}
	}
	closeArchiveErr := archive.Close()
	closeFileErr := output.Close()
	if err != nil {
		return err
	}
	if closeArchiveErr != nil {
		return closeArchiveErr
	}
	return closeFileErr
}

func windowsInstallerAPIKey(seed byte) string {
	return "emk-" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{seed}, 32))
}

func slicesEqual(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
