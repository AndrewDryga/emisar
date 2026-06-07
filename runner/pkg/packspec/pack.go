// Package packspec defines the on-disk schema for an emisar action pack.
package packspec

import (
	"fmt"
	"runtime"
)

// SchemaVersion is the currently supported pack schema version.
const SchemaVersion = 1

// Pack is the on-disk pack.yaml manifest. It references action and runbook
// YAML files relative to the pack root.
type Pack struct {
	SchemaVersion int    `yaml:"schema_version"`
	ID            string `yaml:"id"`
	Name          string `yaml:"name"`
	Version       string `yaml:"version"`
	Description   string `yaml:"description"`
	Vendor        string `yaml:"vendor,omitempty"`
	Homepage      string `yaml:"homepage,omitempty"`

	Requires Requirements `yaml:"requires,omitempty"`

	// Detect describes how `emisar pack suggest` recognizes that this
	// pack's target service is present on a host. Optional: when omitted,
	// the suggester derives a signal from Requires.Binaries (minus
	// ubiquitous helpers, server-side).
	Detect Detect `yaml:"detect,omitempty"`

	// Setup documents what an operator must do on the runner host before
	// this pack's actions can work — chiefly the environment variables its
	// tools read to authenticate. Surfaced by `emisar pack install` and
	// `emisar pack info`. Optional: packs that act only on the local host
	// can omit it or set just a summary.
	Setup Setup `yaml:"setup,omitempty"`

	Actions []string `yaml:"actions,omitempty"`

	// AllowSymlinks lets the pack include symlinks for action YAML and
	// script files. Default false: any symlinked path resolves outside
	// the pack root and the loader rejects it, even if the lexical path
	// looked contained. Set to true only for packs you trust to manage
	// their own symlink hygiene.
	AllowSymlinks bool `yaml:"allow_symlinks,omitempty"`

	// Root is the absolute path to the pack directory. Set by the loader.
	Root string `yaml:"-"`
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
	OS       []string `yaml:"os,omitempty"`
	Binaries []string `yaml:"binaries,omitempty"`
}

// Detect is the service-presence signal for `emisar pack suggest`. It is
// deliberately separate from Requirements (the tools the pack's actions
// USE to run): a pack can drive a service over its HTTP API with curl yet
// only be detectable by the service's own process or a listening port.
// The three signals are OR'd — any hit means "this service is here" — so a
// service-API pack like grafana lists its server process / port here while
// leaving curl in Requires. A pack about a remote service (a cloud API)
// declares no Detect, and is therefore never auto-suggested.
type Detect struct {
	// Binaries specific to the service (not generic helpers like curl).
	Binaries []string `yaml:"binaries,omitempty"`
	// Processes are executable names that, when running, indicate the
	// service is present (e.g. "grafana-server").
	Processes []string `yaml:"processes,omitempty"`
	// Ports are TCP ports that, when listened on, indicate the service
	// (e.g. 3000 for Grafana, 9090 for Prometheus).
	Ports []int `yaml:"ports,omitempty"`
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
	Summary string `yaml:"summary,omitempty"`
	// Env is the environment variables the pack's tool reads. Each must
	// also be added to the runner's inherit_env to reach the process.
	Env []EnvVar `yaml:"env,omitempty"`
	// Notes are extra setup caveats (file-based auth alternatives,
	// required privileges, group membership, …) as scannable bullets.
	Notes []string `yaml:"notes,omitempty"`
	// Verify is the id of a low-risk read action an operator can run to
	// confirm the pack can reach and authenticate to its target. Checked
	// at load time to be one of the pack's own actions.
	Verify string `yaml:"verify,omitempty"`
}

// EnvVar documents one environment variable a pack's tool reads to find or
// authenticate to its target.
type EnvVar struct {
	Name        string `yaml:"name"`
	Required    bool   `yaml:"required,omitempty"`
	Description string `yaml:"description,omitempty"`
	Default     string `yaml:"default,omitempty"`
	Example     string `yaml:"example,omitempty"`
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
	return nil
}

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
