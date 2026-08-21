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
	temp, err := os.MkdirTemp("", "emisar-mcp-windows-installtest-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)

	releaseDir := filepath.Join(temp, "release")
	archiveRoot := "emisar-mcp-" + windowsMCPVersion + "-windows-amd64"
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

	requested := []string(nil)
	cliKey := windowsInstallerAPIKey(1)
	cliReplacementKey := windowsInstallerAPIKey(3)
	explicitKey := windowsInstallerAPIKey(4)
	cursorKey := windowsInstallerAPIKey(2)
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
			_, _ = io.WriteString(writer, checksums)
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
			serverMu.Unlock()
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"account_id":   "018f0000-0000-7000-8000-000000000003",
				"account_slug": "windows-installer-test",
				"account_name": "Windows installer test",
				"client_keys": map[string]string{
					"emisar-mcp-cli": key,
					"cursor":         cursorKey,
				},
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
	cursorDir := filepath.Join(home, ".cursor")
	if err := os.MkdirAll(cursorDir, 0o700); err != nil {
		return err
	}
	cursorConfig := filepath.Join(cursorDir, "mcp.json")
	if err := os.WriteFile(cursorConfig, []byte("{\"theme\":\"dark\"}\n"), 0o600); err != nil {
		return err
	}
	env := map[string]string{
		"APPDATA":                      appData,
		"LOCALAPPDATA":                 localAppData,
		"USERPROFILE":                  home,
		"HOME":                         home,
		"EMISAR_ALLOW_INSECURE":        "1",
		"EMISAR_MCP_TEST_APPDATA":      appData,
		"EMISAR_MCP_TEST_BASE_URL":     server.URL,
		"EMISAR_MCP_TEST_HOME":         home,
		"EMISAR_MCP_TEST_LOCALAPPDATA": localAppData,
		"EMISAR_MCP_TEST_NO_BROWSER":   "1",
	}
	installer := filepath.Join(root, "install-mcp.ps1")
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
	if bytes.Contains(output, []byte(cliKey)) || bytes.Contains(output, []byte(cursorKey)) {
		return fmt.Errorf("installer output disclosed a delivered API key")
	}
	serverMu.Lock()
	firstRequested := append([]string(nil), requested...)
	firstDeviceGrants := deviceGrants
	serverMu.Unlock()
	if firstDeviceGrants != 1 || !slicesEqual(firstRequested, []string{"emisar-mcp-cli", "cursor"}) {
		return fmt.Errorf(
			"device grants = %d, requested clients = %v; want one grant for CLI and Cursor\n%s",
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
	configData, err := os.ReadFile(cursorConfig)
	if err != nil {
		return err
	}
	var config map[string]any
	if err := json.Unmarshal(configData, &config); err != nil {
		return fmt.Errorf("decode Cursor config: %w", err)
	}
	servers, serversOK := config["mcpServers"].(map[string]any)
	entry, entryOK := servers["emisar"].(map[string]any)
	clientEnv, envOK := entry["env"].(map[string]any)
	themeOK := config["theme"] == "dark"
	commandOK := entry["command"] == installed
	keyOK := clientEnv["EMISAR_API_KEY"] == cursorKey
	if !themeOK || !serversOK || !entryOK || !envOK || !commandOK || !keyOK {
		return fmt.Errorf(
			"Cursor config validation failed: theme=%t servers=%t entry=%t env=%t command=%t key=%t",
			themeOK,
			serversOK,
			entryOK,
			envOK,
			commandOK,
			keyOK,
		)
	}
	backupData, err := os.ReadFile(cursorConfig + ".emisar-bak")
	if err != nil || !bytes.Equal(backupData, []byte("{\"theme\":\"dark\"}\n")) {
		return fmt.Errorf("Cursor config backup did not preserve the original file: %w", err)
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
	if bytes.Contains(output, []byte(cliReplacementKey)) || bytes.Contains(output, []byte(explicitKey)) {
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
	configData, err = os.ReadFile(cursorConfig)
	if err != nil {
		return err
	}
	if !bytes.Contains(configData, []byte(`"theme": "dark"`)) || bytes.Contains(configData, []byte(`"emisar"`)) || bytes.Contains(configData, []byte(cursorKey)) {
		return fmt.Errorf("uninstall did not remove only the Emisar entry: %s", configData)
	}
	if _, err := os.Stat(credentials); !os.IsNotExist(err) {
		return fmt.Errorf("uninstall left CLI credentials: %v", err)
	}
	if _, err := os.Stat(cursorConfig + ".emisar-bak"); !os.IsNotExist(err) {
		return fmt.Errorf("uninstall left Cursor config backup: %v", err)
	}
	return nil
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
