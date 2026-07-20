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
	workspace := t.TempDir()
	item := scenario{Prompt: "inspect the fleet", AllowedTools: []string{"list_runners", "run_action"}}
	cfg := runConfig{Provider: "claude", Binary: "claude", Model: "claude-sonnet-4-5", BudgetUSD: "10"}
	got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999/token", workspace)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(workspace, "mcp-eval.json")
	want := []string{
		"-p", "inspect the fleet",
		"--output-format", "json",
		"--model", "claude-sonnet-4-5",
		"--bare",
		"--strict-mcp-config",
		"--mcp-config", configPath,
		"--tools", "",
		"--allowedTools", "mcp__emisar_eval__list_runners,mcp__emisar_eval__run_action",
		"--no-session-persistence",
		"--max-budget-usd", "10",
	}
	if got.binary != "claude" || !reflect.DeepEqual(got.args, want) {
		t.Fatalf("claude argv = %q %#v", got.binary, got.args)
	}
	config, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(config) != `{"mcpServers":{"emisar_eval":{"type":"http","url":"http://127.0.0.1:9999/token"}}}`+"\n" {
		t.Fatalf("mcp config = %s", config)
	}
}

func TestCodexInvocationRegistersHTTPRelayAndPinsModel(t *testing.T) {
	item := scenario{Prompt: "inspect the fleet"}
	base := []string{
		"exec", "--json", "--ephemeral", "--ignore-user-config",
		"--sandbox", "read-only", "--color", "never",
		"-c", `mcp_servers.emisar_eval.url="http://127.0.0.1:9999/token"`,
	}
	for model, want := range map[string][]string{
		"":        append(append([]string{}, base...), "inspect the fleet"),
		"gpt-5.1": append(append([]string{}, base...), "--model", "gpt-5.1", "inspect the fleet"),
	} {
		cfg := runConfig{Provider: "codex", Binary: "codex", Model: model}
		got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999/token", t.TempDir())
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
	cfg := runConfig{Provider: "codex", Binary: "codex", CodexBypassSandbox: true}
	got, err := buildInvocation(cfg, item, "http://127.0.0.1:9999/token", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(got.args, " ")
	if !strings.Contains(joined, "--dangerously-bypass-approvals-and-sandbox") {
		t.Fatalf("bypass opt-in missing from argv: %#v", got.args)
	}
}

func TestBuildInvocationRejectsUnknownProvider(t *testing.T) {
	if _, err := buildInvocation(runConfig{Provider: "gemini"}, scenario{}, "http://127.0.0.1:1/t", t.TempDir()); err == nil {
		t.Fatal("unknown provider was accepted")
	}
}

func TestChildEnvStripsEmisarAndProviderSecrets(t *testing.T) {
	t.Setenv("EMISAR_API_KEY", "portal-secret")
	t.Setenv("ANTHROPIC_API_KEY", "anthropic-secret")
	t.Setenv("OPENAI_API_KEY", "openai-secret")
	t.Setenv("CLAUDE_CODE_ENTRYPOINT", "cli")
	t.Setenv("CLAUDECODE", "1")
	joined := strings.Join(childEnv("ANTHROPIC_API_KEY"), "\n")
	for _, gone := range []string{"EMISAR_API_KEY=", "OPENAI_API_KEY=", "CLAUDE_CODE_ENTRYPOINT=", "CLAUDECODE="} {
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
