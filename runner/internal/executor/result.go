package executor

// Status describes the high-level outcome of a process invocation.
type Status string

const (
	StatusOK        Status = "ok"        // exit code 0
	StatusNonZero   Status = "nonzero"   // process exited with non-zero code
	StatusTimeout   Status = "timeout"   // killed by deadline
	StatusCancelled Status = "cancelled" // killed because the caller cancelled
	StatusFailed    Status = "failed"    // could not start or other infra error
)

// Truncated reports whether output streams hit their byte limits.
type Truncated struct {
	Stdout bool
	Stderr bool
}

// Result is the durable record of a single process invocation.
type Result struct {
	Status       Status    `json:"status"`
	Binary       string    `json:"binary"`
	Argv         []string  `json:"argv"`
	ArgvSHA256   string    `json:"argv_sha256"`
	CWD          string    `json:"cwd,omitempty"`
	EnvKeys      []string  `json:"env_keys,omitempty"`
	Stdout       string    `json:"stdout"`
	Stderr       string    `json:"stderr"`
	StdoutBytes  int       `json:"stdout_bytes"`
	StderrBytes  int       `json:"stderr_bytes"`
	StdoutSHA256 string    `json:"stdout_sha256,omitempty"`
	StderrSHA256 string    `json:"stderr_sha256,omitempty"`
	ExitCode     int       `json:"exit_code"`
	DurationMS   int64     `json:"duration_ms"`
	TimedOut     bool      `json:"timed_out"`
	Truncated    Truncated `json:"truncated"`
	StartError   string    `json:"start_error,omitempty"`
	ScriptSHA256 string    `json:"script_sha256,omitempty"`
}
