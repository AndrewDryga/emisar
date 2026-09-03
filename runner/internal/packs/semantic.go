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

var shellInterpreters = map[string]bool{
	"sh":   true,
	"bash": true,
	"dash": true,
	"ash":  true,
	"hush": true,
	"fish": true,
	"csh":  true,
	"tcsh": true,
	"ksh":  true,
	"zsh":  true,
}

// codeInterpreters execute source, modules, or scripts selected by their argv.
// Their option grammars vary by implementation and version, so an open-ended
// model value is never a safe argv channel. Finite choices remain pack-authored.
// A version suffix counts as the same interpreter (see codeInterpreter), which
// is why node22 and gawk5 are not spelled out.
var codeInterpreters = map[string]bool{
	"python":     true,
	"python3":    true,
	"perl":       true,
	"ruby":       true,
	"node":       true,
	"nodejs":     true,
	"deno":       true,
	"bun":        true,
	"awk":        true,
	"gawk":       true,
	"mawk":       true,
	"nawk":       true,
	"php":        true,
	"lua":        true,
	"luajit":     true,
	"Rscript":    true,
	"tclsh":      true,
	"wish":       true,
	"pwsh":       true,
	"powershell": true,
	"osascript":  true,
}

// These variables select startup files, modules, or runtime configuration that
// can execute code before a fixed program runs. A shell or wrapper can front any
// of the listed interpreters, so it receives the union; a direct interpreter
// receives only its own variables below.
var indirectCodeSelectionEnvVars = map[string]bool{
	"ENV":              true,
	"HOME":             true,
	"KSH_ENV":          true,
	"XDG_CONFIG_HOME":  true,
	"ZDOTDIR":          true,
	"PYTHONHOME":       true,
	"PYTHONPATH":       true,
	"PYTHONUSERBASE":   true,
	"PERLLIB":          true,
	"PERL5LIB":         true,
	"RUBYLIB":          true,
	"RUBYGEMS_GEMDEPS": true,
	"GEM_HOME":         true,
	"GEM_PATH":         true,
	"NODE_PATH":        true,
	"AWKPATH":          true,
	"AWKLIBPATH":       true,
	"PHPRC":            true,
	"PHP_INI_SCAN_DIR": true,
	"LUA_INIT":         true,
	"LUA_PATH":         true,
	"LUA_CPATH":        true,
	"R_PROFILE":        true,
	"R_PROFILE_USER":   true,
	"R_LIBS":           true,
	"TCLLIBPATH":       true,
	"PSModulePath":     true,
}

// execWrappers reinterpret their own argv as another executable, shell source,
// environment, or runtime-appended arguments. Proving a free-form value is data
// would require copying each platform's evolving option grammar. Keep this
// boundary intentionally small: wrapper argv may contain only fixed or finite
// pack-authored choices. Shipped packs use no wrapper command binaries.
var execWrappers = map[string]bool{
	"env":         true,
	"timeout":     true,
	"gtimeout":    true,
	"time":        true,
	"nice":        true,
	"ionice":      true,
	"taskset":     true,
	"setsid":      true,
	"stdbuf":      true,
	"nohup":       true,
	"xargs":       true,
	"gxargs":      true,
	"flock":       true,
	"script":      true,
	"busybox":     true,
	"runuser":     true,
	"sudo":        true,
	"su":          true,
	"doas":        true,
	"chroot":      true,
	"nsenter":     true,
	"unshare":     true,
	"setpriv":     true,
	"systemd-run": true,
}

// validateShellProgramReferences keeps caller-controlled values out of source
// or command-selection text. Direct shells retain their safe data channels:
// ordinary execution.env values and argv after a fixed -c program. Wrappers and
// non-shell code interpreters accept only finite pack-authored values because
// their option grammars can turn any earlier argv token into code or a child
// executable. A regex is not proof against shell expansion.
func validateShellProgramReferences(action *actionspec.Action, argv []string) error {
	args := make(map[string]actionspec.Arg, len(action.Args))
	for _, arg := range action.Args {
		args[arg.Name] = arg
	}
	base := ""
	if action.Execution.Command != nil {
		base = filepath.Base(action.Execution.Command.Binary)
	} else if action.Execution.Script != nil {
		if action.Execution.Script.Interpreter == "" {
			base = "sh"
		} else {
			base = filepath.Base(action.Execution.Script.Interpreter)
		}
	}
	for name, value := range action.Execution.Env {
		if !environmentSelectsCode(base, name) {
			continue
		}
		if argName, unbounded := firstUnboundedArgumentReference([]string{value}, args); unbounded {
			return fmt.Errorf(
				"action %s: execution.env %s must be pack-authored, not args.%s",
				action.ID,
				name,
				argName,
			)
		}
	}
	if action.Execution.Command == nil {
		if execWrappers[base] {
			return fmt.Errorf(
				"action %s: execution.script.interpreter %s is a command wrapper, not a script interpreter",
				action.ID,
				action.Execution.Script.Interpreter,
			)
		}
		return nil
	}
	if execWrappers[base] {
		if name, ok := firstUnboundedArgumentReference(argv, args); ok {
			return fmt.Errorf(
				"action %s: arg %s must not be passed through %s command selection; wrappers accept only fixed or finite values",
				action.ID,
				name,
				base,
			)
		}
		return nil
	}
	if codeInterpreter(base) {
		if name, ok := firstUnboundedArgumentReference(argv, args); ok {
			return fmt.Errorf(
				"action %s: arg %s must not be passed through %s interpreter argv; pass open-ended data through execution.env",
				action.ID,
				name,
				base,
			)
		}
		return nil
	}
	if !shellInterpreters[base] {
		return nil
	}

	program, staticCommand := shellProgramPrefix(argv)
	if action.ID == "shell.run_script" && action.Risk == actionspec.RiskCritical && staticCommand {
		return nil
	}
	programContext := action.Execution.Command.Binary + " -c program text"
	if !staticCommand {
		programContext = action.Execution.Command.Binary + " shell command selection"
	}
	for _, name := range argumentReferences(program) {
		if shellProgramArgIsBounded(args[name]) {
			continue
		}
		return fmt.Errorf(
			"action %s: arg %s must not be embedded in %s; pass it through execution.env and reference it as \"$VAR\", or pass it as a whole positional argv element after a fixed -c program",
			action.ID,
			name,
			programContext,
		)
	}
	return nil
}

// codeInterpreter reports whether base names a source-executing interpreter,
// accepting a bare version suffix (python3.12, node22, gawk5) as the same
// program. The version forms used to live in a second, shorter table that
// omitted node and awk, so exactly those two escaped the check.
func codeInterpreter(base string) bool {
	if codeInterpreters[base] {
		return true
	}
	for name := range codeInterpreters {
		suffix, found := strings.CutPrefix(base, name)
		if !found || suffix == "" {
			continue
		}
		if strings.Trim(suffix, "0123456789.") == "" {
			return true
		}
	}
	return false
}

func environmentSelectsCode(base, name string) bool {
	if name == "PATH" || name == "SHELL" {
		return true
	}
	if (shellInterpreters[base] || execWrappers[base]) && indirectCodeSelectionEnvVars[name] {
		return true
	}
	switch {
	case strings.HasPrefix(base, "python"):
		return name == "HOME" || name == "PYTHONHOME" || name == "PYTHONPATH" || name == "PYTHONUSERBASE"
	case strings.HasPrefix(base, "perl"):
		return name == "PERLLIB" || name == "PERL5LIB"
	case strings.HasPrefix(base, "ruby"):
		return name == "RUBYLIB" || name == "RUBYGEMS_GEMDEPS" || name == "GEM_HOME" || name == "GEM_PATH"
	case base == "node" || base == "nodejs" || base == "deno" || base == "bun":
		return name == "NODE_PATH"
	case strings.HasSuffix(base, "awk"):
		return name == "AWKPATH" || name == "AWKLIBPATH"
	case strings.HasPrefix(base, "php"):
		return name == "PHPRC" || name == "PHP_INI_SCAN_DIR"
	case strings.HasPrefix(base, "lua"):
		return name == "LUA_INIT" || name == "LUA_PATH" || name == "LUA_CPATH"
	case base == "Rscript":
		return name == "R_PROFILE" || name == "R_PROFILE_USER" || name == "R_LIBS"
	case base == "tclsh" || base == "wish":
		return name == "TCLLIBPATH"
	case base == "pwsh" || base == "powershell":
		return name == "PSModulePath"
	}
	// An ordinary command keeps its application environment: ENV and HOME are
	// real configuration for tools that are not interpreters, and refusing
	// them everywhere buries authors in false positives
	// (TestLoad_OrdinaryBinaryKeepsApplicationEnvironment).
	return false
}

func firstUnboundedArgumentReference(templates []string, args map[string]actionspec.Arg) (string, bool) {
	for _, template := range templates {
		for _, name := range argumentReferences(template) {
			if !shellProgramArgIsBounded(args[name]) {
				return name, true
			}
		}
	}
	return "", false
}

// shellProgramPrefix proves the one canonical program boundary used by shipped
// actions. Values after a fixed `-c PROGRAM` are positional data. Any other
// spelling is left intact so a free reference anywhere fails closed instead of
// relying on a shell-version-specific option grammar.
func shellProgramPrefix(tokens []string) (program string, staticCommand bool) {
	if len(tokens) >= 2 && tokens[0] == "-c" {
		return strings.Join(tokens[:2], " "), true
	}
	return strings.Join(tokens, " "), false
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
