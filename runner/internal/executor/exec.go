package executor

import (
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// PlanForExec builds a Plan for an exec-kind action given its already-rendered
// argv. limits should be the effective limits computed by the action runtime.
func PlanForExec(a *actionspec.Action, renderedArgv []string, env map[string]string, limits Limits) Plan {
	cwd := a.Execution.CWD
	if cwd == "" {
		cwd = "/"
	}
	return Plan{
		Binary: a.Execution.Command.Binary,
		Argv:   renderedArgv,
		CWD:    cwd,
		Env:    env,
		Limits: limits,
		User:   a.Execution.User,
	}
}
