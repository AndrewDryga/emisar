package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/andrewdryga/emisar/runner/internal/admission"
	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// runtime is the live in-memory wiring of one emisar process.
type runtime struct {
	cfg        *config.Config
	externalID string
	journal    *audit.Journal
	engine     *engine.Engine
	admission  *admission.Policy
}

func (r *runtime) ensureExternalID() (string, error) {
	if r.externalID != "" {
		return r.externalID, nil
	}
	id, err := resolveExternalID(r.cfg.Runner.ID, r.cfg.Paths.DataDir)
	if err != nil {
		return "", err
	}
	r.externalID = id
	r.journal.SetAgentID(id)
	return id, nil
}

// registry returns the current pack registry from the engine. After a
// SIGHUP reload, this reflects the new registry.
func (r *runtime) registry() *packs.Registry { return r.engine.Registry() }

// defaultConfigPaths lists where emisar looks for config.yaml when
// --config isn't given, in priority order: the canonical install
// location first, then a per-user XDG path.
func defaultConfigPaths() []string {
	paths := []string{"/etc/emisar/config.yaml"}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		paths = append(paths, filepath.Join(home, ".config", "emisar", "config.yaml"))
	}
	return paths
}

// resolveConfigPath decides which config.yaml to load so operators don't
// have to pass --config on every command. Precedence: the explicit
// --config flag, then $EMISAR_CONFIG, then the first well-known location
// that exists. An explicit flag/env value is returned as-is (config.Load
// reports if it's unreadable); auto-discovered paths must exist to win.
func resolveConfigPath() (string, error) {
	if flagConfig != "" {
		return flagConfig, nil
	}
	if env := os.Getenv("EMISAR_CONFIG"); env != "" {
		return env, nil
	}
	for _, p := range defaultConfigPaths() {
		if isRegularFile(p) {
			return p, nil
		}
	}
	return "", fmt.Errorf(
		"no config found — looked in $EMISAR_CONFIG and %s; pass --config <path>",
		strings.Join(defaultConfigPaths(), ", "),
	)
}

func isRegularFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func loadConfig() (*config.Config, error) {
	cfgPath, err := resolveConfigPath()
	if err != nil {
		return nil, err
	}
	return config.Load(cfgPath)
}

func loadRegistry(cfg *config.Config) (*packs.Registry, []string, error) {
	packDirs := cfg.Paths.Packs
	if len(flagPacksDir) > 0 {
		packDirs = flagPacksDir
	}
	registry, err := packs.LoadAll(packDirs, packs.LoadOptions{})
	return registry, packDirs, err
}

// boot loads config, packs, and the JSONL journal, then constructs the
// action engine. CLI subcommands call this and use whichever fields they
// need.
func boot() (*runtime, error) {
	cfg, err := loadConfig()
	if err != nil {
		return nil, err
	}
	return bootWithConfig(cfg)
}

func bootWithConfig(cfg *config.Config) (*runtime, error) {
	registry, packDirs, err := loadRegistry(cfg)
	if err != nil {
		return nil, err
	}

	jsonlSink, err := audit.OpenJSONL(cfg.Events.JSONLPath, audit.JSONLOptions{
		MaxSizeBytes: cfg.Events.MaxSizeBytes,
		MaxBackups:   cfg.Events.MaxBackups,
	})
	if err != nil {
		return nil, err
	}
	journal := audit.New(audit.Defaults{
		AgentID: cfg.Runner.ID,
		Group:   cfg.Runner.Group,
	}, jsonlSink)
	globalRules, err := redact.CompileAll(redact.DefaultRules(), cfg.Redaction.Rules)
	if err != nil {
		return nil, err
	}

	// Operator inherit_env extends the always-on defaults (PATH, locale) — it
	// does not replace them, so adding e.g. NOMAD_TOKEN can't drop PATH and
	// break binary resolution.
	exec := executor.New()
	exec.AllowInheritEnv(cfg.Execution.InheritEnv...)

	admit, err := admission.New(cfg.Admission.Allow, cfg.Admission.Deny, cfg.Admission.MaxRisk)
	if err != nil {
		return nil, fmt.Errorf("admission: %w", err)
	}

	eng := engine.New(engine.Config{
		Registry:     registry,
		Executor:     exec,
		Journal:      journal,
		Redactor:     redact.New(globalRules),
		PreviewBytes: cfg.Events.MaxPreviewBytes,
		CancelGrace:  cfg.Execution.CancelGrace.Std(),
		PackDirs:     packDirs,
		Admission:    admit,
	})

	return &runtime{
		cfg:        cfg,
		externalID: cfg.Runner.ID,
		journal:    journal,
		engine:     eng,
		admission:  admit,
	}, nil
}

// parseArgFlag turns a list of "key=value" flags into a typed map. JSON-ish
// literals (true/false/null/numbers/arrays/objects) are decoded; otherwise
// the value is kept as a string.
func parseArgFlag(pairs []string) (map[string]any, error) {
	out := make(map[string]any, len(pairs))
	for _, p := range pairs {
		i := strings.IndexByte(p, '=')
		if i < 0 {
			return nil, fmt.Errorf("--arg %q must be key=value", p)
		}
		key, raw := p[:i], p[i+1:]
		out[key] = coerceArgValue(raw)
	}
	return out, nil
}

func coerceArgValue(raw string) any {
	if raw == "" {
		return ""
	}
	switch raw {
	case "true":
		return true
	case "false":
		return false
	case "null":
		return nil
	}
	if n, err := strconv.ParseInt(raw, 10, 64); err == nil {
		return n
	}
	if f, err := strconv.ParseFloat(raw, 64); err == nil {
		return f
	}
	switch raw[0] {
	case '[', '{':
		var v any
		if err := json.Unmarshal([]byte(raw), &v); err == nil {
			return v
		}
	}
	return raw
}

func printJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func banner(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}
