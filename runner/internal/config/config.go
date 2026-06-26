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
	Signing   Signing   `yaml:"signing,omitempty"`
	Events    Events    `yaml:"events"`
	Redaction Redaction `yaml:"redaction"`
}

// Signing is the client-attested-dispatch gate: the strongest defense against
// a compromised control plane. When enforce_signatures is on, the runner runs a
// dispatch ONLY if it carries a valid Ed25519 attestation whose leaf key is
// vouched for by a certificate signed by one of the trusted CAs — so the cloud
// can relay a real user's MCP-signed action but can never originate one itself.
// The runner ALSO advertises this to the cloud, which then disables its own
// (operator/runbook) dispatch to this runner.
//
// The runner-target binding is the cert's SCOPE, asserted by the OFFLINE CA and
// matched only against this runner's local runner.group/runner.labels — never a
// value the control plane supplies. Trusting one CA instead of every leaf key
// makes onboarding an operator one signature and zero runner-config edits; a
// scoped cert gives redirect protection, an empty-scope cert is the explicit
// weaker "valid on any runner that trusts the CA" mode.
type Signing struct {
	EnforceSignatures bool        `yaml:"enforce_signatures,omitempty"`
	TrustedCAs        []TrustedCA `yaml:"trusted_cas,omitempty"`
	// MaxAttestationAge bounds how far in the past (or future, for clock skew)
	// a signed dispatch's issued_at may be — it caps replay exposure and the
	// nonce cache. A dispatch queued while the runner was offline longer than
	// this is refused as stale and must be re-issued. Defaults to 24h. This is
	// INDEPENDENT of the cert's own validity window: a long cert TTL must never
	// widen the replay window.
	MaxAttestationAge actionspec.Duration `yaml:"max_attestation_age,omitempty"`
}

// TrustedCA is one Ed25519 certificate-authority public key the runner trusts.
// The offline CA signs short-lived certs that vouch for leaf signing keys; the
// runner verifies the cert under ca_id's public_key, then verifies the
// attestation under the leaf key the cert carries. public_key is hex-encoded
// (64 chars / 32 bytes); ca_id is a stable label the cert echoes so the runner
// knows which CA to check. The CA PRIVATE key stays offline/customer-held and
// never touches the runner or the portal.
type TrustedCA struct {
	CAID      string `yaml:"ca_id"`
	PublicKey string `yaml:"public_key"`
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
		// The bootstrap auth key must never reach a child process's environment
		// (readable via /proc/<pid>/environ, crash dumps, child logs). Refuse an
		// inherit_env that would leak it into every action the runner spawns.
		for _, name := range c.Execution.InheritEnv {
			if name == c.Cloud.AuthKeyEnv {
				return fmt.Errorf(
					"config: execution.inherit_env must not include the auth key var %q — "+
						"it would leak the bootstrap secret into every action's environment",
					name,
				)
			}
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
	if err := c.validateSigning(); err != nil {
		return err
	}
	for i := range c.Redaction.Rules {
		if err := c.Redaction.Rules[i].Validate(); err != nil {
			return fmt.Errorf("config: redaction[%d]: %w", i, err)
		}
	}
	return nil
}

// validateSigning checks the client-attested-dispatch config. enforce_signatures
// with no trusted_cas is a footgun — the runner would refuse EVERY dispatch — so
// it's rejected. CA ids must be present and unique; the public-key bytes are
// parsed and length-checked when the verifier is built at connect.
func (c *Config) validateSigning() error {
	if c.Signing.EnforceSignatures && len(c.Signing.TrustedCAs) == 0 {
		return fmt.Errorf(
			"config: signing.enforce_signatures is on but signing.trusted_cas is empty — " +
				"the runner would refuse every dispatch")
	}
	seen := make(map[string]bool, len(c.Signing.TrustedCAs))
	for i, ca := range c.Signing.TrustedCAs {
		if strings.TrimSpace(ca.CAID) == "" {
			return fmt.Errorf("config: signing.trusted_cas[%d].ca_id required", i)
		}
		if seen[ca.CAID] {
			return fmt.Errorf("config: signing.trusted_cas has duplicate ca_id %q", ca.CAID)
		}
		seen[ca.CAID] = true
		if strings.TrimSpace(ca.PublicKey) == "" {
			return fmt.Errorf("config: signing.trusted_cas[%d].public_key required", i)
		}
	}
	if c.Signing.MaxAttestationAge <= 0 {
		c.Signing.MaxAttestationAge = actionspec.Duration(86_400e9) // 24h
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
	if err := CheckEndpointScheme(c.Cloud.URL, c.Cloud.AllowInsecure); err != nil {
		// Cleartext to the cloud sends the runner auth key in plaintext.
		return fmt.Errorf("config: cloud.url %w (set cloud.allow_insecure: true to override)", err)
	}
	return nil
}

// CheckEndpointScheme rejects a cleartext (http/ws) URL to a non-loopback host —
// it exposes whatever the runner sends and invites MITM. https/wss pass; an
// unknown scheme is left for the dialer to reject; loopback passes (local dev);
// any other insecure host needs an explicit allowInsecure opt-in. Shared by
// cloud.url validation and the pack fetch — a MITM must not be able to serve
// poisoned pack bytes over plain http (the pack hash is re-verified, so this is
// defense-in-depth).
func CheckEndpointScheme(rawURL string, allowInsecure bool) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return fmt.Errorf("%q is not a valid URL: %w", rawURL, err)
	}
	if u.Scheme != "http" && u.Scheme != "ws" {
		return nil
	}
	if allowInsecure || isLoopbackHost(u.Hostname()) {
		return nil
	}
	return fmt.Errorf("%q uses cleartext %s to a non-loopback host; use https", rawURL, u.Scheme)
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
