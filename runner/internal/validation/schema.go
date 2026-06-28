// Package validation coerces, defaults, and validates LLM-supplied
// arguments against the declared arg schema of an action or runbook.
//
// Validation invariants (matching docs/security-model.md):
//   - unknown arg names are rejected
//   - missing required args are rejected
//   - declared defaults are applied before policy evaluation
//   - duration args are parsed and bounded
//   - path args are cleaned and checked against allow/deny rules
//   - arrays validate every element
package validation

import (
	"fmt"
)

// Error wraps a validation failure with the offending arg name and a
// stable code suitable for surfacing to LLMs/HTTP callers.
type Error struct {
	Arg    string
	Code   string
	Reason string
}

func (e *Error) Error() string {
	if e.Arg == "" {
		return e.Reason
	}
	return fmt.Sprintf("argument %s: %s", e.Arg, e.Reason)
}

func newError(arg, code, format string, args ...any) *Error {
	return &Error{Arg: arg, Code: code, Reason: fmt.Sprintf(format, args...)}
}
