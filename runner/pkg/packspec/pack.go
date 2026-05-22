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
// The runner records these and ships them to cloud in the agent_state
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
