package executor

import (
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// PlanForExec builds a Plan for an exec-kind action given its already-rendered
// argv. limits should be the effective limits computed by the action runtime.
func PlanForExec(a *actionspec.Action, renderedArgv []string, env map[string]string, limits Limits) Plan {
	return Plan{
		Binary: a.Execution.Command.Binary,
		Argv:   renderedArgv,
		CWD:    EffectiveCWD(a),
		Env:    env,
		Limits: limits,
		User:   a.Execution.User,
	}
}

// EffectiveCWD is shared by argument validation and both execution plans.
// An omitted working directory means the filesystem root, never the daemon's CWD.
func EffectiveCWD(a *actionspec.Action) string {
	if a.Execution.CWD == "" {
		return "/"
	}
	return a.Execution.CWD
}
