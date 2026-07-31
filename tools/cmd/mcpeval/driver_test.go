package main

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestClaudeInvocationPinsVerifiedFlags(t *testing.T) {
	item := scenario{Prompt: "inspect the fleet", AllowedTools: []string{"list_runners", "run_action"}}
	cfg := runConfig{
		Provider: "claude", Binary: "claude", BridgeBinary: "/tmp/emisar-mcp",
		Model: "claude-sonnet-4-5", BudgetUSD: "10",
	}
	// API-key CI and local keychain auth use the same isolated startup. The
	// throwaway workspace has no project/local settings, and bypassing the
	// interactive permission prompt lets headless mode invoke the relay tools.
	for _, name := range []string{"local keychain (no key)", "CI api key"} {
		t.Run(name, func(t *testing.T) {
			if name == "CI api key" {
				t.Setenv("ANTHROPIC_API_KEY", "sk-ant-present")
			} else {
				t.Setenv("ANTHROPIC_API_KEY", "")
			}
			workspace := t.TempDir()
			got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999", "eval-token", workspace)
			if err != nil {
				t.Fatal(err)
			}
			configPath := filepath.Join(workspace, "mcp-eval.json")
			want := []string{"-p", "inspect the fleet", "--output-format", "json", "--model", "claude-sonnet-4-5"}
			want = append(want,
				"--setting-sources", "project,local",
				"--strict-mcp-config",
				"--mcp-config", configPath,
				"--tools", "Read",
				"--dangerously-skip-permissions",
				"--no-session-persistence",
				"--max-budget-usd", "10",
			)
			if got.binary != "claude" || !reflect.DeepEqual(got.args, want) {
				t.Fatalf("claude argv = %q %#v", got.binary, got.args)
			}
			config, err := os.ReadFile(configPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(config) != `{"mcpServers":{"emisar_eval":{"args":[],"command":"/tmp/emisar-mcp","env":{"EMISAR_API_KEY":"eval-token","EMISAR_CLIENT":"claude","EMISAR_URL":"http://127.0.0.1:9999"},"type":"stdio"}}}`+"\n" {
				t.Fatalf("mcp config = %s", config)
			}
		})
	}
}

func TestCodexInvocationRegistersCandidateBridgeAndPinsModel(t *testing.T) {
	item := scenario{Prompt: "inspect the fleet"}
	base := []string{
		"exec", "--json", "--ephemeral", "--ignore-user-config",
		"--sandbox", "read-only", "--color", "never",
		"-c", `mcp_servers.emisar_eval.command="/tmp/emisar-mcp"`,
		"-c", `mcp_servers.emisar_eval.env={EMISAR_URL="http://127.0.0.1:9999",EMISAR_API_KEY="eval-token",EMISAR_CLIENT="codex"}`,
	}
	for model, want := range map[string][]string{
		"":        append(append([]string{}, base...), "inspect the fleet"),
		"gpt-5.1": append(append([]string{}, base...), "--model", "gpt-5.1", "inspect the fleet"),
	} {
		cfg := runConfig{Provider: "codex", Binary: "codex", BridgeBinary: "/tmp/emisar-mcp", Model: model}
		got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999", "eval-token", t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(got.args, want) {
			t.Fatalf("codex argv (model %q) = %#v", model, got.args)
		}
	}
}

func TestCodexInvocationBypassIsExplicitOptIn(t *testing.T) {
	item := scenario{Prompt: "inspect the fleet"}
	cfg := runConfig{Provider: "codex", Binary: "codex", BridgeBinary: "/tmp/emisar-mcp", CodexBypassSandbox: true}
	got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999", "eval-token", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(got.args, " ")
	if !strings.Contains(joined, "--dangerously-bypass-approvals-and-sandbox") {
		t.Fatalf("bypass opt-in missing from argv: %#v", got.args)
	}
}

func TestBuildInvocationRejectsUnknownProvider(t *testing.T) {
	if _, err := buildInvocation(runConfig{Provider: "other"}, scenario{}, "http://127.0.0.1:1", "token", t.TempDir()); err == nil {
		t.Fatal("unknown provider was accepted")
	}
}

func TestGeminiInvocationUsesIsolatedProjectBridgeAndNoCoreTools(t *testing.T) {
	t.Setenv("GEMINI_API_KEY", "gemini-secret")
	workspace := t.TempDir()
	cfg := runConfig{Provider: "gemini", Binary: "gemini", BridgeBinary: "/tmp/emisar-mcp", Model: "gemini-test"}
	got, err := buildInvocation(
		cfg,
		scenario{Prompt: "inspect the fleet"},
		"http://127.0.0.1:9999",
		"eval-token",
		workspace,
	)
	if err != nil {
		t.Fatal(err)
	}
	wantArgs := []string{
		"-p", "inspect the fleet", "--output-format", "json", "--skip-trust",
		"--approval-mode", "yolo", "--allowed-mcp-server-names", "emisar_eval",
		"--model", "gemini-test",
	}
	if !reflect.DeepEqual(got.args, wantArgs) {
		t.Fatalf("gemini argv = %#v", got.args)
	}
	config, err := os.ReadFile(filepath.Join(workspace, ".gemini", "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(config), `"core":[]`) ||
		!strings.Contains(string(config), `"/tmp/emisar-mcp"`) {
		t.Fatalf("gemini config = %s", config)
	}
	if strings.Contains(strings.Join(got.env, "\n"), "OPENAI_API_KEY=") {
		t.Fatalf("gemini environment retained another provider key: %q", got.env)
	}
}

func TestGrokInvocationUsesIsolatedProjectBridgeAndNoBuiltins(t *testing.T) {
	t.Setenv("XAI_API_KEY", "xai-secret")
	workspace := t.TempDir()
	cfg := runConfig{Provider: "grok", Binary: "grok", BridgeBinary: "/tmp/emisar-mcp"}
	got, err := buildInvocation(
		cfg,
		scenario{Prompt: "inspect the fleet"},
		"http://127.0.0.1:9999",
		"eval-token",
		workspace,
	)
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(got.args, "\n")
	for _, flag := range []string{"--tools\n", "--no-subagents", "--no-memory", "--disable-web-search", "--no-auto-update"} {
		if !strings.Contains(joined, flag) {
			t.Fatalf("grok argv missing %q: %#v", flag, got.args)
		}
	}
	config, err := os.ReadFile(filepath.Join(workspace, ".grok", "config.toml"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(config), `command = "/tmp/emisar-mcp"`) ||
		!strings.Contains(string(config), `EMISAR_API_KEY="eval-token"`) {
		t.Fatalf("grok config = %s", config)
	}
}

func TestChildEnvStripsEmisarAndProviderSecrets(t *testing.T) {
	t.Setenv("EMISAR_API_KEY", "portal-secret")
	t.Setenv("ANTHROPIC_API_KEY", "anthropic-secret")
	t.Setenv("OPENAI_API_KEY", "openai-secret")
	t.Setenv("GEMINI_API_KEY", "gemini-secret")
	t.Setenv("XAI_API_KEY", "xai-secret")
	t.Setenv("CLAUDE_CODE_ENTRYPOINT", "cli")
	t.Setenv("CLAUDECODE", "1")
	joined := strings.Join(childEnv("ANTHROPIC_API_KEY"), "\n")
	for _, gone := range []string{
		"EMISAR_API_KEY=", "OPENAI_API_KEY=", "GEMINI_API_KEY=", "XAI_API_KEY=",
		"CLAUDE_CODE_ENTRYPOINT=", "CLAUDECODE=",
	} {
		if strings.Contains(joined, gone) {
			t.Fatalf("environment kept %s: %s", gone, joined)
		}
	}
	if !strings.Contains(joined, "ANTHROPIC_API_KEY=anthropic-secret") || !strings.Contains(joined, "PATH=") {
		t.Fatalf("environment lost the provider key or PATH: %s", joined)
	}
}

func TestRunAgentRecordsExitCodeAndOutput(t *testing.T) {
	result, err := runAgent(context.Background(), invocation{
		binary: "sh", args: []string{"-c", "echo answer; echo diag >&2; exit 3"}, dir: t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if result.ExitCode != 3 || result.Stdout != "answer\n" || result.Stderr != "diag\n" || result.TimedOut {
		t.Fatalf("agent result = %#v", result)
	}
}

func TestRunAgentMarksTimeout(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	result, err := runAgent(ctx, invocation{binary: "sh", args: []string{"-c", "sleep 5"}, dir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if !result.TimedOut {
		t.Fatalf("agent result = %#v", result)
	}
}

func TestRunAgentMissingBinaryIsHarnessError(t *testing.T) {
	if _, err := runAgent(context.Background(), invocation{binary: "mcpeval-no-such-binary", dir: t.TempDir()}); err == nil {
		t.Fatal("missing binary did not error")
	}
}

func TestBoundedBufferTruncates(t *testing.T) {
	buffer := &boundedBuffer{limit: 4}
	if _, err := buffer.Write([]byte("123456")); err != nil {
		t.Fatal(err)
	}
	if buffer.String() != "1234" || !buffer.Truncated() {
		t.Fatalf("buffer = %q truncated=%t", buffer.String(), buffer.Truncated())
	}
}
