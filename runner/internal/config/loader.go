package config

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"go.yaml.in/yaml/v3"
)

// Load reads and validates a config file. Paths are resolved relative to
// the config file's directory so configs can use ./packs etc.
func Load(path string) (*Config, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("config: resolve %s: %w", path, err)
	}
	if err := checkConfigOwnership(abs); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return nil, fmt.Errorf("config: read %s: %w", abs, err)
	}
	var cfg Config
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("config: parse %s: %w", abs, err)
	}
	if err := decoder.Decode(&yaml.Node{}); err != io.EOF {
		if err == nil {
			err = fmt.Errorf("multiple YAML documents are not allowed")
		}
		return nil, fmt.Errorf("config: parse %s: %w", abs, err)
	}
	base := filepath.Dir(abs)
	for i, p := range cfg.Paths.Packs {
		cfg.Paths.Packs[i] = relocate(p, base)
	}
	cfg.Paths.DataDir = relocate(cfg.Paths.DataDir, base)
	cfg.Paths.WorkDir = relocate(cfg.Paths.WorkDir, base)
	cfg.Cloud.TokenPath = relocate(cfg.Cloud.TokenPath, base)
	cfg.Events.JSONLPath = relocate(cfg.Events.JSONLPath, base)

	// Env overrides. install.sh sets EMISAR_URL so the same baked-in
	// config can target dev / prod control planes without re-templating.
	// EMISAR_GROUP / EMISAR_RUNNER_ID relabel container fleets without
	// mounting a config file: the group is a dispatch-targeting input, so
	// unrelated fleets must not share the image's baked default, and a
	// DaemonSet pins the node name as the identity via fieldRef. Empty
	// values never blank a file value. Overrides land before Validate so
	// the effective values are the ones checked.
	if url := os.Getenv("EMISAR_URL"); url != "" {
		cfg.Cloud.URL = url
	}
	if group := os.Getenv("EMISAR_GROUP"); group != "" {
		cfg.Runner.Group = group
	}
	if id := os.Getenv("EMISAR_RUNNER_ID"); id != "" {
		cfg.Runner.ID = id
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// relocate resolves a possibly-relative path against base. Absolute paths
// are returned as-is.
func relocate(p, base string) string {
	if p == "" {
		return p
	}
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Clean(filepath.Join(base, p))
}

// checkConfigOwnership refuses a config file anyone other than its owner can
// write.
//
// This file decides `paths.packs` — which is to say what code the runner
// executes — plus `admission` and `signing.trusted_cas`. A group- or
// world-writable one hands all three to whoever holds that write bit, and
// `$EMISAR_CONFIG` is honoured wherever it points, so the file need not even be
// the one an operator installed. `readToken` already refuses a token file on
// the same grounds; the file that chooses the code is at least as load-bearing
// as the file that holds the credential.
//
// Ownership itself is checked on Unix only (Windows has no meaningful uid
// here), and a file owned by root is accepted whoever we are: root wrote it.
func checkConfigOwnership(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("config: stat %s: %w", path, err)
	}
	if perm := info.Mode().Perm(); perm&0o022 != 0 {
		return fmt.Errorf(
			"config: %s is writable by group or other (%#o); chmod go-w %s", path, perm, path)
	}
	return checkConfigOwner(info, path)
}
