package packs

import (
	"encoding/json"
	"fmt"
	"path/filepath"
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
		if _, err := validation.Validate(portableSchema([]actionspec.Arg{arg}), nil, nil); err != nil {
			return fmt.Errorf("action %s: arg %s: invalid default: %w", action.ID, arg.Name, err)
		}
	}
	for _, example := range action.Examples {
		if _, err := validation.Validate(portableSchema(action.Args), example.Args, nil); err != nil {
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

// programInterpreters maps an interpreter's name to the short flag rune that
// introduces program text on its argv: a shell or python reads its program
// after -c, perl/ruby/node/awk after -e, php after -r.
var programInterpreters = map[string]rune{
	"/bin/sh": 'c',
	"sh":      'c',
	"bash":    'c',
	"dash":    'c',
	"ash":     'c',
	"ksh":     'c',
	"zsh":     'c',
	"busybox": 'c',
	"python":  'c',
	"python3": 'c',
	"perl":    'e',
	"ruby":    'e',
	"node":    'e',
	"awk":     'e',
	"gawk":    'e',
	"php":     'r',
}

// execWrappers are binaries that exec a command taken from their OWN argv, so an
// interpreter can hide behind one: `timeout 30 sh -c '…'` names timeout (not a
// shell) as the binary. Keying the guard on the binary alone waved a caller's
// value straight into `sh -c` — arbitrary command execution from an action
// argument. When the binary is a wrapper, the argv is scanned for the real
// interpreter it fronts. A binary that is NEITHER an interpreter nor a wrapper
// runs its own argument grammar, whose tokens are its data, not a nested command
// — `nomad node status` must not be read as a Node.js program.
var execWrappers = map[string]bool{
	"env":     true,
	"timeout": true,
	"nice":    true,
	"setsid":  true,
	"stdbuf":  true,
	"nohup":   true,
	"xargs":   true,
	"flock":   true,
	"runuser": true,
	"script":  true,
}

// validateShellProgramReferences keeps caller-controlled values out of the
// program text an interpreter runs after its program flag. A regex is not proof
// against every shell expansion; authors must instead pass open-ended text
// through env or a positional argv element. Finite membership and bounded
// numeric args remain pack-authored program choices, not caller-authored shell
// text. The interpreter is resolved through the binary and any exec-wrapper in
// front of it, so a wrapper cannot hide the shell. (awk's positional-program
// form is not matched — its ambiguous option grammar risks false positives; the
// -e/-c forms are.)
func validateShellProgramReferences(action *actionspec.Action, argv []string) error {
	if action.Execution.Command == nil {
		return nil
	}
	interpreter, flag, rest, ok := interpreterInvocation(action.Execution.Command.Binary, argv)
	if !ok {
		return nil
	}
	program, ok := interpreterProgram(rest, flag)
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
			"action %s: arg %s must not be embedded in %s -%c program text; pass it through execution.env and reference it as \"$VAR\", or pass it as a whole positional argv element",
			action.ID,
			name,
			interpreter,
			flag,
		)
	}
	return nil
}

// interpreterInvocation resolves which interpreter the command runs and the argv
// that follows it: the binary itself, or — when the binary is a known
// exec-wrapper — the first interpreter token in its argv. A binary that is
// neither returns ok=false, so its own argument tokens are never scanned.
func interpreterInvocation(binary string, argv []string) (name string, flag rune, rest []string, ok bool) {
	if f, isInterp := interpreterFlag(binary); isInterp {
		return binary, f, argv, true
	}
	if !execWrappers[filepath.Base(binary)] {
		return "", 0, nil, false
	}
	for index, tok := range argv {
		if f, isInterp := interpreterFlag(tok); isInterp {
			return tok, f, argv[index+1:], true
		}
	}
	return "", 0, nil, false
}

// interpreterFlag reports whether a token names a program interpreter (matched
// by the whole token or its path base, so "/usr/bin/python3" counts) and its
// program flag.
func interpreterFlag(token string) (rune, bool) {
	if f, ok := programInterpreters[token]; ok {
		return f, true
	}
	if base := filepath.Base(token); base != token {
		if f, ok := programInterpreters[base]; ok {
			return f, true
		}
	}
	return 0, false
}

// interpreterProgram returns the program-text token that follows the flag rune
// (e.g. -c for a shell, -e for perl), tolerating combined short flags like -ec.
// A lone "--" ends option scanning.
func interpreterProgram(tokens []string, flag rune) (string, bool) {
	for index, arg := range tokens {
		if arg == "--" {
			return "", false
		}
		if len(arg) < 2 || arg[0] != '-' || arg[1] == '-' || !strings.ContainsRune(arg[1:], flag) {
			continue
		}
		if index+1 >= len(tokens) {
			return "", false
		}
		return tokens[index+1], true
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
	case actionspec.ArgString, actionspec.ArgPath,
		actionspec.ArgStringArray, actionspec.ArgIntegerArray:
		// An array renders one token per element into the program text, so it is
		// no more bounded than its element type is — and integer_array was
		// treated as bounded only because it fell through to the old default.
		return false
	case actionspec.ArgInteger, actionspec.ArgNumber:
		return arg.Validation != nil &&
			arg.Validation.Min != nil &&
			arg.Validation.Max != nil
	case actionspec.ArgBoolean:
		// Two values, neither able to carry a shell metacharacter.
		return true
	case actionspec.ArgDuration:
		// Parsed through time.ParseDuration before it renders, so the literal is
		// a duration or the dispatch never happens.
		return true
	default:
		// An arg kind this lint has not been taught about is NOT bounded. The
		// old `default: true` said the opposite, so the next ArgType added would
		// have been waved straight into shell program text with nothing to
		// notice — a fail-OPEN default on the check that keeps cloud-supplied
		// values out of a command string.
		return false
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
