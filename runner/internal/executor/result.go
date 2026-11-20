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

// Result is what Execute observed about one process invocation. The engine
// redacts it and builds the durable journal record (audit.ExecutionInfo) from it.
type Result struct {
	Status      Status
	Binary      string
	Argv        []string
	CWD         string
	EnvKeys     []string
	Stdout      string
	Stderr      string
	StdoutBytes int
	StderrBytes int
	ExitCode    int
	DurationMS  int64
	TimedOut    bool
	Truncated   Truncated
	StartError  string
}
