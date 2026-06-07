// Package config loads and validates the runner configuration file.
package config

import (
	"fmt"
	"net"
	"net/url"
	"strings"

	"github.com/andrewdryga/emisar/runner/pkg/actionspec"
)

// SchemaVersion is the currently supported config schema version.
const SchemaVersion = 1

// Config is the on-disk runner configuration. The runner has no HTTP
// listener; all commands arrive over an outbound websocket to the control
// plane.
type Config struct {
	SchemaVersion int `yaml:"schema_version"`

	Runner    Runner    `yaml:"runner"`
	Cloud     Cloud     `yaml:"cloud"`
	Paths     Paths     `yaml:"paths"`
	Execution Execution `yaml:"execution"`
	Admission Admission `yaml:"admission,omitempty"`
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
	URL        string `yaml:"url"`
	AuthKeyEnv string `yaml:"auth_key_env"`
	// AllowInsecure opts in to a cleartext (http/ws) control-plane URL on
	// a non-loopback host. Off by default: plaintext transmits the runner
	// auth key in the clear, so it's only permitted for loopback dev or
	// when an operator explicitly accepts the risk.
	AllowInsecure  bool                `yaml:"allow_insecure,omitempty"`
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

// Admission is the local action allowlist / denylist. Defense-in-depth
// on top of cloud policy: a compromised control plane can ask the
// runner to execute any action, but admission decides what this host
// will actually permit. Both lists accept shell-style globs over action
// ids (e.g. `cassandra.*`, `*.restart`).
//
//   - Empty allow + empty deny → admit everything (default).
//   - Non-empty allow → action id MUST match at least one allow entry.
//   - Non-empty deny → action id MUST NOT match any deny entry.
//   - Both → allow gate first, then deny gate.
//
// Blocked actions are also hidden from the catalog this runner
// advertises to cloud, so they don't appear in the portal at all.
type Admission struct {
	Allow []string `yaml:"allow,omitempty"`
	Deny  []string `yaml:"deny,omitempty"`
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
	} else {
		if c.Cloud.AuthKeyEnv == "" {
			return fmt.Errorf("config: cloud.auth_key_env required when cloud.url is set")
		}
		if err := c.validateCloudTransportSecurity(); err != nil {
			return err
		}
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

// validateCloudTransportSecurity refuses a cleartext (http/ws) control-
// plane URL to a non-loopback host: the runner sends its auth key and
// per-runner token over that channel, so plaintext to a real host exposes
// credentials and invites MITM command injection. Loopback is allowed for
// local development; any other insecure endpoint requires an explicit
// cloud.allow_insecure opt-in so it can never happen by accident in prod.
func (c *Config) validateCloudTransportSecurity() error {
	u, err := url.Parse(c.Cloud.URL)
	if err != nil {
		return fmt.Errorf("config: cloud.url %q is not a valid URL: %w", c.Cloud.URL, err)
	}
	if u.Scheme != "http" && u.Scheme != "ws" {
		return nil // https/wss are fine; an unknown scheme is rejected at dial.
	}
	if c.Cloud.AllowInsecure || isLoopbackHost(u.Hostname()) {
		return nil
	}
	return fmt.Errorf(
		"config: cloud.url %q uses cleartext %s to a non-loopback host, which sends the runner auth key in plaintext; use https/wss, or set cloud.allow_insecure: true to override",
		c.Cloud.URL, u.Scheme)
}

// isLoopbackHost reports whether host is localhost or a loopback IP, the
// only place cleartext cloud transport is safe without an explicit opt-in.
func isLoopbackHost(host string) bool {
	// DNS is case-insensitive, so accept any casing of localhost.
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
