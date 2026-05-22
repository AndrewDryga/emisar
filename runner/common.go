package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/andrewdryga/emisar/runner/internal/audit"
	"github.com/andrewdryga/emisar/runner/internal/config"
	"github.com/andrewdryga/emisar/runner/internal/engine"
	"github.com/andrewdryga/emisar/runner/internal/executor"
	"github.com/andrewdryga/emisar/runner/internal/packs"
	"github.com/andrewdryga/emisar/runner/internal/redact"
)

// runtime is the live in-memory wiring of one emisar process.
type runtime struct {
	cfg     *config.Config
	journal *audit.Journal
	cursor  *audit.Cursor
	engine  *engine.Engine
}

// registry returns the current pack registry from the engine. After a
// SIGHUP reload, this reflects the new registry.
func (r *runtime) registry() *packs.Registry { return r.engine.Registry() }

// boot loads config, packs, and the JSONL journal, then constructs the
// action engine. CLI subcommands call this and use whichever fields they
// need.
func boot() (*runtime, error) {
	if flagConfig == "" {
		return nil, fmt.Errorf("--config is required")
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return nil, err
	}

	packDirs := cfg.Paths.Packs
	if len(flagPacksDir) > 0 {
		packDirs = flagPacksDir
	}
	registry, err := packs.LoadAll(packDirs, packs.LoadOptions{})
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
	cursor, err := audit.OpenCursor(cfg.Events.CursorPath, 4096)
	if err != nil {
		return nil, err
	}

	globalRules, err := redact.CompileAll(redact.DefaultRules(), cfg.Redaction.Rules)
	if err != nil {
		return nil, err
	}

	exec := executor.New()
	if len(cfg.Execution.InheritEnv) > 0 {
		exec.InheritEnv = cfg.Execution.InheritEnv
	}

	eng := engine.New(engine.Config{
		Registry:     registry,
		Executor:     exec,
		Journal:      journal,
		Redactor:     redact.New(globalRules),
		PreviewBytes: cfg.Events.MaxPreviewBytes,
		CancelGrace:  cfg.Execution.CancelGrace.Std(),
		PackDirs:     packDirs,
	})

	return &runtime{
		cfg:     cfg,
		journal: journal,
		cursor:  cursor,
		engine:  eng,
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
