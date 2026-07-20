// Command mcpeval drives a real headless coding agent (Claude Code, or
// optionally Codex) through a policy-enforcing loopback MCP relay against a
// local Emisar portal, then scores the recorded API behavior against hard
// conformance rules. The scheduled mcp-eval workflow runs it weekly against
// the docker compose stack; see README.md next to this file.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/andrewdryga/emisar/tools/internal/repo"
)

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "mcpeval:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	flags := flag.NewFlagSet("mcpeval", flag.ContinueOnError)
	flags.SetOutput(stderr)
	provider := flags.String("provider", "claude", "agent to evaluate: claude or codex")
	scenarioPath := flags.String("scenarios", "tools/mcpeval/scenarios.json", "scenario corpus")
	scenarioID := flags.String("scenario", "read-only-host-health", "scenario ID")
	portalURL := flags.String("portal", "http://localhost:4010", "local Emisar portal URL")
	model := flags.String("model", "", "model to pin (claude default: claude-sonnet-4-5; codex default: the CLI's configured model)")
	binary := flags.String("bin", "", "agent executable (default: the provider name on PATH)")
	budget := flags.String("budget-usd", "10", "spend cap passed to claude --max-budget-usd")
	timeout := flags.Duration("timeout", 10*time.Minute, "agent run timeout")
	output := flags.String("out", "", "write the JSON report to this path (otherwise printed)")
	codexBypass := flags.Bool("codex-bypass-sandbox", false,
		"pass --dangerously-bypass-approvals-and-sandbox to codex; required for dispatch "+
			"(headless codex cancels annotation-gated MCP tools), intended for externally "+
			"sandboxed environments like the CI job")
	if err := flags.Parse(args); err != nil {
		return err
	}
	apiKey := os.Getenv("EMISAR_API_KEY")
	if apiKey == "" {
		return errors.New("EMISAR_API_KEY is required (the relay holds it; the agent never sees it)")
	}
	repoRoot, err := repo.Root()
	if err != nil {
		return err
	}
	cfg := runConfig{
		Provider: *provider, RepoRoot: repoRoot,
		ScenarioPath: rootedPath(repoRoot, *scenarioPath), ScenarioID: *scenarioID,
		PortalURL: *portalURL, APIKey: apiKey,
		Model: *model, Binary: *binary, BudgetUSD: *budget,
		OutputPath: *output, Timeout: *timeout, CodexBypassSandbox: *codexBypass,
	}
	if cfg.Binary == "" {
		cfg.Binary = cfg.Provider
	}
	if cfg.Model == "" && cfg.Provider == "claude" {
		cfg.Model = "claude-sonnet-4-5"
	}

	result, err := execute(cfg)
	if err != nil {
		return err
	}
	encoded, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	if cfg.OutputPath != "" {
		if err := os.WriteFile(cfg.OutputPath, encoded, 0o600); err != nil {
			return err
		}
	} else if _, err := stdout.Write(encoded); err != nil {
		return err
	}
	if _, err := io.WriteString(stdout, summarize(result)); err != nil {
		return err
	}
	if !result.Score.Passed {
		return fmt.Errorf("scenario failed with %d hard violation(s)", len(result.Score.Failures))
	}
	return nil
}

func execute(cfg runConfig) (report, error) {
	item, err := loadScenario(cfg.ScenarioPath, cfg.ScenarioID)
	if err != nil {
		return report{}, err
	}
	relay, err := newRelay(cfg.PortalURL, cfg.APIKey, item)
	if err != nil {
		return report{}, err
	}
	relay.start()
	defer relay.close()

	workspace, err := prepareWorkspace()
	if err != nil {
		return report{}, err
	}
	defer os.RemoveAll(workspace)
	inv, err := buildInvocation(cfg, item, relay.endpoint(), workspace)
	if err != nil {
		return report{}, err
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ctx, timeoutCancel := context.WithTimeout(ctx, cfg.Timeout)
	defer timeoutCancel()
	started := time.Now()
	agent, err := runAgent(ctx, inv)
	if err != nil {
		return report{}, err
	}
	calls := relay.recorder.snapshot()
	return report{
		Version: 2, Provider: cfg.Provider, Model: cfg.Model, Scenario: item.ID,
		StartedAt: started.UTC().Format(time.RFC3339Nano), DurationMS: time.Since(started).Milliseconds(),
		Agent: agent, ToolCalls: calls,
		Score: scoreReport(item, calls, agent),
	}, nil
}

func summarize(result report) string {
	var out strings.Builder
	fmt.Fprintf(&out, "mcpeval: provider=%s model=%s scenario=%s in %.1fs\n",
		result.Provider, result.Model, result.Scenario, float64(result.DurationMS)/1000)
	s := result.Score
	fmt.Fprintf(&out, "  calls=%d errors=%d policy_blocked=%d invalid_args=%d inspection_violations=%d runs_started=%d runs_terminal=%d\n",
		s.TotalCalls, s.ErrorCalls, s.PolicyBlockedCalls, s.InvalidArgsCalls, s.InspectionViolations, s.RunsStarted, s.RunsTerminal)
	if s.Passed {
		out.WriteString("  PASS\n")
		return out.String()
	}
	out.WriteString("  FAIL\n")
	for _, failure := range s.Failures {
		fmt.Fprintf(&out, "  - %s\n", failure)
	}
	return out.String()
}

func rootedPath(root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}
