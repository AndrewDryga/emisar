// Package config loads and validates the runner configuration file.
package config

import (
	"fmt"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// SchemaVersion is the currently supported config schema version.
const SchemaVersion = 1

// Config is the on-disk runner configuration. The runner has no HTTP
// listener; all commands arrive over an outbound websocket to the control
// plane.
type Config struct {
	SchemaVersion int `yaml:"schema_version"`

	Runner     Runner     `yaml:"runner"`
	Cloud     Cloud     `yaml:"cloud"`
	Paths     Paths     `yaml:"paths"`
	Execution Execution `yaml:"execution"`
	Events    Events    `yaml:"events"`
	Redaction Redaction `yaml:"redaction"`
}

// Runner describes this runner's identity.
//
// Group is the primary categorization label the runner advertises to
// cloud. Cloud uses it to bucket runners in the UI without operator
// configuration (e.g., "all runners in group cassandra-us-east1").
type Runner struct {
	ID     string            `yaml:"id"`
	Group  string            `yaml:"group"`
	Labels map[string]string `yaml:"labels,omitempty"`
}

// Cloud configures the outbound websocket connection.
type Cloud struct {
	URL            string              `yaml:"url"`
	AuthKeyEnv     string              `yaml:"auth_key_env"`
	TokenPath      string              `yaml:"token_path,omitempty"`
	HeartbeatEvery actionspec.Duration `yaml:"heartbeat_every,omitempty"`
	ReconnectMin   actionspec.Duration `yaml:"reconnect_min,omitempty"`
	ReconnectMax   actionspec.Duration `yaml:"reconnect_max,omitempty"`
}

// Paths configures filesystem locations.
type Paths struct {
	DataDir string   `yaml:"data_dir"`
	WorkDir string   `yaml:"work_dir,omitempty"`
	Packs   []string `yaml:"packs"`
}

// Execution sets default execution behaviour (per-action limits are still
// the source of truth; this is for the inherited-env allowlist and similar
// global knobs).
type Execution struct {
	InheritEnv []string `yaml:"inherit_env,omitempty"`
	// CancelGrace is the SIGTERM->SIGKILL window applied when an action
	// is cancelled (via cloud `cancel` or by the action's own timeout).
	// Defaults to 30s.
	CancelGrace actionspec.Duration `yaml:"cancel_grace,omitempty"`
}

// Events configures the local JSONL journal and ack cursor.
type Events struct {
	JSONLPath       string `yaml:"jsonl_path"`
	MaxPreviewBytes int    `yaml:"max_preview_bytes,omitempty"`
	// CursorPath is the sidecar file recording which event IDs the
	// cloud has acknowledged. Defaults to "<JSONLPath>.cursor" if empty.
	CursorPath string `yaml:"cursor_path,omitempty"`
	// MaxSizeBytes triggers JSONL rotation when the active file
	// reaches this size. Zero disables rotation. Default 100 MiB.
	MaxSizeBytes int64 `yaml:"max_size_bytes,omitempty"`
	// MaxBackups is how many rotated files to keep (.1 .. .N). Default 5.
	MaxBackups int `yaml:"max_backups,omitempty"`
}

// Redaction holds global redaction rules applied to every action's output.
type Redaction struct {
	Rules []actionspec.RedactionRule `yaml:"rules,omitempty"`
}

// Validate normalises and checks the config.
func (c *Config) Validate() error {
	if c.SchemaVersion != SchemaVersion {
		return fmt.Errorf("config: unsupported schema_version %d (want %d)", c.SchemaVersion, SchemaVersion)
	}
	if c.Runner.Group == "" {
		return fmt.Errorf("config: runner.group required")
	}
	// runner.id is allowed to be empty at first start — cloud will assign one
	// when the auth_key is exchanged. Operators who want a stable id can set
	// it manually.
	if c.Cloud.URL == "" {
		// Permitted: developer using only CLI subcommands locally.
	} else if c.Cloud.AuthKeyEnv == "" {
		return fmt.Errorf("config: cloud.auth_key_env required when cloud.url is set")
	}
	if c.Cloud.HeartbeatEvery <= 0 {
		c.Cloud.HeartbeatEvery = actionspec.Duration(30e9) // 30s
	}
	if c.Execution.CancelGrace <= 0 {
		c.Execution.CancelGrace = actionspec.Duration(30e9) // 30s
	}
	if c.Cloud.ReconnectMin <= 0 {
		c.Cloud.ReconnectMin = actionspec.Duration(1e9) // 1s
	}
	if c.Cloud.ReconnectMax <= 0 {
		c.Cloud.ReconnectMax = actionspec.Duration(60e9) // 60s
	}
	if len(c.Paths.Packs) == 0 {
		c.Paths.Packs = []string{"/etc/emisar/packs"}
	}
	if c.Events.JSONLPath == "" {
		return fmt.Errorf("config: events.jsonl_path required")
	}
	if c.Events.MaxPreviewBytes <= 0 {
		c.Events.MaxPreviewBytes = 4096
	}
	if c.Events.CursorPath == "" {
		c.Events.CursorPath = c.Events.JSONLPath + ".cursor"
	}
	if c.Events.MaxSizeBytes == 0 {
		c.Events.MaxSizeBytes = 100 * 1024 * 1024 // 100 MiB
	}
	if c.Events.MaxBackups == 0 {
		c.Events.MaxBackups = 5
	}
	for i := range c.Redaction.Rules {
		if err := c.Redaction.Rules[i].Validate(); err != nil {
			return fmt.Errorf("config: redaction[%d]: %w", i, err)
		}
	}
	return nil
}
