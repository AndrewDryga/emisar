package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	emisarServerName    = "emisar"
	configBackupSuffix  = ".emisar-bak"
	claudeToolPattern   = "mcp__emisar__*"
	grokToolPermission  = "MCPTool(emisar__*)"
	codexApprovalOption = "default_tools_approval_mode"
)

// The entry each client's own schema expects. Field order is the struct's, so
// the written block reads the way the client's documentation shows it.

type clientEnvBlock struct {
	URL    string `json:"EMISAR_URL"`
	APIKey string `json:"EMISAR_API_KEY"`
	Client string `json:"EMISAR_CLIENT"`
}

func newClientEnvBlock(request clientEntryRequest) clientEnvBlock {
	return clientEnvBlock{URL: request.Origin, APIKey: request.APIKey, Client: request.ClientID}
}

type stdServerEntry struct {
	Command string         `json:"command"`
	Env     clientEnvBlock `json:"env"`
	Trust   bool           `json:"trust,omitempty"`
}

type opencodeServerEntry struct {
	Type        string         `json:"type"`
	Command     []string       `json:"command"`
	Enabled     bool           `json:"enabled"`
	Environment clientEnvBlock `json:"environment"`
}

type copilotServerEntry struct {
	Type    string         `json:"type"`
	Command string         `json:"command"`
	Args    []string       `json:"args"`
	Env     clientEnvBlock `json:"env"`
	Tools   []string       `json:"tools"`
}

type zedServerEntry struct {
	Source  string         `json:"source"`
	Command string         `json:"command"`
	Args    []string       `json:"args"`
	Env     clientEnvBlock `json:"env"`
}

type vscodeServerEntry struct {
	Type    string   `json:"type"`
	Command string   `json:"command"`
	Args    []string `json:"args"`
	EnvFile string   `json:"envFile"`
}

// Every value below lands inside a JSON, TOML, or YAML string literal. JSON is
// escaped by encoding/json, and TOML basic strings and YAML double-quoted
// scalars both accept that exact escape set — so one quoting helper serves all
// three. A control byte is refused outright rather than escaped: a value
// carrying one is not something the portal or an install path produces, and a
// config file that can name a second `command` is a code-execution surface.
var configControlBytes = regexp.MustCompile(`[\x00-\x1f\x7f]`)

func safeConfigValue(value string) bool {
	return value != "" && !configControlBytes.MatchString(value)
}

func quoteConfigString(value string) (string, error) {
	if !safeConfigValue(value) {
		return "", fmt.Errorf("unsupported characters in config value")
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

func (request clientEntryRequest) validate() error {
	for _, value := range []string{request.Command, request.Origin, request.APIKey, request.ClientID} {
		if !safeConfigValue(value) {
			return errors.New("a connection value contains unsupported characters")
		}
	}
	if request.EnvFile != "" && !safeConfigValue(request.EnvFile) {
		return errors.New("a connection value contains unsupported characters")
	}
	return nil
}

// install writes this client's emisar entry, backing up an existing file first.
func (client detectedClient) install(request clientEntryRequest) error {
	request.EnvFile = client.EnvFilePath
	if err := request.validate(); err != nil {
		return err
	}
	// Refuse before writing a separate env file, so a hostile source cannot
	// leave credentials behind after an otherwise failed install.
	if err := refuseConfigSymlink(client.ConfigFile); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(client.ConfigFile), 0o700); err != nil {
		return err
	}
	if client.EnvFilePath != "" {
		if err := writeClientEnvFile(client.EnvFilePath, request); err != nil {
			return err
		}
	}
	if fileHasContent(client.ConfigFile) {
		if err := backupConfigFile(client.ConfigFile); err != nil {
			return err
		}
	}
	switch client.format {
	case formatTOML:
		return client.installTOML(request)
	case formatYAML:
		return client.installYAML(request)
	default:
		return client.installJSON(request)
	}
}

func (client detectedClient) installJSON(request clientEntryRequest) error {
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	entry := client.entry(request)
	edited, err := insertJSONMember(raw, client.container, emisarServerName, entry)
	if err != nil {
		return err
	}
	document, err := parseJSONConfig(edited)
	if err != nil {
		return fmt.Errorf("the edited config is not valid JSON: %w", err)
	}
	written, ok := lookupJSONPath(document, client.container, emisarServerName)
	if !ok || !sameJSONValue(written, entry) {
		return errors.New("the emisar entry did not survive the edit")
	}
	return writeConfigFile(client.ConfigFile, edited)
}

func (client detectedClient) installTOML(request clientEntryRequest) error {
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if tomlEmisarTable.MatchString(raw) {
		return nil
	}
	command, err := quoteConfigString(request.Command)
	if err != nil {
		return err
	}
	origin, err := quoteConfigString(request.Origin)
	if err != nil {
		return err
	}
	key, err := quoteConfigString(request.APIKey)
	if err != nil {
		return err
	}
	id, err := quoteConfigString(request.ClientID)
	if err != nil {
		return err
	}
	var block strings.Builder
	block.WriteString("[mcp_servers.emisar]\n")
	fmt.Fprintf(&block, "command = %s\n", command)
	fmt.Fprintf(&block, "env = { EMISAR_URL = %s, EMISAR_API_KEY = %s, EMISAR_CLIENT = %s }\n", origin, key, id)
	if request.AutoPermit && client.autoPermit == autoPermitEntryApprovalMode {
		fmt.Fprintf(&block, "%s = \"approve\"\n", codexApprovalOption)
	}
	return writeConfigFile(client.ConfigFile, appendConfigBlock(raw, block.String()))
}

func (client detectedClient) installYAML(request clientEntryRequest) error {
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// Appending a whole top-level key is always valid; merging into an existing
	// one risks a duplicate key, so that case takes the manual snippet instead.
	if regexp.MustCompile(`(?m)^` + regexp.QuoteMeta(client.yamlTop) + `:`).MatchString(raw) {
		return fmt.Errorf("this config already defines %s", client.yamlTop)
	}
	command, err := quoteConfigString(request.Command)
	if err != nil {
		return err
	}
	origin, err := quoteConfigString(request.Origin)
	if err != nil {
		return err
	}
	key, err := quoteConfigString(request.APIKey)
	if err != nil {
		return err
	}
	id, err := quoteConfigString(request.ClientID)
	if err != nil {
		return err
	}
	var block strings.Builder
	if client.ID == "hermes" {
		block.WriteString("mcp_servers:\n  emisar:\n")
		fmt.Fprintf(&block, "    command: %s\n", command)
		block.WriteString("    env:\n")
		fmt.Fprintf(&block, "      EMISAR_URL: %s\n", origin)
		fmt.Fprintf(&block, "      EMISAR_API_KEY: %s\n", key)
		fmt.Fprintf(&block, "      EMISAR_CLIENT: %s\n", id)
	} else {
		block.WriteString("extensions:\n  emisar:\n    name: emisar\n")
		fmt.Fprintf(&block, "    cmd: %s\n", command)
		block.WriteString("    args: []\n    enabled: true\n    envs:\n")
		fmt.Fprintf(&block, "      EMISAR_URL: %s\n", origin)
		fmt.Fprintf(&block, "      EMISAR_API_KEY: %s\n", key)
		fmt.Fprintf(&block, "      EMISAR_CLIENT: %s\n", id)
		block.WriteString("    type: stdio\n    timeout: 300\n")
	}
	return writeConfigFile(client.ConfigFile, appendConfigBlock(raw, block.String()))
}

func appendConfigBlock(raw, block string) string {
	if strings.TrimSpace(raw) == "" {
		return block
	}
	return strings.TrimRight(raw, "\n") + "\n\n" + block
}

// remove drops this client's emisar entry and the backup the install left.
func (client detectedClient) remove() error {
	raw, err := readConfigFile(client.ConfigFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	var edited string
	switch client.format {
	case formatTOML:
		edited = removeTOMLTable(raw)
	case formatYAML:
		edited = removeYAMLEntry(raw, client.yamlTop)
	default:
		edited, _, err = removeJSONMember(raw, client.container, emisarServerName)
		if err != nil {
			return err
		}
		if _, parseErr := parseJSONConfig(edited); parseErr != nil {
			return fmt.Errorf("the edited config is not valid JSON: %w", parseErr)
		}
	}
	if edited != raw {
		if err := writeConfigFile(client.ConfigFile, edited); err != nil {
			return err
		}
	}
	if client.configured(client.ConfigFile) {
		return errors.New("the emisar entry is still present")
	}
	if client.EnvFilePath != "" {
		if err := os.Remove(client.EnvFilePath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := os.Remove(client.ConfigFile + configBackupSuffix); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// removeTOMLTable drops [mcp_servers.emisar] and its child tables through the
// next unrelated table header. A client's own CLI may have written the env as a
// child table where this bridge writes an inline one.
var tomlEmisarHeader = regexp.MustCompile(`^\[mcp_servers\.emisar(\.[^\]]+)?\][ \t]*$`)

func removeTOMLTable(raw string) string {
	lines := strings.Split(raw, "\n")
	kept := make([]string, 0, len(lines))
	skipping := false
	for _, line := range lines {
		trimmed := strings.TrimRight(line, "\r")
		switch {
		case tomlEmisarHeader.MatchString(trimmed):
			skipping = true
			continue
		case strings.HasPrefix(trimmed, "["):
			skipping = false
		}
		if !skipping {
			kept = append(kept, line)
		}
	}
	return strings.Join(kept, "\n")
}

// removeYAMLEntry drops the emisar entry under the client's top-level key, and
// the key itself once it has no other children so a later connect can append.
func removeYAMLEntry(raw, top string) string {
	lines := strings.Split(raw, "\n")
	kept := make([]string, 0, len(lines))
	inTop := false
	skipIndent := -1
	for _, line := range lines {
		trimmed := strings.TrimRight(line, "\r")
		indent := len(trimmed) - len(strings.TrimLeft(trimmed, " \t"))
		if skipIndent >= 0 {
			if strings.TrimSpace(trimmed) == "" || indent > skipIndent {
				continue
			}
			skipIndent = -1
		}
		if strings.TrimSpace(trimmed) != "" && indent == 0 {
			inTop = strings.HasPrefix(trimmed, top+":")
		}
		if inTop && indent > 0 && strings.TrimSpace(trimmed) == "emisar:" {
			skipIndent = indent
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(dropEmptyYAMLKey(kept, top), "\n")
}

func dropEmptyYAMLKey(lines []string, top string) []string {
	kept := make([]string, 0, len(lines))
	for index, line := range lines {
		if strings.TrimRight(line, " \t\r") == top+":" {
			next := index + 1
			for next < len(lines) && strings.TrimSpace(lines[next]) == "" {
				next++
			}
			if next >= len(lines) || len(lines[next]) == len(strings.TrimLeft(lines[next], " \t")) {
				continue
			}
		}
		kept = append(kept, line)
	}
	return kept
}

// applyAutoPermit silences a client's own "allow this tool?" prompt for the
// emisar server alone. Codex and Gemini carry the setting inside the entry this
// run already wrote, so only the two clients that keep it elsewhere land here.
func (client detectedClient) applyAutoPermit(roots configRoots) error {
	switch client.autoPermit {
	case autoPermitClaudeSettings:
		return editClaudePermission(filepath.Join(roots.home, ".claude", "settings.json"), true)
	case autoPermitGrokPermission:
		return addGrokPermission(client.ConfigFile)
	default:
		return nil
	}
}

func (client detectedClient) removeAutoPermit(roots configRoots) error {
	switch client.autoPermit {
	case autoPermitClaudeSettings:
		return editClaudePermission(filepath.Join(roots.home, ".claude", "settings.json"), false)
	case autoPermitGrokPermission:
		return removeGrokPermission(client.ConfigFile)
	default:
		return nil
	}
}

// editClaudePermission adds or removes our one entry in Claude Code's own
// settings file. Whatever else is allowed stays allowed, and an emptied list is
// left in place — the shape is the operator's, not ours to tidy.
func editClaudePermission(path string, allow bool) error {
	raw, err := readConfigFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if !allow {
				return nil
			}
			raw = ""
		} else {
			return err
		}
	}
	if allow {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return err
		}
		if strings.TrimSpace(raw) != "" {
			if err := backupConfigFile(path); err != nil {
				return err
			}
		}
	}
	document, err := parseJSONConfig(raw)
	if err != nil {
		return err
	}
	entries, err := claudeAllowList(document)
	if err != nil {
		return err
	}
	updated := make([]string, 0, len(entries)+1)
	present := false
	for _, entry := range entries {
		if entry == claudeToolPattern {
			present = true
			continue
		}
		updated = append(updated, entry)
	}
	if !allow && !present {
		// Our rule is not here. Writing anyway would add a permissions block to
		// a file that never had one, which is not what a removal does.
		return nil
	}
	if allow {
		updated = append(updated, claudeToolPattern)
	}
	edited, err := insertJSONMember(raw, []string{"permissions"}, "allow", updated)
	if err != nil {
		return err
	}
	return writeConfigFile(path, edited)
}

func claudeAllowList(document map[string]any) ([]string, error) {
	permissions, ok := document["permissions"]
	if !ok {
		return nil, nil
	}
	block, ok := permissions.(map[string]any)
	if !ok {
		return nil, errors.New("permissions is not an object")
	}
	allow, ok := block["allow"]
	if !ok {
		return nil, nil
	}
	list, ok := allow.([]any)
	if !ok {
		return nil, errors.New("permissions.allow is not a list")
	}
	entries := make([]string, 0, len(list))
	for _, item := range list {
		text, ok := item.(string)
		if !ok {
			return nil, errors.New("permissions.allow holds a non-string entry")
		}
		entries = append(entries, text)
	}
	return entries, nil
}

// Grok keeps tool permissions in its own [permission] table. A second one is
// invalid TOML, and hand-merging into an existing allow array is the kind of
// edit that silently corrupts a config we do not own — so an existing table is
// left untouched and the caller prints the manual snippet instead.
var grokPermissionTable = regexp.MustCompile(`(?m)^[ \t]*\[permission\][ \t]*$`)

func addGrokPermission(path string) error {
	raw, err := readConfigFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if strings.Contains(raw, grokToolPermission) {
		return nil
	}
	if grokPermissionTable.MatchString(raw) {
		return errors.New("this config already defines [permission]")
	}
	block := fmt.Sprintf("[permission]\nallow = [%q]\n", grokToolPermission)
	return writeConfigFile(path, appendConfigBlock(raw, block))
}

func removeGrokPermission(path string) error {
	raw, err := readConfigFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if !strings.Contains(raw, grokToolPermission) {
		return nil
	}
	entry := fmt.Sprintf("allow = [%q]", grokToolPermission)
	lines := strings.Split(raw, "\n")
	kept := make([]string, 0, len(lines))
	for index := 0; index < len(lines); index++ {
		trimmed := strings.TrimRight(lines[index], "\r")
		// Only the table this bridge appended goes: our single entry directly
		// under the header. An operator who added their own rules keeps it.
		if strings.TrimSpace(trimmed) == "[permission]" && index+1 < len(lines) &&
			strings.TrimSpace(strings.TrimRight(lines[index+1], "\r")) == entry {
			index++
			continue
		}
		kept = append(kept, lines[index])
	}
	edited := strings.Join(kept, "\n")
	if strings.Contains(edited, grokToolPermission) {
		return errors.New("the [permission] table carries other rules")
	}
	return writeConfigFile(path, edited)
}

// writeClientEnvFile keeps a syncable editor config free of the API key: the
// key lives beside the bridge's own credential state instead.
func writeClientEnvFile(path string, request clientEntryRequest) error {
	directory := filepath.Dir(path)
	for _, candidate := range []string{filepath.Dir(directory), directory, path} {
		if info, err := os.Lstat(candidate); err == nil && info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s is a symlink", candidate)
		}
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return err
	}
	body := fmt.Sprintf(
		"EMISAR_URL=%s\nEMISAR_API_KEY=%s\nEMISAR_CLIENT=%s\n",
		request.Origin, request.APIKey, request.ClientID,
	)
	return writeConfigFile(path, body)
}

// writeConfigFile stages beside the target and renames. A plain write would
// follow a destination symlink; a rename replaces the link itself.
func writeConfigFile(path, contents string) error {
	directory := filepath.Dir(path)
	staged, err := os.CreateTemp(directory, ".emisar-mcp.*")
	if err != nil {
		return err
	}
	stagedPath := staged.Name()
	defer os.Remove(stagedPath)
	if _, err := staged.WriteString(contents); err != nil {
		staged.Close()
		return err
	}
	if err := staged.Chmod(0o600); err != nil {
		staged.Close()
		return err
	}
	if err := staged.Sync(); err != nil {
		staged.Close()
		return err
	}
	if err := staged.Close(); err != nil {
		return err
	}
	return os.Rename(stagedPath, path)
}

func backupConfigFile(path string) error {
	raw, err := readConfigFile(path)
	if err != nil {
		return err
	}
	return writeConfigFile(path+configBackupSuffix, raw)
}
