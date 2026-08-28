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
	hostname   string
	externalID string
	journal    *audit.Journal
	engine     *engine.Engine
	admission  *admission.Policy
}

// registry returns the current pack registry from the engine. After a
// SIGHUP reload, this reflects the new registry.
func (r *runtime) registry() *packs.Registry { return r.engine.Registry() }

// defaultConfigPaths lists where emisar looks for config.yaml when --config
// isn't given, in priority order: the canonical install location first, then
// the per-user ones.
//
// os.UserConfigDir() comes first among those because it is what the platform
// actually means by "the user's config directory" — it honours
// $XDG_CONFIG_HOME on Unix and is ~/Library/Application Support on macOS, which
// is where emisar-mcp already writes. Hardcoding ~/.config called itself XDG
// while ignoring the one variable XDG defines, and on a Mac it meant one
// product writing one tree and reading another.
//
// The literal ~/.config path stays as a second candidate: it is where an
// existing config sits, and dropping a location a reader already finds would
// break those hosts for no gain. Deduplicated, since on Linux without
// $XDG_CONFIG_HOME the two are the same directory.
func defaultConfigPaths() []string {
	paths := []string{"/etc/emisar/config.yaml"}
	seen := map[string]bool{}

	add := func(dir string) {
		if dir == "" {
			return
		}
		path := filepath.Join(dir, "emisar", "config.yaml")
		if seen[path] {
			return
		}
		seen[path] = true
		paths = append(paths, path)
	}

	if dir, err := os.UserConfigDir(); err == nil {
		add(dir)
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		add(filepath.Join(home, ".config"))
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
	// The daemon degrades a broken installed pack instead of refusing to
	// boot: one unparseable pack file once crash-looped a production runner
	// 1,164 times, taking every healthy pack down with it. Callers surface
	// Registry.Degraded(); publisher/verification paths keep fail-fast.
	registry, err := packs.LoadAll(packDirs, packs.LoadOptions{SkipBrokenPacks: true})
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
	hostname, err := os.Hostname()
	if err != nil {
		return nil, fmt.Errorf("read hostname: %w", err)
	}
	externalID, err := resolveExternalID(cfg.Runner.ID, hostname)
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
		RunnerID: externalID,
		Group:    cfg.Runner.Group,
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
		Registry:       registry,
		Executor:       exec,
		Journal:        journal,
		Redactor:       redact.New(globalRules),
		PreviewBytes:   cfg.Events.MaxPreviewBytes,
		CancelGrace:    cfg.Execution.CancelGrace.Std(),
		PackDirs:       packDirs,
		Admission:      admit,
		ProtectedPaths: protectedPaths(cfg),
	})

	return &runtime{
		cfg:        cfg,
		hostname:   hostname,
		externalID: externalID,
		journal:    journal,
		engine:     eng,
		admission:  admit,
	}, nil
}

// protectedPaths lists the roots holding this runner's own credentials, which
// no action argument may name: the config directory — config.yaml sits beside
// runner.env, which carries the enrollment key and every pack credential the
// operator exported — and the state directory, which holds the control-plane
// bearer token. install.sh relocates both (--etc-dir, --data-dir), so they are
// read from the loaded config rather than hardcoded into a pack's denylist.
func protectedPaths(cfg *config.Config) []string {
	candidates := []string{cfg.Paths.DataDir}
	if cfg.Source != "" {
		candidates = append(candidates, filepath.Dir(cfg.Source))
	}
	if cfg.Cloud.TokenPath != "" {
		candidates = append(candidates, filepath.Dir(cfg.Cloud.TokenPath))
	}
	out := make([]string, 0, len(candidates))
	seen := make(map[string]struct{}, len(candidates))
	for _, p := range candidates {
		clean := filepath.Clean(strings.TrimSpace(p))
		// A relative root can't be compared against the absolute path the
		// executor uses, and "/" would refuse every path arg on the host
		// rather than the runner's own state. Neither is a real install.
		if !filepath.IsAbs(clean) || clean == string(filepath.Separator) {
			continue
		}
		if _, dup := seen[clean]; dup {
			continue
		}
		seen[clean] = struct{}{}
		out = append(out, clean)
	}
	return out
}

// parseArgFlag turns a list of "key=value" flags into a typed map. JSON
// literals are decoded; otherwise the value is kept as a string.
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
	case '"', '[', '{':
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
