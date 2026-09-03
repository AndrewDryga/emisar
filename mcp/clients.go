package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// The one list of LLM clients this bridge can configure. It replaces the
// per-installer tables the shell and PowerShell scripts each carried: the
// installers now place the binary and hand the connection phase here, so one
// table serves macOS, Linux, and Windows.

type configFormat int

const (
	formatJSON configFormat = iota
	formatTOML
	formatYAML
)

type clientAdapter struct {
	ID    string
	Label string

	format configFormat

	// JSON: the container path the client's own schema puts servers under, and
	// the entry it expects there.
	container []string
	entry     func(request clientEntryRequest) any

	// YAML: the client's top-level key. A block is appended only when the key is
	// absent, because merging into existing YAML risks a duplicate key.
	yamlTop string

	// file resolves the configuration file; marker resolves the path whose
	// existence means the client is installed (default: the file's directory).
	file   func(roots configRoots) string
	marker func(roots configRoots) string

	// envFile holds the API key outside a config file the client may sync.
	envFile func(roots configRoots) string

	// autoPermit silences this client's own per-tool prompt for the emisar
	// server alone. Empty means the client offers no server-scoped setting.
	autoPermit autoPermitKind
}

type autoPermitKind int

const (
	autoPermitNone autoPermitKind = iota
	autoPermitEntryTrust
	autoPermitEntryApprovalMode
	autoPermitClaudeSettings
	autoPermitGrokPermission
)

type clientEntryRequest struct {
	Command    string
	Origin     string
	APIKey     string
	ClientID   string
	EnvFile    string
	AutoPermit bool
}

// configRoots are the three directory roots these clients build paths from.
// appConfig is the platform's application-configuration directory, while
// dotConfig is a literal ~/.config that several cross-platform CLIs use even
// on macOS and Windows.
type configRoots struct {
	home      string
	appConfig string
	dotConfig string
}

func resolveConfigRoots(home string) configRoots {
	roots := configRoots{home: home, dotConfig: filepath.Join(home, ".config")}
	switch runtime.GOOS {
	case "darwin":
		roots.appConfig = filepath.Join(home, "Library", "Application Support")
	case "windows":
		if appData := os.Getenv("APPDATA"); appData != "" {
			roots.appConfig = appData
		} else {
			roots.appConfig = filepath.Join(home, "AppData", "Roaming")
		}
	default:
		if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
			roots.appConfig = xdg
		} else {
			roots.appConfig = roots.dotConfig
		}
	}
	return roots
}

func homePath(parts ...string) func(configRoots) string {
	return func(roots configRoots) string {
		return filepath.Join(append([]string{roots.home}, parts...)...)
	}
}

func appConfigPath(parts ...string) func(configRoots) string {
	return func(roots configRoots) string {
		return filepath.Join(append([]string{roots.appConfig}, parts...)...)
	}
}

func dotConfigPath(parts ...string) func(configRoots) string {
	return func(roots configRoots) string {
		return filepath.Join(append([]string{roots.dotConfig}, parts...)...)
	}
}

func standardEntry(request clientEntryRequest) any {
	return stdServerEntry{Command: request.Command, Env: newClientEnvBlock(request)}
}

// Gemini CLI is the only client whose own schema puts the auto-permit switch
// inside the server entry. Every other client here either keeps it elsewhere
// (Claude Code's settings.json, Grok's [permission] table) or has none, so
// `trust` goes in one entry rather than every entry — an operator's config is
// not a place to leave a key its client never defined.
func trustingEntry(request clientEntryRequest) any {
	return stdServerEntry{
		Command: request.Command,
		Env:     newClientEnvBlock(request),
		Trust:   request.AutoPermit,
	}
}

// clientAdapters is ordered the way the connection table is printed.
var clientAdapters = []clientAdapter{
	{
		ID:         "claude-code",
		Label:      "Claude Code",
		format:     formatJSON,
		container:  []string{"mcpServers"},
		entry:      standardEntry,
		file:       homePath(".claude.json"),
		marker:     homePath(".claude"),
		autoPermit: autoPermitClaudeSettings,
	},
	{
		ID:        "claude-desktop",
		Label:     "Claude Desktop",
		format:    formatJSON,
		container: []string{"mcpServers"},
		entry:     standardEntry,
		file:      appConfigPath("Claude", "claude_desktop_config.json"),
	},
	{
		ID:        "cursor",
		Label:     "Cursor",
		format:    formatJSON,
		container: []string{"mcpServers"},
		entry:     standardEntry,
		file:      homePath(".cursor", "mcp.json"),
	},
	{
		ID:        "vscode",
		Label:     "VS Code",
		format:    formatJSON,
		container: []string{"servers"},
		entry: func(request clientEntryRequest) any {
			return vscodeServerEntry{
				Type:    "stdio",
				Command: request.Command,
				Args:    []string{},
				EnvFile: request.EnvFile,
			}
		},
		file:    appConfigPath("Code", "User", "mcp.json"),
		marker:  appConfigPath("Code"),
		envFile: appConfigPath("emisar", "credentials", "vscode.env"),
	},
	{
		ID:         "gemini",
		Label:      "Gemini CLI",
		format:     formatJSON,
		container:  []string{"mcpServers"},
		entry:      trustingEntry,
		file:       homePath(".gemini", "settings.json"),
		autoPermit: autoPermitEntryTrust,
	},
	{
		ID:         "codex",
		Label:      "Codex CLI",
		format:     formatTOML,
		file:       homePath(".codex", "config.toml"),
		autoPermit: autoPermitEntryApprovalMode,
	},
	{
		ID:        "openclaw",
		Label:     "OpenClaw",
		format:    formatJSON,
		container: []string{"mcp", "servers"},
		entry:     standardEntry,
		file:      homePath(".openclaw", "openclaw.json"),
	},
	{
		ID:        "opencode",
		Label:     "OpenCode",
		format:    formatJSON,
		container: []string{"mcp"},
		entry: func(request clientEntryRequest) any {
			return opencodeServerEntry{
				Type:        "local",
				Command:     []string{request.Command},
				Enabled:     true,
				Environment: newClientEnvBlock(request),
			}
		},
		file: dotConfigPath("opencode", "opencode.json"),
	},
	{
		ID:        "windsurf",
		Label:     "Windsurf",
		format:    formatJSON,
		container: []string{"mcpServers"},
		entry:     standardEntry,
		file:      homePath(".codeium", "windsurf", "mcp_config.json"),
	},
	{
		ID:        "pi",
		Label:     "Pi",
		format:    formatJSON,
		container: []string{"mcpServers"},
		entry:     standardEntry,
		file:      homePath(".pi", "agent", "mcp.json"),
		marker:    homePath(".pi"),
	},
	{
		ID:        "copilot-cli",
		Label:     "Copilot CLI",
		format:    formatJSON,
		container: []string{"mcpServers"},
		entry: func(request clientEntryRequest) any {
			return copilotServerEntry{
				Type:    "local",
				Command: request.Command,
				Args:    []string{},
				Env:     newClientEnvBlock(request),
				Tools:   []string{"*"},
			}
		},
		file: homePath(".copilot", "mcp-config.json"),
	},
	{
		ID:        "zed",
		Label:     "Zed",
		format:    formatJSON,
		container: []string{"context_servers"},
		entry: func(request clientEntryRequest) any {
			return zedServerEntry{
				Source:  "custom",
				Command: request.Command,
				Args:    []string{},
				Env:     newClientEnvBlock(request),
			}
		},
		file: func(roots configRoots) string {
			if runtime.GOOS == "windows" {
				return filepath.Join(roots.appConfig, "Zed", "settings.json")
			}
			return filepath.Join(roots.dotConfig, "zed", "settings.json")
		},
	},
	{
		ID:      "hermes",
		Label:   "Hermes",
		format:  formatYAML,
		yamlTop: "mcp_servers",
		file:    homePath(".hermes", "config.yaml"),
	},
	{
		ID:      "goose",
		Label:   "Goose",
		format:  formatYAML,
		yamlTop: "extensions",
		file:    dotConfigPath("goose", "config.yaml"),
	},
	{
		ID:         "grok",
		Label:      "Grok CLI",
		format:     formatTOML,
		file:       homePath(".grok", "config.toml"),
		autoPermit: autoPermitGrokPermission,
	},
}

func lookupClientAdapter(id string) (clientAdapter, bool) {
	for _, adapter := range clientAdapters {
		if adapter.ID == id {
			return adapter, true
		}
	}
	return clientAdapter{}, false
}

func clientAdapterIDs() []string {
	ids := make([]string, 0, len(clientAdapters))
	for _, adapter := range clientAdapters {
		ids = append(ids, adapter.ID)
	}
	return ids
}

// detectedClient is one adapter resolved against this machine.
type detectedClient struct {
	clientAdapter
	ConfigFile  string
	EnvFilePath string
	Connected   bool
}

func (adapter clientAdapter) resolve(roots configRoots) detectedClient {
	client := detectedClient{clientAdapter: adapter, ConfigFile: adapter.file(roots)}
	if adapter.envFile != nil {
		client.EnvFilePath = adapter.envFile(roots)
	}
	client.Connected = adapter.configured(client.ConfigFile)
	return client
}

func (adapter clientAdapter) installed(roots configRoots) bool {
	if info, err := os.Stat(adapter.file(roots)); err == nil && info.Mode().IsRegular() {
		return true
	}
	marker := filepath.Dir(adapter.file(roots))
	if adapter.marker != nil {
		marker = adapter.marker(roots)
	}
	_, err := os.Stat(marker)
	return err == nil
}

var (
	tomlEmisarTable = regexp.MustCompile(`(?m)^[ \t]*\[mcp_servers\.emisar\][ \t]*$`)
	// Noncanonical but valid TOML spellings are refused rather than merged. The
	// tiny editor owns one spelling and must never append a semantic duplicate.
	tomlEmisarReference = regexp.MustCompile(`(?m)^[ \t]*(?:\[[^]\r\n]*mcp_servers[^]\r\n]*emisar[^]\r\n]*\][^\r\n]*|[^#\r\n]*mcp_servers[^#\r\n]*emisar[^#\r\n]*=)`)
	yamlEmisarEntry     = regexp.MustCompile(`(?m)^[ \t]+emisar:[ \t]*$`)
	jsonEmisarKey       = regexp.MustCompile(`"emisar"[ \t\r\n]*:`)
)

// configured reports whether the file already carries an emisar entry. A JSON
// document is inspected structurally; a document too malformed to scan falls
// back to the textual marker so an uninstall still notices the entry.
func (adapter clientAdapter) configured(path string) bool {
	raw, err := readConfigFile(path)
	if err != nil {
		return false
	}
	switch adapter.format {
	case formatTOML:
		return tomlEmisarTable.MatchString(raw)
	case formatYAML:
		return yamlEmisarEntry.MatchString(raw)
	}
	brace, depth, err := resolveJSONContainer(raw, adapter.container)
	if err != nil {
		return jsonEmisarKey.MatchString(raw)
	}
	if depth != len(adapter.container) {
		return false
	}
	_, found, err := findJSONMember(raw, brace, emisarServerName)
	if err != nil {
		return jsonEmisarKey.MatchString(raw)
	}
	return found
}

func readConfigFile(path string) (string, error) {
	if err := refuseConfigSymlink(path); err != nil {
		return "", err
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	if err := validateConfigFileIdentity(path, file); err != nil {
		return "", err
	}
	raw, err := readCappedBody(file, maxJSONConfigBytes)
	if err != nil {
		return "", err
	}
	// A Windows editor writes a UTF-8 BOM and VS Code, Cursor, and the TOML and
	// YAML clients all load such a file happily. Dropping it here is what lets
	// the textual editors below find the document at all; the canonical bytes
	// this bridge writes back simply do not carry one.
	return strings.TrimPrefix(string(raw), "\ufeff"), nil
}

func validateConfigFileIdentity(path string, file *os.File) error {
	opened, err := file.Stat()
	if err != nil {
		return err
	}
	named, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("%s changed while opening: %w", path, err)
	}
	if !opened.Mode().IsRegular() || !named.Mode().IsRegular() || !os.SameFile(opened, named) {
		return fmt.Errorf("%s changed while opening", path)
	}
	return nil
}

func refuseConfigSymlink(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink", path)
	}
	return nil
}

// readConfigSource reads a client config as the starting point for an edit: an
// absent file is the empty document every renderer builds on.
func readConfigSource(path string) (string, error) {
	raw, err := readConfigFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return raw, nil
}

// detectClients returns every supported client present on this machine.
func detectClients(roots configRoots) []detectedClient {
	clients := make([]detectedClient, 0, len(clientAdapters))
	for _, adapter := range clientAdapters {
		if adapter.installed(roots) {
			clients = append(clients, adapter.resolve(roots))
		}
	}
	return clients
}
