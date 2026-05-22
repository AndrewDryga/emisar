// Package executor runs declared action invocations under timeout and output
// size limits. It never uses a shell, never accepts raw command strings, and
// builds argv arrays from rendered templates.
package executor

import "time"

// Limits is the effective set of execution limits applied to a Plan. The
// action runtime computes this from action-declared limits and any
// cloud-supplied opts overrides clamped to the action's min/max envelope.
type Limits struct {
	Timeout        time.Duration
	MaxStdoutBytes int
	MaxStderrBytes int
}
