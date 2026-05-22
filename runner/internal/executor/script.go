package executor

import (
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// PlanForScript builds a Plan for a script-kind action. scriptPath is the
// absolute path resolved by the pack loader (which has already verified the
// path is inside the pack root).
func PlanForScript(a *actionspec.Action, scriptPath, scriptSHA256 string, renderedArgv []string, env map[string]string, limits Limits) Plan {
	interp := a.Execution.Script.Interpreter
	if interp == "" {
		interp = "/bin/sh"
	}
	cwd := a.Execution.CWD
	if cwd == "" {
		cwd = "/"
	}
	argv := append([]string{scriptPath}, renderedArgv...)
	return Plan{
		Binary:       interp,
		Argv:         argv,
		CWD:          cwd,
		Env:          env,
		Limits:       limits,
		ScriptSHA256: scriptSHA256,
		User:         a.Execution.User,
	}
}
