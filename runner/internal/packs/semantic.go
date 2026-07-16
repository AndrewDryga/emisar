package packs

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/andrewdryga/emisar/runner/internal/expressions"
	"github.com/andrewdryga/emisar/runner/internal/validation"
	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// validateActionSemantics exercises concrete author-authored values and
// templates through the same code paths execution uses. Declaration checks in
// actionspec cannot import these internal packages without creating a cycle.
func validateActionSemantics(action *actionspec.Action) error {
	for _, arg := range action.Args {
		if arg.Default == nil {
			continue
		}
		if _, err := validation.Validate(portableSchema([]actionspec.Arg{arg}), nil); err != nil {
			return fmt.Errorf("action %s: arg %s: invalid default: %w", action.ID, arg.Name, err)
		}
	}
	for _, example := range action.Examples {
		if _, err := validation.Validate(portableSchema(action.Args), example.Args); err != nil {
			return fmt.Errorf("action %s: example %q has invalid args: %w", action.ID, example.Title, err)
		}
	}

	args := representativeArgs(action.Args)
	var argv []string
	if action.Execution.Command != nil {
		argv = action.Execution.Command.Argv
	} else {
		argv = action.Execution.Argv
	}
	if err := expressions.ValidateReferences(argv, action.Execution.Env, args); err != nil {
		return fmt.Errorf("action %s: invalid execution template: %w", action.ID, err)
	}
	return nil
}

// Defaults and examples are authoring data, not host-local dispatches. Preserve
// every pure type and value constraint while omitting path containment, whose
// symlink and permission checks depend on the machine running pack validation.
func portableSchema(schema []actionspec.Arg) []actionspec.Arg {
	result := make([]actionspec.Arg, len(schema))
	for index, arg := range schema {
		result[index] = arg
		if arg.Validation == nil {
			continue
		}
		constraints := *arg.Validation
		constraints.AllowedPaths = nil
		constraints.DeniedPaths = nil
		constraints.AllowedPrefixes = nil
		constraints.DeniedPrefixes = nil
		result[index].Validation = &constraints
	}
	return result
}

func representativeArgs(schema []actionspec.Arg) map[string]any {
	args := make(map[string]any, len(schema))
	for _, arg := range schema {
		switch arg.Type {
		case actionspec.ArgString, actionspec.ArgPath:
			args[arg.Name] = "value"
		case actionspec.ArgInteger:
			args[arg.Name] = int64(1)
		case actionspec.ArgNumber:
			args[arg.Name] = json.Number("1")
		case actionspec.ArgBoolean:
			args[arg.Name] = true
		case actionspec.ArgDuration:
			args[arg.Name] = time.Second
		case actionspec.ArgStringArray:
			args[arg.Name] = []string{"value"}
		case actionspec.ArgIntegerArray:
			args[arg.Name] = []int64{1}
		}
	}
	return args
}
