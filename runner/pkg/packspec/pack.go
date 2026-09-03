// Package packspec defines the on-disk schema for an emisar action pack.
package packspec

import (
	"fmt"
	"runtime"
	"strings"
	"unicode"
	"unicode/utf8"
)

// SchemaVersion is the currently supported pack schema version.
const SchemaVersion = 1

// Pack is the on-disk pack.yaml manifest. It references action and runbook
// YAML files relative to the pack root.
//
// The json tags mirror the on-disk names so `emisar pack list/info --json`
// emits one snake_case document a fleet script can parse. Root is a
// loader-stamped host path and stays out of the payload.
type Pack struct {
	SchemaVersion int    `yaml:"schema_version" json:"schema_version"`
	ID            string `yaml:"id" json:"id"`
	Name          string `yaml:"name" json:"name"`
	Version       string `yaml:"version" json:"version"`
	Description   string `yaml:"description" json:"description"`
	Vendor        string `yaml:"vendor,omitempty" json:"vendor,omitempty"`
	Homepage      string `yaml:"homepage,omitempty" json:"homepage,omitempty"`

	// RetiredBelow declares that every version of this pack STRICTLY below it
	// is retired: a runner still advertising such a version is refused at
	// dispatch until the operator updates the pack. Author it (dot-numeric,
	// e.g. "0.2.4") in the SAME commit that ships a critical fix + version
	// bump, so the retirement floor lives in the pack's own git history and
	// ships through the normal publish. Retirement is permanent and monotonic:
	// the registry build refuses to lower or drop an already-published floor.
	RetiredBelow string `yaml:"retired_below,omitempty" json:"retired_below,omitempty"`

	Requires Requirements `yaml:"requires,omitempty" json:"requires"`

	// Detect describes how `emisar pack suggest` recognizes that this
	// pack's target service is present on a host. Optional: when omitted,
	// the pack is not auto-suggested from host discovery. Requirements are
	// runtime prerequisites, not evidence that the target exists here.
	Detect Detect `yaml:"detect,omitempty" json:"detect"`

	// Setup documents what an operator must do on the runner host before
	// this pack's actions can work — chiefly the environment variables its
	// tools read to authenticate. Surfaced by `emisar pack install` and
	// `emisar pack info`. Optional: packs that act only on the local host
	// can omit it or set just a summary.
	Setup Setup `yaml:"setup,omitempty" json:"setup"`

	Actions []string `yaml:"actions,omitempty" json:"actions,omitempty"`

	// AllowSymlinks lets the pack include symlinks for action YAML and
	// script files. Default false: any symlinked path resolves outside
	// the pack root and the loader rejects it, even if the lexical path
	// looked contained. Set to true only for packs you trust to manage
	// their own symlink hygiene.
	AllowSymlinks bool `yaml:"allow_symlinks,omitempty" json:"allow_symlinks,omitempty"`

	// Root is the absolute path to the pack directory. Set by the loader.
	Root string `yaml:"-" json:"-"`
}

// Requirements describes optional host requirements declared by a pack.
// The runner records these and ships them to cloud in the runner_state
// advertisement, but does not enforce them at load time:
//
//   - OS mismatch is surfaced via cloud-side fleet filtering (the cloud
//     catalog knows which runners declare which OS) rather than by
//     refusing to load the pack on the wrong OS.
//   - Binaries that aren't on PATH cause the action to fail at execution
//     time — a more useful signal than a load-time PATH check.
//
// MatchesHost is available for callers who want to filter packs by OS
// (e.g., a future pack catalog UI or a smoke-test command).
type Requirements struct {
	OS       []string `yaml:"os,omitempty" json:"os,omitempty"`
	Binaries []string `yaml:"binaries,omitempty" json:"binaries,omitempty"`
}

// Detect is the service-presence signal for `emisar pack suggest`. It is
// deliberately separate from Requirements (the tools the pack's actions
// USE to run): a pack can drive a service over its HTTP API with curl yet
// only be detectable by the service's own binary or process. Binaries and
// Processes name the service, so either one recommends the pack — a
// service-API pack like grafana lists its server process here while
// leaving curl in Requires. Ports only corroborate such a match: they name
// no owner, so declaring them alone never gets a pack auto-suggested. A
// pack about a remote service (a cloud API, a hardware BMC, a remote
// cluster) declares no Detect and requires only off-host client tools
// (curl, ipmitool, kubectl), so it is never auto-suggested either.
type Detect struct {
	// Binaries specific to the service (not generic helpers like curl).
	Binaries []string `yaml:"binaries,omitempty" json:"binaries,omitempty"`
	// Processes are executable names that, when running, indicate the
	// service is present (e.g. "grafana-server").
	Processes []string `yaml:"processes,omitempty" json:"processes,omitempty"`
	// Ports are TCP ports the service listens on (e.g. 3000 for Grafana,
	// 9090 for Prometheus). Corroboration for a pack a binary or process
	// already identified — never a match on their own.
	Ports []int `yaml:"ports,omitempty" json:"ports,omitempty"`
}

// validate checks the detect block is well-formed.
func (d Detect) validate(packID string) error {
	for _, p := range d.Ports {
		if p < 1 || p > 65535 {
			return fmt.Errorf("pack %s: detect.port %d out of range (1-65535)", packID, p)
		}
	}
	return nil
}

// MatchesHost reports whether the current runtime.GOOS is in the OS
// allowlist. An empty list matches any OS.
func (r Requirements) MatchesHost() bool {
	if len(r.OS) == 0 {
		return true
	}
	for _, os := range r.OS {
		if os == runtime.GOOS {
			return true
		}
	}
	return false
}

// Setup is the operator-facing "how to make this pack work" block. It is
// documentation, not enforced config: the runner never reads these env
// vars itself (the pack's tool does), and never injects them — the
// operator must still allowlist each one in the runner's inherit_env.
// `emisar pack install` and `emisar pack info` render it so an operator
// knows exactly what to provision.
type Setup struct {
	// Summary is one or two sentences on the auth model in prose, e.g.
	// "Authenticates via PG* environment variables on the runner host."
	Summary string `yaml:"summary,omitempty" json:"summary,omitempty"`
	// Env is the environment variables the pack's tool reads. Each must
	// also be added to the runner's inherit_env to reach the process.
	Env []EnvVar `yaml:"env,omitempty" json:"env,omitempty"`
	// Notes are extra setup caveats (file-based auth alternatives,
	// provider limitations, …) as scannable bullets. Host permissions live
	// in HostAccess so each grant is tied to the actions it authorizes.
	Notes []string `yaml:"notes,omitempty" json:"notes,omitempty"`
	// HostAccess documents exact, operator-run host permission recipes for
	// actions that cannot run under the runner's default service identity.
	// It is display-only metadata: Emisar never executes these commands.
	HostAccess []HostAccess `yaml:"host_access,omitempty" json:"host_access,omitempty"`
	// Verify is the id of a low-risk read action an operator can run to
	// confirm the pack can reach and authenticate to its target. Checked
	// at load time to be one of the pack's own actions.
	Verify string `yaml:"verify,omitempty" json:"verify,omitempty"`
}

// HostAccess groups actions that need the same host authority. Recipes may
// vary by operating system or service layout, but each must grant and verify
// the same requirement.
type HostAccess struct {
	Actions     []string           `yaml:"actions" json:"actions"`
	Requirement string             `yaml:"requirement" json:"requirement"`
	Recipes     []HostAccessRecipe `yaml:"recipes" json:"recipes"`
}

// HostAccessRecipe is a named, copyable setup path. Commands and Verify are
// preserved byte-for-byte through catalog publication; consumers render them
// as code and never interpolate or execute them.
type HostAccessRecipe struct {
	Name     string   `yaml:"name" json:"name"`
	Commands []string `yaml:"commands" json:"commands"`
	Verify   []string `yaml:"verify" json:"verify"`
	Impact   string   `yaml:"impact" json:"impact"`
}

// EnvVar documents one environment variable a pack's tool reads to find or
// authenticate to its target.
type EnvVar struct {
	Name        string `yaml:"name" json:"name"`
	Required    bool   `yaml:"required,omitempty" json:"required,omitempty"`
	Description string `yaml:"description,omitempty" json:"description,omitempty"`
	Default     string `yaml:"default,omitempty" json:"default,omitempty"`
	Example     string `yaml:"example,omitempty" json:"example,omitempty"`
}

// Validate checks the setup block is well-formed. Verify is validated by
// the loader (it needs the loaded action set), not here.
func (s Setup) Validate(packID string) error {
	seen := make(map[string]struct{}, len(s.Env))
	for _, e := range s.Env {
		if !validEnvName(e.Name) {
			return fmt.Errorf("pack %s: setup.env name %q is not a valid environment variable name", packID, e.Name)
		}
		if _, dup := seen[e.Name]; dup {
			return fmt.Errorf("pack %s: duplicate setup.env var %q", packID, e.Name)
		}
		seen[e.Name] = struct{}{}
	}

	actions := make(map[string]struct{})
	for groupIndex, access := range s.HostAccess {
		field := fmt.Sprintf("setup.host_access[%d]", groupIndex)
		if len(access.Actions) == 0 {
			return fmt.Errorf("pack %s: %s.actions must not be empty", packID, field)
		}
		for _, actionID := range access.Actions {
			if err := validateSetupText(field+".actions", actionID, false); err != nil {
				return fmt.Errorf("pack %s: %w", packID, err)
			}
			if _, duplicate := actions[actionID]; duplicate {
				return fmt.Errorf("pack %s: duplicate setup.host_access action %q", packID, actionID)
			}
			actions[actionID] = struct{}{}
		}
		if err := validateSetupText(field+".requirement", access.Requirement, true); err != nil {
			return fmt.Errorf("pack %s: %w", packID, err)
		}
		if len(access.Recipes) == 0 {
			return fmt.Errorf("pack %s: %s.recipes must not be empty", packID, field)
		}
		recipeNames := make(map[string]struct{}, len(access.Recipes))
		for recipeIndex, recipe := range access.Recipes {
			recipeField := fmt.Sprintf("%s.recipes[%d]", field, recipeIndex)
			if err := validateSetupText(recipeField+".name", recipe.Name, true); err != nil {
				return fmt.Errorf("pack %s: %w", packID, err)
			}
			normalizedName := strings.Join(strings.Fields(recipe.Name), " ")
			if _, duplicate := recipeNames[normalizedName]; duplicate {
				return fmt.Errorf("pack %s: %s has duplicate recipe name %q", packID, field, recipe.Name)
			}
			recipeNames[normalizedName] = struct{}{}
			if len(recipe.Commands) == 0 {
				return fmt.Errorf("pack %s: %s.commands must not be empty", packID, recipeField)
			}
			for _, command := range recipe.Commands {
				if err := validateSetupText(recipeField+".commands", command, false); err != nil {
					return fmt.Errorf("pack %s: %w", packID, err)
				}
			}
			if len(recipe.Verify) == 0 {
				return fmt.Errorf("pack %s: %s.verify must not be empty", packID, recipeField)
			}
			for _, command := range recipe.Verify {
				if err := validateSetupText(recipeField+".verify", command, false); err != nil {
					return fmt.Errorf("pack %s: %w", packID, err)
				}
			}
			if err := validateSetupText(recipeField+".impact", recipe.Impact, true); err != nil {
				return fmt.Errorf("pack %s: %w", packID, err)
			}
		}
	}
	return nil
}

func validateSetupText(field, value string, prose bool) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("%s must not be empty", field)
	}
	if !utf8.ValidString(value) {
		return fmt.Errorf("%s must be valid UTF-8", field)
	}
	for _, r := range value {
		allowedProseWhitespace := prose && (r == '\n' || r == '\r' || r == '\t')
		if !allowedProseWhitespace && (unicode.IsControl(r) || unicode.In(r, unicode.Cf)) {
			return fmt.Errorf("%s contains unsafe control character U+%04X", field, r)
		}
	}
	return nil
}

// ValidEnvName exposes the environment-variable name charset so an action's
// execution.env is held to the same shape as a pack's setup.env, rather than
// mirroring a copy that could drift.
func ValidEnvName(s string) bool { return validEnvName(s) }

// validEnvName reports whether s is a POSIX-shaped environment variable
// name (first char a letter or underscore, rest alphanumeric/underscore).
func validEnvName(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z':
		case c >= 'a' && c <= 'z':
		case c == '_':
		case c >= '0' && c <= '9' && i > 0:
		default:
			return false
		}
	}
	return true
}

// Validate checks that the pack manifest itself is well-formed.
func (p *Pack) Validate() error {
	if p.SchemaVersion != SchemaVersion {
		return fmt.Errorf("pack: unsupported schema_version %d (want %d)", p.SchemaVersion, SchemaVersion)
	}
	if p.ID == "" {
		return fmt.Errorf("pack: missing id")
	}
	if !validPackID(p.ID) {
		return fmt.Errorf("pack: invalid id %q (must match [a-z][a-z0-9-]{0,63})", p.ID)
	}
	if p.Name == "" {
		return fmt.Errorf("pack %s: missing name", p.ID)
	}
	if p.Version == "" {
		return fmt.Errorf("pack %s: missing version", p.ID)
	}
	if !validVersion(p.Version) {
		return fmt.Errorf("pack %s: invalid version %q (allowed: alphanumerics, dot, hyphen, plus)", p.ID, p.Version)
	}
	if p.RetiredBelow != "" && !validDotNumeric(p.RetiredBelow) {
		return fmt.Errorf("pack %s: retired_below %q must be a dot-numeric version (e.g. 0.2.4)", p.ID, p.RetiredBelow)
	}
	if p.Description == "" {
		return fmt.Errorf("pack %s: missing description", p.ID)
	}
	if len(p.Actions) == 0 {
		return fmt.Errorf("pack %s: must declare at least one action", p.ID)
	}
	if err := p.Setup.Validate(p.ID); err != nil {
		return err
	}
	if err := p.Detect.validate(p.ID); err != nil {
		return err
	}
	return nil
}

// ValidPackID and ValidVersion expose the pack-id and version charsets for
// the install CLI's pre-fetch validation of `name=version`, so it shares this
// exact boundary rather than mirroring a copy that could drift.
func ValidPackID(id string) bool { return validPackID(id) }

// ValidVersion reports whether v is within the safe pack-version charset.
func ValidVersion(v string) bool { return validVersion(v) }

// validVersion bounds the version to a safe charset. It flows into
// content-addressed object PATHS (catalog TarballObject) and filesystem writes,
// so a value like "1.0/../x" must never escape the output dir. Semver plus its
// pre-release/build metadata all fit within a leading alphanumeric followed by
// [A-Za-z0-9.+-]; anything with a slash or path segment is rejected.
func validVersion(v string) bool {
	if v == "" || len(v) > 64 {
		return false
	}
	for i := 0; i < len(v); i++ {
		c := v[i]
		alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		if i == 0 && !alnum {
			return false
		}
		if !alnum && c != '.' && c != '-' && c != '+' {
			return false
		}
	}
	return true
}

// validDotNumeric reports whether s is a dot-separated run of non-negative
// integers ("0.2.4") — the strict shape retirement comparisons require, so a
// version the ordering machinery can't compare never reaches it.
func validDotNumeric(s string) bool {
	if s == "" {
		return false
	}
	for _, seg := range strings.Split(s, ".") {
		if seg == "" {
			return false
		}
		for i := 0; i < len(seg); i++ {
			if seg[i] < '0' || seg[i] > '9' {
				return false
			}
		}
	}
	return true
}

// validPackID accepts simple ids ("cassandra") and dot-namespaced ones
// ("myorg.cassandra"). Each dot-separated segment is [a-z][a-z0-9_-]*.
func validPackID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	start := 0
	for i := 0; i <= len(id); i++ {
		if i == len(id) || id[i] == '.' {
			if i == start {
				return false
			}
			seg := id[start:i]
			if !validPackSegment(seg) {
				return false
			}
			start = i + 1
		}
	}
	return true
}

func validPackSegment(s string) bool {
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
