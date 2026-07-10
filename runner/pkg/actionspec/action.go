package actionspec

import (
	"fmt"
	"regexp"
	"strings"
)

// SchemaVersion is the currently supported action schema version.
const SchemaVersion = 1

// Action is the YAML definition of an LLM-callable primitive capability.
//
// The on-disk schema is intentionally compact: title for UI labelling,
// description for the long-form prose the LLM and humans both read,
// side_effects for the scannable list, and the executable contract
// (args + execution + output). Pack authors do not write multiple
// near-duplicate prose fields.
//
// Loaders also stamp PackID, PackRoot, and SourcePath at load time; those
// fields are not part of the on-disk schema.
type Action struct {
	SchemaVersion int      `yaml:"schema_version"`
	ID            string   `yaml:"id"`
	Title         string   `yaml:"title"`
	Kind          Kind     `yaml:"kind"`
	Risk          Risk     `yaml:"risk"`
	Description   string   `yaml:"description"`
	SideEffects   []string `yaml:"side_effects"`

	Args      []Arg     `yaml:"args"`
	Execution Execution `yaml:"execution"`
	Output    Output    `yaml:"output"`
	Examples  []Example `yaml:"examples,omitempty"`

	PackID     string `yaml:"-"`
	PackRoot   string `yaml:"-"`
	SourcePath string `yaml:"-"`
}

// Execution describes how an action runs.
//
// For Kind == exec, Command must be set.
// For Kind == script, Script must be set; Argv passes extra args to the script.
type Execution struct {
	Command *Command `yaml:"command,omitempty"`
	Script  *Script  `yaml:"script,omitempty"`
	Argv    []string `yaml:"argv,omitempty"`
	Timeout Duration `yaml:"timeout"`
	// TimeoutMin and TimeoutMax bound any cloud-supplied opts.timeout
	// override. If unset, defaults to Timeout (no override allowed).
	TimeoutMin Duration `yaml:"timeout_min,omitempty"`
	TimeoutMax Duration `yaml:"timeout_max,omitempty"`
	// SuccessExitCodes lists non-zero exit codes the executor treats as
	// success in addition to 0 — for tools that signal a benign state with a
	// specific code (iscsiadm exits 21 for "no active sessions"; journalctl
	// --grep exits 1 for "no matches"). Each must be 1..255 (0 is always
	// success). The allowlist is exact: an unlisted non-zero code still fails,
	// so it never softens the executor to "any non-zero is success".
	SuccessExitCodes []int `yaml:"success_exit_codes,omitempty"`
	// CancelGrace overrides the runner-wide cancel_grace for this action.
	// Used when SIGTERM needs more time than the default (e.g., Cassandra
	// repair clean-up). Zero means "use the config default."
	CancelGrace Duration          `yaml:"cancel_grace,omitempty"`
	CWD         string            `yaml:"cwd,omitempty"`
	Env         map[string]string `yaml:"env,omitempty"`
	User        string            `yaml:"user,omitempty"`
}

// Command describes an exec invocation. Argv is rendered through the template
// engine before exec.
type Command struct {
	Binary string   `yaml:"binary"`
	Argv   []string `yaml:"argv"`
}

// Script describes a scripted invocation. Path is resolved relative to the
// owning pack root and must not escape it.
type Script struct {
	Path        string `yaml:"path"`
	Interpreter string `yaml:"interpreter"`
}

// Output configures parsing, size limits, and action-local redaction rules.
//
// MaxStdoutBytes/MaxStderrBytes are the defaults; *Min/*Max bound any
// cloud-supplied opts override. If *Min/*Max are unset, no override allowed.
type Output struct {
	Parser            Parser          `yaml:"parser,omitempty"`
	ParserRequired    bool            `yaml:"parser_required,omitempty"`
	MaxStdoutBytes    int             `yaml:"max_stdout_bytes,omitempty"`
	MaxStdoutBytesMin int             `yaml:"max_stdout_bytes_min,omitempty"`
	MaxStdoutBytesMax int             `yaml:"max_stdout_bytes_max,omitempty"`
	MaxStderrBytes    int             `yaml:"max_stderr_bytes,omitempty"`
	MaxStderrBytesMin int             `yaml:"max_stderr_bytes_min,omitempty"`
	MaxStderrBytesMax int             `yaml:"max_stderr_bytes_max,omitempty"`
	Redact            []RedactionRule `yaml:"redact,omitempty"`
}

// RedactionRule is a redaction directive (regex or literal) attached to an
// action or to global config.
type RedactionRule struct {
	Name        string `yaml:"name"`
	Type        string `yaml:"type"`
	Pattern     string `yaml:"pattern,omitempty"`
	Literal     string `yaml:"literal,omitempty"`
	Replacement string `yaml:"replacement,omitempty"`
}

// Example is a documented sample invocation.
type Example struct {
	Title string         `yaml:"title" json:"title"`
	Args  map[string]any `yaml:"args" json:"args"`
}

// reservedArgNames are the top-level request fields the control plane owns
// on every MCP action dispatch (POST /tools/:action_id): the audit reason,
// the runner or runners target selector, the idempotency_key retry control,
// the wait sync-poll knob, and the action_id itself. The control plane strips
// these from the request before the remaining keys reach the runner as action
// args, so an action arg sharing one of these names could never receive a
// value. Reject the collision at pack-validation time rather than letting it
// silently break dispatch.
//
// Keep in sync with the portal's drop list in
// apps/emisar_web/lib/emisar_web/controllers/mcp_controller.ex.
var reservedArgNames = map[string]struct{}{
	"action_id":       {},
	"reason":          {},
	"runner":          {},
	"runners":         {},
	"wait":            {},
	"idempotency_key": {},
}

// secretArgNameRe matches arg names that look secret-bearing (for SecretArgWarnings).
var secretArgNameRe = regexp.MustCompile(`(?i)(token|password|passwd|secret|api_?key)`)

// SecretArgWarnings flags args whose NAME looks secret-bearing but aren't marked
// `sensitive: true` — routing a real secret through such an arg would leak it into
// execution.argv and the recorded executed_command. A lint (warning), not a hard
// error: an arg that merely contains "token" in its name may be a non-secret id,
// so the author decides — `emisar pack validate` surfaces it, doesn't reject it.
func (a *Action) SecretArgWarnings() []string {
	var warnings []string
	for _, arg := range a.Args {
		if !arg.Sensitive && secretArgNameRe.MatchString(arg.Name) {
			warnings = append(warnings,
				fmt.Sprintf("action %q: arg %q looks secret-bearing but is not marked `sensitive: true`", a.ID, arg.Name))
		}
	}
	return warnings
}

// Validate checks that the action is internally consistent and ready to load.
func (a *Action) Validate() error {
	if a.SchemaVersion != SchemaVersion {
		return fmt.Errorf("action %s: unsupported schema_version %d (want %d)", a.ID, a.SchemaVersion, SchemaVersion)
	}
	if a.ID == "" {
		return fmt.Errorf("action: missing id")
	}
	if !validActionID(a.ID) {
		return fmt.Errorf("action: invalid id %q (must match [a-z][a-z0-9._-]*\\.[a-z][a-z0-9_-]*)", a.ID)
	}
	if a.Title == "" {
		return fmt.Errorf("action %s: missing title", a.ID)
	}
	if err := validateEnums(a.Kind, a.Risk, a.Output.Parser); err != nil {
		return fmt.Errorf("action %s: %w", a.ID, err)
	}
	if a.Description == "" {
		return fmt.Errorf("action %s: missing description", a.ID)
	}
	if len(a.SideEffects) == 0 {
		return fmt.Errorf("action %s: missing side_effects", a.ID)
	}
	if a.Execution.Timeout <= 0 {
		return fmt.Errorf("action %s: execution.timeout must be > 0", a.ID)
	}
	if err := validateTimeoutBounds(a); err != nil {
		return err
	}
	if err := validateSuccessExitCodes(a); err != nil {
		return err
	}
	if a.Output.MaxStdoutBytes <= 0 {
		return fmt.Errorf("action %s: output.max_stdout_bytes must be > 0", a.ID)
	}
	if a.Output.MaxStderrBytes <= 0 {
		return fmt.Errorf("action %s: output.max_stderr_bytes must be > 0", a.ID)
	}
	if err := validateOutputBounds(a); err != nil {
		return err
	}
	switch a.Kind {
	case KindExec:
		if a.Execution.Command == nil {
			return fmt.Errorf("action %s: exec kind requires execution.command", a.ID)
		}
		if a.Execution.Command.Binary == "" {
			return fmt.Errorf("action %s: execution.command.binary required", a.ID)
		}
		if a.Execution.Script != nil {
			return fmt.Errorf("action %s: exec kind must not set execution.script", a.ID)
		}
	case KindScript:
		if a.Execution.Script == nil {
			return fmt.Errorf("action %s: script kind requires execution.script", a.ID)
		}
		if a.Execution.Script.Path == "" {
			return fmt.Errorf("action %s: execution.script.path required", a.ID)
		}
		if a.Execution.Command != nil {
			return fmt.Errorf("action %s: script kind must not set execution.command", a.ID)
		}
	}
	seen := make(map[string]struct{}, len(a.Args))
	for i := range a.Args {
		if err := a.Args[i].Validate(); err != nil {
			return fmt.Errorf("action %s: %w", a.ID, err)
		}
		if _, reserved := reservedArgNames[a.Args[i].Name]; reserved {
			return fmt.Errorf("action %s: arg %q is a reserved control-plane field (one of action_id/reason/runner/runners/wait/idempotency_key) and would be stripped before reaching the runner; rename it", a.ID, a.Args[i].Name)
		}
		if _, dup := seen[a.Args[i].Name]; dup {
			return fmt.Errorf("action %s: duplicate arg %q", a.ID, a.Args[i].Name)
		}
		seen[a.Args[i].Name] = struct{}{}
	}
	for _, rr := range a.Output.Redact {
		if err := rr.Validate(); err != nil {
			return fmt.Errorf("action %s: %w", a.ID, err)
		}
	}
	if err := validateExecutionEnv(a); err != nil {
		return err
	}
	return nil
}

// validateExecutionEnv rejects environment variables a pack must not set:
// the dynamic-linker (LD_*/DYLD_*) and shell-startup (BASH_ENV) hijack
// vectors. The runner's job is to constrain WHAT runs, so even a trusted
// pack must not be able to LD_PRELOAD a library or BASH_ENV a script into
// the target process. A binary that genuinely needs extra libraries should
// get them from the system, not a per-action env injection. Matched
// case-sensitively — the loader only honors the canonical uppercase forms,
// so a lowercased variant would be inert anyway.
func validateExecutionEnv(a *Action) error {
	for k := range a.Execution.Env {
		if strings.HasPrefix(k, "LD_") || strings.HasPrefix(k, "DYLD_") || k == "BASH_ENV" {
			return fmt.Errorf("action %s: execution.env must not set %q (dynamic-linker/shell-init hijack vector)", a.ID, k)
		}
	}
	return nil
}

func validateTimeoutBounds(a *Action) error {
	t := a.Execution.Timeout
	tMin := a.Execution.TimeoutMin
	tMax := a.Execution.TimeoutMax
	if tMin == 0 {
		tMin = t
	}
	if tMax == 0 {
		tMax = t
	}
	if tMin > tMax {
		return fmt.Errorf("action %s: timeout_min > timeout_max", a.ID)
	}
	if t < tMin || t > tMax {
		return fmt.Errorf("action %s: timeout default %s outside [%s, %s]", a.ID, t, tMin, tMax)
	}
	return nil
}

// validateSuccessExitCodes enforces that any declared benign exit code is a
// real non-zero Unix exit status (1..255) and that the list has no duplicates.
// 0 is always success, so listing it is a mistake; a code outside 1..255 can
// never be returned by a process, so it would be dead config that hides a typo.
func validateSuccessExitCodes(a *Action) error {
	seen := make(map[int]struct{}, len(a.Execution.SuccessExitCodes))
	for _, code := range a.Execution.SuccessExitCodes {
		if code < 1 || code > 255 {
			return fmt.Errorf("action %s: execution.success_exit_codes %d out of range (must be 1..255; 0 is always success)", a.ID, code)
		}
		if _, dup := seen[code]; dup {
			return fmt.Errorf("action %s: execution.success_exit_codes has duplicate %d", a.ID, code)
		}
		seen[code] = struct{}{}
	}
	return nil
}

func validateOutputBounds(a *Action) error {
	check := func(field string, def, lo, hi int) error {
		if lo == 0 {
			lo = def
		}
		if hi == 0 {
			hi = def
		}
		if lo > hi {
			return fmt.Errorf("action %s: %s_min > %s_max", a.ID, field, field)
		}
		if def < lo || def > hi {
			return fmt.Errorf("action %s: %s default %d outside [%d, %d]", a.ID, field, def, lo, hi)
		}
		return nil
	}
	if err := check("max_stdout_bytes", a.Output.MaxStdoutBytes, a.Output.MaxStdoutBytesMin, a.Output.MaxStdoutBytesMax); err != nil {
		return err
	}
	return check("max_stderr_bytes", a.Output.MaxStderrBytes, a.Output.MaxStderrBytesMin, a.Output.MaxStderrBytesMax)
}

// validActionID enforces the convention "<ns>.<name>" with optional extra
// dot-separated namespaces (e.g. "myorg.cassandra.nodetool_status"). Each
// segment matches [a-z][a-z0-9_-]*.
func validActionID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	segments := 0
	start := 0
	for i := 0; i <= len(id); i++ {
		if i == len(id) || id[i] == '.' {
			if i == start {
				return false
			}
			seg := id[start:i]
			if !validIDSegment(seg) {
				return false
			}
			segments++
			start = i + 1
		}
	}
	return segments >= 2
}

func validIDSegment(s string) bool {
	if s == "" {
		return false
	}
	first := s[0]
	if !(first >= 'a' && first <= 'z') {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9':
		case c == '_' || c == '-':
		default:
			return false
		}
	}
	return true
}

// Validate checks that a redaction rule has the fields required by its type.
func (r RedactionRule) Validate() error {
	if r.Name == "" {
		return fmt.Errorf("redaction rule: missing name")
	}
	switch r.Type {
	case "regex":
		if r.Pattern == "" {
			return fmt.Errorf("redaction rule %s: regex requires pattern", r.Name)
		}
		// Compile here so an uncompilable redaction pattern fails `pack
		// validate` at authoring time. Otherwise the action loads, then at
		// runtime the combined redactor's CompileAll fails and silently falls
		// back to the global rules only — dropping this rule and leaking the
		// exact output it was meant to mask (fail-open). Fail closed instead.
		if _, err := regexp.Compile(r.Pattern); err != nil {
			return fmt.Errorf("redaction rule %s: invalid pattern %q: %w", r.Name, r.Pattern, err)
		}
	case "literal":
		if r.Literal == "" {
			return fmt.Errorf("redaction rule %s: literal requires literal", r.Name)
		}
	default:
		return fmt.Errorf("redaction rule %s: invalid type %q", r.Name, r.Type)
	}
	return nil
}
