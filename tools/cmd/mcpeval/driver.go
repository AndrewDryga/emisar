package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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

func buildInvocation(cfg runConfig, item scenario, endpoint, workspace string) (invocation, error) {
	switch cfg.Provider {
	case "claude":
		return claudeInvocation(cfg, item, endpoint, workspace)
	case "codex":
		return codexInvocation(cfg, item, endpoint, workspace)
	default:
		return invocation{}, fmt.Errorf("unknown provider %q (want claude or codex)", cfg.Provider)
	}
}

// claudeInvocation runs Claude Code headless. Flags verified against the
// installed `claude --help` (2.1.212).
//
// The auth mode picks the isolation flag, and the two are mutually exclusive:
//   - CI (ANTHROPIC_API_KEY set) uses `--bare` — it forces clean API-key auth
//     and skips hooks, plugins, auto-memory, CLAUDE.md discovery, AND keychain
//     reads, while still honoring `--mcp-config`. This is the documented
//     headless path; without it the fuller startup left MCP unregistered under
//     API-key auth and the model role-played tool calls as text (calls=0).
//   - Local dev (no key) uses `--setting-sources project,local` — `--bare`
//     would force API-key auth and fail with no key, so instead we keep the
//     subscription keychain login while still isolating from the user's global
//     config (the throwaway workspace has no project/local settings).
//
// `--strict-mcp-config` limits MCP to our generated relay config and
// `--tools ""` disables every built-in tool, so the only tools are the relay's.
// `--dangerously-skip-permissions` is required, not optional: under API-key
// headless auth, `--allowedTools` did not pre-approve the MCP tools — Claude
// fetched the relay's tools/list (the handshake reaches the relay) but excluded
// them from the model's tool set pending an approval no headless run can give,
// so the model saw only the server name and role-played tool calls as text
// (calls=0, empty permission_denials — the tools were never offered, not
// denied). Skipping permissions is the same bypass the Codex lane needs for
// headless dispatch; the relay's fail-closed allowlist, not the agent's
// permission prompt, is the real security boundary here.
func claudeInvocation(cfg runConfig, item scenario, endpoint, workspace string) (invocation, error) {
	configPath, err := writeClaudeMCPConfig(workspace, endpoint)
	if err != nil {
		return invocation{}, err
	}
	isolation := []string{"--setting-sources", "project,local"}
	if os.Getenv("ANTHROPIC_API_KEY") != "" {
		isolation = []string{"--bare"}
	}
	args := []string{"-p", item.Prompt, "--output-format", "json", "--model", cfg.Model}
	args = append(args, isolation...)
	args = append(args,
		"--strict-mcp-config",
		"--mcp-config", configPath,
		"--tools", "",
		"--dangerously-skip-permissions",
		"--no-session-persistence",
		"--max-budget-usd", cfg.BudgetUSD,
	)
	return invocation{binary: cfg.Binary, args: args, env: childEnv("ANTHROPIC_API_KEY"), dir: workspace}, nil
}

func writeClaudeMCPConfig(workspace, endpoint string) (string, error) {
	config, err := json.Marshal(map[string]any{
		"mcpServers": map[string]any{
			"emisar_eval": map[string]any{"type": "http", "url": endpoint},
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

// codexInvocation runs Codex headless — a best-effort second provider. Flags
// verified against the installed `codex exec --help` (codex-cli 0.144.5):
// --ignore-user-config skips ~/.codex/config.toml (auth still resolves),
// --ephemeral persists no session files, --sandbox read-only confines
// model-generated shell commands, and the -c override registers the relay the
// same way `codex mcp add <name> --url <url>` writes it.
// run_action truthfully advertises non-readonly MCP annotations, and headless
// Codex synthesizes "user cancelled MCP tool call" for annotation-gated tools
// — the burn-in run scored clean discovery (get_action inspection threaded
// correctly) and zero dispatches. No supported config unlocks MCP approval alone
// (`--ask-for-approval` exists only on the top-level command, and
// `approval_policy="never"` governs shell commands), so dispatch requires the
// documented bypass flag, gated behind an explicit opt-in for externally
// sandboxed environments.
func codexInvocation(cfg runConfig, item scenario, endpoint, workspace string) (invocation, error) {
	args := []string{
		"exec",
		"--json",
		"--ephemeral",
		"--ignore-user-config",
		"--sandbox", "read-only",
		"--color", "never",
		"-c", fmt.Sprintf("mcp_servers.emisar_eval.url=%q", endpoint),
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
		if key == "CLAUDECODE" || hasAnyPrefix(key, "EMISAR_", "ANTHROPIC_", "OPENAI_", "CLAUDE_") {
			continue
		}
		env = append(env, item)
	}
	if keepValue != "" {
		env = append(env, keep+"="+keepValue)
	}
	return env
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
