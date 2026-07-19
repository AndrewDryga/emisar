// Package actionhost inspects host facts that affect whether an action can
// start. These facts are runtime evidence, not part of the trusted descriptor.
package actionhost

import (
	"os/exec"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// PrimaryExecutable returns the program the executor starts for an action.
func PrimaryExecutable(action *actionspec.Action) string {
	switch action.Kind {
	case actionspec.KindExec:
		if action.Execution.Command != nil {
			return action.Execution.Command.Binary
		}
	case actionspec.KindScript:
		if action.Execution.Script != nil {
			if action.Execution.Script.Interpreter == "" {
				return "/bin/sh"
			}
			return action.Execution.Script.Interpreter
		}
	}
	return ""
}

// PrimaryExecutableAvailable reports whether the executor can resolve the
// primary program using the runner process's PATH and execute permission.
func PrimaryExecutableAvailable(action *actionspec.Action) bool {
	executable := PrimaryExecutable(action)
	if executable == "" {
		return false
	}
	_, err := exec.LookPath(executable)
	return err == nil
}
