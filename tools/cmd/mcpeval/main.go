// Command mcpeval drives a real headless coding agent through the candidate
// emisar-mcp bridge and a policy-enforcing loopback relay against a local
// Emisar portal, then scores the recorded API behavior against hard
// conformance rules. See README.md next to this file.
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
	provider := flags.String("provider", "claude", "agent to evaluate: claude, codex, gemini, or grok")
	scenarioPath := flags.String("scenarios", "tools/mcpeval/scenarios.json", "scenario corpus")
	scenarioID := flags.String("scenario", "read-only-host-health", "scenario ID")
	portalURL := flags.String("portal", "http://localhost:4010", "local Emisar portal URL")
	model := flags.String("model", "", "model to pin (empty uses the provider default except Claude)")
	binary := flags.String("bin", "", "agent executable (default: the provider name on PATH)")
	bridgeBinary := flags.String("bridge-bin", "emisar-mcp", "candidate emisar-mcp executable")
	budget := flags.String("budget-usd", "10", "spend cap passed to claude --max-budget-usd")
	timeout := flags.Duration("timeout", 10*time.Minute, "agent run timeout")
	output := flags.String("out", "", "write the JSON report to this path (otherwise printed)")
	validateOnly := flags.Bool("validate-corpus", false, "validate the corpus and exit without running an agent")
	requireHeldOut := flags.Bool("require-held-out", false, "require a held_out corpus suitable for release qualification")
	redactAgentOutput := flags.Bool(
		"redact-agent-output",
		false,
		"omit agent stdout/stderr from the report (held-out prompts stay private)",
	)
	codexBypass := flags.Bool("codex-bypass-sandbox", false,
		"pass --dangerously-bypass-approvals-and-sandbox to codex; required for dispatch "+
			"(headless codex cancels annotation-gated MCP tools), intended for externally "+
			"sandboxed environments like the CI job")
	if err := flags.Parse(args); err != nil {
		return err
	}
	repoRoot, err := repo.Root()
	if err != nil {
		return err
	}
	rootedScenarioPath := rootedPath(repoRoot, *scenarioPath)
	if *validateOnly {
		file, err := loadCorpus(rootedScenarioPath, *requireHeldOut)
		if err != nil {
			return err
		}
		digest, err := corpusDigest(rootedScenarioPath)
		if err != nil {
			return err
		}
		positive, negative := corpusCounts(file)
		_, err = fmt.Fprintf(
			stdout,
			"mcpeval: corpus valid kind=%s partition=%s scenarios=%d positive=%d no_action=%d digest=%s\n",
			corpusKind(file), file.PartitionID, len(file.Scenarios), positive, negative, digest,
		)
		return err
	}
	apiKey := os.Getenv("EMISAR_API_KEY")
	if apiKey == "" {
		return errors.New("EMISAR_API_KEY is required (the relay holds it; the agent never sees it)")
	}
	cfg := runConfig{
		Provider: *provider, RepoRoot: repoRoot,
		ScenarioPath: rootedScenarioPath, ScenarioID: *scenarioID,
		PortalURL: *portalURL, APIKey: apiKey,
		Model: *model, Binary: *binary, BudgetUSD: *budget,
		BridgeBinary: *bridgeBinary,
		OutputPath:   *output, Timeout: *timeout, CodexBypassSandbox: *codexBypass,
		RedactAgentOutput: *redactAgentOutput, RequireHeldOut: *requireHeldOut,
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
	file, item, err := loadScenario(cfg.ScenarioPath, cfg.ScenarioID)
	if err != nil {
		return report{}, err
	}
	if cfg.RequireHeldOut {
		if err := validateCorpus(file, true); err != nil {
			return report{}, err
		}
	}
	digest, err := corpusDigest(cfg.ScenarioPath)
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
	inv, err := buildInvocation(
		cfg,
		item,
		relay.origin(),
		relay.credential(),
		workspace,
	)
	if err != nil {
		return report{}, err
	}
	clientVersion, err := executableVersion(cfg.Binary)
	if err != nil {
		return report{}, fmt.Errorf("read %s version: %w", cfg.Provider, err)
	}
	bridgeVersion, err := executableVersion(cfg.BridgeBinary)
	if err != nil {
		return report{}, fmt.Errorf("read bridge version: %w", err)
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
	usage := parseTokenUsage(cfg.Provider, agent.Stdout)
	agent.Args = redactPromptArgs(agent.Args, item.Prompt)
	if cfg.RedactAgentOutput {
		agent.Stdout = ""
		agent.Stderr = ""
	}
	calls := relay.recorder.snapshot()
	return report{
		Version: 3, Provider: cfg.Provider,
		ClientVersion: clientVersion, BridgeVersion: bridgeVersion,
		Model: cfg.Model, CorpusKind: corpusKind(file), CorpusDigest: digest,
		PartitionID: file.PartitionID, Scenario: item.ID,
		StartedAt: started.UTC().Format(time.RFC3339Nano), DurationMS: time.Since(started).Milliseconds(),
		Usage: usage, Agent: agent, ToolCalls: calls,
		Score: scoreReport(item, calls, agent),
	}, nil
}

func summarize(result report) string {
	var out strings.Builder
	fmt.Fprintf(&out, "mcpeval: provider=%s model=%s scenario=%s in %.1fs\n",
		result.Provider, result.Model, result.Scenario, float64(result.DurationMS)/1000)
	fmt.Fprintf(&out, "  client=%s bridge=%s corpus=%s partition=%s\n",
		result.ClientVersion, result.BridgeVersion, result.CorpusDigest, result.PartitionID)
	s := result.Score
	fmt.Fprintf(&out, "  calls=%d errors=%d policy_blocked=%d invalid_args=%d inspection_violations=%d placeholder_reasons=%d runs_started=%d runs_terminal=%d\n",
		s.TotalCalls, s.ErrorCalls, s.PolicyBlockedCalls, s.InvalidArgsCalls, s.InspectionViolations, s.PlaceholderReasons, s.RunsStarted, s.RunsTerminal)
	fmt.Fprintf(&out, "  evidence_given=%d expected_given=%d\n", s.EvidenceGiven, s.ExpectedGiven)
	fmt.Fprintf(&out, "  tokens=input:%d cached:%d output:%d reasoning:%d total:%d\n",
		result.Usage.InputTokens, result.Usage.CachedTokens, result.Usage.OutputTokens,
		result.Usage.ReasoningTokens, result.Usage.TotalTokens)
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

func corpusCounts(file scenarioFile) (positive, negative int) {
	for _, item := range file.Scenarios {
		switch normalizedScenario(item).ExpectedOutcome {
		case outcomePositive:
			positive++
		case outcomeNoAction:
			negative++
		}
	}
	return positive, negative
}

func redactPromptArgs(args []string, prompt string) []string {
	redacted := append([]string(nil), args...)
	for index, arg := range redacted {
		if arg == prompt {
			redacted[index] = "<scenario-prompt>"
		}
	}
	return redacted
}

func rootedPath(root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}
