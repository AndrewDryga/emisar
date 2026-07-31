package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// invocation is the fully-constructed agent subprocess: binary, argv,
// stripped environment, and the throwaway workspace it runs in.
type invocation struct {
	binary string
	args   []string
	env    []string
	dir    string
}

func buildInvocation(
	cfg runConfig,
	item scenario,
	relayOrigin, relayCredential, workspace string,
) (invocation, error) {
	switch cfg.Provider {
	case "claude":
		return claudeInvocation(cfg, item, relayOrigin, relayCredential, workspace)
	case "codex":
		return codexInvocation(cfg, item, relayOrigin, relayCredential, workspace)
	case "gemini":
		return geminiInvocation(cfg, item, relayOrigin, relayCredential, workspace)
	case "grok":
		return grokInvocation(cfg, item, relayOrigin, relayCredential, workspace)
	default:
		return invocation{}, fmt.Errorf("unknown provider %q (want claude, codex, gemini, or grok)", cfg.Provider)
	}
}

// claudeInvocation runs Claude Code headless. Flags verified against the
// installed `claude --help` (2.1.217).
//
// Both auth modes use `--setting-sources project,local`. The throwaway
// workspace has neither source, so CI still starts clean and authenticates
// from ANTHROPIC_API_KEY while local development can use the keychain.
// `--bare` is intentionally absent: repeated API-key certification runs
// completed normally but offered the model none of the explicit MCP tools.
//
// `--strict-mcp-config` limits MCP to our generated bridge config. Keep only
// the read-only `Read` built-in; the throwaway workspace contains only the
// generated bridge config, and the relay remains the fail-closed boundary for
// Emisar calls. Claude defers MCP tools behind its built-in ToolSearch by
// default, so the restricted tool set must pair with ENABLE_TOOL_SEARCH=false,
// which loads the explicit MCP tools up front.
// `--dangerously-skip-permissions` is required, not optional: under API-key
// headless auth, `--allowedTools` did not pre-approve the MCP tools — Claude
// fetched the relay's tools/list (the handshake reaches the relay) but excluded
// them from the model's tool set pending an approval no headless run can give,
// so the model saw only the server name and role-played tool calls as text
// (calls=0, empty permission_denials — the tools were never offered, not
// denied). Skipping permissions is the same bypass the Codex lane needs for
// headless dispatch; the relay's fail-closed allowlist, not the agent's
// permission prompt, is the real security boundary here.
func claudeInvocation(
	cfg runConfig,
	item scenario,
	relayOrigin, relayCredential, workspace string,
) (invocation, error) {
	configPath, err := writeClaudeMCPConfig(cfg, workspace, relayOrigin, relayCredential)
	if err != nil {
		return invocation{}, err
	}
	args := []string{"-p", item.Prompt, "--output-format", "json", "--model", cfg.Model}
	args = append(args,
		"--setting-sources", "project,local",
		"--strict-mcp-config",
		"--mcp-config", configPath,
		"--tools", "Read",
		"--dangerously-skip-permissions",
		"--no-session-persistence",
		"--max-budget-usd", cfg.BudgetUSD,
	)
	env := replaceEnv(childEnv("ANTHROPIC_API_KEY"), "ENABLE_TOOL_SEARCH", "false")
	return invocation{binary: cfg.Binary, args: args, env: env, dir: workspace}, nil
}

func writeClaudeMCPConfig(
	cfg runConfig,
	workspace, relayOrigin, relayCredential string,
) (string, error) {
	config, err := json.Marshal(map[string]any{
		"mcpServers": map[string]any{
			"emisar_eval": map[string]any{
				"type":    "stdio",
				"command": cfg.BridgeBinary,
				"args":    []string{},
				"env":     bridgeEnv(relayOrigin, relayCredential, cfg.Provider),
			},
		},
	})
	if err != nil {
		return "", err
	}
	path := filepath.Join(workspace, "mcp-eval.json")
	if err := os.WriteFile(path, append(config, '\n'), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

// codexInvocation runs Codex headless as one required certification lane. Flags
// verified against the installed `codex exec --help` (codex-cli 0.145.0):
// --ignore-user-config skips ~/.codex/config.toml (auth still resolves),
// --ephemeral persists no session files, --sandbox read-only confines
// model-generated shell commands, and the -c overrides register the exact
// candidate stdio bridge without reading a user's MCP configuration.
// run_action truthfully advertises non-readonly MCP annotations, and headless
// Codex synthesizes "user cancelled MCP tool call" for annotation-gated tools
// — the burn-in run scored clean discovery (get_action inspection threaded
// correctly) and zero dispatches. No supported config unlocks MCP approval alone
// (`--ask-for-approval` exists only on the top-level command, and
// `approval_policy="never"` governs shell commands), so dispatch requires the
// documented bypass flag, gated behind an explicit opt-in for externally
// sandboxed environments.
func codexInvocation(
	cfg runConfig,
	item scenario,
	relayOrigin, relayCredential, workspace string,
) (invocation, error) {
	args := []string{
		"exec",
		"--json",
		"--ephemeral",
		"--ignore-user-config",
		"--sandbox", "read-only",
		"--color", "never",
		"-c", "mcp_servers.emisar_eval.command=" + strconv.Quote(cfg.BridgeBinary),
		"-c", "mcp_servers.emisar_eval.env=" +
			tomlInlineTable(bridgeEnv(relayOrigin, relayCredential, cfg.Provider)),
	}
	if cfg.CodexBypassSandbox {
		args = append(args, "--dangerously-bypass-approvals-and-sandbox")
	}
	if cfg.Model != "" {
		args = append(args, "--model", cfg.Model)
	}
	args = append(args, item.Prompt)
	return invocation{binary: cfg.Binary, args: args, env: childEnv("OPENAI_API_KEY"), dir: workspace}, nil
}

// geminiInvocation runs Gemini CLI headless with a project-local settings file.
// Flags and the stdio MCP shape are verified against Gemini CLI 0.50.0. An
// explicit empty core-tool list leaves only MCP meta-tools available.
func geminiInvocation(
	cfg runConfig,
	item scenario,
	relayOrigin, relayCredential, workspace string,
) (invocation, error) {
	if err := writeGeminiConfig(cfg, workspace, relayOrigin, relayCredential); err != nil {
		return invocation{}, err
	}
	args := []string{
		"-p", item.Prompt,
		"--output-format", "json",
		"--skip-trust",
		"--approval-mode", "yolo",
		"--allowed-mcp-server-names", "emisar_eval",
	}
	if cfg.Model != "" {
		args = append(args, "--model", cfg.Model)
	}
	return invocation{
		binary: cfg.Binary,
		args:   args,
		env:    isolatedChildEnv("GEMINI_API_KEY", workspace),
		dir:    workspace,
	}, nil
}

func writeGeminiConfig(
	cfg runConfig,
	workspace, relayOrigin, relayCredential string,
) error {
	config, err := json.Marshal(map[string]any{
		"tools": map[string]any{"core": []string{}},
		"mcpServers": map[string]any{
			"emisar_eval": map[string]any{
				"command": cfg.BridgeBinary,
				"args":    []string{},
				"env":     bridgeEnv(relayOrigin, relayCredential, cfg.Provider),
				"trust":   true,
			},
		},
	})
	if err != nil {
		return err
	}
	dir := filepath.Join(workspace, ".gemini")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "settings.json"), append(config, '\n'), 0o600)
}

// grokInvocation runs Grok Build headless. Flags and the project MCP TOML are
// verified against Grok 0.2.101. `--tools ""` removes built-ins while Grok's
// documented always-on MCP meta-tools remain available.
func grokInvocation(
	cfg runConfig,
	item scenario,
	relayOrigin, relayCredential, workspace string,
) (invocation, error) {
	if err := writeGrokConfig(cfg, workspace, relayOrigin, relayCredential); err != nil {
		return invocation{}, err
	}
	args := []string{
		"-p", item.Prompt,
		"--output-format", "json",
		"--yolo",
		"--tools", "",
		"--no-subagents",
		"--no-memory",
		"--disable-web-search",
		"--no-auto-update",
	}
	if cfg.Model != "" {
		args = append(args, "--model", cfg.Model)
	}
	env := isolatedChildEnv("XAI_API_KEY", workspace)
	env = replaceEnv(env, "GROK_HOME", filepath.Join(workspace, ".grok-home"))
	return invocation{binary: cfg.Binary, args: args, env: env, dir: workspace}, nil
}

func writeGrokConfig(
	cfg runConfig,
	workspace, relayOrigin, relayCredential string,
) error {
	dir := filepath.Join(workspace, ".grok")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	content := "[mcp_servers.emisar_eval]\n" +
		"command = " + strconv.Quote(cfg.BridgeBinary) + "\n" +
		"args = []\n" +
		"env = " + tomlInlineTable(bridgeEnv(relayOrigin, relayCredential, cfg.Provider)) + "\n" +
		"enabled = true\n"
	return os.WriteFile(filepath.Join(dir, "config.toml"), []byte(content), 0o600)
}

func bridgeEnv(relayOrigin, relayCredential, provider string) map[string]string {
	return map[string]string{
		"EMISAR_URL":     relayOrigin,
		"EMISAR_API_KEY": relayCredential,
		"EMISAR_CLIENT":  provider,
	}
}

func tomlInlineTable(values map[string]string) string {
	keys := []string{"EMISAR_URL", "EMISAR_API_KEY", "EMISAR_CLIENT"}
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+strconv.Quote(values[key]))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

// childEnv strips every Emisar and provider credential from the inherited
// environment, then re-adds only the one key the launched agent itself needs.
// The Emisar API key stays relay-side: the agent process can never read it.
func childEnv(keep string) []string {
	keepValue := ""
	env := make([]string, 0, len(os.Environ()))
	for _, item := range os.Environ() {
		key, value, _ := strings.Cut(item, "=")
		if key == keep {
			keepValue = value
			continue
		}
		if key == "CLAUDECODE" || hasAnyPrefix(
			key,
			"EMISAR_",
			"ANTHROPIC_",
			"OPENAI_",
			"CLAUDE_",
			"GEMINI_",
			"GOOGLE_",
			"XAI_",
			"GROK_",
		) {
			continue
		}
		env = append(env, item)
	}
	if keepValue != "" {
		env = append(env, keep+"="+keepValue)
	}
	return env
}

func isolatedChildEnv(keep, workspace string) []string {
	return replaceEnv(childEnv(keep), "HOME", filepath.Join(workspace, "home"))
}

func replaceEnv(env []string, key, value string) []string {
	prefix := key + "="
	out := make([]string, 0, len(env)+1)
	for _, item := range env {
		if !strings.HasPrefix(item, prefix) {
			out = append(out, item)
		}
	}
	return append(out, prefix+value)
}

func hasAnyPrefix(value string, prefixes ...string) bool {
	for _, prefix := range prefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}

// runAgent executes the agent to completion, capturing bounded output. A
// missing binary is a harness error; a nonzero exit or timeout is recorded in
// the result and scored.
func runAgent(ctx context.Context, inv invocation) (agentResult, error) {
	cmd := exec.CommandContext(ctx, inv.binary, inv.args...)
	cmd.Dir = inv.dir
	cmd.Env = inv.env
	cmd.WaitDelay = 10 * time.Second // let pipes drain after a kill instead of hanging Wait
	stdout := &boundedBuffer{limit: maxAgentStdoutBytes}
	stderr := &boundedBuffer{limit: maxAgentStderrBytes}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	result := agentResult{
		Binary: inv.binary, Args: inv.args,
		Stdout: stdout.String(), StdoutTruncated: stdout.Truncated(),
		Stderr: stderr.String(), StderrTruncated: stderr.Truncated(),
	}
	switch {
	case err == nil:
	case ctx.Err() != nil:
		result.TimedOut = true
		result.ExitCode = -1
	default:
		var exitError *exec.ExitError
		if !errors.As(err, &exitError) {
			return agentResult{}, fmt.Errorf("start agent %s: %w", inv.binary, err)
		}
		result.ExitCode = exitError.ExitCode()
	}
	return result, nil
}

func executableVersion(binary string) (string, error) {
	output, err := exec.Command(binary, "--version").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s --version: %w: %s", binary, err, boundedText(output, 4096))
	}
	return strings.TrimSpace(boundedText(output, 4096)), nil
}

func boundedText(value []byte, limit int) string {
	if len(value) > limit {
		value = value[:limit]
	}
	return string(value)
}

// boundedBuffer keeps the first limit bytes and drops the rest, so a runaway
// agent cannot balloon the report.
type boundedBuffer struct {
	mu        sync.Mutex
	buf       strings.Builder
	limit     int
	truncated bool
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	remaining := b.limit - b.buf.Len()
	if remaining > 0 {
		write := p
		if len(write) > remaining {
			write = write[:remaining]
		}
		_, _ = b.buf.Write(write)
	}
	if len(p) > remaining {
		b.truncated = true
	}
	return len(p), nil
}

func (b *boundedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *boundedBuffer) Truncated() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.truncated
}
