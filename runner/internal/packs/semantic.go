package packs

import (
	"encoding/json"
	"fmt"
	"strings"
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
	if err := validateShellProgramReferences(action, argv); err != nil {
		return err
	}
	return nil
}

// validateShellProgramReferences keeps caller-controlled values out of the
// program text interpreted by /bin/sh -c. A regex is not proof against every
// shell expansion; authors must instead pass open-ended text through env or a
// positional argv element. Finite membership and bounded numeric args remain
// pack-authored program choices, not caller-authored shell text.
func validateShellProgramReferences(action *actionspec.Action, argv []string) error {
	if action.Execution.Command == nil || action.Execution.Command.Binary != "/bin/sh" {
		return nil
	}
	program, ok := shellProgram(argv)
	if !ok {
		return nil
	}
	if action.ID == "shell.run_script" && action.Risk == actionspec.RiskCritical {
		return nil
	}

	args := make(map[string]actionspec.Arg, len(action.Args))
	for _, arg := range action.Args {
		args[arg.Name] = arg
	}
	for _, name := range argumentReferences(program) {
		arg := args[name]
		if shellProgramArgIsBounded(arg) {
			continue
		}
		return fmt.Errorf(
			"action %s: arg %s must not be embedded in /bin/sh -c program text; pass it through execution.env and reference it as \"$VAR\", or pass it as a whole positional argv element",
			action.ID,
			name,
		)
	}
	return nil
}

func shellProgram(argv []string) (string, bool) {
	for index, arg := range argv {
		if arg == "--" {
			return "", false
		}
		if len(arg) < 2 || arg[0] != '-' || arg[1] == '-' || !strings.ContainsRune(arg[1:], 'c') {
			continue
		}
		if index+1 >= len(argv) {
			return "", false
		}
		return argv[index+1], true
	}
	return "", false
}

// argumentReferences is called only after expressions.ValidateReferences has
// accepted the template, so every block has the supported args.<name>[?]
// grammar.
func argumentReferences(template string) []string {
	var references []string
	for {
		start := strings.Index(template, "{{")
		if start < 0 {
			return references
		}
		template = template[start+2:]
		end := strings.Index(template, "}}")
		if end < 0 {
			return references
		}
		expression := strings.TrimSpace(template[:end])
		expression = strings.TrimSpace(strings.TrimSuffix(expression, "?"))
		references = append(references, strings.TrimPrefix(expression, "args."))
		template = template[end+2:]
	}
}

func shellProgramArgIsBounded(arg actionspec.Arg) bool {
	if arg.Validation != nil &&
		(len(arg.Validation.Enum) > 0 || len(arg.Validation.Allowed) > 0) {
		return true
	}
	switch arg.Type {
	case actionspec.ArgString, actionspec.ArgPath, actionspec.ArgStringArray:
		return false
	case actionspec.ArgInteger, actionspec.ArgNumber:
		return arg.Validation != nil &&
			arg.Validation.Min != nil &&
			arg.Validation.Max != nil
	default:
		return true
	}
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
