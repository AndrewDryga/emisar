package main

import "time"

const (
	maxMCPFrameBytes    = 512 << 10
	maxActionArgsBytes  = 32 << 10
	maxRunnerRefs       = 16
	maxAgentStdoutBytes = 512 << 10
	maxAgentStderrBytes = 64 << 10
)

type scenarioFile struct {
	Version   int        `json:"version"`
	Scenarios []scenario `json:"scenarios"`
}

type scenario struct {
	ID              string   `json:"id"`
	Prompt          string   `json:"prompt"`
	AllowedTools    []string `json:"allowed_tools"`
	AllowedActions  []string `json:"allowed_actions"`
	RequiredTools   []string `json:"required_tools"`
	RequiredActions []string `json:"required_actions"`
}

type callRecord struct {
	Sequence             int        `json:"sequence"`
	Tool                 string     `json:"tool"`
	ArgumentKeys         []string   `json:"argument_keys"`
	ArgumentsDigest      string     `json:"arguments_digest"`
	ActionID             string     `json:"action_id,omitempty"`
	PackRef              string     `json:"pack_ref,omitempty"`
	RunnerCount          int        `json:"runner_count,omitempty"`
	ReasonPlaceholder    bool       `json:"reason_placeholder,omitempty"`
	EvidencePresent      bool       `json:"evidence_present,omitempty"`
	ExpectedPresent      bool       `json:"expected_present,omitempty"`
	BlockedByPolicy      bool       `json:"blocked_by_policy,omitempty"`
	ResponseError        bool       `json:"response_error"`
	ResponseCode         string     `json:"response_code,omitempty"`
	RunStates            []runState `json:"run_states,omitempty"`
	ResponseBytes        int        `json:"response_bytes"`
	StartedAt            string     `json:"started_at"`
	CompletedAt          string     `json:"completed_at,omitempty"`
	priorContractMatched bool
}

type runState struct {
	RunID       string `json:"run_id"`
	OperationID string `json:"operation_id"`
	Status      string `json:"status"`
	RunURL      string `json:"run_url,omitempty"`
	RunnerName  string `json:"runner_name,omitempty"`
}

type agentResult struct {
	Binary          string   `json:"binary"`
	Args            []string `json:"args"`
	ExitCode        int      `json:"exit_code"`
	TimedOut        bool     `json:"timed_out,omitempty"`
	Stdout          string   `json:"stdout,omitempty"`
	StdoutTruncated bool     `json:"stdout_truncated,omitempty"`
	Stderr          string   `json:"stderr,omitempty"`
	StderrTruncated bool     `json:"stderr_truncated,omitempty"`
}

type score struct {
	Passed                 bool     `json:"passed"`
	Failures               []string `json:"failures,omitempty"`
	TotalCalls             int      `json:"total_calls"`
	ErrorCalls             int      `json:"error_calls"`
	PolicyBlockedCalls     int      `json:"policy_blocked_calls"`
	InvalidArgsCalls       int      `json:"invalid_args_calls"`
	InspectionViolations   int      `json:"inspection_violations"`
	PlaceholderReasons     int      `json:"placeholder_reasons"`
	EvidenceGiven          int      `json:"evidence_given"`
	ExpectedGiven          int      `json:"expected_given"`
	RepeatedFailedCalls    int      `json:"repeated_failed_calls"`
	RunsStarted            int      `json:"runs_started"`
	RunsTerminal           int      `json:"runs_terminal"`
	NonTerminalRuns        []string `json:"non_terminal_runs,omitempty"`
	MissingRequiredTools   []string `json:"missing_required_tools,omitempty"`
	MissingRequiredActions []string `json:"missing_required_actions,omitempty"`
}

type report struct {
	Version    int          `json:"version"`
	Provider   string       `json:"provider"`
	Model      string       `json:"model,omitempty"`
	Scenario   string       `json:"scenario"`
	StartedAt  string       `json:"started_at"`
	DurationMS int64        `json:"duration_ms"`
	Agent      agentResult  `json:"agent"`
	ToolCalls  []callRecord `json:"tool_calls"`
	Score      score        `json:"score"`
}

type runConfig struct {
	Provider     string
	RepoRoot     string
	ScenarioPath string
	ScenarioID   string
	PortalURL    string
	APIKey       string
	Model        string
	Binary       string
	BudgetUSD    string
	OutputPath   string
	Timeout      time.Duration
	// Codex-only: pass --dangerously-bypass-approvals-and-sandbox so headless
	// runs can dispatch annotation-gated MCP tools. Only for externally
	// sandboxed environments (the CI job) or an explicit local opt-in.
	CodexBypassSandbox bool
}
