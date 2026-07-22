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
	if url := os.Getenv("EMISAR_URL"); url != "" {
		cfg.Cloud.URL = url
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
